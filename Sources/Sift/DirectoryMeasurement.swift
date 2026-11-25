import Foundation

/// Folder-attributed size plus the newest modification date found inside.
/// The date is a write time, not a last-use time: reading a cached file does
/// not update it. Directory dates are included because adding or removing an
/// entry updates its parent even when extracted files keep archive timestamps.
struct DirectoryMeasurement: Equatable, Sendable {
    var bytes: Int64 = 0
    var newestChange: Date?

    mutating func add(_ other: DirectoryMeasurement) {
        bytes += other.bytes
        if let date = other.newestChange, date > (newestChange ?? .distantPast) { newestChange = date }
    }

    /// Returns nil when any part of the tree could not be read, so a partial
    /// total is never presented as a measured size. A missing path measures as empty.
    static func measure(_ url: URL, now: Date = Date(), fileManager: FileManager = .default) -> DirectoryMeasurement? {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
            .contentModificationDateKey
        ]
        guard let root = try? url.resourceValues(forKeys: keys) else {
            return fileManager.fileExists(atPath: url.path) ? nil : DirectoryMeasurement()
        }
        var result = DirectoryMeasurement()
        // Dates in the future come from broken clocks or archives; ignoring them
        // keeps one odd file from marking a cache as permanently in use.
        let latestPlausibleDate = now.addingTimeInterval(60)
        func record(_ values: URLResourceValues) {
            guard values.isSymbolicLink != true else { return }
            if values.isRegularFile == true {
                result.bytes += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            }
            guard values.isRegularFile == true || values.isDirectory == true,
                  let date = values.contentModificationDate, date <= latestPlausibleDate,
                  date > (result.newestChange ?? .distantPast) else { return }
            result.newestChange = date
        }
        record(root)
        // A symbolic link is never followed: only its own entry is counted.
        guard root.isDirectory == true, root.isSymbolicLink != true else { return result }

        var failed = false
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in failed = true; return true }
        ) else { return nil }
        while let item = enumerator.nextObject() as? URL {
            guard let values = try? item.resourceValues(forKeys: keys) else { failed = true; continue }
            record(values)
        }
        return failed ? nil : result
    }
}
