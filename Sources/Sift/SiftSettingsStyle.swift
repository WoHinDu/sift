import AppKit
import SwiftUI

/// Tern-style settings surfaces are opaque: glass controls may sit above
/// them, but the underlying cleanup rows must never show through the text.
enum SiftSettingsStyle {
    static let content = dynamic(dark: (22, 21, 20), light: (245, 245, 244))
    static let card = dynamic(dark: (27, 27, 26), light: (255, 255, 255))
    static let border = dynamic(dark: (51, 50, 48), light: (218, 218, 217))

    private static func dynamic(dark: (CGFloat, CGFloat, CGFloat), light: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: rgb.0 / 255, green: rgb.1 / 255, blue: rgb.2 / 255, alpha: 1)
        })
    }
}

extension View {
    func siftSettingsCard() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(SiftSettingsStyle.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
