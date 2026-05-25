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

    #if !MAS_BUILD
    private let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    #endif
    private var modeTogglesView: ModeTogglesView?
    private let modeSwitcher = FloatingModeSwitcher()

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
        modeSwitcher.delegate = self
    }

    private func setupHotkeys() {
        hotkeys.onCapture = { [weak self] in self?.handleCaptureHotkey() }
        hotkeys.onTab     = { [weak self] in self?.handleTabCycle() }
        hotkeys.onEscape  = { [weak self] in self?.handleEscapeWhileSPXActive() }
        hotkeys.registerCaptureHotkey()
    }

    /// Sync the per-mode conditional hotkeys (Tab / Esc) with current state.
    /// Tab is live only during capture with ≥2 enabled modes (so we don't
    /// hold the bare Tab key system-wide). Esc is live only when SPX is the
    /// active capture mode (so it can dismiss the click-through ghost
    /// overlay; in opaque modes OverlayWindow itself is the key window and
    /// handles Esc via keyDown).
    private func syncStateHotkeys() {
        let tabLive = isCapturing && EnabledModesStore.load().count > 1
        let escLive = isCapturing && currentMode == .spx
        hotkeys.setTabHotkeyActive(tabLive)
        hotkeys.setEscapeHotkeyActive(escLive)
    }

    /// Carbon-hotkey Esc dispatcher — closes the overlay and wipes preserved
    /// segments, mirroring the view's keyDown handler. Reachable even when
    /// the overlay is in ghost mode (not the key window).
    fileprivate func handleEscapeWhileSPXActive() {
        guard isCapturing, currentMode == .spx else { return }
        overlay.dismiss()
        cancelCapture()
        updateStatusLabel(nil)
    }

    fileprivate func handleTabCycle() {
        guard isCapturing, EnabledModesStore.load().count > 1 else { return }
        cycleMode()
    }

    /// Called when SPX is dismissed via click — overlay closes but the segments
    /// remain in memory. Reset capture state so the next hotkey re-enters SPX.
    private func handleSPXPreserveHide() {
        isCapturing = false
        spxResumePending = true
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
        }
        rebuildMenu()
    }

    private func updateStatusLabel(_ label: String?) {
        statusItem.button?.title = label.map { " \($0)" } ?? ""
    }

    private func rebuildMenu() {
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

        statusItem.menu = menu
    }

    // MARK: Capture Flow

    @objc func handleCaptureHotkey() {
        if isCapturing {
            // In SPX the hotkey toggles ghost/opaque overlay; mode-switching
            // is now done via the floating mode switcher (or cycle).
            if currentMode == .spx {
                spxIsGhost.toggle()
                overlay.setSPXGhost(spxIsGhost)
            } else {
                cycleMode()
            }
        } else {
            let enabled = EnabledModesStore.load()
            // spxResumePending only counts if SPX is still in the enabled set —
            // otherwise the user disabled SPX between sessions, so honor the
            // current enabled list and drop the stale resume hint.
            if spxResumePending && !enabled.contains(.spx) {
                spxResumePending = false
            }
            currentMode = spxResumePending ? .spx : (enabled.first ?? .ocr)
            startCapture()
        }
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

    private func switchActiveCaptureMode(to mode: CaptureMode, silent: Bool = false) {
        currentMode = mode
        modeSwitcher.setCurrentMode(mode)
        syncStateHotkeys()
        switch mode {
        case .ocr:
            overlay.switchToOCRMode()
            overlay.preScanWordBoxes(level: .fast, screenImages: screenImagesForOverlay)
            updateStatusLabel(nil)
            if !silent { ToastWindow.show("OCR") }
        case .hex:
            overlay.switchToHEXMode { [weak self] hex in
                self?.handleColorPicked(hex)
            }
            updateStatusLabel("HEX")
            if !silent { ToastWindow.show("HEX") }
        #if !MAS_BUILD
        case .dom:
            overlay.switchToDOMMode { [weak self] label in
                self?.handleDOMElementPicked(label)
            }
            updateStatusLabel("DOM")
            if !silent { ToastWindow.show("DOM") }
            DOMExtractor.getDOMElements(from: previousApp) { [weak self] elements in
                guard let self else { return }
                if elements.isEmpty {
                    ToastWindow.show("Open in Safari/Chrome", style: .error)
                    if let next = self.nextEnabledMode(after: .dom) {
                        self.switchActiveCaptureMode(to: next, silent: true)
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
            if !silent { ToastWindow.show("SVG") }
            SVGExtractor.getSVGBoundingBoxes(from: previousApp) { [weak self] boxes in
                self?.overlay.setSVGBoxes(boxes)
            }
        #endif
        case .spx:
            overlay.switchToSPXMode { [weak self] label in
                self?.handleSPXSizePicked(label)
            }
            updateStatusLabel("SPX")
            if !silent { ToastWindow.show("SPX") }
        }
    }

    private func startCapture() {
        guard PermissionManager.hasScreenRecordingPermission else {
            PermissionManager.showPermissionDeniedAlert()
            return
        }
        preCaptureScreens()
        isCapturing = true
        previousApp = NSWorkspace.shared.frontmostApplication
        syncStateHotkeys()

        let enabled = EnabledModesStore.load()
        if enabled.count >= 2 {
            modeSwitcher.show(enabled: enabled, current: currentMode, anchorScreen: NSScreen.main)
        } else {
            modeSwitcher.hide()
        }

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
                        self.switchActiveCaptureMode(to: next, silent: true)
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
        modeSwitcher.hide()
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
        modeSwitcher.hide()
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
        // Editing the enabled set invalidates any pending SPX resume — the
        // user explicitly chose a different configuration, so the next hotkey
        // should follow it, not jump back into SPX.
        if !enabled.contains(.spx) { spxResumePending = false }
    }

    @objc private func setHighlightColor(_ sender: NSMenuItem) {
        guard let hex = sender.representedObject as? String else { return }
        UserDefaults.standard.set(hex, forKey: "highlightColorHex")
        rebuildMenu()
    }

    @objc private func quitApp() { NSApp.terminate(nil) }
}

// MARK: - FloatingModeSwitcherDelegate

extension AppDelegate: FloatingModeSwitcherDelegate {
    func floatingSwitcher(_ switcher: FloatingModeSwitcher, didSelectMode mode: CaptureMode) {
        guard isCapturing, mode != currentMode else { return }
        // Exiting SPX clears its ghost state so a future SPX session starts opaque.
        if currentMode == .spx && mode != .spx {
            spxIsGhost = false
            overlay.setSPXGhost(false)
        }
        switchActiveCaptureMode(to: mode, silent: true)
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
