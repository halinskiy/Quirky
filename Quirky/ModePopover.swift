import Cocoa

protocol ModePopoverDelegate: AnyObject {
    func modePopover(_ popover: ModePopover, didSelectMode mode: CaptureMode)
}

/// Mode chooser anchored under the menu-bar item.
///
/// Replaces the old floating pill that slid in over the middle of the
/// screen: that thing auto-parked, drifted, forgot where the user dragged
/// it and covered the very content being measured. This one hangs off the
/// status item — same place every time, no timers, no auto-hide. It closes
/// when the user clicks anywhere else (the overlay included) or when the
/// capture session ends.
///
/// It's a hand-rolled panel rather than an NSPopover because the capture
/// overlay lives at `CGShieldingWindowLevel()`; an NSPopover would render
/// underneath it and would need to activate the app to take clicks.
final class ModePopover {

    static let chipSize = NSSize(width: 58, height: 34)
    static let chipGap: CGFloat = 6
    static let pad: CGFloat = 10
    static let cornerRadius: CGFloat = 12
    static let arrowHeight: CGFloat = 8
    static let arrowHalfWidth: CGFloat = 9
    /// Distance between the status item's bottom edge and the arrow tip.
    static let anchorGap: CGFloat = 2
    /// Drops out from under the menu bar and slides back up into it.
    static let openDuration: TimeInterval = 0.22
    static let closeDuration: TimeInterval = 0.15
    static let openOffset: CGFloat = 12
    static let closeOffset: CGFloat = 8
    /// Left alone, the picker gets out of the way on its own. Hovering it
    /// holds it open; switching modes brings it back.
    static let autoHideDelay: TimeInterval = 2.0

    weak var delegate: ModePopoverDelegate?
    /// Mouse activity over the picker counts as overlay activity: the
    /// stuck-overlay watchdog must not read "cursor parked on the chips" as
    /// "the overlay stopped hearing input".
    var onActivity: (() -> Void)?

    private let panel: NSPanel
    private let content: ModePopoverView
    private(set) var isVisible = false
    private(set) var currentMode: CaptureMode = .ocr

    /// Clicks in this window (the status item itself) don't dismiss the
    /// popover — the status item's own action handles the toggle.
    weak var anchorWindow: NSWindow?
    /// Kept so the icon stays lit while the picker is open, the way a menu
    /// lights its own status item.
    private weak var statusButton: NSStatusBarButton?

    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var autoHideTimer: Timer?

    // Frame + alpha animator. AppKit's implicit animation on a borderless
    // panel can't drive both cleanly, so interpolate at 60 Hz by hand.
    private var animTimer: Timer?
    private var animFromFrame: NSRect = .zero
    private var animToFrame: NSRect = .zero
    private var animFromAlpha: CGFloat = 0
    private var animToAlpha: CGFloat = 1
    private var animStart: CFTimeInterval = 0
    private var animDuration: CFTimeInterval = 0
    private var animEasing: (CGFloat) -> CGFloat = { $0 }
    private var animCompletion: (() -> Void)?

