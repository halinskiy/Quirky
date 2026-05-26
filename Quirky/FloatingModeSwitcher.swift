import Cocoa

protocol FloatingModeSwitcherDelegate: AnyObject {
    func floatingSwitcher(_ switcher: FloatingModeSwitcher, didSelectMode mode: CaptureMode)
}

enum FloatingSwitcherEdge {
    case top, right, bottom, left
}

/// Glass-pill mode chooser that floats above the capture overlay.
/// Slides in from the bottom edge when capture starts, auto-parks at the
/// nearest screen edge after an idle delay, leaving only an arrow tab
/// visible. Click the tab — or drag the pill — to bring it back.
final class FloatingModeSwitcher {

    static let chipSize = NSSize(width: 60, height: 36)
    static let chipGap: CGFloat = 6
    static let pillPad: CGFloat = 10
    static let pillCornerRadius: CGFloat = 16
    static let arrowTabThickness: CGFloat = 22

    /// Invisible mouse-tracking padding around the visible pill content.
    /// `approachPadAbove` is the "approach zone" — cursor moving toward
    /// the parked tab from the screen interior enters the tracking area
    /// well before reaching the visible tab, so the pill pops up earlier.
    /// `approachPadBelow` keeps the cursor inside the tracking bounds
    /// after the panel slides up from its parked position (so the
    /// previous parked-tab-position is still inside the window),
    /// eliminating the unpark/re-park bounce.
    static let approachPadAbove: CGFloat = 110
    static let approachPadBelow: CGFloat = 32

    static let autoParkDelay: TimeInterval = 2.5
    static let initialShowDelay: TimeInterval = 1.7
    static let unparkDuration: TimeInterval = 0.62
    static let parkDuration: TimeInterval = 0.34
    static let parkInset: CGFloat = 28
    static let hoverUnparkDelay: TimeInterval = 0.07
    /// Park almost immediately after the cursor leaves the panel bounds.
    /// Small grace so a 1-pixel cursor wiggle past the edge doesn't park.
    static let exitParkDelay: TimeInterval = 0.18

    weak var delegate: FloatingModeSwitcherDelegate?

    private let panel: NSPanel
    private let container: FloatingSwitcherContainer

    private var enabledModes: [CaptureMode] = []
    private(set) var currentMode: CaptureMode = .ocr
    private var parkedEdge: FloatingSwitcherEdge = .bottom
    private(set) var isParked: Bool = true
    private var idleTimer: Timer?
    private var hoverUnparkTimer: Timer?
    private var exitParkTimer: Timer?
    private var isVisible = false

    // Spring animator state.
    private var animTimer: Timer?
    private var animStartFrame: NSRect = .zero
    private var animTargetFrame: NSRect = .zero
    private var animStartTime: CFTimeInterval = 0
    private var animDuration: CFTimeInterval = 0
    private var animEasing: (CGFloat) -> CGFloat = { $0 }
    private var animCompletion: (() -> Void)?

