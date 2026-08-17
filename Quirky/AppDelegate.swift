import Cocoa
#if !MAS_BUILD
import Sparkle
#endif

// MARK: - Capture Mode

enum CaptureMode: String, CaseIterable {
    case ocr
    case hex
    #if !MAS_BUILD
    // DOM and SVG modes drive Safari/Chrome via Apple Events, which the
    // Mac App Store sandbox doesn't grant without temporary-exception
    // entitlements that Apple frequently denies. They ship only in the
    // direct-distribution build.
    case dom
    case svg
    #endif
    case spx
    var displayName: String { rawValue.uppercased() }
}

// MARK: - Enabled Modes Storage

private enum EnabledModesStore {
    private static let key = "enabledModes"
    /// Source of truth for cycle order; tracks CaptureMode declaration
    /// (so MAS builds without .dom/.svg get the right order automatically).
    private static let canonicalOrder: [CaptureMode] = CaptureMode.allCases

    static func load() -> [CaptureMode] {
        let raw = UserDefaults.standard.array(forKey: key) as? [String]
        let modes = (raw ?? canonicalOrder.map { $0.rawValue })
            .compactMap(CaptureMode.init(rawValue:))
        let unique = canonicalOrder.filter { modes.contains($0) }
        return unique.isEmpty ? [.ocr] : unique
    }

    static func save(_ modes: [CaptureMode]) {
        let canonical = canonicalOrder.filter { modes.contains($0) }
        let final = canonical.isEmpty ? [CaptureMode.ocr] : canonical
        UserDefaults.standard.set(final.map { $0.rawValue }, forKey: key)
    }
}

// MARK: - Last Mode Storage

/// Remembers the mode the user last worked in, so the next ⌘⇧1 resumes
/// where they left off instead of always restarting at the first enabled
/// mode. Persisted across launches.
private enum LastModeStore {
    private static let key = "lastCaptureMode"

    static func load() -> CaptureMode? {
        guard let raw = UserDefaults.standard.string(forKey: key) else { return nil }
        return CaptureMode(rawValue: raw)
    }

    static func save(_ mode: CaptureMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: key)
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let overlay = OverlayWindow()
    private let hotkeys = HotkeyManager()
    private var isCapturing = false
    private var currentMode: CaptureMode = .ocr
    private var spxResumePending = false  // true while SPX is hidden-but-preserved
    private var spxIsGhost = false        // SPX overlay is in see-through (click-through) state
    private var previousApp: NSRunningApplication?
    private var preCapturedImages: [(displayID: CGDirectDisplayID, bounds: CGRect, image: CGImage)] = []

    // Stuck-overlay defenses. The overlay covers the whole screen above the
    // menu bar, so a wedged one leaves the machine unusable: the user sees a
    // frozen screenshot and can't reach anything to close it.
    private var watchdog: Timer?
    private var lastOverlayActivity = Date()
    private var captureStartedAt = Date.distantPast
    private var hotkeyBurst: [Date] = []