    init() {
        let rect = NSRect(x: 0, y: 0, width: 320, height: 64)
        panel = NSPanel(contentRect: rect,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        // Above the capture overlay, which sits at the shielding level.
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = false

        content = ModePopoverView(frame: rect)
        panel.contentView = content
        content.onChipClick = { [weak self] mode in self?.handleChip(mode) }
        // Cursor on the picker means the user is still choosing — hold it open.
        content.onMouseEnter = { [weak self] in
            self?.cancelAutoHide()
            self?.onActivity?()
        }
        content.onMouseExit = { [weak self] in self?.scheduleAutoHide() }
        content.onMouseMove = { [weak self] in self?.onActivity?() }
    }

    deinit {
        removeMonitors()
        autoHideTimer?.invalidate()
        animTimer?.invalidate()
    }

    // MARK: - Public API

    /// Shows the popover under `statusButton`, listing `enabled` modes with
    /// `current` highlighted. Re-showing while visible just refreshes it.
    func show(enabled: [CaptureMode], current: CaptureMode, statusButton: NSStatusBarButton?) {
        guard let button = statusButton, let buttonWindow = button.window else { return }
        guard !enabled.isEmpty else { hide(); return }

        currentMode = current
        anchorWindow = buttonWindow
        self.statusButton = button   // `statusButton` here is the parameter
        // Deferred: AppKit clears the button's highlight when it finishes
        // handling the click that got us here, so setting it inline is a no-op.
        DispatchQueue.main.async { button.highlight(true) }
        content.configure(enabled: enabled, current: current)

        let size = content.preferredSize(for: enabled.count)
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = NSScreen.screens.first { $0.frame.intersects(buttonFrame) } ?? NSScreen.main
        let visible = screen?.frame ?? buttonFrame

        var originX = buttonFrame.midX - size.width / 2
        originX = max(visible.minX + 8, min(originX, visible.maxX - size.width - 8))
        let originY = buttonFrame.minY - Self.anchorGap - size.height

        let frame = NSRect(x: originX, y: originY, width: size.width, height: size.height)
        content.frame = NSRect(origin: .zero, size: size)
        content.arrowCenterX = min(max(buttonFrame.midX - originX,
                                       Self.cornerRadius + Self.arrowHalfWidth),
                                   size.width - Self.cornerRadius - Self.arrowHalfWidth)
        content.needsDisplay = true

        // Off-screen (or mid-close): start the drop from just under the menu
        // bar. Already open: animate from wherever it currently sits, so a
        // re-show during the closing slide reverses instead of jumping.
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.setFrame(frame.offsetBy(dx: 0, dy: Self.openOffset), display: false)
            panel.orderFrontRegardless()
        } else {
            panel.setFrame(NSRect(origin: panel.frame.origin, size: frame.size), display: false)
        }
        installMonitors()
        isVisible = true
        animate(toFrame: frame, alpha: 1,
                duration: Self.openDuration, easing: Self.easeOutBack)
        scheduleAutoHide()
    }

    func setCurrentMode(_ mode: CaptureMode) {
        currentMode = mode
        content.setActiveMode(mode)
        // Switching modes is fresh intent — give the picker its full dwell
        // again so the user sees where they landed.
        if isVisible { scheduleAutoHide() }
    }

    func hide() {
        cancelAutoHide()
        removeMonitors()
        statusButton?.highlight(false)
        statusButton = nil
        guard isVisible || panel.isVisible else { return }
        isVisible = false
        animate(toFrame: panel.frame.offsetBy(dx: 0, dy: Self.closeOffset), alpha: 0,
                duration: Self.closeDuration, easing: Self.easeInQuad) { [weak self] in
            self?.panel.orderOut(nil)
        }
    }

    func toggle(enabled: [CaptureMode], current: CaptureMode, statusButton: NSStatusBarButton?) {
        if isVisible { hide() }
        else { show(enabled: enabled, current: current, statusButton: statusButton) }
    }

    // MARK: - Dismiss-on-outside-click

