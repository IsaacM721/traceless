import AppKit

/// Removes an app and its traces. Nothing is deleted permanently: every file goes to the
/// Trash and a manifest is written so Traceless can put it all back.
enum Remover {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static var historyDir: URL {
        home.appendingPathComponent("Library/Application Support/Traceless/History", isDirectory: true)
    }

    static func isRunning(_ app: InstalledApp) -> Bool {
        !runningApps(app).isEmpty || !webAppHostPIDs(for: app.url.path).isEmpty
    }

    static func uninstall(_ app: InstalledApp, traces: [Trace], step: @escaping (String) -> Void) async -> RemovalResult {
        let fm = FileManager.default
        log("=== Uninstall \(app.name) — \(traces.count) items selected ===")
        var manifest = RemovalManifest(app: app.name, appPath: app.url.path, date: Date(), records: [],
                                       dockTileRemoved: false, receiptsForgotten: [])
        var failures: [String] = []
        var freed: Int64 = 0

        // 1. Quit the app, its helpers, and the shared web app host if this is a web app.
        step("Quitting \(app.name)…")
        if let note = await quit(app) { failures.append(note) }

        // 2. Stop background items before their files go.
        var adminCommands: [String] = []
        for trace in traces {
            guard case let .launchJob(label, system) = trace.kind, let label else { continue }
            if system {
                adminCommands.append("/bin/launchctl bootout system/\(quote(label)) 2>/dev/null")
            } else {
                let r = Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
                log("launchctl bootout gui/\(getuid())/\(label) → \(r.status)")
            }
        }

        // 3. Move files to the Trash. Launch Services forgets the app first, so Spotlight,
        //    Launchpad and "Open With" stop offering it.
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        if traces.contains(where: { $0.category == .application }) {
            let r = Shell.run(lsregister, ["-u", app.url.path])
            log("Unregistered from Launch Services → \(r.status == 0 ? "ok" : "status \(r.status)")")
        }
        step("Moving items to the Trash…")
        var adminQueue: [Trace] = []
        for trace in traces {
            guard let url = trace.url, case .file = trace.kind.fileLike else { continue }
            guard Safety.isAllowed(url) else {
                failures.append("\(url.path.tildePath) was skipped by Traceless's safety rules.")
                log("Refused by safety rules: \(url.path)", "WARN")
                continue
            }
            guard fm.fileExists(atPath: url.path) || (try? url.checkResourceIsReachable()) == true || isSymlink(url) else {
                log("Already gone: \(url.path)")
                continue
            }
            if trace.needsAdmin { adminQueue.append(trace); continue }
            do {
                var resulting: NSURL?
                try fm.trashItem(at: url, resultingItemURL: &resulting)
                manifest.records.append(RemovalRecord(original: url.path, trashed: (resulting as URL?)?.path, viaAdmin: false))
                freed += trace.size
                log("Moved to Trash: \(url.path) → \((resulting as URL?)?.path ?? "?")")
            } catch {
                log("Trash failed for \(url.path): \(error.localizedDescription)", "WARN")
                if trace.category == .application, let trashed = await recycle(url) {
                    manifest.records.append(RemovalRecord(original: url.path, trashed: trashed.path, viaAdmin: false))
                    freed += trace.size
                    log("Moved to Trash with Finder's help: \(url.path)")
                } else {
                    adminQueue.append(trace)
                }
            }
        }

        // 4. One password prompt for everything protected.
        let receipts = traces.compactMap { trace -> String? in
            if case let .receipt(id) = trace.kind { return id } else { return nil }
        }
        for id in receipts { adminCommands.append("/usr/sbin/pkgutil --forget \(quote(id)) >/dev/null 2>&1") }
        if !adminQueue.isEmpty || !adminCommands.isEmpty {
            step("Waiting for your password…")
            let admin = runAdmin(adminQueue, commands: adminCommands, appName: app.name)
            manifest.records += admin.records
            failures += admin.failures
            freed += adminQueue.filter { t in admin.records.contains { $0.original == t.url?.path } }.reduce(0) { $0 + $1.size }
            if admin.ok { manifest.receiptsForgotten = receipts }
        }

        // 5. Tidy system records: preferences cache, Launch Services, Dock.
        step("Cleaning up system records…")
        for record in manifest.records where record.original.hasPrefix(home.path + "/Library/Preferences/") && record.original.hasSuffix(".plist")
            && !record.original.contains("/ByHost/") {
            let domain = ((record.original as NSString).lastPathComponent as NSString).deletingPathExtension
            Shell.run("/usr/bin/defaults", ["delete", domain]) // flushes cfprefsd's cached copy
            log("Flushed preferences cache for \(domain)")
        }
        let appRemoved = manifest.records.contains { $0.original == app.url.path }
        if !appRemoved, traces.contains(where: { $0.category == .application }) {
            Shell.run(lsregister, ["-f", app.url.path]) // still there: register it again
        }
        if traces.contains(where: { $0.kind == .dockTile }), removeDockTile(app.url.path) {
            manifest.dockTileRemoved = true
            log("Removed Dock icon")
        }

        // 6. Verify: every removed path must be gone from its original place.
        let stillThere = manifest.records.filter { FileManager.default.fileExists(atPath: $0.original) }
        log("Verified: \(manifest.records.count - stillThere.count) of \(manifest.records.count) removed paths are gone")
        for r in stillThere { failures.append("\(r.original.tildePath) came back after removal (the app may have recreated it).") }

        // 7. Save the undo manifest.
        let manifestURL = save(manifest)
        log("=== Done: \(formatBytes(freed)) moved to the Trash, \(failures.count) problems ===")
        for f in failures { log("  Problem: \(f)", "WARN") }
        log.flush()
        return RemovalResult(manifest: manifest, manifestURL: manifestURL, failures: failures, freed: freed, appRemoved: appRemoved)
    }

