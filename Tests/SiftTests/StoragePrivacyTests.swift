import AppKit
import SwiftUI
import XCTest
@testable import Sift

final class StoragePrivacyTests: XCTestCase {
    private func fixture() throws -> URL {
        // Outside macOS's real per-user protected temporary-data tree.
        let root = URL(fileURLWithPath: "/private/tmp/Sift-privacy-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.standardizedFileURL
    }
    private func write(_ path: String, in root: URL, bytes: Int = 4096) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 17, count: bytes).write(to: file)
    }

    func testKnownProtectedPathsAndDataAliasesAreRecognizedLexically() {
        let policy = StoragePrivacyPolicy(home: "/Users/test")
        for suffix in ["Music", "Music/Music/Music Library.musiclibrary", "Pictures", "Desktop", "Documents", "Downloads", ".Trash",
                       "Library/Containers/com.apple.Music", "Library/Group Containers", "Library/Mail", "Library/Messages",
                       "Library/Calendars", "Library/Application Support/AddressBook", "Library/CloudStorage"] {
            XCTAssertTrue(policy.isProtected("/Users/test/" + suffix), suffix)
            XCTAssertTrue(policy.isProtected(StorageOverviewService.rootPath + "/Users/test/" + suffix), suffix)
        }
        XCTAssertTrue(policy.isProtected("/Users/other/Music"))
        XCTAssertTrue(policy.isProtected("/private/var/folders/xx/yy"))
        XCTAssertTrue(policy.isProtected("/var/db/TCC"))
        XCTAssertTrue(policy.isProtected("/Volumes/External"))
        XCTAssertTrue(policy.isProtected("/somewhere/My Photos.photoslibrary/private"))
        XCTAssertEqual(StoragePrivacyPolicy.canonical(StorageOverviewService.rootPath + "/Users/test/a/../Music"), "/Users/test/Music")
    }

    func testOrdinaryDeveloperPathsAreNotSkippedAndExplicitConsentIsNarrow() {
        let policy = StoragePrivacyPolicy(home: "/Users/test")
        for path in ["/Users/test/.cache/uv", "/Users/test/.codex/worktrees", "/Users/test/Library/Caches/Codex",
                     "/Users/test/Library/Developer/Xcode/DerivedData", "/projects/Music", "/Users/test/Music-old",
                     "/Users/test/Library/Containers-old"] {
            XCTAssertFalse(policy.isProtected(path), path)
        }
        XCTAssertTrue(policy.shouldSkip("/Users/test/Music", scanRoot: "/Users/test"))
        XCTAssertFalse(policy.shouldSkip("/Users/test/Music/library", scanRoot: "/Users/test/Music"))
        XCTAssertFalse(policy.shouldSkip("/Users/test/Documents/project", scanRoot: "/Users/test/Documents/project"))
        XCTAssertTrue(policy.identifier(for: "/Users/test/Music").hasSuffix(":explicit-location"))
        XCTAssertTrue(policy.fallbackMasks(for: "/Users/test/Music").isEmpty)
        XCTAssertTrue(policy.fallbackMasks(for: "/Users/test").contains("Music"))
    }

    func testNativeScanSkipsBeforeOpeningDeniedMediaFolderAndValidationDoesToo() throws {
        let root = try fixture()
        let music = root.appendingPathComponent("Music")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: music.path); try? FileManager.default.removeItem(at: root) }
        try write("Music/private-song", in: root, bytes: 1_048_576)
        try write("Library/Containers/com.apple.Music/private-database", in: root, bytes: 1_048_576)
        try write("Library/Caches/build-data", in: root, bytes: 4096)
        try write("Projects/repo/output", in: root, bytes: 4096)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: music.path)
        let policy = StoragePrivacyPolicy(home: root.path)
        let result = try NativeStorageScanner(privacyPolicy: policy).measure(path: root.path)
        let validation = try NativeStorageScanner(metadataOnly: true, privacyPolicy: policy).measure(path: root.path)
        XCTAssertFalse(result.measurement.limitedAccess, "Skipping precedes openat, so denied folders do not produce access failures")
        XCTAssertFalse(validation.measurement.limitedAccess)
        XCTAssertEqual(result.fingerprint, validation.fingerprint)
        XCTAssertEqual(result.measurement.privacyExcluded, true)
        XCTAssertTrue(result.measurement.excludedPaths?.contains(music.path) ?? false)
        XCTAssertEqual(result.measurement.folders.first { $0.path == music.path }?.privacySkipped, true)
        XCTAssertFalse(result.children.contains { $0.path == music.path }, "Skipped roots must not become fake empty measurements")
        XCTAssertFalse(result.measurement.largeFiles?.contains { $0.path.contains("private-") } ?? true)
        XCTAssertEqual(result.measurement.fileCount, 2)
        XCTAssertLessThan(try XCTUnwrap(result.measurement.totalBytes), 100_000)
        let library = try XCTUnwrap(result.children.first { $0.path == root.appendingPathComponent("Library").path })
        XCTAssertEqual(library.folders.first { $0.path.hasSuffix("/Containers") }?.privacySkipped, true)
        XCTAssertEqual(library.privacyExcluded, true)
    }

    func testExplicitProtectedLocationCanBeMeasuredAfterChoosingIt() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("Music/private-song", in: root, bytes: 65_536)
        let policy = StoragePrivacyPolicy(home: root.path)
        let music = root.appendingPathComponent("Music").path
        let native = try NativeStorageScanner(privacyPolicy: policy).measure(path: music).measurement
        let fallback = StorageOverviewService(privacyPolicy: policy).measureTree(path: music, engine: .du).measurement
        XCTAssertEqual(native.fileCount, 1)
        XCTAssertEqual(native.privacyExcluded, false)
        XCTAssertEqual(native.privacyPolicy, policy.identifier(for: music))
        XCTAssertEqual(native.totalBytes, fallback.totalBytes)
        XCTAssertEqual(fallback.privacyExcluded, false)
    }

    func testDUAndNativeFailureFallbackKeepPrivacyExclusions() throws {
        let root = try fixture()
        let music = root.appendingPathComponent("Music")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: music.path); try? FileManager.default.removeItem(at: root) }
        try write("Music/private-song", in: root, bytes: 1_048_576)
        try write("Projects/repo/output", in: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: music.path)
        let policy = StoragePrivacyPolicy(home: root.path)
        let service = StorageOverviewService(privacyPolicy: policy, nativeScan: { _, _, _, _ in throw NativeStorageScanner.ScanError.unsupported })
        for engine in [StorageOverviewService.Engine.du, .native] {
            let result = service.measureTree(path: root.path, engine: engine).measurement
            XCTAssertFalse(result.limitedAccess, "du -I must skip denied Music before descending")
            XCTAssertEqual(result.privacyExcluded, true)
            XCTAssertEqual(result.privacyPolicy, policy.identifier(for: root.path))
            XCTAssertFalse(result.folders.contains { $0.path == music.path })
            XCTAssertLessThan(try XCTUnwrap(result.totalBytes), 100_000)
        }
    }

    func testPrivacyScopeSurvivesProgressAndHistoryAndDoesNotCompareAgainstOldFullScans() throws {
        let old = StorageMeasurement(path: "/example", folders: [], totalBytes: 1000, date: Date(), limitedAccess: false, timedOut: false,
            largeFiles: [.init(path: "/example/Music/old-private-song", bytes: 1000, logicalBytes: 1000, shared: false)], fileCount: 1)
        let skipped = StorageFolder(path: "/example/Music", bytes: 0, privacySkipped: true)
        let progress = StorageScanProgress(path: old.path, startedAt: Date(), completedDirectories: 1, currentPath: nil, folders: [skipped], children: [], totalBytes: nil,
            privacyPolicy: StoragePrivacyPolicy.version, privacyExcluded: true, excludedPaths: [skipped.path])
        let partial = progress.displaying(over: old)
        XCTAssertEqual(partial.privacyExcluded, true)
        XCTAssertNil(partial.largeFiles, "An unrestricted file sample must not leak back into a privacy-safe refresh")
        XCTAssertFalse(partial.comparable(to: old), "Excluding protected folders must not be shown as a cleanup or size decrease")
        let decoded = try JSONDecoder().decode(StorageMeasurement.self, from: JSONEncoder().encode(partial))
        XCTAssertEqual(decoded.excludedPaths, [skipped.path])
        XCTAssertEqual(decoded.folders.first?.privacySkipped, true)
        XCTAssertNil(decoded.totalBytes)
        let complete = StorageMeasurement(path: old.path, folders: [skipped], totalBytes: 0, date: Date(), limitedAccess: false, timedOut: false,
            privacyPolicy: StoragePrivacyPolicy.version, privacyExcluded: true)
        XCTAssertEqual(StorageBrowserStatus.resolve(measurement: complete, scanning: false, queuePosition: nil, stopping: false), .privacyScoped)
    }

    func testWorkspaceDiscoverySkipsProtectedLibrariesButKeepsDeveloperProjects() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["Music/not-a-cleanup-target/.git/config", "Projects/repo/.git/config"] { try write(path, in: root) }
        let scanner = WorkspaceScanner(privacyPolicy: StoragePrivacyPolicy(home: root.path))
        let discovered = scanner.discoverWorkspaces(in: [root])
        XCTAssertEqual(discovered.map(\.path), [root.appendingPathComponent("Projects/repo").path])
        XCTAssertEqual(scanner.discoverWorkspaces(in: [root.appendingPathComponent("Music/not-a-cleanup-target")]).count, 1)
    }
}