    private func installMonitors() {
        removeMonitors()
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // Keyboard too: once the user starts driving the overlay from the
        // keyboard (H/V rulers, T, Esc) the chooser has served its purpose
        // and shouldn't sit on top of what they're measuring. Tab-cycling is
        // a Carbon hotkey, so it never lands here — it refreshes the chips
        // through setCurrentMode instead.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks.union(.keyDown)) { [weak self] event in
            guard let self else { return event }
            // Clicks on the panel itself and on the status item are handled
            // by their own targets.
            if event.type != .keyDown,
               event.window === self.panel || event.window === self.anchorWindow {
                return event
            }
            self.hide()
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            self?.hide()
        }
    }

    private func removeMonitors() {
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
    }

    private func handleChip(_ mode: CaptureMode) {
        currentMode = mode
        content.setActiveMode(mode)
        scheduleAutoHide()
        delegate?.modePopover(self, didSelectMode: mode)
    }

    // MARK: - Auto-hide

    private func scheduleAutoHide() {
        cancelAutoHide()
        guard isVisible else { return }
        let t = Timer(timeInterval: Self.autoHideDelay, repeats: false) { [weak self] _ in
            self?.hide()
        }
        // .common so the countdown keeps running through mouse tracking loops.
        RunLoop.current.add(t, forMode: .common)
        autoHideTimer = t
    }

    private func cancelAutoHide() {
        autoHideTimer?.invalidate()
        autoHideTimer = nil
    }

    // MARK: - Animation

    private func animate(toFrame: NSRect, alpha: CGFloat,
                         duration: TimeInterval,
                         easing: @escaping (CGFloat) -> CGFloat,
                         completion: (() -> Void)? = nil) {
        animTimer?.invalidate()
        animFromFrame = panel.frame
        animToFrame = toFrame
        animFromAlpha = panel.alphaValue
        animToAlpha = alpha
        animStart = CACurrentMediaTime()
        animDuration = duration
        animEasing = easing
        // A new animation supersedes the previous one; drop its completion so
        // a stale close can't order the panel out from under a fresh open.
        animCompletion = completion

        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tickAnimation()
        }
        RunLoop.current.add(t, forMode: .common)
        animTimer = t
    }

    private func tickAnimation() {
        let raw = max(0.0, min(1.0, (CACurrentMediaTime() - animStart) / max(0.001, animDuration)))
        let p = animEasing(CGFloat(raw))
        panel.setFrame(NSRect(
            x: animFromFrame.origin.x + (animToFrame.origin.x - animFromFrame.origin.x) * p,
            y: animFromFrame.origin.y + (animToFrame.origin.y - animFromFrame.origin.y) * p,
            width: animFromFrame.width + (animToFrame.width - animFromFrame.width) * p,
            height: animFromFrame.height + (animToFrame.height - animFromFrame.height) * p
        ), display: true)
        // Alpha rides a plain linear ramp — easing it with the frame makes the
        // overshoot read as a flicker.
        panel.alphaValue = animFromAlpha + (animToAlpha - animFromAlpha) * CGFloat(raw)

        guard raw >= 1.0 else { return }
        animTimer?.invalidate()
        animTimer = nil
        panel.setFrame(animToFrame, display: true)
        panel.alphaValue = animToAlpha
        let done = animCompletion
        animCompletion = nil
        done?()
    }

    /// Gentle overshoot so the picker drops out of the menu bar with weight.
    private static func easeOutBack(_ t: CGFloat) -> CGFloat {
        let c1: CGFloat = 1.0
        let c3: CGFloat = c1 + 1
        let u = t - 1
        return 1 + c3 * u * u * u + c1 * u * u
    }

    /// Accelerating retreat back up into the menu bar.
    private static func easeInQuad(_ t: CGFloat) -> CGFloat { t * t }
}

// MARK: - Content view

final class ModePopoverView: NSView {

    var onChipClick: ((CaptureMode) -> Void)?
    var onMouseEnter: (() -> Void)?
    var onMouseExit: (() -> Void)?
    var onMouseMove: (() -> Void)?
    /// Horizontal center of the arrow in view coords — set by the owner so
    /// the tip points at the status item even when the panel is clamped to
    /// the screen edge.
    var arrowCenterX: CGFloat = 40

    private var enabledModes: [CaptureMode] = []
    private var currentMode: CaptureMode = .ocr
    private var hoveredChip: Int?

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private static let labelFont: CTFont = {
        if let f = CGFont("Helvetica-Bold" as CFString) {
            return CTFontCreateWithGraphicsFont(f, 12, nil, nil)
        }
        return CTFontCreateWithName("Helvetica" as CFString, 12, nil)
    }()

    func preferredSize(for chipCount: Int) -> NSSize {
        let n = CGFloat(max(1, chipCount))
        let pad = ModePopover.pad
        let chip = ModePopover.chipSize
        let gap = ModePopover.chipGap
        return NSSize(width: pad * 2 + n * chip.width + (n - 1) * gap,
                      height: pad * 2 + chip.height + ModePopover.arrowHeight)
    }

    func configure(enabled: [CaptureMode], current: CaptureMode) {
        enabledModes = enabled
        currentMode = current
        hoveredChip = nil
        needsDisplay = true
    }

    func setActiveMode(_ mode: CaptureMode) {
        currentMode = mode
        needsDisplay = true
    }

    // MARK: Geometry

