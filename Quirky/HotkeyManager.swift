import Cocoa
import Carbon.HIToolbox

/// Sandbox-safe global hotkey manager. Uses Carbon's `RegisterEventHotKey`,
/// which is the only system-wide hotkey API Apple sanctions inside the
/// App Store sandbox (CGEventTap requires Accessibility and is rejected
/// by App Review). Each hotkey is registered on demand and unregistered
/// the moment its trigger condition stops being true, so we don't sit
/// on common keys like Tab / Esc system-wide outside an active capture.
///
/// The handler chain hops to the main thread before invoking app code —
/// the Carbon callback runs on whatever thread HIToolbox uses, which is
/// not safe for AppKit mutation.
final class HotkeyManager {

    enum HotkeyID: UInt32 {
        case capture = 1   // ⌘⇧1 — always registered while the app runs
        case tab = 2       // Tab — registered only during capture w/ ≥2 modes
        case escape = 3    // Esc — registered only while SPX is the active mode
        case shiftTab = 4  // ⇧Tab — same window as Tab, cycles the other way
    }

    /// FourCharCode 'QRKY' for hotkey signature.
    private static let signature: OSType = 0x51524B59

    var onCapture: (() -> Void)?
    var onTab: (() -> Void)?
    var onShiftTab: (() -> Void)?
    var onEscape: (() -> Void)?

    private var captureRef: EventHotKeyRef?
    private var tabRef: EventHotKeyRef?
    private var shiftTabRef: EventHotKeyRef?
    private var escRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init() {
        installEventHandler()
    }

    deinit {
        unregisterAll()
        if let h = handlerRef { RemoveEventHandler(h) }
    }

    // MARK: Public registration

    /// Always-on ⌘⇧1 — call once at app launch.
    func registerCaptureHotkey() {
        guard captureRef == nil else { return }
        captureRef = register(
            id: .capture,
            keyCode: UInt32(kVK_ANSI_1),
            modifiers: UInt32(cmdKey | shiftKey)
        )
    }

    /// Tab cycles modes forward during capture, ⇧Tab backward; only register
    /// when capture is active AND there's more than one mode to cycle to.
    /// Outside that window both pass through to the focused app.
    ///
    /// Carbon matches modifiers exactly, so ⇧Tab needs its own registration —
    /// the bare-Tab hotkey never fires while Shift is down.
    func setTabHotkeyActive(_ active: Bool) {
        if active {
            if tabRef == nil {
                tabRef = register(id: .tab, keyCode: UInt32(kVK_Tab), modifiers: 0)
            }
            if shiftTabRef == nil {
                shiftTabRef = register(id: .shiftTab, keyCode: UInt32(kVK_Tab), modifiers: UInt32(shiftKey))
            }
        } else {
            if let ref = tabRef { UnregisterEventHotKey(ref); tabRef = nil }
            if let ref = shiftTabRef { UnregisterEventHotKey(ref); shiftTabRef = nil }
        }
    }

    /// Esc dismisses SPX ghost overlay; only register while SPX is the
    /// active capture mode. Otherwise the OverlayWindow itself catches
    /// Esc via its keyDown handler (it's the key window in opaque modes).
    func setEscapeHotkeyActive(_ active: Bool) {
        if active {
            guard escRef == nil else { return }
            escRef = register(id: .escape, keyCode: UInt32(kVK_Escape), modifiers: 0)
        } else if let ref = escRef {
            UnregisterEventHotKey(ref)
            escRef = nil
        }
    }

    func unregisterAll() {
        if let ref = captureRef { UnregisterEventHotKey(ref); captureRef = nil }
        if let ref = tabRef { UnregisterEventHotKey(ref); tabRef = nil }
        if let ref = shiftTabRef { UnregisterEventHotKey(ref); shiftTabRef = nil }
        if let ref = escRef { UnregisterEventHotKey(ref); escRef = nil }
    }

    // MARK: Internals

    private func register(id: HotkeyID, keyCode: UInt32, modifiers: UInt32) -> EventHotKeyRef? {
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id.rawValue)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status != noErr {
            NSLog("Quirky: RegisterEventHotKey(\(id)) failed with status \(status)")
            return nil
        }
        return ref
    }

    private func installEventHandler() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, ctx -> OSStatus in
                guard let eventRef = eventRef, let ctx = ctx else { return noErr }
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard hotKeyID.signature == HotkeyManager.signature else { return noErr }
                let mgr = Unmanaged<HotkeyManager>.fromOpaque(ctx).takeUnretainedValue()
                let id = HotkeyID(rawValue: hotKeyID.id)
                DispatchQueue.main.async {
                    switch id {
                    case .capture:  mgr.onCapture?()
                    case .tab:      mgr.onTab?()
                    case .shiftTab: mgr.onShiftTab?()
                    case .escape:   mgr.onEscape?()
                    case .none:     break
                    }
                }
                return noErr
            },
            1,
            &spec,
            userData,
            &handlerRef
        )
    }
}
