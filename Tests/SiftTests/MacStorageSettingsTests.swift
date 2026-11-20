import XCTest
@testable import Sift

final class MacStorageSettingsTests: XCTestCase {
    func testStorageLinkTargetsSystemSettingsWithoutRequestingFileAccess() {
        XCTAssertEqual(MacStorageSettings.url.scheme, "x-apple.systempreferences")
        XCTAssertEqual(MacStorageSettings.url.absoluteString, "x-apple.systempreferences:com.apple.settings.Storage")
        XCTAssertFalse(MacStorageSettings.url.isFileURL)
    }
}
