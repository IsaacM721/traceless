import AppKit
import Security

/// What is installed right now, so one app's search never claims another app's files.
struct InstalledIndex {
    let bundleIDs: Set<String>
    let nameCounts: [String: Int]

    init(apps: [InstalledApp]) {
        bundleIDs = Set(apps.compactMap { $0.bundleID?.lowercased() })
        var counts: [String: Int] = [:]
        for app in apps { counts[TraceFinder.norm(app.name), default: 0] += 1 }
        nameCounts = counts
    }
}

/// Paths Traceless refuses to touch, whatever a match says. This is the guard against the
/// failure people report most: an uninstaller removing documents or system files.
enum Safety {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    static func isAllowed(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.path
        let userLib = home + "/Library/"
        let allowedRoots = [userLib, "/Library/", "/Applications/", home + "/Applications/",
                            "/private/var/folders/", "/var/folders/"]
        guard allowedRoots.contains(where: { p.hasPrefix($0) }) else { return false }

        let forbidden = ["/System", "/Library/Apple", userLib + "Mobile Documents", userLib + "CloudStorage",
                         userLib + "Mail", userLib + "Messages", userLib + "Keychains", userLib + "Photos",
                         userLib + "Containers/com.apple.Safari.WebApp/Data/Library/Safari",
                         userLib + "Group Containers/group.com.apple.notes"]
        if forbidden.contains(where: { p == $0 || p.hasPrefix($0 + "/") }) { return false }

        // Never a whole Library area (".../Library/Caches"), only something inside one.
        for lib in [userLib, "/Library/"] where p.hasPrefix(lib) {
            if p.dropFirst(lib.count).split(separator: "/").count < 2 { return false }
        }
        // The shared container every Safari web app lives in is never removed whole.
        if p.hasPrefix(userLib + "Containers/com.apple.Safari.WebApp"),
           p.split(separator: "/").count <= (userLib + "Containers/com.apple.Safari.WebApp/Data/Library").split(separator: "/").count + 1 {
            return false
        }
        if p.hasPrefix("/Applications/") || p.hasPrefix(home + "/Applications/") {
            return p.lowercased().hasSuffix(".app")
        }
        return true
    }
}

final class TraceFinder {
    struct Place {
        let url: URL
        let category: TraceCategory
        var system = false
        var groupContainers = false
        var crashReports = false
        var vendorFolders = false
    }

    struct Hit {
        let strength: MatchStrength
        let reason: String
    }

    static let generic: Set<String> = [
        "app", "apps", "helper", "helpers", "update", "updater", "data", "cache", "caches", "logs", "log",
        "temp", "tmp", "google", "microsoft", "apple", "adobe", "mozilla", "default", "shared", "common",
        "user", "users", "library", "support", "plugins", "settings", "config", "web", "webapp", "client",
        "desktop", "launcher", "installer", "uninstaller", "service", "services", "agent", "daemon",
        "crashpad", "crashreporter", "electron", "chrome", "chromium", "python", "java", "node", "com",
    ]
    static let reverseDNSRoots: Set<String> = ["com", "org", "net", "io", "app", "co", "de", "ai", "dev", "me", "us", "uk", "fr", "jp", "cn", "ru"]

