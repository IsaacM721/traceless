import Foundation

enum AppScanner {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static var roots: [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true),
         home.appendingPathComponent("Applications", isDirectory: true)]
    }

    /// Every .app in /Applications and ~/Applications, plus apps one or two folders deep
    /// (vendor folders such as "Utilities", "Arturia", "Chrome Apps").
    static func discover() -> [URL] {
        var found: [URL] = []
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        func walk(_ dir: URL, depth: Int) {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles]) else { return }
            for item in items {
                let values = try? item.resourceValues(forKeys: Set(keys))
                if values?.isSymbolicLink == true { continue }
                if item.pathExtension.lowercased() == "app" {
                    found.append(item.standardizedFileURL)
                } else if values?.isDirectory == true, depth < 2 {
                    walk(item, depth: depth + 1)
                }
            }
        }
        for root in roots { walk(root, depth: 0) }
        return found
    }

    static func describe(_ url: URL) -> InstalledApp {
        let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
        let bundleID = info["CFBundleIdentifier"] as? String
        let kind: AppKind
        if bundleID?.hasPrefix("com.apple.Safari.WebApp.") == true { kind = .safariWebApp }
        else if bundleID?.hasPrefix("com.google.Chrome.app.") == true { kind = .chromeApp }
        else { kind = .native }
        return InstalledApp(
            url: url,
            name: url.deletingPathExtension().lastPathComponent,
            bundleID: bundleID,
            version: info["CFBundleShortVersionString"] as? String,
            executable: info["CFBundleExecutable"] as? String,
            bundleName: (info["CFBundleDisplayName"] ?? info["CFBundleName"]) as? String,
            kind: kind,
            isProtected: isSystemProtected(url))
    }

    /// Apps such as Safari are sealed by System Integrity Protection (SF_RESTRICTED flag).
    static func isSystemProtected(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        let restricted: UInt32 = 0x0008_0000 // SF_RESTRICTED
        return (st.st_flags & restricted) != 0 || url.path.hasPrefix("/System/")
    }

    /// An app's real footprint. Some installers (Multipass, for one) make the bundle's
    /// Contents folder a link into /Library; measure where it really lives.
    static func appSize(of url: URL) -> Int64 {
        let contents = url.appendingPathComponent("Contents")
        if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: contents.path) {
            let target = URL(fileURLWithPath: dest, relativeTo: url).standardizedFileURL.resolvingSymlinksInPath()
            return allocatedSize(of: url) + allocatedSize(of: target)
        }
        return allocatedSize(of: url)
    }

    /// Space the item really takes on disk: allocated blocks, not the logical file size,
    /// with hard-linked files counted once. Uses fts for speed on huge bundles like Xcode.
    static func allocatedSize(of url: URL) -> Int64 {
        var total: Int64 = 0
        var seenInodes = Set<UInt64>()
        guard let cPath = strdup(url.path) else { return 0 }
        defer { free(cPath) }
        var paths: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return 0 }
        defer { fts_close(fts) }
        while let entry = fts_read(fts) {
            let info = Int32(entry.pointee.fts_info)
            guard info == FTS_F || info == FTS_SL || info == FTS_DP || info == FTS_DEFAULT,
                  let st = entry.pointee.fts_statp?.pointee else { continue }
            if info == FTS_F && st.st_nlink > 1 {
                let key = UInt64(st.st_ino) ^ (UInt64(UInt32(bitPattern: st.st_dev)) << 48)
                if !seenInodes.insert(key).inserted { continue }
            }
            total += Int64(st.st_blocks) * 512
        }
        return total
    }
}