    init() {
        let rect = NSRect(x: 0, y: 0, width: 320, height: 86)
        panel = NSPanel(contentRect: rect,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = false

        container = FloatingSwitcherContainer(frame: rect)
        panel.contentView = container

        container.onChipClick = { [weak self] mode in self?.handleChip(mode) }
        container.onArrowClick = { [weak self] in self?.handleArrowClick() }
        container.onDragMove = { [weak self] dx, dy in self?.handleDragMove(dx: dx, dy: dy) }
        container.onDragEnd = { [weak self] in self?.handleDragEnd() }
        container.onHoverChange = { [weak self] in self?.handleHoverChange() }
        container.onArrowHoverChange = { [weak self] hovered in self?.handleArrowHoverChange(hovered) }
        container.onPanelMouseEnter = { [weak self] in self?.handlePanelEnter() }
        container.onPanelMouseExit = { [weak self] in self?.handlePanelExit() }
    }

    deinit {
        idleTimer?.invalidate()
        hoverUnparkTimer?.invalidate()
        exitParkTimer?.invalidate()
        animTimer?.invalidate()
    }

    // MARK: - Public API

    func show(enabled: [CaptureMode], current: CaptureMode, anchorScreen: NSScreen?) {
        guard enabled.count >= 2 else { hide(); return }
        let screen = anchorScreen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen = screen else { return }

        enabledModes = enabled
        currentMode = current
        parkedEdge = .bottom
        isParked = true
        isVisible = true

        container.configure(enabled: enabled, current: current, edge: .bottom, parked: true)
        let size = container.preferredSize(for: enabled.count, edge: .bottom)
        let panelW = size.width
        let panelH = size.height
        let sf = screen.frame
        let unparkedFrame = NSRect(
            x: sf.midX - panelW / 2,
            y: sf.minY + Self.parkInset,
            width: panelW, height: panelH
        )
        let parkedStart = parkedFrame(for: unparkedFrame, edge: .bottom, screen: screen)
        panel.setFrame(parkedStart, display: false)
        panel.orderFrontRegardless()

        // Slide in: parked → unparked with a springy overshoot, then auto-park.
        // Claim the unparked state before starting the animation so a hover
        // during slide-in doesn't fire a second unpark.
        container.setParked(false)
        isParked = false
        animateFrame(to: unparkedFrame,
                     duration: Self.unparkDuration,
                     easing: Self.easeOutBack) { [weak self] in
            guard let self = self else { return }
            self.scheduleAutoPark(after: Self.initialShowDelay)
        }
    }

    func setCurrentMode(_ mode: CaptureMode) {
        currentMode = mode
        container.setActiveMode(mode)
        // Mode change is explicit user feedback — cancel any pending park and
        // bring the pill back into view so the user sees which mode they
        // just switched to. Without this, cycling via Cmd+Shift+1 while the
        // pill is already parked (or about to park) would silently update
        // the active chip behind the screen edge.
        exitParkTimer?.invalidate()
        exitParkTimer = nil
        if isVisible, isParked {
            unpark(animated: true)
        } else {
            kickIdleTimer()
        }
    }

    func hide() {
        idleTimer?.invalidate()
        hoverUnparkTimer?.invalidate()
        exitParkTimer?.invalidate()
        animTimer?.invalidate()
        animTimer = nil
        isVisible = false
        panel.orderOut(nil)
    }

    // MARK: - Park / unpark

    private func handleArrowClick() {
        // Hover handles the common "open" case automatically; clicks remain
        // a deliberate fallback for trackpad tap-to-click and parking.
        if isParked { unpark(animated: true) } else { parkToEdge(parkedEdge, animated: true) }
    }

    private func handleChip(_ mode: CaptureMode) {
        // Switching modes counts as activity — keep the pill visible a bit longer.
        currentMode = mode
        container.setActiveMode(mode)
        kickIdleTimer()
        delegate?.floatingSwitcher(self, didSelectMode: mode)
    }

    private func handleHoverChange() {
        if !isParked { kickIdleTimer() }
    }

    /// Cursor entered the panel bounds — cancel any pending exit-park.
    /// (User is interacting again, so don't dismiss.)
    private func handlePanelEnter() {
        exitParkTimer?.invalidate()
        exitParkTimer = nil
    }

    /// Cursor left the panel bounds — park almost immediately. This is the
    /// user's "I'm done with this" signal; we don't make them wait for the
    /// longer idle timeout.
    private func handlePanelExit() {
        guard isVisible, !isParked else { return }
        exitParkTimer?.invalidate()
        let t = Timer(timeInterval: Self.exitParkDelay, repeats: false) { [weak self] _ in
            guard let self = self, self.isVisible, !self.isParked else { return }
            self.parkToEdge(self.parkedEdge, animated: true)
        }
        RunLoop.current.add(t, forMode: .common)
        exitParkTimer = t
    }

    private func handleArrowHoverChange(_ hovered: Bool) {
        guard isParked, isVisible else {
            hoverUnparkTimer?.invalidate()
            hoverUnparkTimer = nil
            return
        }
        if hovered {
            // Tiny debounce so a fast cursor flyby past the tab doesn't pop the pill.
            hoverUnparkTimer?.invalidate()
            let t = Timer(timeInterval: Self.hoverUnparkDelay, repeats: false) { [weak self] _ in
                guard let self = self, self.isParked, self.isVisible else { return }
                self.unpark(animated: true)
            }
            RunLoop.current.add(t, forMode: .common)
            hoverUnparkTimer = t
        } else {
            hoverUnparkTimer?.invalidate()
            hoverUnparkTimer = nil
        }
    }

    private func handleDragMove(dx: CGFloat, dy: CGFloat) {
        // Bottom-locked — only horizontal movement. Vertical drag is
        // ignored so the pill can't be pulled off its edge.
        var f = panel.frame
        f.origin.x += dx
        panel.setFrameOrigin(f.origin)
        idleTimer?.invalidate()
    }

    private func handleDragEnd() {
        snapToNearestEdge()
    }

    private func unpark(animated: Bool) {
        guard isParked, let screen = panel.screen ?? NSScreen.main else { return }
        // Claim the state immediately so a near-simultaneous hover + click
        // doesn't restart the animation halfway through.
        isParked = false
        hoverUnparkTimer?.invalidate()
        hoverUnparkTimer = nil
        let f = panel.frame
        let target = unparkedFrame(for: f, edge: parkedEdge, screen: screen)
        container.setParked(false)
        let finish: () -> Void = { [weak self] in
            guard let self = self else { return }
            self.scheduleAutoPark(after: Self.autoParkDelay)
        }
        if animated {
            animateFrame(to: target,
                         duration: Self.unparkDuration,
                         easing: Self.easeOutBack,
                         completion: finish)
        } else {
            panel.setFrameOrigin(target.origin)
            finish()
        }
    }

    private func parkToEdge(_ edge: FloatingSwitcherEdge, animated: Bool) {
        guard !isParked, let screen = panel.screen ?? NSScreen.main else { return }
        isParked = true
        let f = panel.frame
        let target = parkedFrame(for: f, edge: edge, screen: screen)
        container.setParked(true)
        idleTimer?.invalidate()
        if animated {
            animateFrame(to: target,
                         duration: Self.parkDuration,
                         easing: Self.easeOutCubic)
        } else {
            panel.setFrameOrigin(target.origin)
        }
    }

    private func snapToNearestEdge() {
        // Bottom-only by design — user feedback was that snap-to-any-edge
        // made the pill feel unstable. Drag still moves the pill, but
        // release always re-snaps to the bottom edge at the new x.
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let f = panel.frame
        parkedEdge = .bottom
        container.configure(enabled: enabledModes, current: currentMode, edge: .bottom, parked: false)
        let target = unparkedFrame(for: f, edge: .bottom, screen: screen)
        animateFrame(to: target,
                     duration: Self.unparkDuration,
                     easing: Self.easeOutBack) { [weak self] in
            guard let self = self else { return }
            self.isParked = false
            self.scheduleAutoPark(after: Self.autoParkDelay)
        }
    }

    private func parkedFrame(for f: NSRect, edge: FloatingSwitcherEdge, screen: NSScreen) -> NSRect {
        let sf = screen.frame
        let tab = Self.arrowTabThickness
        let padAbove = Self.approachPadAbove
        let padBelow = Self.approachPadBelow
        // Visible-content height (pill + tab) — what we want to leave the
        // tab portion of when parked.
        let visibleH = f.height - padAbove - padBelow
        var r = f
        switch edge {
        case .bottom:
            // Window origin so that the tab (at y = padBelow + pillH inside
            // the window) sits flush with the screen bottom edge.
            r.origin.y = sf.minY - (padBelow + (visibleH - tab))
        case .top:
            r.origin.y = sf.maxY - tab - padAbove
        case .left:   r.origin.x = sf.minX - f.width + tab
        case .right:  r.origin.x = sf.maxX - tab
        }
        return r
    }

    private func unparkedFrame(for f: NSRect, edge: FloatingSwitcherEdge, screen: NSScreen) -> NSRect {
        let sf = screen.frame
        let inset = Self.parkInset
        let padBelow = Self.approachPadBelow
        var r = f
        switch edge {
        case .bottom:
            // Pill sits at screen.minY + inset; the window itself starts
            // padBelow lower so the tracking area still covers the
            // previous parked-tab cursor position (no bounce on unpark).
            r.origin.y = sf.minY + inset - padBelow
        case .top:
            r.origin.y = sf.maxY - f.height - inset + Self.approachPadAbove
        case .left:   r.origin.x = sf.minX + inset
        case .right:  r.origin.x = sf.maxX - f.width - inset
        }
        // Keep within screen bounds along the perpendicular axis.
        switch edge {
        case .bottom, .top:
            r.origin.x = max(sf.minX + 8, min(r.origin.x, sf.maxX - f.width - 8))
        case .left, .right:
            r.origin.y = max(sf.minY + 8, min(r.origin.y, sf.maxY - f.height - 8))
        }
        return r
    }

    // MARK: - Idle timer

    private func scheduleAutoPark(after delay: TimeInterval) {
        idleTimer?.invalidate()
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self = self, self.isVisible, !self.isParked else { return }
            self.parkToEdge(self.parkedEdge, animated: true)
        }
        RunLoop.current.add(t, forMode: .common)
        idleTimer = t
    }

