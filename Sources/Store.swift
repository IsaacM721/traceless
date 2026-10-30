import AppKit
import Observation

struct LaunchOptions {
    var select: String?
    var demoUninstall = false
    var restoreLast = false

    static func parse() -> LaunchOptions {
        var options = LaunchOptions()
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--select"), i + 1 < args.count { options.select = args[i + 1] }
        options.demoUninstall = args.contains("--demo-uninstall")
        options.restoreLast = args.contains("--restore-last")
        return options
    }
}

@MainActor @Observable
final class AppStore {
    enum Phase { case loading, ready }
    enum Sort: String, CaseIterable { case size = "Size", name = "Name" }

    var phase: Phase = .loading
    var apps: [InstalledApp] = []
    var measured = 0
    var total = 0
    var bytesSoFar: Int64 = 0
    var sort: Sort = .size
    var detail: DetailModel?
    var selectionID: String? {
        didSet { if oldValue != selectionID { updateDetail() } }
    }
    @ObservationIgnored var options = LaunchOptions.parse()

    var selectedApp: InstalledApp? { apps.first { $0.id == selectionID } }
    var totalBytes: Int64 { apps.reduce(0) { $0 + $1.size } }

    func load() async {
        phase = .loading
        measured = 0
        bytesSoFar = 0
        total = 0
        let started = Date()
        log("Measuring apps in /Applications and ~/Applications on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        let urls = await Task.detached(priority: .userInitiated) { AppScanner.discover() }.value
        total = urls.count

        var results: [InstalledApp] = []
        await withTaskGroup(of: InstalledApp.self) { group in
            var pending = urls.makeIterator()
            func next() -> Bool {
                guard let url = pending.next() else { return false }
                group.addTask(priority: .userInitiated) {
                    var app = AppScanner.describe(url)
                    app.size = AppScanner.appSize(of: url)
                    return app
                }
                return true
            }
            for _ in 0..<max(4, ProcessInfo.processInfo.activeProcessorCount) where !next() { break }
            for await app in group {
                results.append(app)
                measured += 1
                bytesSoFar += app.size
                _ = next()
            }
        }
        // Keep the wheel up long enough to read, never a flash.
        let elapsed = Date().timeIntervalSince(started)
        if elapsed < 1.2 { try? await Task.sleep(nanoseconds: UInt64((1.2 - elapsed) * 1_000_000_000)) }

        apps = results
        applySort()
        log("Measured \(apps.count) apps, \(formatBytes(totalBytes)) on disk, in \(String(format: "%.1f", elapsed))s")
        for app in apps { log("  \(formatBytes(app.size).padding(toLength: 10, withPad: " ", startingAt: 0)) \(app.name) — \(app.url.path)") }
        phase = .ready

        if let name = options.select?.lowercased(), let match = apps.first(where: { $0.name.lowercased() == name }) {
            options.select = nil
            selectionID = match.id
        } else if selectionID == nil || selectedApp == nil {
            selectionID = nil
        }
    }

    /// Puts back everything from the most recent uninstall, then measures again.
    func restoreLast() async {
        guard let manifest = Remover.latestManifest() else { return }
        let notes = await Task.detached(priority: .userInitiated) { Remover.restore(manifest) }.value
        options.select = manifest.app
        await load()
        if !notes.isEmpty {
            let alert = NSAlert()
            alert.messageText = "\(manifest.app) is back, with notes"
            alert.informativeText = notes.joined(separator: "\n\n")
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    func applySort() {
        switch sort {
        case .size: apps.sort { $0.size > $1.size }
        case .name: apps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    func finished(with app: InstalledApp, removed: Bool) {
        if removed { apps.removeAll { $0.id == app.id } }
        selectionID = nil
    }

    func reinsert(_ app: InstalledApp) {
        if !apps.contains(where: { $0.id == app.id }) { apps.append(app); applySort() }
    }

    private func updateDetail() {
        guard let app = selectedApp else { detail = nil; return }
        let model = DetailModel(app: app, store: self)
        detail = model
        Task { await model.scan() }
    }
}

@MainActor @Observable
final class DetailModel {
    enum State {
        case scanning, ready, removing(String), done(RemovalResult)
    }

    let app: InstalledApp
    var traces: [Trace] = []
    var locked: [String] = []
    var hasFullDiskAccess = true
    var isRunning = false
    var state: State = .scanning
    var confirming = false
    @ObservationIgnored weak var store: AppStore?

    init(app: InstalledApp, store: AppStore) {
        self.app = app
        self.store = store
    }

    var isReady: Bool { if case .ready = state { return true } else { return false } }
    var canUninstall: Bool { isReady && !app.isProtected && !selected.isEmpty }
    var selected: [Trace] { traces.filter(\.isSelected) }
    var selectedBytes: Int64 { selected.reduce(0) { $0 + $1.size } }
    var categories: [TraceCategory] { Array(Set(traces.map(\.category))).sorted() }

    func indices(in category: TraceCategory) -> [Int] { traces.indices.filter { traces[$0].category == category } }
    func bytes(in category: TraceCategory) -> Int64 { traces.filter { $0.category == category }.reduce(0) { $0 + $1.size } }

    var summary: String {
        let others = selected.filter { $0.category != .application }
        let appBytes = selected.first { $0.category == .application }?.size ?? 0
        if traces.count == 1 { return "No leftovers found. Removing \(app.name) frees \(formatBytes(appBytes))." }
        if others.isEmpty { return "Removing \(app.name) frees \(formatBytes(selectedBytes))." }
        let otherBytes = others.reduce(0) { $0 + $1.size }
        let places = others.count == 1 ? "1 other place" : "\(others.count) other places"
        return "Removing \(app.name) frees \(formatBytes(selectedBytes)): \(formatBytes(appBytes)) for the app and \(formatBytes(otherBytes)) in \(places)."
    }

    var confirmMessage: String {
        var text = isRunning ? "\(app.name) will quit. " : ""
        let n = selected.count
        text += "\(n) item\(n == 1 ? "" : "s") (\(formatBytes(selectedBytes))) will move to the Trash. You can restore them from Traceless until you empty the Trash."
        if selected.contains(where: \.needsAdmin) { text += " Some items are protected, so macOS will ask for your password." }
        return text
    }

    func scan() async {
        state = .scanning
        let app = self.app
        let index = InstalledIndex(apps: store?.apps ?? [])
        async let running = Task.detached { Remover.isRunning(app) }.value
        let report = await Task.detached(priority: .userInitiated) { TraceFinder(app: app, index: index).run() }.value
        traces = report.traces
        locked = report.lockedPlaces
        hasFullDiskAccess = report.hasFullDiskAccess
        isRunning = await running
        state = .ready

        if store?.options.demoUninstall == true {
            store?.options.demoUninstall = false
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            confirming = true
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            confirming = false
            await uninstall()
        }
    }

    func uninstall() async {
        guard canUninstall else { return }
        let chosen = selected
        let app = self.app
        state = .removing("Getting ready…")
        // Off the main thread, so the window keeps drawing while files move.
        let result = await Task.detached(priority: .userInitiated) {
            await Remover.uninstall(app, traces: chosen) { message in
                Task { @MainActor in
                    if case .removing = self.state { self.state = .removing(message) }
                }
            }
        }.value
        isRunning = false
        state = .done(result)
    }

    func restore(_ result: RemovalResult) async {
        state = .removing("Putting \(app.name) back…")
        let manifest = result.manifest
        let notes = await Task.detached { Remover.restore(manifest) }.value
        store?.reinsert(app)
        await scan()
        if !notes.isEmpty { log("Restore notes: \(notes.joined(separator: " | "))") }
    }
}
