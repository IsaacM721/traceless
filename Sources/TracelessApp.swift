import SwiftUI
import AppKit

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--cli") {
            exit(CLI.run(Array(args[(i + 1)...])))
        }
        TracelessApp.main()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct TracelessApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = AppStore()

    var body: some Scene {
        Window("Traceless", id: "main") {
            ContentView().environment(store)
        }
        .defaultSize(width: 1080, height: 700)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Rescan Applications") { Task { await store.load() } }
                    .keyboardShortcut("r")
            }
            CommandMenu("App") {
                Button("Uninstall…") { store.detail?.confirming = true }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(!(store.detail?.canUninstall ?? false))
                Button("Reveal in Finder") {
                    if let app = store.selectedApp { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(store.selectedApp == nil)
                Button("Restore Last Uninstall") { Task { await store.restoreLast() } }
                    .keyboardShortcut("z", modifiers: [.command, .shift, .option])
                Divider()
                Picker("Sort By", selection: Binding(get: { store.sort }, set: { store.sort = $0; store.applySort() })) {
                    ForEach(AppStore.Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            }
            CommandGroup(replacing: .help) {
                Button("Show Log") { NSWorkspace.shared.open(Log.shared.fileURL) }
                Button("Show Removal History") {
                    try? FileManager.default.createDirectory(at: Remover.historyDir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(Remover.historyDir)
                }
            }
        }
    }
}

/// Same engine from Terminal, for testing and logs:
///   Traceless --cli list
///   Traceless --cli scan "App Name"
///   Traceless --cli uninstall "App Name" --yes
enum CLI {
    static func run(_ args: [String]) -> Int32 {
        Log.shared.echo = true
        guard let command = args.first else {
            print("usage: Traceless --cli list | scan <name> | uninstall <name> --yes | restore <undo-record.json>")
            return 64
        }
        log("Traceless CLI '\(args.joined(separator: " "))' on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        let started = Date()
        let urls = AppScanner.discover()
        var apps = [InstalledApp?](repeating: nil, count: urls.count)
        apps.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: urls.count) { i in
                var app = AppScanner.describe(urls[i])
                app.size = AppScanner.appSize(of: urls[i])
                buffer[i] = app
            }
        }
        let list = apps.compactMap { $0 }.sorted { $0.size > $1.size }
        log("Measured \(list.count) apps in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")

        if command == "restore" {
            guard args.count >= 2, let data = try? Data(contentsOf: URL(fileURLWithPath: args[1])) else { print("Pass an undo record from \(Remover.historyDir.path)"); return 64 }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            guard let manifest = try? decoder.decode(RemovalManifest.self, from: data) else { print("That isn't a Traceless undo record."); return 65 }
            let notes = Remover.restore(manifest)
            print("Restored \(manifest.app).")
            notes.forEach { print("  ! \($0)") }
            return 0
        }
        switch command {
        case "list":
            for app in list {
                print("\(formatBytes(app.size).padding(toLength: 11, withPad: " ", startingAt: 0))\(app.isProtected ? "🔒 " : "   ")\(app.name)  —  \(app.url.path.tildePath)")
            }
            print("\n\(list.count) apps · \(formatBytes(list.reduce(0) { $0 + $1.size })) on disk")
            return 0
        case "scan", "uninstall":
            guard args.count >= 2 else { print("Name an app."); return 64 }
            guard let app = list.first(where: { $0.name.lowercased() == args[1].lowercased() }) else {
                print("No app named \(args[1]) in Applications.")
                return 1
            }
            let report = TraceFinder(app: app, index: InstalledIndex(apps: list)).run()
            let chosen = report.traces.filter(\.isSelected)
            print("\n\(app.name) — \(app.subtitle)")
            for t in report.traces {
                print("  \(t.isSelected ? "[x]" : "[ ]") \(formatBytes(t.size).padding(toLength: 10, withPad: " ", startingAt: 0)) \(t.category.title): \(t.url?.path.tildePath ?? t.title)")
                print("        \(t.strength.label) — \(t.reason)")
            }
            if !report.lockedPlaces.isEmpty { print("\n  Locked, not checked: \(report.lockedPlaces.joined(separator: ", "))") }
            print("\n  Selected: \(chosen.count) items, \(formatBytes(chosen.reduce(0) { $0 + $1.size }))")
            guard command == "uninstall" else { return 0 }
            guard args.contains("--yes") else { print("Add --yes to move these to the Trash."); return 0 }
            guard !app.isProtected else { print("\(app.name) is part of macOS."); return 1 }
            var result: RemovalResult?
            Task.detached { result = await Remover.uninstall(app, traces: chosen) { log("Step: \($0)") } }
            while result == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
            print("\nMoved \(result!.manifest.records.count) items (\(formatBytes(result!.freed))) to the Trash.")
            result!.failures.forEach { print("  ! \($0)") }
            if let m = result!.manifestURL { print("Undo record: \(m.path)") }
            return result!.failures.isEmpty ? 0 : 2
        default:
            print("Unknown command \(command)")
            return 64
        }
    }
}
