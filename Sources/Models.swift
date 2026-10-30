import Foundation

enum AppKind: Hashable {
    case native, safariWebApp, chromeApp
}

struct InstalledApp: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let name: String
    let bundleID: String?
    let version: String?
    let executable: String?
    let bundleName: String?
    let kind: AppKind
    /// Sealed by macOS (System Integrity Protection). Shown for its size, never removed.
    let isProtected: Bool
    var size: Int64 = 0

    var subtitle: String {
        switch kind {
        case .safariWebApp: return "Safari web app · made with Add to Dock"
        case .chromeApp: return "Chrome app shortcut"
        case .native:
            var parts: [String] = []
            if let version { parts.append("Version \(version)") }
            if let bundleID { parts.append(bundleID) }
            return parts.isEmpty ? url.path.tildePath : parts.joined(separator: " · ")
        }
    }
}

enum TraceCategory: Int, CaseIterable, Comparable {
    case application, integration, preferences, support, caches, containers, webData,
         savedState, logs, launchItems, helpers, plugins, temporary, receipts

    var title: String {
        switch self {
        case .application: return "Application"
        case .integration: return "Dock"
        case .preferences: return "Preferences"
        case .support: return "Application Support"
        case .caches: return "Caches"
        case .containers: return "Containers"
        case .webData: return "Web Data & Cookies"
        case .savedState: return "Saved Window State"
        case .logs: return "Logs & Crash Reports"
        case .launchItems: return "Background Items"
        case .helpers: return "Privileged Helpers"
        case .plugins: return "Plug-ins & Extensions"
        case .temporary: return "Temporary Files"
        case .receipts: return "Installer Receipts"
        }
    }

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// How sure Traceless is that an item belongs to the app. Only `.related` and up are
/// checked by default; `.shared` items stay unchecked so other apps keep working.
enum MatchStrength: Int, Comparable {
    case shared, related, name, exact

    var label: String {
        switch self {
        case .exact: return "Exact match"
        case .name: return "Name match"
        case .related: return "Earlier install"
        case .shared: return "Shared"
        }
    }

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

enum TraceKind: Hashable {
    case file
    case launchJob(label: String?, system: Bool)
    case receipt(String)
    case dockTile
}

struct Trace: Identifiable, Hashable {
    let id = UUID()
    let url: URL?
    let title: String
    let category: TraceCategory
    let strength: MatchStrength
    let reason: String
    var size: Int64
    let needsAdmin: Bool
    var isSelected: Bool
    let kind: TraceKind

    var location: String {
        switch kind {
        case .dockTile: return "Dock"
        case .receipt: return "Installer database"
        default: return url?.deletingLastPathComponent().path.tildePath ?? ""
        }
    }
}

struct TraceReport {
    var traces: [Trace]
    var lockedPlaces: [String]
    var hasFullDiskAccess: Bool
}

struct RemovalRecord: Codable {
    let original: String
    let trashed: String?
    let viaAdmin: Bool
}

struct RemovalManifest: Codable {
    let app: String
    let appPath: String
    let date: Date
    var records: [RemovalRecord]
    var dockTileRemoved: Bool
    var receiptsForgotten: [String]
}

struct RemovalResult {
    var manifest: RemovalManifest
    var manifestURL: URL?
    var failures: [String]
    var freed: Int64
    var appRemoved: Bool
}
