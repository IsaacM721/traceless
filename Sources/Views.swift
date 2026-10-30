import SwiftUI
import AppKit

// MARK: - Spinning wheel

/// The pinwheel macOS shows under the pointer while it's busy, drawn in SwiftUI. Five
/// glossy blades, clockwise, one turn a second. With Reduce Motion on it stays still and
/// the progress bar beneath carries the meaning.
struct Pinwheel: View {
    var size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let blades: [(Color, Color)] = [
        (Color(red: 0.10, green: 0.36, blue: 0.95), Color(red: 0.36, green: 0.72, blue: 1.00)),
        (Color(red: 0.12, green: 0.62, blue: 0.20), Color(red: 0.50, green: 0.88, blue: 0.30)),
        (Color(red: 0.98, green: 0.72, blue: 0.00), Color(red: 1.00, green: 0.92, blue: 0.30)),
        (Color(red: 0.95, green: 0.38, blue: 0.05), Color(red: 1.00, green: 0.62, blue: 0.20)),
        (Color(red: 0.86, green: 0.10, blue: 0.22), Color(red: 0.98, green: 0.40, blue: 0.55)),
        (Color(red: 0.48, green: 0.18, blue: 0.80), Color(red: 0.72, green: 0.45, blue: 0.98)),
    ]

    private var gradient: AngularGradient {
        var stops: [Gradient.Stop] = []
        let n = Double(Self.blades.count)
        for (i, blade) in Self.blades.enumerated() {
            stops.append(.init(color: blade.0, location: Double(i) / n))
            stops.append(.init(color: blade.1, location: (Double(i) + 0.999) / n))
        }
        return AngularGradient(stops: stops, center: .center)
    }

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let angle = reduceMotion ? 0 : t.truncatingRemainder(dividingBy: 1.0) * 360
            ZStack {
                Circle().fill(gradient).rotationEffect(.degrees(angle))
                Circle().fill(RadialGradient(colors: [.white.opacity(0.65), .white.opacity(0.0)],
                                             center: UnitPoint(x: 0.36, y: 0.28),
                                             startRadius: 0, endRadius: size * 0.55))
                Circle().fill(RadialGradient(colors: [.clear, .black.opacity(0.22)], center: .center,
                                             startRadius: size * 0.3, endRadius: size * 0.52))
                Circle().strokeBorder(.black.opacity(0.18), lineWidth: max(0.5, size / 90))
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.2), radius: size / 10, y: size / 20)
        }
        .accessibilityHidden(true)
    }
}

struct LoadingView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 26) {
            Pinwheel(size: 96)
            VStack(spacing: 10) {
                Text(store.total == 0 ? "Finding your apps" : "Measuring your apps")
                    .font(.title3.weight(.semibold))
                ProgressView(value: Double(store.measured), total: Double(max(store.total, 1)))
                    .progressViewStyle(.linear)
                    .frame(width: 260)
                Text(store.total == 0 ? "Looking in Applications…" :
                        "\(store.measured) of \(store.total) apps · \(formatBytes(store.bytesSoFar)) so far")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Measuring your apps, \(store.measured) of \(store.total)")
    }
}

// MARK: - Window

struct ContentView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Group {
            switch store.phase {
            case .loading: LoadingView()
            case .ready: MainView()
            }
        }
        .frame(minWidth: 880, minHeight: 560)
        .task {
            if store.options.restoreLast {
                store.options.restoreLast = false
                await store.restoreLast()
            } else if store.apps.isEmpty {
                await store.load()
            }
        }
    }
}

enum IconCache {
    @MainActor private static var cache: [String: NSImage] = [:]
    @MainActor static func icon(_ url: URL) -> NSImage {
        if let hit = cache[url.path] { return hit }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache[url.path] = image
        return image
    }
}

struct MainView: View {
    @Environment(AppStore.self) private var store
    @State private var search = ""

    private var filtered: [InstalledApp] {
        guard !search.isEmpty else { return store.apps }
        return store.apps.filter { $0.name.localizedCaseInsensitiveContains(search) || ($0.bundleID ?? "").localizedCaseInsensitiveContains(search) }
    }
    private var largest: Int64 { store.apps.map(\.size).max() ?? 1 }

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            List(selection: $store.selectionID) {
                Section {
                    ForEach(filtered) { app in
                        AppRow(app: app, fraction: Double(app.size) / Double(max(largest, 1)))
                            .tag(app.id)
                    }
                } header: {
                    Text("\(store.apps.count) apps · \(formatBytes(store.totalBytes))")
                        .monospacedDigit()
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Search apps")
            .navigationSplitViewColumnWidth(min: 270, ideal: 310, max: 420)
            .toolbar {
                ToolbarItem {
                    Picker("Sort By", selection: $store.sort) {
                        ForEach(AppStore.Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .help("Sort apps")
                    .onChange(of: store.sort) { store.applySort() }
                }
            }
        } detail: {
            if let detail = store.detail {
                AppDetailView(model: detail).id(detail.app.id)
            } else {
                ContentUnavailableView {
                    Label("Select an App", systemImage: "app.dashed")
                } description: {
                    Text("Choose an app to see every file it keeps on your Mac and how much space it all takes.")
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await store.load() } } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .help("Measure your apps again")
            }
        }
    }
}

struct AppRow: View {
    let app: InstalledApp
    let fraction: Double

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: IconCache.icon(app.url))
                .resizable()
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(app.name).lineLimit(1)
                    if app.isProtected {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.tertiary)
                            .help("Part of macOS")
                            .accessibilityLabel("Part of macOS")
                    }
                }
                // Share of the largest app: the list reads as a storage map at a glance.
                GeometryReader { geo in
                    Capsule().fill(.tint.opacity(0.55))
                        .frame(width: max(3, geo.size.width * fraction), height: 3)
                }
                .frame(height: 3)
                .accessibilityHidden(true)
            }
            Spacer(minLength: 6)
            Text(formatBytes(app.size))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Detail