    // MARK: - Quitting

    private static func runningApps(_ app: InstalledApp) -> [NSRunningApplication] {
        let target = app.url.standardizedFileURL.path
        return NSWorkspace.shared.runningApplications.filter { running in
            guard running.processIdentifier != getpid() else { return false }
            if running.bundleURL?.standardizedFileURL.path == target { return true }
            if let bid = app.bundleID, running.bundleIdentifier == bid { return true }
            return running.executableURL?.path.hasPrefix(target + "/") == true
        }
    }

    /// Safari web apps run inside Apple's shared "Web App" host process, started with
    /// --bundlepath pointing at the web app. Match that argument exactly.
    static func webAppHostPIDs(for path: String) -> [pid_t] {
        let out = Shell.run("/bin/ps", ["-axww", "-o", "pid=,command="]).out
        return out.split(separator: "\n").compactMap { line -> pid_t? in
            let text = String(line)
            guard text.contains("--bundlepath \(path) ") || text.hasSuffix("--bundlepath \(path)") else { return nil }
            let pid = pid_t(text.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "") ?? 0
            return pid > 0 && pid != getpid() ? pid : nil
        }
    }

    private static func quit(_ app: InstalledApp) async -> String? {
        let apps = runningApps(app)
        let hosts = webAppHostPIDs(for: app.url.path)
        let pids = Array(Set(apps.map(\.processIdentifier) + hosts)).sorted()
        guard !pids.isEmpty else { log("\(app.name) isn't running"); return nil }
        log("Asking \(app.name) to quit (pids \(pids.map(String.init).joined(separator: ", ")))")
        apps.forEach { $0.terminate() }
        hosts.forEach { kill($0, SIGTERM) }
        func alive() -> [pid_t] { pids.filter { kill($0, 0) == 0 } }
        for _ in 0..<40 where !alive().isEmpty { try? await Task.sleep(nanoseconds: 250_000_000) }
        let stuck = alive()
        guard !stuck.isEmpty else { log("\(app.name) quit"); return nil }
        log("\(app.name) didn't quit within 10 s; force quitting \(stuck)", "WARN")
        apps.filter { stuck.contains($0.processIdentifier) }.forEach { $0.forceTerminate() }
        stuck.forEach { kill($0, SIGKILL) }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        return alive().isEmpty ? nil : "\(app.name) wouldn't quit, so some files may still be in use."
    }

    // MARK: - Trash helpers

    private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private static func recycle(_ url: URL) async -> URL? {
        await withCheckedContinuation { continuation in
            NSWorkspace.shared.recycle([url]) { map, error in
                continuation.resume(returning: error == nil ? map[url] : nil)
            }
        }
    }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func trashName(for path: String, stamp: String, index: Int) -> String {
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        let suffix = " (Traceless \(stamp)-\(index))"
        return home.appendingPathComponent(".Trash").appendingPathComponent(ext.isEmpty ? stem + suffix : "\(stem)\(suffix).\(ext)").path
    }

