import Cocoa
import ScreenCaptureKit

final class PermissionManager {

    // MARK: Screen Recording

    static var hasScreenRecordingPermission: Bool {
        return CGPreflightScreenCaptureAccess()
    }

    /// Call at every app launch — registers the app in "Screen & System Audio Recording"
    /// via ScreenCaptureKit without showing any dialog.
    static func registerWithScreenCaptureKit() {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { _, _ in }
    }

    @discardableResult
    static func requestScreenRecordingPermission() -> Bool {
        // macOS 15+: ScreenCaptureKit registers the app in "Screen & System Audio Recording" list
        registerWithScreenCaptureKit()
        // Legacy API: shows the system prompt on older macOS
        CGRequestScreenCaptureAccess()
        return hasScreenRecordingPermission
    }

    static func showPermissionDeniedAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = "Quirky needs Screen Recording permission to read text, colors and pixel sizes from your screen.\n\nPlease grant access in System Settings → Privacy & Security → Screen Recording."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