    #if !MAS_BUILD
    private let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    #endif
    private var modeTogglesView: ModeTogglesView?
    private let modePopover = ModePopover()

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupStatusItem()
        // Always register with ScreenCaptureKit so app appears in Screen & System Audio Recording list.
        // On macOS 15+, CGPreflightScreenCaptureAccess() may return true without registering in the new TCC list.
        PermissionManager.registerWithScreenCaptureKit()
        if !PermissionManager.hasScreenRecordingPermission { PermissionManager.requestScreenRecordingPermission() }
        setupHotkeys()
        overlay.onSPXPreserveHide = { [weak self] in self?.handleSPXPreserveHide() }
        overlay.onActivity = { [weak self] in self?.lastOverlayActivity = Date() }
        modePopover.onActivity = { [weak self] in self?.lastOverlayActivity = Date() }
        modePopover.delegate = self
        // Losing focus while an opaque overlay covers the screen is the exact
        // shape of the stuck-overlay bug: the user can drive other apps but
        // only sees a frozen screenshot. Bail out of capture instead.
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleAppResignedActive),
            name: NSApplication.didResignActiveNotification, object: nil)
    }

    private func setupHotkeys() {
        hotkeys.onCapture = { [weak self] in self?.handleCaptureHotkey() }
        hotkeys.onTab     = { [weak self] in self?.handleTabCycle() }
        hotkeys.onEscape  = { [weak self] in self?.handleEscapeHotkey() }
        hotkeys.registerCaptureHotkey()
    }

    /// Sync the per-mode conditional hotkeys (Tab / Esc) with current state.
    /// Tab is live only during capture with ≥2 enabled modes (so we don't
    /// hold the bare Tab key system-wide).
    ///
    /// Esc stays live for the whole capture, in every mode. It used to be
    /// registered only for SPX, on the theory that other modes get Esc
    /// through the overlay's own keyDown — but that needs the overlay to be
    /// the key window, and any focus loss (another app stealing it, a system
    /// dialog, a Space switch) left the user with a frozen screen and no way
    /// out at all.
    private func syncStateHotkeys() {
        let live = isCapturing || overlay.isShowing
        let tabLive = isCapturing && EnabledModesStore.load().count > 1
        hotkeys.setTabHotkeyActive(tabLive)
        hotkeys.setEscapeHotkeyActive(live)
    }

    /// Carbon-hotkey Esc dispatcher. Tears down the overlay whenever one is
    /// on screen, regardless of mode or of what the capture state thinks —
    /// this is the guaranteed way out.
    fileprivate func handleEscapeHotkey() {
        guard isCapturing || overlay.isShowing else { return }
        forceExitCapture()
    }

    /// Unconditional teardown: overlay down, ghost cleared, hotkeys released,
    /// popover closed, focus returned. Every escape route calls this.
    private func forceExitCapture() {
        overlay.forceInteractive()
        overlay.dismiss()
        cancelCapture()
        updateStatusLabel(nil)
        modePopover.hide()
    }

    @objc private func handleAppResignedActive() {
        // Ghost mode is deliberately unfocused — that's the whole point of it.
        guard overlay.isShowing, !spxIsGhost else { return }
        // Ignore the brief flap while the overlay is still coming up.
        guard Date().timeIntervalSince(captureStartedAt) > 0.8 else { return }
        yieldOverlay()
    }

    /// Gets a frozen overlay out of the user's way. In SPX that means ghost
    /// rather than exit: the screen stops being a screenshot and clicks reach
    /// the app underneath, but the measurements survive. Other modes have
    /// nothing to preserve, so they just close.
    private func yieldOverlay() {
        if isCapturing, currentMode == .spx, !spxIsGhost {
            spxIsGhost = true
            overlay.setSPXGhost(true)
            lastOverlayActivity = Date()
            modePopover.hide()
        } else {
            forceExitCapture()
        }
    }

    // MARK: Watchdog

    /// Runs only while an overlay is on screen. Checks the invariants that,
    /// when broken, leave the machine unusable — and repairs or tears down
    /// rather than trusting that no future code path can break them.
    private func startWatchdog() {
        stopWatchdog()
        lastOverlayActivity = Date()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.watchdogTick()
        }
        RunLoop.current.add(t, forMode: .common)
        watchdog = t
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    private func watchdogTick() {
        guard overlay.isShowing else {
            // Windows are gone but state says otherwise — resync and stop.
            if isCapturing { cancelCapture() }
            stopWatchdog()
            return
        }

        // 1. Windows on screen with no capture running: orphaned overlay.
        if !isCapturing {
            forceExitCapture()
            return
        }

        // 2. Click-through outside ghost: the frozen-screen-but-clickable
        //    state. Repair immediately rather than wait for an escape.
        if !spxIsGhost && overlay.hasClickThroughWindow {
            overlay.forceInteractive()
        }

        guard !spxIsGhost else { return }

        // 3. The user is clearly driving the machine (mouse moving right now)
        //    but the overlay hasn't heard an event in seconds. That means our
        //    events are going somewhere else while our screenshot still
        //    covers everything — the exact failure being defended against.
        let systemIdle = CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                                 eventType: .mouseMoved)
        let overlayIdle = Date().timeIntervalSince(lastOverlayActivity)
        if overlayIdle > 4.0 && systemIdle < 1.0 {
            yieldOverlay()
            return
        }

        // 4. Backstop: nothing at all reached the overlay for two minutes.
        //    Either the user walked away or it's wedged; both want it gone.
        if overlayIdle > 120 {
            forceExitCapture()
        }
    }

    /// Rapid repeated hotkey presses read as "get me out of here" — the
    /// instinct when the screen is stuck. Three within a second bail out, but
    /// only when the overlay actually looks wedged: mashing the hotkey to
    /// spin through modes is normal and must keep working.
    private func registerHotkeyBurstAndCheckPanic() -> Bool {
        let now = Date()
        hotkeyBurst.append(now)
        hotkeyBurst = hotkeyBurst.filter { now.timeIntervalSince($0) < 1.0 }
        guard hotkeyBurst.count >= 3, overlaySeemsWedged else { return false }
        hotkeyBurst.removeAll()
        return true
    }

    /// Conservative "this overlay is not healthy" test. Ghost mode is
    /// intentionally click-through and unfocused, so it never counts.
    private var overlaySeemsWedged: Bool {
        guard overlay.isShowing else { return false }
        if !isCapturing { return true }
        guard !spxIsGhost else { return false }
        if overlay.hasClickThroughWindow { return true }
        if !NSApp.isActive { return true }
        // Never heard a single event since the overlay came up.
        return lastOverlayActivity < captureStartedAt
            && Date().timeIntervalSince(captureStartedAt) > 3.0
    }

    fileprivate func handleTabCycle() {
        guard isCapturing, EnabledModesStore.load().count > 1 else { return }
        lastOverlayActivity = Date()
        cycleMode()
    }

    /// Called when SPX is dismissed via click — overlay closes but the segments
    /// remain in memory. Reset capture state so the next hotkey re-enters SPX.
    private func handleSPXPreserveHide() {
        isCapturing = false
        spxResumePending = true
        stopWatchdog()
        // Without this the Tab and Esc hotkeys stay registered after capture
        // ends, swallowing both keys system-wide in every other app.
        syncStateHotkeys()
        updateStatusLabel(nil)
        smartReturnFocus()
    }

    // MARK: Status Item & Menu

    private func setupMainMenu() {
        let mainMenu = NSMenu()
        NSApp.mainMenu = mainMenu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: "Quirky") {
                image.isTemplate = true
                button.image = image
                button.imagePosition = .imageLeading
            } else {
                button.title = "OCR"
            }
            // Left click opens the mode popover, right click the settings
            // menu. `statusItem.menu` stays unset so the left click reaches
            // our action instead of being swallowed by the menu.
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func updateStatusLabel(_ label: String?) {
        statusItem.button?.title = label.map { " \($0)" } ?? ""
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if isRightClick {
            modePopover.hide()
            showSettingsMenu()
        } else {
            modePopover.toggle(enabled: EnabledModesStore.load(),
                               current: isCapturing ? currentMode : startMode,
                               statusButton: statusItem.button)
        }
    }

    /// Pops the settings menu under the status item. Attaching it to
    /// `statusItem.menu` only for the duration of the click keeps the left
    /// click free for the mode popover.
    private func showSettingsMenu() {
        statusItem.menu = buildSettingsMenu()
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func buildSettingsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.minimumWidth = 280

        let togglesItem = NSMenuItem()
        let togglesView = ModeTogglesView(enabled: EnabledModesStore.load()) { [weak self] mode in
            self?.toggleMode(mode)
        }
        togglesItem.view = togglesView
        modeTogglesView = togglesView
        menu.addItem(togglesItem)

        menu.addItem(.separator())

        let colorItem = NSMenuItem(title: "Highlight Color", action: nil, keyEquivalent: "")
        let colorSubmenu = NSMenu()
        let colors: [(String, String)] = [
            ("Yellow", "FFD60A"), ("Green", "30D158"), ("Blue", "0A84FF"),
            ("Orange", "FF9F0A"), ("Pink", "FF375F"), ("Purple", "BF5AF2"),
        ]
        let currentHex = UserDefaults.standard.string(forKey: "highlightColorHex") ?? "FFD60A"
        for (name, hex) in colors {
            let item = NSMenuItem(title: name, action: #selector(setHighlightColor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = hex
            item.state = (hex == currentHex) ? .on : .off
            let swatch = NSImage(size: NSSize(width: 12, height: 12))
            swatch.lockFocus()
            NSColor(hex: hex).setFill()
            NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 12, height: 12)).fill()
            swatch.unlockFocus()
            item.image = swatch
            colorSubmenu.addItem(item)
        }
        colorItem.submenu = colorSubmenu
        menu.addItem(colorItem)

        menu.addItem(.separator())

        #if !MAS_BUILD
        // Sparkle drives auto-updates for the direct-distribution build;
        // the Mac App Store build uses the system updater (App Store.app)
        // and forbids bundled updaters.
        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "u")
        updateItem.target = updaterController
        menu.addItem(updateItem)

        menu.addItem(.separator())
        #endif

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    // MARK: Capture Flow

    @objc func handleCaptureHotkey() {
        // Pressing the hotkey is the user talking to the overlay, so it counts
        // as activity — otherwise the idle checks fire on a session the user
        // is clearly driving from the keyboard.
        lastOverlayActivity = Date()
        if isCapturing || overlay.isShowing {
            if registerHotkeyBurstAndCheckPanic() {
                forceExitCapture()
                return
            }
        }
        if isCapturing {
            // In SPX the hotkey toggles ghost/opaque overlay; mode-switching
            // is done in the menu-bar popover (or by cycling with Tab).
            if currentMode == .spx {
                if spxIsGhost { leaveSPXGhost() }
                else {
                    spxIsGhost = true
                    overlay.setSPXGhost(true)
                }
            } else {
                cycleMode()
            }
            showModePopover()
        } else {
            currentMode = startMode
            startCapture()
        }
    }

    /// Leaves SPX ghost mode on a freshly shot screen instead of the frame
    /// captured when the session started. Ghost mode exists so the user can
    /// go work in another app with the markings floating on top — by the time
    /// they come back, that original frame shows a screen that's gone.
    private func leaveSPXGhost() {
        // Whatever the user was working in while transparent is where focus
        // should land when they finish measuring, not the app they started from.
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier { previousApp = front }

        overlay.refreshBackground(capture: { [weak self] in
            guard let self else { return [] }
            self.preCaptureScreens()
            return self.screenImagesForOverlay
        }, completion: { [weak self] in
            guard let self else { return }
            self.spxIsGhost = false
            // Ghost is click-through, so the overlay heard nothing the whole
            // time it was transparent. Reset the clock before the idle checks
            // start applying again.
            self.lastOverlayActivity = Date()
            // Ghost mode hands key status back to the other app, so take it
            // back explicitly — otherwise H/V/T keys go nowhere.
            NSApp.activate(ignoringOtherApps: true)
            self.overlay.setSPXGhost(false)
        })
    }

    /// Mode a fresh capture session opens in: the SPX session being resumed,
    /// otherwise the mode the user last worked in, otherwise the first
    /// enabled one.
    private var startMode: CaptureMode {
        let enabled = EnabledModesStore.load()
        // spxResumePending only counts if SPX is still in the enabled set —
        // otherwise the user disabled SPX between sessions, so honor the
        // current enabled list and drop the stale resume hint.
        if spxResumePending && !enabled.contains(.spx) {
            spxResumePending = false
        }
        if spxResumePending { return .spx }
        if let last = LastModeStore.load(), enabled.contains(last) { return last }
        return enabled.first ?? .ocr
    }

    /// Shows the mode chooser under the menu-bar icon. Single-mode setups
    /// have nothing to choose, so it stays hidden there.
    private func showModePopover() {
        let enabled = EnabledModesStore.load()
        guard enabled.count >= 2 else { modePopover.hide(); return }
        modePopover.show(enabled: enabled, current: currentMode, statusButton: statusItem.button)
    }

    private func cycleMode() {
        guard let next = nextEnabledMode(after: currentMode) else { return }
        switchActiveCaptureMode(to: next)
    }

    /// Returns the next enabled mode in the canonical cycle, or `nil` if `current`
    /// is the only enabled mode.
    private func nextEnabledMode(after current: CaptureMode) -> CaptureMode? {
        let enabled = EnabledModesStore.load()
        guard enabled.count > 1 else { return nil }
        let idx = enabled.firstIndex(of: current) ?? -1
        return enabled[(idx + 1) % enabled.count]
    }

    private func switchActiveCaptureMode(to mode: CaptureMode) {
        // Single place where ghost is dropped on a mode change. Leaving it to
        // individual call sites is what let Tab-out-of-ghost strand the
        // overlay click-through over an opaque screenshot.
        if spxIsGhost {
            spxIsGhost = false
            overlay.forceInteractive()
        }
        currentMode = mode
        LastModeStore.save(mode)
        modePopover.setCurrentMode(mode)
        syncStateHotkeys()
        switch mode {
        case .ocr:
            overlay.switchToOCRMode()
            overlay.preScanWordBoxes(level: .fast, screenImages: screenImagesForOverlay)
            updateStatusLabel(nil)
        case .hex:
            overlay.switchToHEXMode { [weak self] hex in
                self?.handleColorPicked(hex)
            }
            updateStatusLabel("HEX")
        #if !MAS_BUILD
        case .dom:
            overlay.switchToDOMMode { [weak self] label in
                self?.handleDOMElementPicked(label)
            }
            updateStatusLabel("DOM")
            DOMExtractor.getDOMElements(from: previousApp) { [weak self] elements in
                guard let self else { return }
                if elements.isEmpty {
                    ToastWindow.show("Open in Safari/Chrome", style: .error)
                    if let next = self.nextEnabledMode(after: .dom) {
                        self.switchActiveCaptureMode(to: next)
                    } else {
                        self.cancelCapture()
                        self.overlay.dismiss()
                    }
                    return
                }
                self.overlay.setDOMElements(elements)
            }
        case .svg:
            overlay.switchToSVGMode()
            updateStatusLabel("SVG")
            SVGExtractor.getSVGBoundingBoxes(from: previousApp) { [weak self] boxes in
                self?.overlay.setSVGBoxes(boxes)
            }
        #endif
        case .spx:
            overlay.switchToSPXMode { [weak self] label in
                self?.handleSPXSizePicked(label)
            }
            updateStatusLabel("SPX")
        }
    }

    private func startCapture() {
        guard PermissionManager.hasScreenRecordingPermission else {
            PermissionManager.showPermissionDeniedAlert()
            return
        }
        preCaptureScreens()
        isCapturing = true
        captureStartedAt = Date()
        startWatchdog()
        LastModeStore.save(currentMode)
        // Clicking the menu-bar item can bring Quirky forward; in that case
        // keep whatever app was in front before so focus returns there.
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier { previousApp = front }
        syncStateHotkeys()
        showModePopover()

        switch currentMode {
        case .ocr:
            overlay.showFast(screenImages: screenImagesForOverlay, onComplete: { [weak self] rect in
                self?.handleCaptureComplete(rect)
            }, onCancel: { [weak self] in
                self?.cancelCapture()
            })

        #if !MAS_BUILD
        case .svg:
            updateStatusLabel("SVG")
            overlay.showForSVG(screenImages: screenImagesForOverlay, onComplete: { [weak self] rect in
                self?.handleCaptureComplete(rect)
            }, onCancel: { [weak self] in
                self?.updateStatusLabel(nil)
                self?.cancelCapture()
            })
            SVGExtractor.getSVGBoundingBoxes(from: previousApp) { [weak self] boxes in
                self?.overlay.setSVGBoxes(boxes)
            }
        #endif

        case .hex:
            updateStatusLabel("HEX")
            overlay.showForHEX(screenImages: screenImagesForOverlay, onColorPicked: { [weak self] hex in
                self?.handleColorPicked(hex)
            }, onCancel: { [weak self] in
                self?.updateStatusLabel(nil)
                self?.cancelCapture()
            })

        #if !MAS_BUILD
        case .dom:
            updateStatusLabel("DOM")
            overlay.showForDOM(screenImages: screenImagesForOverlay, onElementPicked: { [weak self] label in
                self?.handleDOMElementPicked(label)
            }, onCancel: { [weak self] in
                self?.updateStatusLabel(nil)
                self?.cancelCapture()
            })
            DOMExtractor.getDOMElements(from: previousApp) { [weak self] elements in
                guard let self else { return }
                if elements.isEmpty {
                    ToastWindow.show("Open in Safari/Chrome", style: .error)
                    if let next = self.nextEnabledMode(after: .dom) {
                        self.switchActiveCaptureMode(to: next)
                    } else {
                        self.cancelCapture()
                        self.overlay.dismiss()
                    }
                    return
                }
                self.overlay.setDOMElements(elements)
            }
        #endif

        case .spx:
            updateStatusLabel("SPX")
            overlay.showForSPX(screenImages: screenImagesForOverlay, onSizePicked: { [weak self] label in
                self?.handleSPXSizePicked(label)
            }, onCancel: { [weak self] in
                self?.updateStatusLabel(nil)
                self?.cancelCapture()
            })
        }
    }

    private func cancelCapture() {
        isCapturing = false
        spxResumePending = false  // Esc / mode-switch wipes preserved SPX
        spxIsGhost = false
        preCapturedImages = []
        hotkeyBurst.removeAll()
        stopWatchdog()
        modePopover.hide()
        syncStateHotkeys()
        smartReturnFocus()
    }

    private func handleColorPicked(_ hex: String) {
        isCapturing = false
        syncStateHotkeys()
        updateStatusLabel(nil)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hex, forType: .string)
        ToastWindow.show(hex)
        smartReturnFocus()
    }

    #if !MAS_BUILD
    private func handleDOMElementPicked(_ label: String) {
        isCapturing = false
        syncStateHotkeys()
        updateStatusLabel(nil)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(label, forType: .string)
        ToastWindow.show(label)
        smartReturnFocus()
    }
    #endif

    private func handleSPXSizePicked(_ label: String) {
        isCapturing = false
        syncStateHotkeys()
        updateStatusLabel(nil)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(label, forType: .string)
        ToastWindow.show(label)
        smartReturnFocus()
    }

    private func handleCaptureComplete(_ cgRect: CGRect) {
        switch currentMode {
        case .ocr, .hex: performPreCapturedOCR(on: cgRect)
        #if !MAS_BUILD
        case .svg: performSVGExtraction(on: cgRect)
        case .dom: break // DOM mode picks via onElementPicked, never triggers onComplete
        #endif
        case .spx: break // SPX mode picks via onSizePicked, never triggers onComplete
        }
    }

    // MARK: Pre-capture

    private func preCaptureScreens() {
        preCapturedImages = []
        for screen in NSScreen.screens {
            if let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
               let image = CGDisplayCreateImage(displayID) {
                preCapturedImages.append((displayID, CGDisplayBounds(displayID), image))
            }
        }
    }

    private var screenImagesForOverlay: [(displayID: CGDirectDisplayID, image: CGImage)] {
        preCapturedImages.map { ($0.displayID, $0.image) }
    }

    private func cropPreCapture(to rect: CGRect) -> CGImage? {
        for (_, bounds, image) in preCapturedImages {
            if bounds.contains(CGPoint(x: rect.midX, y: rect.midY)) {
                let scale = CGFloat(image.width) / bounds.width
                let localRect = CGRect(
                    x: (rect.origin.x - bounds.origin.x) * scale,
                    y: (rect.origin.y - bounds.origin.y) * scale,
                    width: rect.width * scale, height: rect.height * scale
                )
                return image.cropping(to: localRect)
            }
        }
        return nil
    }

    // MARK: OCR

    private func performPreCapturedOCR(on rect: CGRect) {
        isCapturing = false
        syncStateHotkeys()
        guard let cropped = cropPreCapture(to: rect) else {
            ToastWindow.show("Capture failed")
            preCapturedImages = []
            smartReturnFocus()
            return
        }
        preCapturedImages = []
        OCREngine.recognizeText(in: cropped) { [weak self] text in
            guard let self else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { ToastWindow.show("No text found") }
            else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(trimmed, forType: .string)
                ToastWindow.show("Copied")
            }
            self.smartReturnFocus()
        }
    }

    // MARK: SVG

    #if !MAS_BUILD
    private func performSVGExtraction(on rect: CGRect) {
        let browserApp = previousApp
        SVGExtractor.extractSVGs(in: rect, from: browserApp) { [weak self] svgs in
            guard let self else { return }
            self.isCapturing = false
            self.syncStateHotkeys()
            if svgs.isEmpty { ToastWindow.show("No SVGs found") }
            else {
                SVGExtractor.copyToClipboard(svgs)
                ToastWindow.show(svgs.count == 1 ? "1 SVG copied" : "\(svgs.count) SVGs copied")
            }
            self.smartReturnFocus()
        }
    }
    #endif

    // MARK: Focus

    private func smartReturnFocus() {
        updateStatusLabel(nil)
        modePopover.hide()
        if NSApp.isActive { previousApp?.activate() }
        previousApp = nil
    }

    // MARK: Menu Actions

    private func toggleMode(_ mode: CaptureMode) {
        var enabled = EnabledModesStore.load()
        if enabled.contains(mode) {
            guard enabled.count > 1 else { return }
            enabled.removeAll { $0 == mode }
        } else {
            enabled.append(mode)
        }
        EnabledModesStore.save(enabled)
        modeTogglesView?.update(enabled: enabled)
        // Keep an open popover in sync with the set the user just edited.
        if modePopover.isVisible {
            modePopover.show(enabled: enabled,
                             current: enabled.contains(currentMode) ? currentMode : (enabled.first ?? .ocr),
                             statusButton: statusItem.button)
        }
        // Editing the enabled set invalidates any pending SPX resume — the
        // user explicitly chose a different configuration, so the next hotkey
        // should follow it, not jump back into SPX.
        if !enabled.contains(.spx) { spxResumePending = false }
    }

    @objc private func setHighlightColor(_ sender: NSMenuItem) {
        guard let hex = sender.representedObject as? String else { return }
        UserDefaults.standard.set(hex, forKey: "highlightColorHex")
    }

    @objc private func quitApp() { NSApp.terminate(nil) }
}