    private func kickIdleTimer() {
        guard isVisible, !isParked else { return }
        scheduleAutoPark(after: Self.autoParkDelay)
    }

    // MARK: - Animation (custom spring — NSAnimationContext can't overshoot
    // cleanly with allowsImplicitAnimation on a borderless panel, so drive
    // the frame manually at 60Hz with a spring-y easing curve).

    private func animateFrame(to target: NSRect,
                              duration: TimeInterval,
                              easing: @escaping (CGFloat) -> CGFloat,
                              completion: (() -> Void)? = nil) {
        animTimer?.invalidate()
        animStartFrame = panel.frame
        animTargetFrame = target
        animStartTime = CACurrentMediaTime()
        animDuration = duration
        animEasing = easing
        // If a previous animation had a completion that hasn't fired, drop it —
        // the new animation supersedes it.
        animCompletion = completion

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tickAnimation()
        }
        RunLoop.current.add(timer, forMode: .common)
        animTimer = timer
    }

    private func tickAnimation() {
        let elapsed = CACurrentMediaTime() - animStartTime
        let raw = max(0.0, min(1.0, elapsed / animDuration))
        let p = animEasing(CGFloat(raw))
        let f = NSRect(
            x: animStartFrame.origin.x + (animTargetFrame.origin.x - animStartFrame.origin.x) * p,
            y: animStartFrame.origin.y + (animTargetFrame.origin.y - animStartFrame.origin.y) * p,
            width: animStartFrame.size.width + (animTargetFrame.size.width - animStartFrame.size.width) * p,
            height: animStartFrame.size.height + (animTargetFrame.size.height - animStartFrame.size.height) * p
        )
        panel.setFrame(f, display: true)
        if raw >= 1.0 {
            animTimer?.invalidate()
            animTimer = nil
            panel.setFrame(animTargetFrame, display: true)
            let c = animCompletion
            animCompletion = nil
            c?()
        }
    }

    // Playful overshoot (~10%) — Airbnb-style spring.
    static func easeOutBack(_ t: CGFloat) -> CGFloat {
        let c1: CGFloat = 1.70158
        let c3: CGFloat = c1 + 1
        let u = t - 1
        return 1 + c3 * u * u * u + c1 * u * u
    }

    // Clean settle without overshoot — used when parking back off-screen.
    static func easeOutCubic(_ t: CGFloat) -> CGFloat {
        let u = t - 1
        return 1 + u * u * u
    }
}

