import AppKit
import SwiftUI
import XCTest
@testable import Sift

final class StorageBrowserOverviewTests: XCTestCase {
    func testCapacityDoesNotInventFreeSpaceForUnavailableOrRacingValues() {
        for values in [StorageCapacityPresentation(free: nil, capacity: nil),
                       .init(free: 100, capacity: nil), .init(free: 101, capacity: 100),
                       .init(free: -1, capacity: 100), .init(free: 0, capacity: 0)] {
            XCTAssertFalse(values.isValid)
            XCTAssertNil(values.used)
            XCTAssertNil(values.freeFraction)
            XCTAssertFalse(values.lowSpace)
        }
        let valid = StorageCapacityPresentation(free: 20, capacity: 100)
        XCTAssertEqual(valid.used, 80)
        XCTAssertEqual(valid.freeFraction, 0.2)
        XCTAssertFalse(valid.lowSpace)
        XCTAssertTrue(StorageCapacityPresentation(free: 0, capacity: 100).lowSpace)
    }

    func testScanStatusPriorityAndIncompleteResultsCannotClaimCompletion() {
        var result = StorageMeasurement(path: "/fixture", folders: [], totalBytes: 100, date: Date(), limitedAccess: false, timedOut: false)
        func state(_ result: StorageMeasurement?) -> StorageBrowserStatus {
            .resolve(measurement: result, scanning: false, queuePosition: nil, stopping: false)
        }
        XCTAssertEqual(state(nil), .unscanned)
        XCTAssertEqual(state(result), .ready)
        XCTAssertEqual(StorageBrowserStatus.resolve(measurement: result, scanning: true, queuePosition: nil, stopping: false), .scanning)
        XCTAssertEqual(StorageBrowserStatus.resolve(measurement: result, scanning: false, queuePosition: 2, stopping: false), .queued(2))
        XCTAssertEqual(StorageBrowserStatus.resolve(measurement: result, scanning: true, queuePosition: nil, stopping: true), .stopping)
        result.cached = true; XCTAssertEqual(state(result), .cached)
        result = StorageMeasurement(path: "/fixture", folders: [], totalBytes: 100, date: Date(), limitedAccess: true, timedOut: false, cached: true)
        XCTAssertEqual(state(result), .limited)
        result = StorageMeasurement(path: "/fixture", folders: [], totalBytes: 100, date: Date(), limitedAccess: true, timedOut: true)
        XCTAssertEqual(state(result), .timedOut)
        result.cancelled = true; XCTAssertEqual(state(result), .cancelled)
        let unfinished = StorageMeasurement(path: "/fixture", folders: [], totalBytes: nil, date: Date(), limitedAccess: false, timedOut: false)
        XCTAssertEqual(state(unfinished), .limited)
        XCTAssertTrue(StorageBrowserStatus.limited.needsAttention)
        XCTAssertFalse(StorageBrowserStatus.scanning.needsAttention)
    }

    func testLocationSelectionPrefersAppDataAndRespectsPathBoundaries() {
        let home = "/Users/test"
        XCTAssertEqual(StorageLocation.shortcuts(home: home).map(\.name), ["Home", "App data", "Data volume"])
        XCTAssertEqual(StorageLocation.selected(for: home + "/Library/Caches", home: home), home + "/Library")
        XCTAssertEqual(StorageLocation.selected(for: StorageOverviewService.rootPath + home + "/.codex", home: home), home)
        XCTAssertEqual(StorageLocation.selected(for: home + "-other/Library", home: home), StorageOverviewService.rootPath)
        XCTAssertEqual(StorageLocation.selected(for: home + "/Library-old", home: home), home)
    }

    @MainActor func testCompactCapacityAndLocationControlsFitTheMenu() {
        for scheme in [ColorScheme.light, .dark] {
            for values in [StorageCapacityPresentation(free: 20_000_000_000, capacity: 500_000_000_000), .init(free: nil, capacity: nil)] {
                let card = NSHostingView(rootView: StorageCapacityOverview(values: values).frame(width: 424).preferredColorScheme(scheme))
                card.layoutSubtreeIfNeeded()
                XCTAssertEqual(card.fittingSize.width, 424, accuracy: 1)
                XCTAssertLessThan(card.fittingSize.height, 120, "The disk overview must leave room for actual results")
            }
            let shortcuts = NSHostingView(rootView: StorageLocationShortcuts(path: .constant(StorageOverviewService.rootPath)).frame(width: 424).preferredColorScheme(scheme))
            shortcuts.layoutSubtreeIfNeeded()
            XCTAssertLessThan(shortcuts.fittingSize.height, 44)
        }
    }

    @MainActor func testStorageBrowserFixturePreviewWhenRequested() throws {
        guard let destination = ProcessInfo.processInfo.environment["SIFT_STORAGE_PREVIEW"] else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Sift-browser-preview-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StorageHistoryStore(url: directory.appendingPathComponent("history.json"))
        let root = StorageOverviewService.rootPath
        let snapshot = StorageMeasurement(path: root, folders: [
            .init(path: root + "/Users", bytes: 60_000_000_000),
            .init(path: root + "/Library", bytes: 25_000_000_000),
            .init(path: root + "/private", bytes: 8_000_000_000)
        ], totalBytes: 93_000_000_000, date: Date(), limitedAccess: false, timedOut: false,
            largeFiles: [.init(path: root + "/Users/demo/Downloads/archive.dmg", bytes: 2_000_000_000, logicalBytes: 3_000_000_000, shared: true)], fileCount: 12345)
        store.save([root: snapshot])
        let overview = StorageOverviewModel(store: store, measure: { _, _, _ in XCTFail("Preview must not scan"); return (snapshot, []) })
        let app = AppModel()
        app.globalCaches = []; app.workspaces = []
        let content = VStack(alignment: .leading, spacing: 12) {
            Text("Fixture preview · Storage redesign").font(.caption2).foregroundStyle(SiftChartStyle.mutedText)
            StorageExplorerView(overview: overview).environmentObject(app)
        }.padding(18).frame(width: 460).background(Color(white: 0.07)).preferredColorScheme(.dark)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: destination))
    }
}
