import AppKit
import SwiftUI
import XCTest
@testable import Sift

final class SiftSettingsStyleTests: XCTestCase {
    @MainActor func testSettingsSurfacesAreOpaqueInBothAppearances() throws {
        for name in [NSAppearance.Name.darkAqua, .aqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            appearance.performAsCurrentDrawingAppearance {
                let content = NSColor(SiftSettingsStyle.content).usingColorSpace(.sRGB)!
                let card = NSColor(SiftSettingsStyle.card).usingColorSpace(.sRGB)!
                XCTAssertEqual(content.alphaComponent, 1, accuracy: 0.001)
                XCTAssertEqual(card.alphaComponent, 1, accuracy: 0.001)
                XCTAssertGreaterThan(card.redComponent, content.redComponent)
                XCTAssertEqual(content.redComponent, name == .darkAqua ? 22.0 / 255 : 245.0 / 255, accuracy: 0.005)
            }
        }
    }

    @MainActor func testGroupedSettingsCardFitsPanelWidth() {
        let card = NSHostingView(rootView: VStack(alignment: .leading, spacing: 9) {
            Text("WORKTREE CLEANUP").font(.caption.weight(.semibold))
            HStack {
                Text("Delete immediately").font(.caption)
                Spacer()
                Toggle("Delete immediately", isOn: .constant(false)).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            Text("Permanent deletion cannot be undone. Workspace roots, source files, and .git remain protected.")
                .font(.caption2).fixedSize(horizontal: false, vertical: true)
        }.siftSettingsCard().frame(width: 358))
        card.layoutSubtreeIfNeeded()
        XCTAssertEqual(card.fittingSize.width, 358, accuracy: 1)
        XCTAssertGreaterThan(card.fittingSize.height, 70)
        XCTAssertLessThan(card.fittingSize.height, 160)
    }
}