// MARK: - ModePopoverDelegate

extension AppDelegate: ModePopoverDelegate {
    func modePopover(_ popover: ModePopover, didSelectMode mode: CaptureMode) {
        LastModeStore.save(mode)
        // Popover opened straight from the menu bar with nothing running:
        // picking a mode starts the session in it.
        guard isCapturing else {
            currentMode = mode
            startCapture()
            return
        }
        guard mode != currentMode else { return }
        // Exiting SPX clears its ghost state so a future SPX session starts opaque.
        if currentMode == .spx && mode != .spx {
            spxIsGhost = false
            overlay.setSPXGhost(false)
        }
        switchActiveCaptureMode(to: mode)
    }
}

// MARK: - Mode Toggles View

final class ModeTogglesView: NSView {
    private let onToggle: (CaptureMode) -> Void
    private var enabledModes: Set<CaptureMode>
    private var hoveredIndex: Int? = nil

    private static let squareSize = NSSize(width: 60, height: 36)
    private static let gap: CGFloat = 6
    private static let hPadding: CGFloat = 10
    private static let vPadding: CGFloat = 8

    private static let labelFont: CTFont = {
        if let f = CGFont("Helvetica-Bold" as CFString) {
            return CTFontCreateWithGraphicsFont(f, 12, nil, nil)
        }
        return CTFontCreateWithName("Helvetica" as CFString, 12, nil)
    }()