    /// The rounded body, excluding the arrow that sticks out on top.
    private var bodyRect: NSRect {
        NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - ModePopover.arrowHeight)
    }

    private func chipRect(forIndex i: Int) -> NSRect {
        let chip = ModePopover.chipSize
        return NSRect(x: ModePopover.pad + CGFloat(i) * (chip.width + ModePopover.chipGap),
                      y: ModePopover.pad,
                      width: chip.width, height: chip.height)
    }

    private func indexAt(_ p: NSPoint) -> Int? {
        for i in 0..<enabledModes.count where chipRect(forIndex: i).contains(p) { return i }
        return nil
    }

    /// Body + arrow as a single closed path so the outline has no seam.
    private func shellPath() -> NSBezierPath {
        let b = bodyRect
        let r = ModePopover.cornerRadius
        let aH = ModePopover.arrowHeight
        let aW = ModePopover.arrowHalfWidth
        let cx = min(max(arrowCenterX, b.minX + r + aW), b.maxX - r - aW)

        let p = NSBezierPath()
        p.move(to: NSPoint(x: b.minX + r, y: b.minY))
        p.line(to: NSPoint(x: b.maxX - r, y: b.minY))
        p.appendArc(withCenter: NSPoint(x: b.maxX - r, y: b.minY + r),
                    radius: r, startAngle: -90, endAngle: 0)
        p.line(to: NSPoint(x: b.maxX, y: b.maxY - r))
        p.appendArc(withCenter: NSPoint(x: b.maxX - r, y: b.maxY - r),
                    radius: r, startAngle: 0, endAngle: 90)
        p.line(to: NSPoint(x: cx + aW, y: b.maxY))
        p.line(to: NSPoint(x: cx, y: b.maxY + aH))
        p.line(to: NSPoint(x: cx - aW, y: b.maxY))
        p.line(to: NSPoint(x: b.minX + r, y: b.maxY))
        p.appendArc(withCenter: NSPoint(x: b.minX + r, y: b.maxY - r),
                    radius: r, startAngle: 90, endAngle: 180)
        p.line(to: NSPoint(x: b.minX, y: b.minY + r))
        p.appendArc(withCenter: NSPoint(x: b.minX + r, y: b.minY + r),
                    radius: r, startAngle: 180, endAngle: 270)
        p.close()
        return p
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Device colors only — catalog/dynamic NSColors can crash Core Text
        // rendering paths on macOS 26.
        let shellBG = NSColor(deviceRed: 0.10, green: 0.10, blue: 0.11, alpha: 0.96)
        let shellStroke = NSColor(deviceWhite: 1.0, alpha: 0.10)

        let shell = shellPath()
        shellBG.setFill()
        shell.fill()
        shellStroke.setStroke()
        shell.lineWidth = 1
        shell.stroke()

        let activeFill = NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1)
        let hoverFill = NSColor(deviceWhite: 1.0, alpha: 0.16)
        let activeText = CGColor(red: 0.06, green: 0.06, blue: 0.06, alpha: 1)
        let idleText = CGColor(red: 0.90, green: 0.90, blue: 0.92, alpha: 1)

        for (i, mode) in enabledModes.enumerated() {
            let r = chipRect(forIndex: i)
            let path = NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7)
            let isActive = (mode == currentMode)

            if isActive {
                activeFill.setFill()
                path.fill()
            } else if hoveredChip == i {
                hoverFill.setFill()
                path.fill()
            }

            let attrs: [NSAttributedString.Key: Any] = [
                kCTFontAttributeName as NSAttributedString.Key: Self.labelFont,
                kCTForegroundColorAttributeName as NSAttributedString.Key: isActive ? activeText : idleText
            ]
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: mode.displayName, attributes: attrs))
            let lb = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
            ctx.textPosition = CGPoint(x: r.midX - lb.width / 2 - lb.minX,
                                       y: r.midY - lb.height / 2 - lb.minY)
            CTLineDraw(line, ctx)
        }
    }

    // MARK: Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        onMouseMove?()
        updateHover(event)
    }
    override func mouseEntered(with event: NSEvent) {
        onMouseEnter?()
        updateHover(event)
    }
    override func mouseExited(with event: NSEvent) {
        if hoveredChip != nil { hoveredChip = nil; needsDisplay = true }
        onMouseExit?()
    }

    private func updateHover(_ event: NSEvent) {
        let new = indexAt(convert(event.locationInWindow, from: nil))
        if new != hoveredChip { hoveredChip = new; needsDisplay = true }
    }

    /// Claim the mouse-down so AppKit routes the matching mouse-up here even
    /// though the panel never becomes key.
    override func mouseDown(with event: NSEvent) { updateHover(event) }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = indexAt(p) { onChipClick?(enabledModes[i]) }
    }
}
