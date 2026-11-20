import AppKit

enum MacStorageSettings {
    // Storage.appex's bundle identifier on current macOS.
    static let url = URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!

    @discardableResult static func open() -> Bool {
        if NSWorkspace.shared.open(url) { return true }
        // Still offer System Settings if a future macOS changes the deep link.
        return NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
}