    private static func runAdmin(_ items: [Trace], commands: [String], appName: String) -> (records: [RemovalRecord], failures: [String], ok: Bool) {
        let f = DateFormatter()
        f.dateFormat = "HHmmss"
        let stamp = f.string(from: Date())
        var planned: [(String, String)] = []
        // Stop daemons first, then move files, then forget receipts.
        var lines: [String] = commands.filter { $0.contains("bootout") }
        let bootouts = lines
        let commands = commands.filter { !$0.contains("bootout") }
        for (i, trace) in items.enumerated() {
            guard let src = trace.url?.path else { continue }
            let dst = trashName(for: src, stamp: stamp, index: i)
            planned.append((src, dst))
            lines.append("/bin/mv -f \(quote(src)) \(quote(dst)) || echo FAIL:\(quote(src))")
        }
        lines += commands
        lines.append("true")
        let count = items.count + commands.count + bootouts.count
        let prompt = "Traceless needs your password to remove \(count) protected item\(count == 1 ? "" : "s") of \(appName)."
        let script = "do shell script \(appleScriptString(lines.joined(separator: "; "))) with prompt \(appleScriptString(prompt)) with administrator privileges"
        log("Requesting administrator access for \(items.count) files and \(commands.count) commands")
        let r = Shell.run("/usr/bin/osascript", ["-e", script])
        guard r.status == 0 else {
            log("Administrator step didn't run: \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))", "WARN")
            let msg = r.err.contains("-128") ? "You canceled the password prompt" : "The password step failed"
            return ([], ["\(msg), so \(count) protected item\(count == 1 ? " was" : "s were") left in place."], false)
        }
        var records: [RemovalRecord] = []
        var failures: [String] = []
        for (src, dst) in planned {
            if r.out.contains("FAIL:\(src)") {
                failures.append("Couldn't move \(src.tildePath).")
                log("Admin move failed: \(src)", "WARN")
            } else {
                records.append(RemovalRecord(original: src, trashed: dst, viaAdmin: true))
                log("Moved to Trash (admin): \(src) → \(dst)")
            }
        }
        for c in bootouts + commands { log("Ran as admin: \(c)") }
        return (records, failures, true)
    }

    private static func removeDockTile(_ path: String) -> Bool {
        let domain = "com.apple.dock" as CFString
        guard var items = CFPreferencesCopyAppValue("persistent-apps" as CFString, domain) as? [[String: Any]] else { return false }
        let before = items.count
        items.removeAll { DockTiles.path(of: $0) == path }
        guard items.count != before else { return false }
        CFPreferencesSetAppValue("persistent-apps" as CFString, items as CFArray, domain)
        CFPreferencesAppSynchronize(domain)
        Shell.run("/usr/bin/killall", ["Dock"])
        return true
    }

    private static func save(_ manifest: RemovalManifest) -> URL? {
        try? FileManager.default.createDirectory(at: historyDir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = historyDir.appendingPathComponent("\(f.string(from: manifest.date)) \(manifest.app).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(manifest).write(to: url)
            log("Saved undo record: \(url.path)")
            return url
        } catch {
            log("Couldn't save undo record: \(error.localizedDescription)", "ERROR")
            return nil
        }
    }

    // MARK: - Restore

    static func latestManifest() -> RemovalManifest? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: historyDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let newest = files.filter { $0.pathExtension == "json" }.max {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
        guard let newest, let data = try? Data(contentsOf: newest) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RemovalManifest.self, from: data)
    }

    static func restore(_ manifest: RemovalManifest) -> [String] {
        let fm = FileManager.default
        log("=== Restore \(manifest.app) — \(manifest.records.count) items ===")
        var failures: [String] = []
        var adminLines: [String] = []
        for record in manifest.records {
            guard let trashed = record.trashed else { continue }
            if record.viaAdmin {
                adminLines.append("/bin/mkdir -p \(quote((record.original as NSString).deletingLastPathComponent)); /bin/mv -n \(quote(trashed)) \(quote(record.original))")
                continue
            }
            do {
                guard !fm.fileExists(atPath: record.original) else {
                    failures.append("\(record.original.tildePath) already exists, so the copy in the Trash was kept.")
                    continue
                }
                try fm.createDirectory(atPath: (record.original as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try fm.moveItem(atPath: trashed, toPath: record.original)
                log("Restored \(record.original)")
            } catch {
                let reason = fm.fileExists(atPath: trashed) ? error.localizedDescription : "it's no longer in the Trash."
                failures.append("Couldn't restore \(record.original.tildePath): \(reason)")
                log("Restore failed for \(record.original): \(error.localizedDescription)", "WARN")
            }
        }
        if !adminLines.isEmpty {
            let script = "do shell script \(appleScriptString(adminLines.joined(separator: "; "))) with prompt \(appleScriptString("Traceless needs your password to put back protected items of \(manifest.app).")) with administrator privileges"
            let r = Shell.run("/usr/bin/osascript", ["-e", script])
            if r.status != 0 { failures.append("Protected items weren't put back. You can drag them out of the Trash yourself.") }
        }
        if fm.fileExists(atPath: manifest.appPath) {
            let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
            Shell.run(lsregister, ["-f", manifest.appPath])
        }
        if manifest.dockTileRemoved { failures.append("The Dock icon isn't restored automatically. Drag the app back to the Dock if you want it there.") }
        log("=== Restore finished, \(failures.count) notes ===")
        log.flush()
        return failures
    }
}

private extension TraceKind {
    /// Files and launch-job plists are both moved to the Trash.
    var fileLike: TraceKind {
        switch self {
        case .file, .launchJob: return .file
        default: return self
        }
    }
}