    init(enabled: [CaptureMode], onToggle: @escaping (CaptureMode) -> Void) {
        self.enabledModes = Set(enabled)
        self.onToggle = onToggle
        let count = CGFloat(CaptureMode.allCases.count)
        let width = Self.hPadding * 2 + count * Self.squareSize.width + (count - 1) * Self.gap
        let height = Self.vPadding * 2 + Self.squareSize.height
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func update(enabled: [CaptureMode]) {
        enabledModes = Set(enabled)
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    private func rect(forIndex i: Int) -> NSRect {
        NSRect(
            x: Self.hPadding + CGFloat(i) * (Self.squareSize.width + Self.gap),
            y: Self.vPadding,
            width: Self.squareSize.width,
            height: Self.squareSize.height
        )
    }

    private func indexAt(_ point: NSPoint) -> Int? {
        for (i, _) in CaptureMode.allCases.enumerated() where rect(forIndex: i).contains(point) {
            return i
        }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let onFill = NSColor(deviceRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
        let onFillHover = NSColor(deviceRed: 0.92, green: 0.92, blue: 0.92, alpha: 1.0)
        let offStroke = NSColor(deviceRed: 0.50, green: 0.50, blue: 0.50, alpha: 0.45)
        let offFillHover = NSColor(deviceRed: 0.50, green: 0.50, blue: 0.50, alpha: 0.12)
        let onTextColor = CGColor(red: 0.06, green: 0.06, blue: 0.06, alpha: 1)
        let offTextColor = CGColor(red: 0.55, green: 0.55, blue: 0.55, alpha: 1)

        for (i, mode) in CaptureMode.allCases.enumerated() {
            let r = rect(forIndex: i)
            let path = NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7)
            let isOn = enabledModes.contains(mode)
            let isHovered = hoveredIndex == i

            if isOn {
                (isHovered ? onFillHover : onFill).setFill()
                path.fill()
            } else {
                if isHovered {
                    offFillHover.setFill()
                    path.fill()
                }
                offStroke.setStroke()
                path.lineWidth = 1
                path.stroke()
            }

            let textColor: CGColor = isOn ? onTextColor : offTextColor

            let attrs: [NSAttributedString.Key: Any] = [
                kCTFontAttributeName as NSAttributedString.Key: Self.labelFont,
                kCTForegroundColorAttributeName as NSAttributedString.Key: textColor
            ]
            let attr = NSAttributedString(string: mode.displayName, attributes: attrs)
            let line = CTLineCreateWithAttributedString(attr)
            let lb = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
            ctx.textPosition = CGPoint(
                x: r.midX - lb.width / 2 - lb.minX,
                y: r.midY - lb.height / 2 - lb.minY
            )
            CTLineDraw(line, ctx)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = indexAt(p) {
            onToggle(CaptureMode.allCases[i])
        }
    }

    override func mouseMoved(with event: NSEvent) { updateHover(event) }
    override func mouseEntered(with event: NSEvent) { updateHover(event) }
    override func mouseExited(with event: NSEvent) {
        if hoveredIndex != nil { hoveredIndex = nil; needsDisplay = true }
    }

    private func updateHover(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let new = indexAt(p)
        if new != hoveredIndex { hoveredIndex = new; needsDisplay = true }
    }
}

// MARK: - NSColor HEX Extension

extension NSColor {
    convenience init(hex: String) {
        var hexStr = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard hexStr.count == 6, let val = UInt64(hexStr, radix: 16) else {
            self.init(red: 1, green: 0.84, blue: 0.04, alpha: 1); return
        }
        self.init(
            red:   CGFloat((val >> 16) & 0xFF) / 255.0,
            green: CGFloat((val >>  8) & 0xFF) / 255.0,
            blue:  CGFloat( val        & 0xFF) / 255.0,
            alpha: 1
        )
    }
}
