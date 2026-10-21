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

    /// Asks ScreenCaptureKit whether capture is authorized right now and
    /// reports on the main thread. `CGPreflightScreenCaptureAccess` reflects
    /// the grant the process started with; this reflects the current TCC
    /// state, which is what changes when the user revokes access in System
    /// Settings while the app is running.
    static func checkScreenRecordingAuthorization(_ completion: @escaping (Bool) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { _, error in
            var denied = false
            if let error {
                let nsError = error as NSError
                denied = nsError.domain == SCStreamError.errorDomain
                    && nsError.code == SCStreamError.Code.userDeclined.rawValue
                NSLog("Quirky: ScreenCaptureKit content query failed: \(nsError.domain) \(nsError.code)")
            }
            DispatchQueue.main.async { completion(!denied) }
        }
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
        alert.informativeText = "Quirky needs Screen Recording permission to capture screen regions for text, color, element, SVG, and pixel-measurement extraction.\n\nPlease grant access in System Settings → Privacy & Security → Screen Recording."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        // A menu-bar-only app has nothing in front to attach the alert to;
        // without this it can open behind the frontmost app's windows.
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: Accessibility (required by the DOM inspector)

    // The global hotkey goes through Carbon and needs no Accessibility
    // access. DOM mode does: it reads the browser window's geometry through
    // the Accessibility API, which returns nothing for an untrusted process.

    static var hasAccessibilityPermission: Bool {
        return AXIsProcessTrusted()
    }

    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func showAccessibilityDeniedAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = "Quirky needs Accessibility permission for the DOM inspector — it reads the browser window's position to place element outlines.\n\nPlease grant access in System Settings → Privacy & Security → Accessibility."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: Common

    static func showRestartRequiredAlert() {
        let alert = NSAlert()
        alert.messageText = "Перезапустите приложение"
        alert.informativeText = "После выдачи разрешения нужно перезапустить приложение через меню Apple → Завершить и открыть заново."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "ОК")
        alert.runModal()
    }
}