    static func norm(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private let app: InstalledApp
    private let index: InstalledIndex
    private let fm = FileManager.default
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var traces: [Trace] = []
    private var seen = Set<String>()
    private var locked: [String] = []

    private let ids: [String]
    private let names: Set<String>
    private let vendor: String?
    private let vendorNames: Set<String>
    private let teamID: String?

    init(app: InstalledApp, index: InstalledIndex) {
        self.app = app
        self.index = index

        var idList: [String] = []
        if let bid = app.bundleID?.lowercased() {
            idList.append(bid)
            // Helpers inside the bundle (Electron helpers, login items, extensions) leave their
            // own files. Only vendor-prefixed IDs count, so a bundled framework such as Sparkle,
            // whose preferences other apps share, is never treated as this app's.
            let vendorPrefix = bid.split(separator: ".").prefix(2).joined(separator: ".") + "."
            for id in Self.embeddedBundleIDs(in: app.url) where id.hasPrefix(vendorPrefix) && id != bid {
                idList.append(id)
            }
        }
        ids = idList

        var raw = [app.name]
        if app.kind == .native {
            if let e = app.executable { raw.append(e) }
            if let n = app.bundleName { raw.append(n) }
        }
        names = Set(raw.map(Self.norm).filter { $0.count >= 3 && !Self.generic.contains($0) })

        if app.kind == .native, let parts = app.bundleID?.lowercased().split(separator: "."), parts.count >= 3,
           Self.reverseDNSRoots.contains(String(parts[0])), parts[1] != "apple" {
            let v = Self.norm(String(parts[1]))
            vendor = v.count >= 3 ? v : nil
        } else {
            vendor = nil
        }
        if let vendor {
            vendorNames = Set(names.map { $0.hasPrefix(vendor) ? String($0.dropFirst(vendor.count)) : $0 }
                .filter { $0.count >= 3 }).union(names)
        } else {
            vendorNames = names
        }
        teamID = app.kind == .native ? Self.teamID(of: app.url) : nil
    }

    // MARK: - Search

    func run() -> TraceReport {
        let started = Date()
        log("Scanning traces for \(app.name) [\(app.bundleID ?? "no bundle ID")] at \(app.url.path)")
        log("  IDs: \(ids.joined(separator: ", ")) · names: \(names.sorted().joined(separator: ", ")) · team: \(teamID ?? "none")")

        addAppBundle()
        for place in places() { scan(place) }
        if app.kind == .safariWebApp { scanWebAppData() }
        addDockTile()
        addReceipts()

        // Measure everything found, in parallel.
        let urls = traces.map(\.url)
        var sizes = [Int64](repeating: 0, count: urls.count)
        sizes.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: urls.count) { i in
                if let url = urls[i] { buffer[i] = AppScanner.allocatedSize(of: url) }
            }
        }
        for i in traces.indices where traces[i].category != .application { traces[i].size = sizes[i] }

