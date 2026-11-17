import Foundation

/// A conservative traversal policy, not a TCC permission probe. Never enumerate
/// a protected folder to decide whether we may enumerate it. Explicit scans
/// inside one protected location remain possible, subject to macOS consent.
struct StoragePrivacyPolicy: Sendable {
    let home: String
    init(home: String = NSHomeDirectory()) { self.home = Self.canonical(home) }
    static let version = "privacy-safe-v1"
    private static let homeLocations = [
        "Desktop", "Documents", "Downloads", "Music", "Pictures", "Movies", ".Trash",
        "Library/Containers", "Library/Group Containers", "Library/Daemon Containers",
        "Library/Mail", "Library/Messages", "Library/Safari", "Library/Calendars", "Library/Reminders",
        "Library/Photos", "Library/MediaLibrary", "Library/Accounts", "Library/Assistant",
        "Library/Suggestions", "Library/IdentityServices", "Library/PersonalizationPortrait",
        "Library/IntelligencePlatform", "Library/Metadata/CoreSpotlight",
        "Library/Mobile Documents", "Library/CloudStorage",
        "Library/Application Support/AddressBook", "Library/Application Support/CallHistoryDB",
        "Library/Application Support/CallHistoryTransactions", "Library/Application Support/com.apple.TCC",
        "Library/Application Support/CloudDocs"
    ]
    private static let systemLocations = [
        "/private/var/db", "/private/var/folders", "/private/var/protected",
        "/Library/Application Support/com.apple.TCC", "/Library/Containers", "/Volumes", "/Network"
    ]
    private static let mediaPackages = ["photoslibrary", "photolibrary", "musiclibrary", "aplibrary"]

    static func canonical(_ path: String) -> String {
        // Lexical only: do not resolve symlinks or ask the filesystem about
        // a location while deciding whether that location should be skipped.
        var components: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { if !components.isEmpty { components.removeLast() }; continue }
            components.append(part)
        }
        var path = "/" + components.joined(separator: "/")
        let data = StorageOverviewService.rootPath
        if path == data { return "/" }
        if path.hasPrefix(data + "/") { path = String(path.dropFirst(data.count)) }
        if path == "/var" || path.hasPrefix("/var/") { path = "/private" + path }
        if path == "/tmp" || path.hasPrefix("/tmp/") { path = "/private" + path }
        if path == "/etc" || path.hasPrefix("/etc/") { path = "/private" + path }
        return path
    }
    private static func contains(_ root: String, _ path: String) -> Bool {
        root == path || path.hasPrefix(root + "/")
    }

    func isProtected(_ rawPath: String) -> Bool {
        let path = Self.canonical(rawPath)
        if Self.systemLocations.contains(where: { Self.contains($0, path) }) { return true }
        if path.split(separator: "/").contains(where: { component in
            Self.mediaPackages.contains((String(component) as NSString).pathExtension.lowercased())
        }) { return true }
        var homes = [home]
        let parts = path.split(separator: "/")
        if parts.count >= 2, parts[0] == "Users" { homes.append("/Users/" + parts[1]) }
        return homes.contains { home in
            Self.homeLocations.contains { Self.contains(home + "/" + $0, path) }
        }
    }

    func shouldSkip(_ path: String, scanRoot: String) -> Bool {
        !isProtected(scanRoot) && isProtected(path)
    }
    func identifier(for root: String) -> String {
        Self.version + (isProtected(root) ? ":explicit-location" : ":broad")
    }

    /// BSD du matches entry names, not full paths. Its safety fallback is
    /// deliberately more conservative than the path-specific native policy.
    func fallbackMasks(for root: String) -> [String] {
        guard !isProtected(root) else { return [] }
        return Array(Set(Self.homeLocations.map { URL(fileURLWithPath: $0).lastPathComponent } +
            ["db", "folders", "protected", "Volumes", "Network"] + Self.mediaPackages.map { "*." + $0 })).sorted()
    }
}
