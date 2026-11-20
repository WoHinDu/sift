import Foundation
import XCTest
@testable import Sift

private actor CleanupGate {
    private(set) var started: [String] = []
    private var waits: [String: CheckedContinuation<Void, Error>] = [:]
    func run(_ id: String) async throws {
        started.append(id)
        try await withCheckedThrowingContinuation { waits[id] = $0 }
    }
    func release(_ id: String, failing: Bool = false) {
        let continuation = waits.removeValue(forKey: id)
        if failing { continuation?.resume(throwing: NSError(domain: "Fixture cleanup failure", code: 1)) }
        else { continuation?.resume() }
    }
}

final class ParallelCleanupTests: XCTestCase {
    private func cache(_ id: String, path: String? = nil, bytes: Int64 = 100) -> GlobalCache {
        .init(id: id, name: id, detail: "Fixture", symbolName: "shippingbox", state: .available(bytes: bytes, path: path ?? "/fixture/\(id)"))
    }
    @MainActor private func until(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Concurrent cleanup did not reach expected state")
        throw NSError(domain: "Fixture timeout", code: 1)
    }
    func testReservationsRejectDuplicateAndOverlappingPathsButAllowIndependentJobs() {
        var activity = CleanupActivity()
        XCTAssertTrue(activity.begin("cache:uv", paths: ["/Users/test/.cache/uv"]))
        XCTAssertFalse(activity.begin("cache:uv", paths: ["/different"]))
        XCTAssertFalse(activity.begin("worktrees", paths: ["/Users/test/.cache/uv/project/.venv"]))
        XCTAssertFalse(activity.begin("parent", paths: ["/Users/test/.cache"]))
        XCTAssertFalse(activity.begin("alias", paths: ["/System/Volumes/Data/Users/test/.cache/uv"]))
        XCTAssertTrue(activity.begin("cache:bun", paths: ["/Users/test/.cache/uv-other"]))
        XCTAssertTrue(activity.begin("docker", paths: []))
        XCTAssertEqual(activity.jobs.count, 3)
        XCTAssertTrue(activity.jobs.values.allSatisfy(\.overlapped))
        activity.finish("cache:uv")
        XCTAssertFalse(activity.isEmpty)
        XCTAssertTrue(activity.canStart("worktrees", paths: ["/Users/test/.cache/uv/project/.venv"]))
        activity.finish("cache:bun"); activity.finish("docker")
        XCTAssertTrue(activity.isEmpty)
    }
    func testReservationsRecognizeSymlinkAliases() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Sift-cleanup-locks-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        var activity = CleanupActivity()
        XCTAssertTrue(activity.begin("first", paths: [real.path]))
        XCTAssertFalse(activity.canStart("second", paths: [alias.appendingPathComponent("child").path]))
    }

    @MainActor func testIndependentCacheAndDockerJobsReallyOverlapAndFinishIndependently() async throws {
        let gate = CleanupGate()
        let uv = cache("uv"), bun = cache("bun")
        let model = AppModel(cleanup: .init(
            cleanCache: { try await gate.run($0) },
            inspectCache: { id in .init(id: id, name: id, detail: "Fixture", symbolName: "shippingbox", state: .available(bytes: 0, path: "/fixture/\(id)")) },
            pruneDocker: { try await gate.run("docker"); return "Total reclaimed space: 0B" },
            inspectDocker: { .available(reclaimableBytes: 0, detail: "Fixture") }))
        model.globalCaches = [uv, bun]
        model.cleanGlobalCache(uv); model.cleanGlobalCache(bun); model.pruneDockerImages()
        model.cleanGlobalCache(uv); model.pruneDockerImages() // Repeated clicks cannot launch duplicate commands.
        try await until { await gate.started.count == 3 }
        XCTAssertEqual(model.cleaningGlobalCacheIDs, ["uv", "bun"])
        XCTAssertTrue(model.isCleaningDocker)
        XCTAssertTrue(model.isCleaning)
        await gate.release("uv")
        try await until { !model.cleaningGlobalCacheIDs.contains("uv") }
        XCTAssertTrue(model.cleaningGlobalCacheIDs.contains("bun"))
        XCTAssertTrue(model.isCleaningDocker)
        XCTAssertTrue(model.isCleaning, "One completed operation must not clear other busy states")
        await gate.release("bun", failing: true)
        try await until { !model.cleaningGlobalCacheIDs.contains("bun") }
        XCTAssertNotNil(model.cleanupErrors["cache:bun"])
        await gate.release("docker")
        try await until { !model.isCleaning }
        XCTAssertNotNil(model.cleanupErrors["cache:bun"], "A later success must not hide another source's failure")
        let started = await gate.started
        XCTAssertEqual(Set(started), ["uv", "bun", "docker"])
        XCTAssertEqual(started.count, 3)
    }

    @MainActor func testBulkUsesParallelSourceJobsAndSkipsAlreadyRunningSources() async throws {
        let gate = CleanupGate()
        let model = AppModel(cleanup: .init(cleanCache: { try await gate.run($0) },
            inspectCache: { _ in nil }, pruneDocker: { try await gate.run("docker"); return "" },
            inspectDocker: { .available(reclaimableBytes: 0, detail: "Fixture") }))
        model.globalCaches = [cache("uv"), cache("bun"), cache("pulumi")]
        model.dockerState = .available(reclaimableBytes: 100, detail: "Fixture")
        model.cleanGlobalCache(model.globalCaches[0])
        model.cleanAllGlobalCaches()
        model.cleanAllGlobalCaches()
        try await until { await gate.started.count == 3 }
        XCTAssertEqual(model.cleanableGlobalStorageCount, 0)
        XCTAssertFalse(model.cleaningGlobalCacheIDs.contains("pulumi"), "Bulk cleanup still excludes opt-in plugins")
        await gate.release("uv"); await gate.release("bun"); await gate.release("docker")
        try await until { !model.isCleaning }
        let started = await gate.started
        XCTAssertEqual(started.count, 3)
    }

    @MainActor func testCacheReservationOnlyBlocksConflictingWorktreeSelection() async throws {
        let gate = CleanupGate()
        let model = AppModel(cleanup: .init(cleanCache: { try await gate.run($0) }, inspectCache: { _ in nil },
            pruneDocker: { "" }, inspectDocker: { .checking }))
        let uv = cache("uv")
        model.globalCaches = [uv]
        model.cleanGlobalCache(uv)
        let root = URL(fileURLWithPath: "/fixture/project")
        let shared = CleanupCandidate(url: URL(fileURLWithPath: "/fixture/uv/generated/.venv"), kind: CleanupKind.supported[0], allocatedBytes: 100)
        let independent = CleanupCandidate(url: root.appendingPathComponent("node_modules"), kind: CleanupKind.supported[0], allocatedBytes: 100)
        model.workspaces = [.init(url: root, name: "Fixture", branch: "main", repositoryID: "fixture", repositoryName: "Fixture", candidates: [shared, independent])]
        model.selectedCandidateIDs = [shared.id]
        XCTAssertFalse(model.canCleanSelected)
        model.selectedCandidateIDs = [independent.id]
        XCTAssertTrue(model.canCleanSelected)
        try await until { await gate.started.count == 1 }
        await gate.release("uv")
        try await until { !model.isCleaning }
    }
}