        traces.sort { ($0.category, -$0.size) < ($1.category, -$1.size) }
        let fda = Self.hasFullDiskAccess()
        log("  Found \(traces.count) traces in \(String(format: "%.2f", Date().timeIntervalSince(started)))s · locked places: \(locked.count) · Full Disk Access: \(fda)")
        for t in traces {
            log("  \(t.isSelected ? "[x]" : "[ ]") \(t.category.title) · \(t.strength.label) · \(formatBytes(t.size)) · \(t.url?.path ?? t.title) — \(t.reason)")
        }
        return TraceReport(traces: traces, lockedPlaces: locked, hasFullDiskAccess: fda)
    }

    private func places() -> [Place] {
        let L = home.appendingPathComponent("Library")
        let S = URL(fileURLWithPath: "/Library")
        func u(_ base: URL, _ path: String) -> URL { base.appendingPathComponent(path, isDirectory: true) }
        var list: [Place] = [
            Place(url: u(L, "Application Support"), category: .support, vendorFolders: true),
            Place(url: u(L, "Caches"), category: .caches, vendorFolders: true),
            Place(url: u(L, "Preferences"), category: .preferences),
            Place(url: u(L, "Preferences/ByHost"), category: .preferences),
            Place(url: u(L, "Containers"), category: .containers),
            Place(url: u(L, "Group Containers"), category: .containers, groupContainers: true),
            Place(url: u(L, "Application Scripts"), category: .containers),
            Place(url: u(L, "Saved Application State"), category: .savedState),
            Place(url: u(L, "HTTPStorages"), category: .webData),
            Place(url: u(L, "WebKit"), category: .webData),
            Place(url: u(L, "Cookies"), category: .webData),
            Place(url: u(L, "Logs"), category: .logs, vendorFolders: true),
            Place(url: u(L, "Logs/DiagnosticReports"), category: .logs, crashReports: true),
            Place(url: u(L, "Application Support/CrashReporter"), category: .logs),
            Place(url: u(L, "LaunchAgents"), category: .launchItems),
            Place(url: u(L, "Internet Plug-Ins"), category: .plugins),
            Place(url: u(L, "PreferencePanes"), category: .plugins),
            Place(url: u(L, "Services"), category: .plugins),
            Place(url: u(L, "QuickLook"), category: .plugins),
            Place(url: u(L, "Screen Savers"), category: .plugins),
            Place(url: u(L, "Spotlight"), category: .plugins),
            Place(url: u(L, "Input Methods"), category: .plugins),
            Place(url: u(L, "Audio/Plug-Ins/Components"), category: .plugins),
            Place(url: u(L, "Audio/Plug-Ins/VST"), category: .plugins),
            Place(url: u(L, "Audio/Plug-Ins/VST3"), category: .plugins),
        ]
        let system: [(String, TraceCategory, Bool)] = [
            ("Application Support", .support, true), ("Caches", .caches, true), ("Preferences", .preferences, false),
            ("LaunchAgents", .launchItems, false), ("LaunchDaemons", .launchItems, false),
            ("PrivilegedHelperTools", .helpers, false), ("Extensions", .plugins, false),
            ("Internet Plug-Ins", .plugins, false), ("PreferencePanes", .plugins, false), ("QuickLook", .plugins, false),
            ("Screen Savers", .plugins, false), ("Spotlight", .plugins, false), ("Input Methods", .plugins, false),
            ("Audio/Plug-Ins/HAL", .plugins, false), ("Audio/Plug-Ins/Components", .plugins, false),
            ("Audio/Plug-Ins/VST", .plugins, false), ("Audio/Plug-Ins/VST3", .plugins, false),
            ("Logs", .logs, true), ("Logs/DiagnosticReports", .logs, false),
        ]
        for (path, cat, vendorFolders) in system {
            var p = Place(url: u(S, path), category: cat, system: true, vendorFolders: vendorFolders)
            p.crashReports = path.hasSuffix("DiagnosticReports")
            list.append(p)
        }
        for key in [_CS_DARWIN_USER_CACHE_DIR, _CS_DARWIN_USER_TEMP_DIR] {
            var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
            if confstr(key, &buf, buf.count) > 0 {
                list.append(Place(url: URL(fileURLWithPath: String(cString: buf), isDirectory: true), category: .temporary))
            }
        }
        return list
    }

    private func scan(_ place: Place) {
        let entries: [String]
        do {
            entries = try fm.contentsOfDirectory(atPath: place.url.path)
        } catch let error as NSError {
            if error.code == NSFileReadNoPermissionError {
                locked.append(place.url.path.tildePath)
                log("  Locked (no permission): \(place.url.path)", "WARN")
            }
            return
        }
        for entry in entries where !entry.hasPrefix(".") {
            let url = place.url.appendingPathComponent(entry)
            if place.crashReports {
                if let hit = crashReportMatch(entry) { add(url, place, hit) }
                continue
            }
            if let hit = match(entry, groupContainers: place.groupContainers) {
                add(url, place, hit)
                continue
            }
            if place.category == .launchItems, entry.hasSuffix(".plist"), let hit = launchPlistMatch(url) {
                add(url, place, hit)
                continue
            }
            // e.g. ~/Library/Application Support/Google/Chrome for com.google.Chrome
            if place.vendorFolders, let vendor, Self.norm(entry) == vendor, isDirectory(url),
               let children = try? fm.contentsOfDirectory(atPath: url.path) {
                for child in children where vendorNames.contains(Self.norm((child as NSString).deletingPathExtension)) {
                    add(url.appendingPathComponent(child), place,
                        Hit(strength: .name, reason: "Inside the developer's “\(entry)” folder"))
                }
            }
        }
    }

    /// Whole-name matching only: "Opera" never matches "operations.pdf".
    func match(_ entry: String, groupContainers: Bool) -> Hit? {
        let lower = entry.lowercased()
        var base = lower
        for ext in [".plist", ".savedstate", ".binarycookies", ".lockfile", ".log"] where base.hasSuffix(ext) {
            base = String(base.dropLast(ext.count))
            break
        }

        var candidates = [base]
        if groupContainers {
            if base.hasPrefix("group.") { candidates.append(String(base.dropFirst(6))) }
            if let t = teamID?.lowercased(), base.hasPrefix(t + ".") { candidates.append(String(base.dropFirst(t.count + 1))) }
        }
        for id in ids {
            for c in candidates where c == id || c.hasPrefix(id + ".") {
                // A longer ID owned by another installed app wins (com.google.Chrome.app.X is not Chrome's).
                if index.bundleIDs.contains(where: { $0.count > id.count && !ids.contains($0) && (c == $0 || c.hasPrefix($0 + ".")) }) {
                    return nil
                }
                return Hit(strength: .exact, reason: c == id ? "Named after the app's ID" : "Named after the app's ID (\(id))")
            }
        }
        if groupContainers, let t = teamID?.lowercased(), base.hasPrefix(t + ".") {
            return Hit(strength: .shared, reason: "Shared by apps from the same developer, so it stays unless you check it")
        }

        let stem = Self.norm((entry as NSString).deletingPathExtension)
        if names.contains(stem) {
            if index.nameCounts[stem, default: 0] > 1 {
                return Hit(strength: .shared, reason: "Another installed app has the same name, so it stays unless you check it")
            }
            return Hit(strength: .name, reason: "Has the app's exact name")
        }

        // Leftovers from an earlier install of the same app under a different ID,
        // for example com.spotify.client after switching to the Spotify web app.
        let parts = base.split(separator: ".").map(String.init)
        if parts.count >= 2, Self.reverseDNSRoots.contains(parts[0]),
           names.contains(Self.norm(parts[1])) || (parts.count >= 3 && names.contains(Self.norm(parts[2]))) {
            let family = parts.prefix(3).joined(separator: ".")
            let vendorPrefix = parts.prefix(2).joined(separator: ".")
            let stillInstalled = index.bundleIDs.contains { $0 == family || $0.hasPrefix(vendorPrefix + ".") || $0 == vendorPrefix }
                || ids.contains { $0.hasPrefix(vendorPrefix) }
                || NSWorkspace.shared.urlForApplication(withBundleIdentifier: family) != nil
            if !stillInstalled {
                return Hit(strength: .related, reason: "Left by an earlier “\(app.name)” app (\(family)) that's no longer installed")
            }
        }
        return nil
    }

    private func crashReportMatch(_ entry: String) -> Hit? {
        let exts: Set<String> = ["ips", "crash", "diag", "spin", "hang", "cpu_resource"]
        guard exts.contains((entry as NSString).pathExtension.lowercased()) else { return nil }
        var prefixes = [app.name]
        if app.kind == .native, let e = app.executable { prefixes.append(e) }
        for name in prefixes {
            for sep in ["-", "_", "."] where entry.hasPrefix(name + sep) {
                let rest = entry.dropFirst(name.count + 1)
                if rest.first?.isNumber == true {
                    return Hit(strength: .exact, reason: "Crash or hang report from \(name)")
                }
            }
        }
        return nil
    }

    private func launchPlistMatch(_ url: URL) -> Hit? {
        guard let plist = NSDictionary(contentsOf: url) as? [String: Any] else { return nil }
        var associated: [String] = []
        if let list = plist["AssociatedBundleIdentifiers"] as? [String] { associated = list }
        if let one = plist["AssociatedBundleIdentifiers"] as? String { associated = [one] }
        if associated.contains(where: { ids.contains($0.lowercased()) }) {
            return Hit(strength: .exact, reason: "Background item registered to this app")
        }
        let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
        if let program, program.hasPrefix(app.url.path + "/") {
            return Hit(strength: .exact, reason: "Starts a program inside the app")
        }
        return nil
    }

    private func add(_ url: URL, _ place: Place, _ hit: Hit) {
        let key = url.standardizedFileURL.path
        guard !seen.contains(key) else { return }
        guard Safety.isAllowed(url) else {
            log("  Skipped by safety rules: \(key)", "WARN")
            return
        }
        seen.insert(key)
        var kind: TraceKind = .file
        if place.category == .launchItems {
            let label = (NSDictionary(contentsOf: url) as? [String: Any])?["Label"] as? String
            kind = .launchJob(label: label, system: place.url.path.hasSuffix("LaunchDaemons"))
        }
        let needsAdmin = place.system && !fm.isWritableFile(atPath: place.url.path)
        traces.append(Trace(url: url, title: url.lastPathComponent, category: place.category, strength: hit.strength,
                            reason: hit.reason, size: 0, needsAdmin: needsAdmin,
                            isSelected: hit.strength >= .related, kind: kind))
    }

    private func addAppBundle() {
        seen.insert(app.url.standardizedFileURL.path)
        traces.append(Trace(url: app.url, title: app.url.lastPathComponent, category: .application, strength: .exact,
                            reason: app.kind == .safariWebApp ? "The web app you added to the Dock" : "The app itself",
                            size: app.size, needsAdmin: false, isSelected: true, kind: .file))
    }

    /// Safari keeps each web app's website data inside one shared container, in folders
    /// named with the web app's ID. Only those folders are taken, never the container.
    private func scanWebAppData() {
        guard let bid = app.bundleID else { return }
        let uuid = String(bid.dropFirst("com.apple.Safari.WebApp.".count)).lowercased()
        guard uuid.count >= 8 else { return }
        let root = home.appendingPathComponent("Library/Containers/com.apple.Safari.WebApp/Data/Library")
        var denied = false
        let place = Place(url: root, category: .webData)
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [],
                                         errorHandler: { _, error in
            if (error as NSError).code == NSFileReadNoPermissionError { denied = true }
            return true
        }) else { return }
        for case let url as URL in walker {
            if walker.level > 7 { walker.skipDescendants(); continue }
            if url.lastPathComponent.lowercased().contains(uuid) {
                add(url, place, Hit(strength: .exact, reason: "Website data Safari stored for this web app"))
                walker.skipDescendants()
            }
        }
        if denied {
            locked.append("Safari web app data (~/Library/Containers/com.apple.Safari.WebApp)")
            log("  Locked (no permission): Safari web app container", "WARN")
        }
    }

    private func addDockTile() {
        guard let items = CFPreferencesCopyAppValue("persistent-apps" as CFString, "com.apple.dock" as CFString) as? [[String: Any]] else { return }
        if items.contains(where: { DockTiles.path(of: $0) == app.url.path }) {
            traces.append(Trace(url: nil, title: "Icon in the Dock", category: .integration, strength: .exact,
                                reason: "Removed too, so no question-mark icon is left behind",
                                size: 0, needsAdmin: false, isSelected: true, kind: .dockTile))
        }
    }

    private func addReceipts() {
        guard app.kind == .native else { return }
        let result = Shell.run("/usr/sbin/pkgutil", ["--file-info", app.url.path])
        for line in result.out.split(separator: "\n") where line.hasPrefix("pkgid: ") {
            let id = String(line.dropFirst("pkgid: ".count)).trimmingCharacters(in: .whitespaces)
            guard !id.hasPrefix("com.apple.") else { continue }
            traces.append(Trace(url: nil, title: id, category: .receipts, strength: .exact,
                                reason: "macOS's record that an installer put this app here",
                                size: 0, needsAdmin: true, isSelected: true, kind: .receipt(id)))
        }
    }

    // MARK: - Helpers

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    static func embeddedBundleIDs(in appURL: URL) -> [String] {
        let contents = appURL.appendingPathComponent("Contents")
        guard let walker = FileManager.default.enumerator(at: contents, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles]) else { return [] }
        var ids = Set<String>()
        var visited = 0
        for case let url as URL in walker {
            visited += 1
            if visited > 20_000 || walker.level > 7 { walker.skipDescendants(); if visited > 20_000 { break }; continue }
            let ext = url.pathExtension.lowercased()
            if ["app", "appex", "xpc", "systemextension", "plugin"].contains(ext) {
                let info = url.appendingPathComponent("Contents/Info.plist")
                if let id = (NSDictionary(contentsOf: info) as? [String: Any])?["CFBundleIdentifier"] as? String {
                    ids.insert(id.lowercased())
                }
            } else if url.deletingLastPathComponent().lastPathComponent == "LaunchServices" {
                ids.insert(url.lastPathComponent.lowercased()) // privileged helper binaries
            } else if ext == "framework" || ext == "lproj" || url.lastPathComponent == "Resources" {
                walker.skipDescendants()
            }
        }
        return Array(ids)
    }

    static func teamID(of url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// The user's TCC database can only be opened with Full Disk Access.
    static func hasFullDiskAccess() -> Bool {
        let probe = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path
        if let handle = FileHandle(forReadingAtPath: probe) {
            try? handle.close()
            return true
        }
        return false
    }
}

enum DockTiles {
    static func path(of item: [String: Any]) -> String? {
        guard let tile = item["tile-data"] as? [String: Any],
              let file = tile["file-data"] as? [String: Any],
              let string = file["_CFURLString"] as? String else { return nil }
        let url = string.hasPrefix("file://") ? URL(string: string) : URL(fileURLWithPath: string)
        guard var path = url?.standardizedFileURL.path else { return nil }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