// MARK: - Container view

final class FloatingSwitcherContainer: NSView {

    var onChipClick: ((CaptureMode) -> Void)?
    var onArrowClick: (() -> Void)?
    var onDragMove: ((CGFloat, CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?
    var onHoverChange: (() -> Void)?
    var onArrowHoverChange: ((Bool) -> Void)?
    var onPanelMouseEnter: (() -> Void)?
    var onPanelMouseExit: (() -> Void)?

    private var enabledModes: [CaptureMode] = []
    private var currentMode: CaptureMode = .ocr
    private var edge: FloatingSwitcherEdge = .bottom
    private var parked: Bool = true
    private var hoveredChip: Int? = nil
    private var hoveredArrow: Bool = false

    private var lastDragPoint: NSPoint?
    private var didMoveDuringDrag = false

    private static let labelFont: CTFont = {
        if let f = CGFont("Helvetica-Bold" as CFString) {
            return CTFontCreateWithGraphicsFont(f, 12, nil, nil)
        }
        return CTFontCreateWithName("Helvetica" as CFString, 12, nil)
    }()

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func preferredSize(for chipCount: Int, edge: FloatingSwitcherEdge) -> NSSize {
        let n = CGFloat(max(1, chipCount))
        let pad = FloatingModeSwitcher.pillPad
        let chip = FloatingModeSwitcher.chipSize
        let gap = FloatingModeSwitcher.chipGap
        let tab = FloatingModeSwitcher.arrowTabThickness
        let padAbove = FloatingModeSwitcher.approachPadAbove
        let padBelow = FloatingModeSwitcher.approachPadBelow
        // Horizontal pill (top/bottom-parked): chips laid out in a row.
        // Vertical pill (left/right-parked): chips laid out in a column.
        // For bottom — the only edge the user actually uses — we add an
        // approach zone above (so hover triggers early) and a sliver below
        // (so the parked-tab cursor position stays inside the window after
        // the panel animates up).
        switch edge {
        case .bottom, .top:
            let pillW = pad * 2 + n * chip.width + (n - 1) * gap
            let pillH = pad * 2 + chip.height
            return NSSize(width: pillW, height: pillH + tab + padAbove + padBelow)
        case .left, .right:
            let pillW = pad * 2 + chip.height
            let pillH = pad * 2 + n * chip.width + (n - 1) * gap
            return NSSize(width: pillW + tab, height: pillH)
        }
    }

    func configure(enabled: [CaptureMode], current: CaptureMode, edge: FloatingSwitcherEdge, parked: Bool) {
        self.enabledModes = enabled
        self.currentMode = current
        self.edge = edge
        self.parked = parked
        needsDisplay = true
    }

    func setActiveMode(_ mode: CaptureMode) {
        currentMode = mode
        needsDisplay = true
    }

    func setParked(_ parked: Bool) {
        self.parked = parked
        needsDisplay = true
    }

    // MARK: Geometry

    private func pillRect() -> NSRect {
        let tab = FloatingModeSwitcher.arrowTabThickness
        let padAbove = FloatingModeSwitcher.approachPadAbove
        let padBelow = FloatingModeSwitcher.approachPadBelow
        switch edge {
        case .bottom:
            // Pill sits in the lower portion of the window, above the
            // invisible padBelow strip. Tab is drawn just above the pill
            // (between pill and the approach zone above).
            let pillH = bounds.height - tab - padAbove - padBelow
            return NSRect(x: 0, y: padBelow, width: bounds.width, height: pillH)
        case .top:
            let pillH = bounds.height - tab - padAbove - padBelow
            return NSRect(x: 0, y: tab + padAbove, width: bounds.width, height: pillH)
        case .left:   return NSRect(x: tab, y: 0, width: bounds.width - tab, height: bounds.height)
        case .right:  return NSRect(x: 0, y: 0, width: bounds.width - tab, height: bounds.height)
        }
    }

    private func arrowTabRect() -> NSRect {
        let tab = FloatingModeSwitcher.arrowTabThickness
        let padAbove = FloatingModeSwitcher.approachPadAbove
        let padBelow = FloatingModeSwitcher.approachPadBelow
        // Wider for horizontal edges to fit the "Tab ⇥" label; vertical
        // edges keep the original limit since they render the chevron.
        let horizontalLenLimit: CGFloat = 88
        let verticalLenLimit: CGFloat = 64
        switch edge {
        case .bottom:
            let len = min(horizontalLenLimit, bounds.width * 0.55)
            // Tab is the visible strip above the pill — sits between pill
            // (height padBelow..padBelow+pillH) and the approach zone.
            let pillH = bounds.height - tab - padAbove - padBelow
            let tabY = padBelow + pillH
            return NSRect(x: bounds.midX - len / 2, y: tabY, width: len, height: tab)
        case .top:
            let len = min(horizontalLenLimit, bounds.width * 0.55)
            return NSRect(x: bounds.midX - len / 2, y: padAbove, width: len, height: tab)
        case .left:
            let len = min(verticalLenLimit, bounds.height * 0.55)
            return NSRect(x: 0, y: bounds.midY - len / 2, width: tab, height: len)
        case .right:
            let len = min(verticalLenLimit, bounds.height * 0.55)
            return NSRect(x: bounds.width - tab, y: bounds.midY - len / 2, width: tab, height: len)
        }
    }

    private func chipRect(forIndex i: Int) -> NSRect {
        let pill = pillRect()
        let pad = FloatingModeSwitcher.pillPad
        let chip = FloatingModeSwitcher.chipSize
        let gap = FloatingModeSwitcher.chipGap
        switch edge {
        case .bottom, .top:
            let x = pill.minX + pad + CGFloat(i) * (chip.width + gap)
            let y = pill.minY + pad
            return NSRect(x: x, y: y, width: chip.width, height: chip.height)
        case .left, .right:
            // Vertical pill — rotate chip layout. Width here is chip.height,
            // height is chip.width (taller chips for label legibility).
            let x = pill.minX + pad
            let y = pill.minY + pad + CGFloat(i) * (chip.width + gap)
            return NSRect(x: x, y: y, width: chip.height, height: chip.width)
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let pillBG = NSColor(deviceRed: 0.10, green: 0.10, blue: 0.11, alpha: 0.92)
        let pillStroke = NSColor(deviceWhite: 1.0, alpha: 0.08)

        let pill = pillRect()
        let pillPath = NSBezierPath(roundedRect: pill,
                                    xRadius: FloatingModeSwitcher.pillCornerRadius,
                                    yRadius: FloatingModeSwitcher.pillCornerRadius)
        pillBG.setFill()
        pillPath.fill()
        pillStroke.setStroke()
        pillPath.lineWidth = 1
        pillPath.stroke()

        // Chips (only when not parked — parked draws ONLY the arrow tab).
        if !parked {
            let activeFill = NSColor.white
            let hoverFill = NSColor(deviceWhite: 1.0, alpha: 0.18)
            let activeText = CGColor(red: 0.06, green: 0.06, blue: 0.06, alpha: 1)
            let idleText = CGColor(red: 0.90, green: 0.90, blue: 0.92, alpha: 1)

            for (i, mode) in enabledModes.enumerated() {
                let r = chipRect(forIndex: i)
                let cp = NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7)
                let isActive = (mode == currentMode)
                let isHovered = (hoveredChip == i)

                if isActive {
                    activeFill.setFill()
                    cp.fill()
                } else if isHovered {
                    hoverFill.setFill()
                    cp.fill()
                }

                let color: CGColor = isActive ? activeText : idleText
                let attrs: [NSAttributedString.Key: Any] = [
                    kCTFontAttributeName as NSAttributedString.Key: Self.labelFont,
                    kCTForegroundColorAttributeName as NSAttributedString.Key: color
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

        // Arrow tab — always visible. Glyph grows on hover.
        let tabRect = arrowTabRect()
        let tabPath = arrowTabPath(in: tabRect, edge: edge)
        pillBG.setFill()
        tabPath.fill()
        pillStroke.setStroke()
        tabPath.lineWidth = 1
        tabPath.stroke()

        let glyphScale: CGFloat = hoveredArrow ? 1.18 : 1.0
        drawTabIndicator(in: tabRect, edge: edge, scale: glyphScale)
    }

    private static let tabLabelFont: CTFont = {
        if let f = CGFont("Helvetica-Bold" as CFString) {
            return CTFontCreateWithGraphicsFont(f, 11, nil, nil)
        }
        return CTFontCreateWithName("Helvetica" as CFString, 11, nil)
    }()

    private func drawTabIndicator(in rect: NSRect, edge: FloatingSwitcherEdge, scale: CGFloat) {
        // Horizontal "Tab ⇥" label for the default top/bottom park position
        // — communicates that the Tab key cycles modes in addition to the
        // click affordance. Vertical (left/right) tabs are too narrow for
        // horizontal text, so they keep the chevron.
        if edge == .left || edge == .right {
            drawArrowGlyph(in: rect, pointing: arrowDirection(), scale: scale)
            return
        }

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let font: CTFont
        if scale == 1.0 {
            font = Self.tabLabelFont
        } else if let base = CGFont("Helvetica-Bold" as CFString) {
            font = CTFontCreateWithGraphicsFont(base, 11 * scale, nil, nil)
        } else {
            font = CTFontCreateWithName("Helvetica" as CFString, 11 * scale, nil)
        }
        let color = CGColor(red: 1, green: 1, blue: 1, alpha: 0.92)
        let attrs: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: color
        ]
        let attr = NSAttributedString(string: "Tab ⇥", attributes: attrs)
        let line = CTLineCreateWithAttributedString(attr)
        let lb = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        ctx.textPosition = CGPoint(
            x: rect.midX - lb.width / 2 - lb.minX,
            y: rect.midY - lb.height / 2 - lb.minY
        )
        CTLineDraw(line, ctx)
    }

    private func arrowDirection() -> FloatingSwitcherEdge {
        // Parked: arrow points away from the screen edge (toward user — "click to open").
        // Unparked: arrow points back toward the screen edge ("click to hide").
        if parked {
            switch edge {
            case .bottom: return .top
            case .top: return .bottom
            case .left: return .right
            case .right: return .left
            }
        } else {
            return edge
        }
    }

    private func arrowTabPath(in rect: NSRect, edge: FloatingSwitcherEdge) -> NSBezierPath {
        let p = NSBezierPath()
        let r: CGFloat = 10
        switch edge {
        case .bottom:
            p.move(to: NSPoint(x: rect.minX, y: rect.minY))
            p.line(to: NSPoint(x: rect.minX, y: rect.maxY - r))
            p.appendArc(withCenter: NSPoint(x: rect.minX + r, y: rect.maxY - r),
                        radius: r, startAngle: 180, endAngle: 90, clockwise: true)
            p.line(to: NSPoint(x: rect.maxX - r, y: rect.maxY))
            p.appendArc(withCenter: NSPoint(x: rect.maxX - r, y: rect.maxY - r),
                        radius: r, startAngle: 90, endAngle: 0, clockwise: true)
            p.line(to: NSPoint(x: rect.maxX, y: rect.minY))
            p.close()
        case .top:
            p.move(to: NSPoint(x: rect.minX, y: rect.maxY))
            p.line(to: NSPoint(x: rect.minX, y: rect.minY + r))
            p.appendArc(withCenter: NSPoint(x: rect.minX + r, y: rect.minY + r),
                        radius: r, startAngle: 180, endAngle: 270, clockwise: false)
            p.line(to: NSPoint(x: rect.maxX - r, y: rect.minY))
            p.appendArc(withCenter: NSPoint(x: rect.maxX - r, y: rect.minY + r),
                        radius: r, startAngle: 270, endAngle: 360, clockwise: false)
            p.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
            p.close()
        case .left:
            p.move(to: NSPoint(x: rect.maxX, y: rect.minY))
            p.line(to: NSPoint(x: rect.minX + r, y: rect.minY))
            p.appendArc(withCenter: NSPoint(x: rect.minX + r, y: rect.minY + r),
                        radius: r, startAngle: 270, endAngle: 180, clockwise: true)
            p.line(to: NSPoint(x: rect.minX, y: rect.maxY - r))
            p.appendArc(withCenter: NSPoint(x: rect.minX + r, y: rect.maxY - r),
                        radius: r, startAngle: 180, endAngle: 90, clockwise: true)
            p.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
            p.close()
        case .right:
            p.move(to: NSPoint(x: rect.minX, y: rect.minY))
            p.line(to: NSPoint(x: rect.maxX - r, y: rect.minY))
            p.appendArc(withCenter: NSPoint(x: rect.maxX - r, y: rect.minY + r),
                        radius: r, startAngle: 270, endAngle: 360, clockwise: false)
            p.line(to: NSPoint(x: rect.maxX, y: rect.maxY - r))
            p.appendArc(withCenter: NSPoint(x: rect.maxX - r, y: rect.maxY - r),
                        radius: r, startAngle: 0, endAngle: 90, clockwise: false)
            p.line(to: NSPoint(x: rect.minX, y: rect.maxY))
            p.close()
        }
        return p
    }

    private func drawArrowGlyph(in rect: NSRect, pointing: FloatingSwitcherEdge, scale: CGFloat) {
        let s: CGFloat = 6 * scale
        let cx = rect.midX, cy = rect.midY
        let path = NSBezierPath()
        switch pointing {
        case .top:
            path.move(to: NSPoint(x: cx - s, y: cy - s / 2))
            path.line(to: NSPoint(x: cx, y: cy + s / 2))
            path.line(to: NSPoint(x: cx + s, y: cy - s / 2))
        case .bottom:
            path.move(to: NSPoint(x: cx - s, y: cy + s / 2))
            path.line(to: NSPoint(x: cx, y: cy - s / 2))
            path.line(to: NSPoint(x: cx + s, y: cy + s / 2))
        case .left:
            path.move(to: NSPoint(x: cx + s / 2, y: cy - s))
            path.line(to: NSPoint(x: cx - s / 2, y: cy))
            path.line(to: NSPoint(x: cx + s / 2, y: cy + s))
        case .right:
            path.move(to: NSPoint(x: cx - s / 2, y: cy - s))
            path.line(to: NSPoint(x: cx + s / 2, y: cy))
            path.line(to: NSPoint(x: cx - s / 2, y: cy + s))
        }
        path.lineWidth = 2.0
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        NSColor(deviceWhite: 1.0, alpha: 0.92).setStroke()
        path.stroke()
    }

    // MARK: Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseMoved(with event: NSEvent) { updateHover(event) }
    override func mouseEntered(with event: NSEvent) {
        onPanelMouseEnter?()
        updateHover(event)
    }
    override func mouseExited(with event: NSEvent) {
        var changed = false
        var arrowChanged = false
        if hoveredChip != nil { hoveredChip = nil; changed = true }
        if hoveredArrow { hoveredArrow = false; changed = true; arrowChanged = true }
        if changed {
            needsDisplay = true
            onHoverChange?()
            if arrowChanged { onArrowHoverChange?(false) }
        }
        onPanelMouseExit?()
    }

    private func updateHover(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        var newChip: Int? = nil
        if !parked {
            for i in 0..<enabledModes.count where chipRect(forIndex: i).contains(p) {
                newChip = i; break
            }
        }
        let newArrow = arrowTabRect().contains(p)
        let arrowChanged = (newArrow != hoveredArrow)
        if newChip != hoveredChip || arrowChanged {
            hoveredChip = newChip
            hoveredArrow = newArrow
            needsDisplay = true
            onHoverChange?()
            if arrowChanged { onArrowHoverChange?(newArrow) }
        }
    }

    // MARK: Mouse handling

    override func mouseDown(with event: NSEvent) {
        lastDragPoint = event.locationInWindow
        didMoveDuringDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let last = lastDragPoint else { return }
        let now = event.locationInWindow
        let dx = now.x - last.x
        let dy = now.y - last.y
        if abs(dx) + abs(dy) > 2 { didMoveDuringDrag = true }
        if didMoveDuringDrag {
            onDragMove?(dx, dy)
            lastDragPoint = now
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { lastDragPoint = nil }
        if didMoveDuringDrag {
            didMoveDuringDrag = false
            onDragEnd?()
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        if arrowTabRect().contains(p) {
            onArrowClick?()
            return
        }
        if !parked {
            for (i, mode) in enabledModes.enumerated() where chipRect(forIndex: i).contains(p) {
                onChipClick?(mode)
                return
            }
            // Click on pill body (non-chip) — treat as keep-alive activity.
            onHoverChange?()
        } else {
            // Parked but clicked somewhere outside the visible arrow: unpark.
            onArrowClick?()
        }
    }
}