struct AppDetailView: View {
    @Bindable var model: DetailModel
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 22).padding(.vertical, 18)
            Divider()
            content
        }
        .confirmationDialog("Uninstall \(model.app.name)?", isPresented: $model.confirming) {
            Button("Uninstall") { Task { await model.uninstall() } }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.confirmMessage)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(nsImage: IconCache.icon(model.app.url))
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(model.app.name).font(.title.weight(.semibold))
                    if model.isRunning {
                        Text("Open")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(.green.opacity(0.18), in: Capsule())
                            .help("\(model.app.name) is running. It quits before it's removed.")
                    }
                }
                Text(model.app.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if model.isReady && !model.app.isProtected {
                    Text(model.summary).font(.callout).padding(.top, 2)
                }
            }
            Spacer(minLength: 12)
            if model.isReady && !model.app.isProtected {
                Button { model.confirming = true } label: {
                    Label("Uninstall…", systemImage: "trash")
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(!model.canUninstall)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .scanning:
            VStack(spacing: 16) {
                Pinwheel(size: 40)
                Text("Looking everywhere \(model.app.name) keeps files…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            if model.app.isProtected {
                ContentUnavailableView {
                    Label("Part of macOS", systemImage: "lock")
                } description: {
                    Text("\(model.app.name) is sealed by macOS and can't be removed. It's listed so you can see where your \(formatBytes(model.app.size)) goes.")
                }
            } else {
                traceList
            }
        case .removing(let message):
            VStack(spacing: 16) {
                Pinwheel(size: 48)
                Text(message).font(.title3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .done(let result):
            ResultView(model: model, result: result)
        }
    }

    private var traceList: some View {
        List {
            if !model.locked.isEmpty {
                Section { AccessBanner(places: model.locked) }
            }
            ForEach(model.categories, id: \.self) { category in
                Section {
                    ForEach(model.indices(in: category), id: \.self) { i in
                        TraceRow(trace: $model.traces[i])
                    }
                } header: {
                    HStack {
                        Text(category.title)
                        Spacer()
                        Text(formatBytes(model.bytes(in: category))).monospacedDigit()
                    }
                }
            }
        }
        .listStyle(.inset)
    }
}

struct AccessBanner: View {
    let places: [String]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.title2)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(places.count == 1 ? "1 place is locked, so Traceless couldn't check it."
                                       : "\(places.count) places are locked, so Traceless couldn't check them.")
                    .font(.callout.weight(.semibold))
                Text("Turn on Full Disk Access for Traceless in Privacy & Security, then select the app again. Locked: \(places.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Open Privacy Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

struct TraceRow: View {
    @Binding var trace: Trace

    private var icon: NSImage? {
        guard let url = trace.url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $trace.isSelected) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("Remove \(trace.title)")
            Group {
                if let icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: trace.kind == .dockTile ? "dock.rectangle" : "shippingbox")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 20, height: 20)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(trace.title).lineLimit(1).truncationMode(.middle)
                Text("\(trace.location) — \(trace.reason)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if trace.needsAdmin {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Protected: macOS will ask for your password")
                    .accessibilityLabel("Needs your password")
            }
            Text(trace.strength.label)
                .font(.caption)
                .foregroundStyle(trace.strength == .shared ? .orange : .secondary)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
            Text(trace.size > 0 ? formatBytes(trace.size) : "—")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 70, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .contextMenu {
            if let url = trace.url {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.path, forType: .string)
                }
            }
        }
    }
}

struct ResultView: View {
    let model: DetailModel
    let result: RemovalResult
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: result.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 46))
                .foregroundStyle(result.failures.isEmpty ? .green : .orange)
                .accessibilityHidden(true)
            Text(result.failures.isEmpty ? "\(model.app.name) is uninstalled" : "\(model.app.name) is uninstalled, with notes")
                .font(.title2.weight(.semibold))
            Text("\(result.manifest.records.count) items, \(formatBytes(result.freed)), moved to the Trash. Empty the Trash to get the space back.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !result.failures.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(result.failures, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.callout) }
                }
                .padding(12)
                .frame(maxWidth: 520, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack(spacing: 10) {
                Button("Restore") { Task { await model.restore(result) } }
                    .help("Put every item back where it was")
                Button("Show Log") { NSWorkspace.shared.open(Log.shared.fileURL) }
                Button("Done") { store.finished(with: model.app, removed: result.appRemoved) }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.top, 6)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
