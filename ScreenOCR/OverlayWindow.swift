import Cocoa
import Vision

struct DOMElementBox {
    let rect: CGRect    // view-local coords
    let label: String
}

// MARK: - Selection View

final class SelectionView: NSView {
    var onComplete: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    var onColorPicked: ((String) -> Void)?
    var onDOMElementPicked: ((String) -> Void)?
    var onSPXSizePicked: ((String) -> Void)?
    var onSPXHide: (() -> Void)?
    var isSVGMode = false
    var isHEXMode = false
    var isDOMMode = false
    var isSPXMode = false
    var backgroundImage: CGImage? {
        didSet {
            if let img = backgroundImage, isSPXMode {
                spxAnalyzer = SPXAnalyzer(image: img)
                applySPXToleranceToAnalyzer()
            }
        }
    }

    private var startPoint: NSPoint = .zero
    private var selectionRect: NSRect = .zero
    private var isSelecting = false
    private var isDragging = false
    private var isMoving = false
    private var lastDragPoint: NSPoint = .zero
    private var dashPhase: CGFloat = 0
    private var timer: Timer?
    private var hoveredBox: CGRect? = nil

    // HEX mode state
    private var hexPoint: NSPoint = .zero
    private var hexColor: NSColor?

    // DOM mode state
    private var domPoint: NSPoint = .zero
    private var hoveredDOMElement: DOMElementBox?

    // SPX mode state — crosshair whose H/V rays clip to detected edges.
    // Press H to commit the current horizontal segment, V for vertical;
    // commits accumulate on screen and copy "{n} px" to the clipboard.
    private var spxAnalyzer: SPXAnalyzer?
    private var spxCursor: NSPoint = .zero
    private var spxLiveH: SPXLiveSegment?
    private var spxLiveV: SPXLiveSegment?
    fileprivate var spxCommitted: [SPXSegment] = []
    fileprivate var spxColorIndex: Int = 0
    private var spxToleranceIndex: Int = 3
    private var spxDragOrigin: NSPoint = .zero
    private var spxIsDragging: Bool = false
    private var spxLiveDragRect: NSRect = .zero  // snapped, in view coords

    fileprivate struct SPXTolerance {
        let edgeThreshold: UInt8   // gradient strength — lower catches softer edges
        let minRun: Int            // perpendicular run length to qualify as an edge
    }
    /// 7 steps from "only sharp short edges" to "soft window-scale borders".
    /// Higher T lowers the gradient bar (softer borders qualify) AND raises the
    /// run-length bar (lines pass through text and small UI).
    fileprivate static let spxToleranceLevels: [SPXTolerance] = [
        SPXTolerance(edgeThreshold: 40, minRun: 4),
        SPXTolerance(edgeThreshold: 30, minRun: 8),
        SPXTolerance(edgeThreshold: 22, minRun: 14),
        SPXTolerance(edgeThreshold: 16, minRun: 22),   // default
        SPXTolerance(edgeThreshold: 10, minRun: 36),
        SPXTolerance(edgeThreshold:  6, minRun: 60),
        SPXTolerance(edgeThreshold:  3, minRun: 100),
        SPXTolerance(edgeThreshold:  2, minRun: 160)
    ]

    fileprivate struct SPXLiveSegment {
        let start: NSPoint       // view coords
        let end: NSPoint         // view coords
        let pxLength: Int        // image pixels, real device pixels
    }
    fileprivate struct SPXSegment {
        enum Axis { case horizontal, vertical, rect }
        let axis: Axis
        let start: NSPoint       // line: endpoint A; rect: top-left in view coords
        let end: NSPoint         // line: endpoint B; rect: bottom-right
        let pxLength: Int        // line: length; rect: width
        let pxHeight: Int        // line: 0; rect: height
        let color: NSColor

        var label: String {
            axis == .rect ? "\(pxLength)×\(pxHeight)" : "\(pxLength)"
        }
    }
    fileprivate static let spxPalette: [NSColor] = [
        NSColor(deviceRed: 1.00, green: 0.84, blue: 0.04, alpha: 1), // yellow
        NSColor(deviceRed: 0.35, green: 0.78, blue: 0.98, alpha: 1), // cyan
        NSColor(deviceRed: 1.00, green: 0.42, blue: 0.46, alpha: 1), // pink
        NSColor(deviceRed: 0.32, green: 0.78, blue: 0.35, alpha: 1), // green
        NSColor(deviceRed: 0.75, green: 0.55, blue: 0.95, alpha: 1), // purple
        NSColor(deviceRed: 1.00, green: 0.62, blue: 0.04, alpha: 1)  // orange
    ]

    var screenWordBoxes: [CGRect] = []
    var screenSVGBoxes: [CGRect] = []
    var screenDOMElements: [DOMElementBox] = []

    override var acceptsFirstResponder: Bool { true }

    private var activeBoxes: [CGRect] {
        isSVGMode ? screenSVGBoxes : screenWordBoxes
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                self?.dashPhase -= 2.0
                self?.needsDisplay = true
            }
            // .common includes .eventTracking — otherwise the timer freezes
            // during mouse drags and AppKit's shielding-window tracking loops.
            RunLoop.current.add(t, forMode: .common)
            timer = t
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .cursorUpdate],
            owner: self, userInfo: nil
        ))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isHEXMode {
            hexPoint = point
            hexColor = sampleColor(at: point)
            needsDisplay = true
            return
        }
        if isDOMMode {
            domPoint = point
            hoveredDOMElement = pickDeepestDOMElement(at: point)
            needsDisplay = true
            return
        }
        if isSPXMode {
            spxCursor = point
            recomputeSPXLiveSegments()
            needsDisplay = true
            return
        }
        guard !isSelecting else { return }
        hoveredBox = activeBoxes.first(where: { $0.contains(point) })
        needsDisplay = true
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if isHEXMode || isDOMMode { return }
        let point = convert(event.locationInWindow, from: nil)
        startPoint = point
        if isSPXMode {
            spxDragOrigin = point
            spxIsDragging = false
            spxLiveDragRect = .zero
            spxCursor = point
            return
        }
        selectionRect = .zero
        isSelecting = true
        isDragging = false
    }

    private func pickDeepestDOMElement(at point: NSPoint) -> DOMElementBox? {
        var best: DOMElementBox? = nil
        var bestArea: CGFloat = .greatestFiniteMagnitude
        for el in screenDOMElements where el.rect.contains(point) {
            let area = el.rect.width * el.rect.height
            if area < bestArea { best = el; bestArea = area }
        }
        return best
    }

    private var spaceDown: Bool {
        CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(49))
    }

    override func mouseDragged(with event: NSEvent) {
        let current = convert(event.locationInWindow, from: nil)
        if isHEXMode {
            hexPoint = current
            hexColor = sampleColor(at: current)
            needsDisplay = true
            return
        }
        if isDOMMode {
            domPoint = current
            hoveredDOMElement = pickDeepestDOMElement(at: current)
            needsDisplay = true
            return
        }
        if isSPXMode {
            spxCursor = current
            if !spxIsDragging && hypot(current.x - spxDragOrigin.x, current.y - spxDragOrigin.y) > 3 {
                spxIsDragging = true
            }
            if spxIsDragging {
                spxLiveDragRect = snappedDragRect(start: spxDragOrigin, end: current)
            } else {
                recomputeSPXLiveSegments()
            }
            needsDisplay = true
            return
        }
        guard isSelecting else { return }
        if !isDragging {
            if hypot(current.x - startPoint.x, current.y - startPoint.y) > 3 {
                isDragging = true
                hoveredBox = nil
            } else { return }
        }
        let spacePressed = spaceDown
        if spacePressed && !isMoving { isMoving = true; lastDragPoint = current }
        else if !spacePressed && isMoving { isMoving = false }
        if isMoving {
            let dx = current.x - lastDragPoint.x
            let dy = current.y - lastDragPoint.y
            selectionRect.origin.x += dx
            selectionRect.origin.y += dy
            startPoint.x += dx
            startPoint.y += dy
            lastDragPoint = current
        } else {
            selectionRect = NSRect(
                x: min(startPoint.x, current.x), y: min(startPoint.y, current.y),
                width: abs(current.x - startPoint.x), height: abs(current.y - startPoint.y)
            )
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if isHEXMode {
            let point = convert(event.locationInWindow, from: nil)
            let color = hexColor ?? sampleColor(at: point)
            if let color = color {
                onColorPicked?(hexString(for: color))
            } else {
                onCancel?()
            }
            return
        }
        if isDOMMode {
            let point = convert(event.locationInWindow, from: nil)
            if let el = pickDeepestDOMElement(at: point) {
                onDOMElementPicked?(el.label)
            } else {
                onCancel?()
            }
            return
        }
        if isSPXMode {
            if spxIsDragging {
                commitSPXRect(spxLiveDragRect)
                spxIsDragging = false
                spxLiveDragRect = .zero
                recomputeSPXLiveSegments()
                needsDisplay = true
            }
            // A bare click is intentionally a no-op — Esc is the only exit.
            return
        }
        guard isSelecting else { return }
        isSelecting = false
        if !isDragging {
            let clickPoint = convert(event.locationInWindow, from: nil)
            guard let box = activeBoxes.first(where: { $0.contains(clickPoint) }) else { onCancel?(); return }
            completeWith(viewRect: box)
            return
        }
        var inflated = selectionRect
        if inflated.height < 10 { inflated = inflated.insetBy(dx: 0, dy: -10) }
        if inflated.width < 10 { inflated = inflated.insetBy(dx: -10, dy: 0) }
        var finalRect = inflated
        if !isSVGMode {
            for box in screenWordBoxes where inflated.intersects(box) { finalRect = finalRect.union(box) }
        }
        guard finalRect.width > 2, finalRect.height > 2 else { onCancel?(); return }
        completeWith(viewRect: finalRect)
    }

    private func completeWith(viewRect: NSRect) {
        let windowRect = convert(viewRect, to: nil)
        let screenRect = window!.convertToScreen(windowRect)
        let mainH = CGDisplayBounds(CGMainDisplayID()).height
        let cgRect = CGRect(
            x: screenRect.origin.x, y: mainH - screenRect.maxY,
            width: screenRect.width, height: screenRect.height
        )
        onComplete?(cgRect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?(); return }      // Esc
        if isSPXMode {
            switch event.keyCode {
            case 4:  commitSPXAxis(.horizontal)              // H
            case 9:  commitSPXAxis(.vertical)                // V
            case 17: cycleSPXTolerance(event.modifierFlags.contains(.shift) ? -1 : 1) // T
            case 51: popLastSPXSegment()                     // Backspace — undo last
            case 36, 76:                                     // Return / Enter
                guard let last = spxCommitted.last else { return }
                copySPXLengthToPasteboard(last.pxLength)
            default: break
            }
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        if let bg = backgroundImage {
            NSImage(cgImage: bg, size: bounds.size).draw(in: bounds)
        }

        if isHEXMode {
            drawHEXHUD(context: context)
            return
        }

        if isDOMMode {
            drawDOMHUD(context: context)
            return
        }

        if isSPXMode {
            drawSPXHUD(context: context)
            return
        }

        let hex = UserDefaults.standard.string(forKey: "highlightColorHex") ?? "FFD60A"
        let highlightColor = NSColor(hex: hex)
        let dashPattern: [CGFloat] = [4.0, 4.0]
        let cornerRadius: CGFloat = 4

        if !isSelecting || !isDragging, let box = hoveredBox {
            highlightColor.setStroke()
            let path = NSBezierPath(roundedRect: box, xRadius: cornerRadius, yRadius: cornerRadius)
            path.setLineDash(dashPattern, count: 2, phase: dashPhase)
            path.lineWidth = 2.5
            path.stroke()
            highlightColor.withAlphaComponent(0.15).setFill()
            NSBezierPath(roundedRect: box, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        }

        if isDragging && selectionRect.width > 0 && selectionRect.height > 0 {
            context.setFillColor(NSColor(white: 0.5, alpha: 0.12).cgColor)
            context.fill(selectionRect)
            let outerPath = NSBezierPath(rect: selectionRect.insetBy(dx: -1, dy: -1))
            NSColor.black.withAlphaComponent(0.35).setStroke()
            outerPath.lineWidth = 1.0; outerPath.stroke()
            let innerPath = NSBezierPath(rect: selectionRect)
            NSColor.white.withAlphaComponent(0.8).setStroke()
            innerPath.lineWidth = 1.0; innerPath.stroke()
            drawSizeLabel(context: context)
            let hitBoxes = activeBoxes.filter { selectionRect.intersects($0) }
            highlightColor.setStroke()
            for box in mergeBoxesByLine(hitBoxes) {
                let path = NSBezierPath(roundedRect: box, xRadius: cornerRadius, yRadius: cornerRadius)
                path.setLineDash(dashPattern, count: 2, phase: dashPhase)
                path.lineWidth = 2.5; path.stroke()
                highlightColor.withAlphaComponent(0.15).setFill()
                NSBezierPath(roundedRect: box, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            }
        }
    }

    // MARK: HEX HUD

    private func drawHEXHUD(context: CGContext) {
        guard !hexPoint.equalTo(.zero) else { return }

        let hexStr = hexString(for: hexColor)
        let name = hexColor.map { colorName(for: $0) } ?? ""
        let swatchSize: CGFloat = 26
        let hPad: CGFloat = 14
        let gap: CGFloat = 10
        let totalHeight: CGFloat = 44

        // macOS 26: lazy CTFont descriptors from monospacedSystemFont can yield nil-attr
        // entries that crash CTLineCreate during string drawing under low-power/throttled
        // conditions. Build CTLines from named CTFonts directly — no system-font lookup.
        let white  = NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1).cgColor
        let dimmed = NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 0.55).cgColor

        let hexLine  = SelectionView.makeCTLine(hexStr, font: SelectionView.hexFont,  color: white)
        let nameLine = SelectionView.makeCTLine(name,   font: SelectionView.nameFont, color: dimmed)
        let hexBounds  = CTLineGetBoundsWithOptions(hexLine,  [])
        let nameBounds = CTLineGetBoundsWithOptions(nameLine, [])

        let totalWidth = hPad + swatchSize + gap + hexBounds.width + gap + nameBounds.width + hPad

        // Position: prefer top-right of cursor, clamp to screen
        var x = hexPoint.x + 18
        var y = hexPoint.y + 18
        if x + totalWidth > bounds.width - 8 { x = hexPoint.x - totalWidth - 10 }
        if y + totalHeight > bounds.height - 8 { y = hexPoint.y - totalHeight - 10 }
        x = max(8, x); y = max(8, y)

        let bgRect = CGRect(x: x, y: y, width: totalWidth, height: totalHeight)

        // Background pill
        context.saveGState()
        let bgPath = CGPath(roundedRect: bgRect, cornerWidth: totalHeight / 2, cornerHeight: totalHeight / 2, transform: nil)
        context.addPath(bgPath)
        context.setFillColor(NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 0.82).cgColor)
        context.fillPath()
        context.restoreGState()

        // Color swatch
        let swatchX = x + hPad
        let swatchY = y + (totalHeight - swatchSize) / 2
        let swatchRect = CGRect(x: swatchX, y: swatchY, width: swatchSize, height: swatchSize)
        if let color = hexColor, let cgColor = color.usingColorSpace(.deviceRGB)?.cgColor {
            context.setFillColor(cgColor)
            context.fillEllipse(in: swatchRect)
            context.setStrokeColor(NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 0.25).cgColor)
            context.setLineWidth(1)
            context.strokeEllipse(in: swatchRect)
        }

        // HEX text
        let textBaseX = swatchX + swatchSize + gap
        let hexY = y + (totalHeight - hexBounds.height) / 2 - hexBounds.minY
        context.textPosition = CGPoint(x: textBaseX, y: hexY)
        CTLineDraw(hexLine, context)

        // Color name
        let nameX = textBaseX + hexBounds.width + gap
        let nameY = y + (totalHeight - nameBounds.height) / 2 - nameBounds.minY
        context.textPosition = CGPoint(x: nameX, y: nameY)
        CTLineDraw(nameLine, context)
    }

    // Concrete named fonts — never go through monospacedSystemFont/systemFont, whose
    // lazy descriptors can return nil internal attrs on macOS 26 and crash CT.
    private static let hexFont: CTFont = {
        if let f = CGFont("Menlo-Bold" as CFString) { return CTFontCreateWithGraphicsFont(f, 14, nil, nil) }
        return CTFontCreateWithName("Menlo" as CFString, 14, nil)
    }()
    private static let nameFont: CTFont = {
        if let f = CGFont("Helvetica" as CFString) { return CTFontCreateWithGraphicsFont(f, 12, nil, nil) }
        return CTFontCreateWithName("Helvetica" as CFString, 12, nil)
    }()
    private static let sizeLabelFont: CTFont = {
        if let f = CGFont("Menlo-Regular" as CFString) { return CTFontCreateWithGraphicsFont(f, 12, nil, nil) }
        return CTFontCreateWithName("Menlo" as CFString, 12, nil)
    }()
    fileprivate static let domLabelFont: CTFont = {
        if let f = CGFont("Menlo-Regular" as CFString) { return CTFontCreateWithGraphicsFont(f, 12, nil, nil) }
        return CTFontCreateWithName("Menlo" as CFString, 12, nil)
    }()
    fileprivate static let domDimFont: CTFont = {
        if let f = CGFont("Menlo-Regular" as CFString) { return CTFontCreateWithGraphicsFont(f, 11, nil, nil) }
        return CTFontCreateWithName("Menlo" as CFString, 11, nil)
    }()
    private static let spxLabelFont: CTFont = {
        if let f = CGFont("Menlo-Bold" as CFString) { return CTFontCreateWithGraphicsFont(f, 13, nil, nil) }
        return CTFontCreateWithName("Menlo" as CFString, 13, nil)
    }()
    private static let spxHintFont: CTFont = {
        if let f = CGFont("Helvetica" as CFString) { return CTFontCreateWithGraphicsFont(f, 11, nil, nil) }
        return CTFontCreateWithName("Helvetica" as CFString, 11, nil)
    }()

    private func drawDOMHUD(context: CGContext) {
        guard let el = hoveredDOMElement else { return }

        // Highlight rectangle — same yellow dashed style as OCR mode
        let hex = UserDefaults.standard.string(forKey: "highlightColorHex") ?? "FFD60A"
        let highlightColor = NSColor(hex: hex)
        let dashPattern: [CGFloat] = [4.0, 4.0]
        let cornerRadius: CGFloat = 4

        highlightColor.setStroke()
        let path = NSBezierPath(roundedRect: el.rect, xRadius: cornerRadius, yRadius: cornerRadius)
        path.setLineDash(dashPattern, count: 2, phase: dashPhase)
        path.lineWidth = 2.5
        path.stroke()
        highlightColor.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: el.rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()

        // Label tooltip — tag.class.class — width × height
        let dim = "— \(Int(el.rect.width)) × \(Int(el.rect.height))"
        let white = NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1).cgColor
        let dimColor = NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 0.6).cgColor

        let labelLine = SelectionView.makeCTLine(el.label, font: SelectionView.domLabelFont, color: white)
        let dimLine   = SelectionView.makeCTLine(dim,      font: SelectionView.domDimFont,   color: dimColor)
        let labelBounds = CTLineGetBoundsWithOptions(labelLine, [])
        let dimBounds   = CTLineGetBoundsWithOptions(dimLine,   [])

        let hPad: CGFloat = 8
        let vPad: CGFloat = 6
        let gap: CGFloat = 8
        let totalWidth = hPad + labelBounds.width + gap + dimBounds.width + hPad
        let totalHeight = vPad * 2 + max(labelBounds.height, dimBounds.height)

        // Position below the element if room, otherwise above
        let preferBelow = (el.rect.minY - totalHeight - 4) > 8
        var x = el.rect.minX
        var y = preferBelow ? (el.rect.minY - totalHeight - 4) : (el.rect.maxY + 4)
        if x + totalWidth > bounds.width - 8 { x = bounds.width - totalWidth - 8 }
        if y < 8 { y = 8 }
        if y + totalHeight > bounds.height - 8 { y = bounds.height - totalHeight - 8 }
        x = max(8, x)

        let bgRect = CGRect(x: x, y: y, width: totalWidth, height: totalHeight)
        context.saveGState()
        context.addPath(CGPath(roundedRect: bgRect, cornerWidth: 4, cornerHeight: 4, transform: nil))
        context.setFillColor(NSColor(deviceRed: 0.10, green: 0.12, blue: 0.16, alpha: 0.95).cgColor)
        context.fillPath()
        context.restoreGState()

        let labelY = y + (totalHeight - labelBounds.height) / 2 - labelBounds.minY
        context.textPosition = CGPoint(x: x + hPad, y: labelY)
        CTLineDraw(labelLine, context)

        let dimX = x + hPad + labelBounds.width + gap
        let dimY = y + (totalHeight - dimBounds.height) / 2 - dimBounds.minY
        context.textPosition = CGPoint(x: dimX, y: dimY)
        CTLineDraw(dimLine, context)
    }

    /// Switches the view into SPX mode and constructs the analyzer from the current backgroundImage.
    func enableSPXMode(_ onSizePicked: @escaping (String) -> Void) {
        isSPXMode = true
        isSVGMode = false
        isHEXMode = false
        isDOMMode = false
        onSPXSizePicked = onSizePicked
        if let img = backgroundImage {
            spxAnalyzer = SPXAnalyzer(image: img)
        }
        spxLiveH = nil
        spxLiveV = nil
        // NB: spxCommitted / spxColorIndex are intentionally NOT cleared here.
        // The OverlayWindow restores prior segments via setSPXState(...) right
        // after this call when the user re-enters SPX. Esc → dismiss() wipes.
        // Restore the tolerance index from UserDefaults (clamped).
        let stored = UserDefaults.standard.object(forKey: "spxToleranceIndex") as? Int
        let n = SelectionView.spxToleranceLevels.count
        if let s = stored, s >= 0, s < n { spxToleranceIndex = s }
        else { spxToleranceIndex = 3 }
        applySPXToleranceToAnalyzer()
        needsDisplay = true
    }

    func disableSPXMode() {
        isSPXMode = false
        spxAnalyzer = nil
        spxLiveH = nil
        spxLiveV = nil
        spxCommitted.removeAll()
        spxColorIndex = 0
        onSPXSizePicked = nil
    }

    // MARK: SPX helpers

    private var spxCurrentTolerance: SPXTolerance {
        SelectionView.spxToleranceLevels[spxToleranceIndex]
    }

    private var spxMinEdgeLength: Int { spxCurrentTolerance.minRun }

    /// Pushes the current tolerance's edgeThreshold onto the analyzer. The
    /// analyzer's setter triggers a lazy rebuild of the run-length maps the
    /// next time they're queried, so this is cheap.
    private func applySPXToleranceToAnalyzer() {
        spxAnalyzer?.edgeThreshold = spxCurrentTolerance.edgeThreshold
    }

    /// Cycle tolerance index by `delta` (+1 for T, -1 for Shift+T). Wraps.
    private func cycleSPXTolerance(_ delta: Int) {
        let n = SelectionView.spxToleranceLevels.count
        spxToleranceIndex = ((spxToleranceIndex + delta) % n + n) % n
        UserDefaults.standard.set(spxToleranceIndex, forKey: "spxToleranceIndex")
        applySPXToleranceToAnalyzer()
        recomputeSPXLiveSegments()
        needsDisplay = true
    }

    private func viewToImagePixel(_ p: NSPoint) -> (Int, Int)? {
        guard let image = backgroundImage else { return nil }
        let sx = CGFloat(image.width) / bounds.width
        let sy = CGFloat(image.height) / bounds.height
        let px = Int(p.x * sx)
        let py = Int((bounds.height - p.y) * sy)
        guard px >= 0, py >= 0, px < image.width, py < image.height else { return nil }
        return (px, py)
    }

    private func imagePixelToView(_ px: Int, _ py: Int) -> NSPoint {
        guard let image = backgroundImage else { return .zero }
        let sx = bounds.width / CGFloat(image.width)
        let sy = bounds.height / CGFloat(image.height)
        return NSPoint(x: CGFloat(px) * sx, y: bounds.height - CGFloat(py) * sy)
    }

    /// Recomputes the live H/V segments at the current cursor by ray-casting in
    /// the analyzer. Cheap — just two array scans.
    private func recomputeSPXLiveSegments() {
        guard let analyzer = spxAnalyzer,
              let (px, py) = viewToImagePixel(spxCursor) else {
            spxLiveH = nil; spxLiveV = nil; return
        }
        if let h = analyzer.horizontalExtent(at: px, y: py, minEdgeLength: spxMinEdgeLength) {
            let s = imagePixelToView(h.left, py)
            let e = imagePixelToView(h.right, py)
            spxLiveH = SPXLiveSegment(start: s, end: e, pxLength: h.right - h.left)
        } else { spxLiveH = nil }
        if let v = analyzer.verticalExtent(at: px, y: py, minEdgeLength: spxMinEdgeLength) {
            let s = imagePixelToView(px, v.top)
            let e = imagePixelToView(px, v.bottom)
            spxLiveV = SPXLiveSegment(start: s, end: e, pxLength: v.bottom - v.top)
        } else { spxLiveV = nil }
    }

    private func commitSPXAxis(_ axis: SPXSegment.Axis) {
        let live: SPXLiveSegment? = (axis == .horizontal) ? spxLiveH : spxLiveV
        guard let seg = live, seg.pxLength > 1 else { return }
        let color = SelectionView.spxPalette[spxColorIndex % SelectionView.spxPalette.count]
        spxColorIndex += 1
        spxCommitted.append(SPXSegment(axis: axis, start: seg.start, end: seg.end,
                                       pxLength: seg.pxLength, pxHeight: 0, color: color))
        copySPXLengthToPasteboard(seg.pxLength)
        needsDisplay = true
    }

    /// Snap each edge of a view-space rect to the nearest detected edge in the
    /// analyzer. Returns the original rect if no analyzer / out-of-bounds.
    private func snappedDragRect(start: NSPoint, end: NSPoint) -> NSRect {
        let raw = NSRect(
            x: min(start.x, end.x), y: min(start.y, end.y),
            width: abs(end.x - start.x), height: abs(end.y - start.y)
        )
        guard let analyzer = spxAnalyzer,
              let image = backgroundImage,
              raw.width > 1, raw.height > 1 else { return raw }
        let sx = CGFloat(image.width) / bounds.width
        let sy = CGFloat(image.height) / bounds.height
        let imgRect = CGRect(
            x: raw.minX * sx,
            y: (bounds.height - raw.maxY) * sy,
            width: raw.width * sx,
            height: raw.height * sy
        )
        let snapped = analyzer.snapRect(imgRect,
                                        tolerance: max(12, spxMinEdgeLength),
                                        minRunLength: spxMinEdgeLength)
        let viewSX = bounds.width / CGFloat(image.width)
        let viewSY = bounds.height / CGFloat(image.height)
        return NSRect(
            x: snapped.minX * viewSX,
            y: bounds.height - (snapped.minY + snapped.height) * viewSY,
            width: snapped.width * viewSX,
            height: snapped.height * viewSY
        )
    }

    private func commitSPXRect(_ rect: NSRect) {
        guard let image = backgroundImage, rect.width > 2, rect.height > 2 else { return }
        let sx = CGFloat(image.width) / bounds.width
        let sy = CGFloat(image.height) / bounds.height
        let pxW = Int((rect.width * sx).rounded())
        let pxH = Int((rect.height * sy).rounded())
        let color = SelectionView.spxPalette[spxColorIndex % SelectionView.spxPalette.count]
        spxColorIndex += 1
        spxCommitted.append(SPXSegment(
            axis: .rect,
            start: NSPoint(x: rect.minX, y: rect.minY),
            end: NSPoint(x: rect.maxX, y: rect.maxY),
            pxLength: pxW, pxHeight: pxH, color: color
        ))
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("\(pxW) × \(pxH) px", forType: .string)
        needsDisplay = true
    }

    private func popLastSPXSegment() {
        guard !spxCommitted.isEmpty else { return }
        spxCommitted.removeLast()
        if spxColorIndex > 0 { spxColorIndex -= 1 }
        needsDisplay = true
    }

    private func copySPXLengthToPasteboard(_ px: Int) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("\(px) px", forType: .string)
    }

    // MARK: SPX drawing

    private func drawSPXHUD(context: CGContext) {
        // Background dim so colored lines pop on busy screens. Very subtle.
        context.saveGState()
        context.setFillColor(NSColor.black.withAlphaComponent(0.08).cgColor)
        context.fill(bounds)
        context.restoreGState()

        // 1) Committed segments (persistent).
        for seg in spxCommitted {
            if seg.axis == .rect {
                let r = NSRect(x: seg.start.x, y: seg.start.y,
                               width: seg.end.x - seg.start.x,
                               height: seg.end.y - seg.start.y)
                drawSPXRect(context: context, rect: r, color: seg.color,
                            label: seg.label, strong: true)
            } else {
                drawSPXSegmentLine(context: context, start: seg.start, end: seg.end,
                                   color: seg.color, label: seg.label, strong: true)
            }
        }

        let hex = UserDefaults.standard.string(forKey: "highlightColorHex") ?? "FFD60A"
        let liveColor = NSColor(hex: hex)

        // 2) Live preview: either drag-rect (during mouseDragged) or H/V crosshair.
        if spxIsDragging && spxLiveDragRect.width > 1 && spxLiveDragRect.height > 1 {
            let pxW: Int, pxH: Int
            if let image = backgroundImage {
                pxW = Int((spxLiveDragRect.width * CGFloat(image.width) / bounds.width).rounded())
                pxH = Int((spxLiveDragRect.height * CGFloat(image.height) / bounds.height).rounded())
            } else { pxW = Int(spxLiveDragRect.width); pxH = Int(spxLiveDragRect.height) }
            drawSPXRect(context: context, rect: spxLiveDragRect, color: liveColor,
                        label: "\(pxW)×\(pxH)", strong: false)
        } else {
            if let h = spxLiveH {
                drawSPXSegmentLine(context: context, start: h.start, end: h.end,
                                   color: liveColor, label: "\(h.pxLength)", strong: false)
            }
            if let v = spxLiveV {
                drawSPXSegmentLine(context: context, start: v.start, end: v.end,
                                   color: liveColor, label: "\(v.pxLength)", strong: false)
            }
        }

        // Center dot at cursor for precision.
        if spxCursor.x > 0 || spxCursor.y > 0 {
            context.saveGState()
            context.setFillColor(liveColor.cgColor)
            let r: CGFloat = 2.5
            context.fillEllipse(in: CGRect(x: spxCursor.x - r, y: spxCursor.y - r,
                                           width: r * 2, height: r * 2))
            context.restoreGState()
        }

        drawSPXToleranceChip(context: context)
    }

    /// Draws an outlined rectangle measurement with a "W×H" pill anchored at
    /// the top-left of the rect. Committed rects are strong; live drag is thin.
    private func drawSPXRect(context: CGContext, rect: NSRect, color: NSColor,
                             label: String, strong: Bool) {
        guard rect.width >= 1, rect.height >= 1 else { return }
        let alpha: CGFloat = strong ? 1.0 : 0.7
        let lineW: CGFloat = strong ? 1.5 : 1.0
        let drawColor = color.withAlphaComponent(alpha)

        // Halo for legibility.
        context.saveGState()
        context.setStrokeColor(NSColor.black.withAlphaComponent(strong ? 0.5 : 0.3).cgColor)
        context.setLineWidth(lineW + 1.5)
        context.stroke(rect.insetBy(dx: -0.5, dy: -0.5))
        context.restoreGState()

        // Outline.
        drawColor.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = lineW
        path.stroke()

        // Corner ticks for a measurement-tool feel.
        let tick: CGFloat = strong ? 6 : 4
        let caps = NSBezierPath()
        let cs = [rect.origin,
                  NSPoint(x: rect.maxX, y: rect.minY),
                  NSPoint(x: rect.minX, y: rect.maxY),
                  NSPoint(x: rect.maxX, y: rect.maxY)]
        for c in cs {
            // Just two small ticks perpendicular at each corner.
            caps.move(to: NSPoint(x: c.x - tick, y: c.y)); caps.line(to: NSPoint(x: c.x + tick, y: c.y))
            caps.move(to: NSPoint(x: c.x, y: c.y - tick)); caps.line(to: NSPoint(x: c.x, y: c.y + tick))
        }
        caps.lineWidth = lineW
        caps.stroke()

        // Label below the rect, or above if no room.
        let labelCenter: NSPoint
        if rect.minY > 22 {
            labelCenter = NSPoint(x: rect.midX, y: rect.minY - 12)
        } else {
            labelCenter = NSPoint(x: rect.midX, y: rect.maxY + 12)
        }
        let white = NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1).cgColor
        drawSPXPill(context: context, near: labelCenter, text: label,
                    textColor: white, bgColor: drawColor)
    }

    /// Top-right chip: "T  ▮▮▮▯▯  12 px" — visualizes the current tolerance level.
    private func drawSPXToleranceChip(context: CGContext) {
        let levels = SelectionView.spxToleranceLevels
        let current = spxToleranceIndex
        let white = NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1).cgColor
        let labelText = "T  \(current + 1)/\(levels.count)"
        let ctLine = SelectionView.makeCTLine(labelText, font: SelectionView.spxLabelFont, color: white)
        let lb = CTLineGetBoundsWithOptions(ctLine, [])

        let hPad: CGFloat = 10, vPad: CGFloat = 6
        let pipW: CGFloat = 5, pipH: CGFloat = 10, pipGap: CGFloat = 3
        let pipsTotalW = CGFloat(levels.count) * pipW + CGFloat(levels.count - 1) * pipGap
        let innerGap: CGFloat = 10
        let totalW = hPad + lb.width + innerGap + pipsTotalW + hPad
        let totalH = max(lb.height, pipH) + vPad * 2

        let x = bounds.width - totalW - 14
        let y = bounds.height - totalH - 14

        let bg = CGRect(x: x, y: y, width: totalW, height: totalH)
        context.saveGState()
        context.addPath(CGPath(roundedRect: bg, cornerWidth: 6, cornerHeight: 6, transform: nil))
        context.setFillColor(NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 0.78).cgColor)
        context.fillPath()
        context.restoreGState()

        // Label text.
        context.textPosition = CGPoint(x: x + hPad - lb.minX,
                                       y: y + (totalH - lb.height) / 2 - lb.minY)
        CTLineDraw(ctLine, context)

        // Pip bar — filled up to and including current level.
        let pipsX = x + hPad + lb.width + innerGap
        let pipsY = y + (totalH - pipH) / 2
        for i in 0..<levels.count {
            let px = pipsX + CGFloat(i) * (pipW + pipGap)
            let rect = CGRect(x: px, y: pipsY, width: pipW, height: pipH)
            let color: CGColor = (i <= current)
                ? NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1).cgColor
                : NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 0.22).cgColor
            context.saveGState()
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
            context.setFillColor(color)
            context.fillPath()
            context.restoreGState()
        }
    }

    /// Draws a measurement segment with perpendicular end caps and a pill label
    /// near its midpoint. `strong` is for committed segments (thicker + opaque);
    /// non-strong is for live preview (thinner + slightly translucent).
    private func drawSPXSegmentLine(context: CGContext, start: NSPoint, end: NSPoint,
                                    color: NSColor, label: String, strong: Bool) {
        let isHorizontal = abs(end.y - start.y) < 0.5
        let isVertical = abs(end.x - start.x) < 0.5
        guard isHorizontal || isVertical else { return }

        let alpha: CGFloat = strong ? 1.0 : 0.7
        let lineW: CGFloat = strong ? 1.5 : 1.0
        let drawColor = color.withAlphaComponent(alpha)

        // Halo for legibility on busy backgrounds.
        context.saveGState()
        context.setStrokeColor(NSColor.black.withAlphaComponent(strong ? 0.5 : 0.3).cgColor)
        context.setLineWidth(lineW + 1.5)
        context.move(to: start); context.addLine(to: end)
        context.strokePath()
        context.restoreGState()

        // Main line.
        drawColor.setStroke()
        let line = NSBezierPath()
        line.move(to: start); line.line(to: end)
        line.lineWidth = lineW
        line.stroke()

        // Perpendicular end caps (short tick marks marking each endpoint).
        let cap: CGFloat = strong ? 5 : 4
        let caps = NSBezierPath()
        if isHorizontal {
            caps.move(to: NSPoint(x: start.x, y: start.y - cap))
            caps.line(to: NSPoint(x: start.x, y: start.y + cap))
            caps.move(to: NSPoint(x: end.x,   y: end.y - cap))
            caps.line(to: NSPoint(x: end.x,   y: end.y + cap))
        } else {
            caps.move(to: NSPoint(x: start.x - cap, y: start.y))
            caps.line(to: NSPoint(x: start.x + cap, y: start.y))
            caps.move(to: NSPoint(x: end.x - cap,   y: end.y))
            caps.line(to: NSPoint(x: end.x + cap,   y: end.y))
        }
        caps.lineWidth = lineW
        caps.stroke()

        // Label pill — offset perpendicular to the line by ~10 px.
        let mid = NSPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let labelCenter: NSPoint
        if isHorizontal {
            labelCenter = NSPoint(x: mid.x, y: mid.y - 12)
        } else {
            labelCenter = NSPoint(x: mid.x + 22, y: mid.y)
        }
        let white = NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1).cgColor
        drawSPXPill(context: context, near: labelCenter, text: label,
                    textColor: white, bgColor: drawColor)
    }

    private func drawSPXPill(context: CGContext, near center: NSPoint, text: String,
                             textColor: CGColor,
                             bgColor: NSColor = NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 0.82)) {
        let ctLine = SelectionView.makeCTLine(text, font: SelectionView.spxLabelFont, color: textColor)
        let lb = CTLineGetBoundsWithOptions(ctLine, [])
        let hPad: CGFloat = 6, vPad: CGFloat = 3
        let labelW = lb.width + hPad * 2
        let labelH = lb.height + vPad * 2
        var lx = center.x - labelW / 2
        var ly = center.y - labelH / 2
        lx = max(6, min(bounds.width - labelW - 6, lx))
        ly = max(6, min(bounds.height - labelH - 6, ly))

        let bgRect = CGRect(x: lx, y: ly, width: labelW, height: labelH)
        context.saveGState()
        context.addPath(CGPath(roundedRect: bgRect, cornerWidth: 4, cornerHeight: 4, transform: nil))
        context.setFillColor(bgColor.cgColor)
        context.fillPath()
        context.restoreGState()

        context.textPosition = CGPoint(x: lx + hPad - lb.minX, y: ly + vPad - lb.minY)
        CTLineDraw(ctLine, context)
    }

    private static func makeCTLine(_ string: String, font: CTFont, color: CGColor) -> CTLine {
        let attrs: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: color
        ]
        let attrString = NSAttributedString(string: string, attributes: attrs)
        return CTLineCreateWithAttributedString(attrString as CFAttributedString)
    }

    // MARK: Color helpers

    private func sampleColor(at viewPoint: NSPoint) -> NSColor? {
        guard let image = backgroundImage else { return nil }
        let scaleX = CGFloat(image.width) / bounds.width
        let scaleY = CGFloat(image.height) / bounds.height
        let px = Int(viewPoint.x * scaleX)
        let py = Int((bounds.height - viewPoint.y) * scaleY) // NSView Y-flip → CGImage top-left
        guard px >= 0, py >= 0, px < image.width, py < image.height else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(
            data: &pixel, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        ctx.translateBy(x: -CGFloat(px), y: -(CGFloat(image.height) - CGFloat(py) - 1))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        return NSColor(srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
    }

    private func hexString(for color: NSColor?) -> String {
        guard let c = color?.usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X",
                      Int(c.redComponent * 255),
                      Int(c.greenComponent * 255),
                      Int(c.blueComponent * 255))
    }

    private func colorName(for color: NSColor) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return "" }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: nil)
        if b < 0.12 { return "Black" }
        if b > 0.88, s < 0.12 { return "White" }
        if s < 0.15 { return b < 0.4 ? "Dark Gray" : b > 0.7 ? "Light Gray" : "Gray" }
        let hDeg = h * 360
        let tone = b < 0.35 ? "Dark " : b > 0.72 ? "Light " : s < 0.35 ? "Soft " : ""
        let base: String
        switch hDeg {
        case 0..<12, 348..<360: base = "Red"
        case 12..<40:            base = "Orange"
        case 40..<68:            base = "Yellow"
        case 68..<155:           base = "Green"
        case 155..<190:          base = "Cyan"
        case 190..<252:          base = "Blue"
        case 252..<292:          base = "Purple"
        case 292..<348:          base = "Pink"
        default:                 base = "Red"
        }
        return tone + base
    }

    // MARK: Helpers (unchanged)

    private func mergeBoxesByLine(_ boxes: [CGRect]) -> [CGRect] {
        guard !boxes.isEmpty else { return [] }
        let sorted = boxes.sorted { $0.midY < $1.midY }
        let medianH = boxes.map(\.height).sorted()[boxes.count / 2]
        let tolerance = medianH * 0.5
        var lines: [[CGRect]] = []
        var currentLine: [CGRect] = [sorted[0]]
        for i in 1..<sorted.count {
            if abs(sorted[i].midY - currentLine[0].midY) <= tolerance { currentLine.append(sorted[i]) }
            else { lines.append(currentLine); currentLine = [sorted[i]] }
        }
        lines.append(currentLine)
        var result: [CGRect] = []
        for line in lines {
            let byX = line.sorted { $0.minX < $1.minX }
            var merged = byX[0]
            for i in 1..<byX.count {
                if byX[i].minX - merged.maxX < medianH { merged = merged.union(byX[i]) }
                else { result.append(merged); merged = byX[i] }
            }
            result.append(merged)
        }
        return result
    }

    private func drawSizeLabel(context: CGContext) {
        let label = "\(Int(selectionRect.width)) × \(Int(selectionRect.height))"
        let white = NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1).cgColor
        let line = SelectionView.makeCTLine(label, font: SelectionView.sizeLabelFont, color: white)
        let textBounds = CTLineGetBoundsWithOptions(line, [])

        let padding: CGFloat = 6
        let bgRect = CGRect(
            x: selectionRect.midX - (textBounds.width + padding * 2) / 2,
            y: selectionRect.minY - textBounds.height - padding * 2 - 4,
            width: textBounds.width + padding * 2,
            height: textBounds.height + padding * 2
        )
        context.setFillColor(NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 0.7).cgColor)
        context.addPath(CGPath(roundedRect: bgRect, cornerWidth: 4, cornerHeight: 4, transform: nil))
        context.fillPath()

        context.textPosition = CGPoint(
            x: bgRect.minX + padding - textBounds.minX,
            y: bgRect.minY + padding - textBounds.minY
        )
        CTLineDraw(line, context)
    }
}

// MARK: - Key-accepting borderless window

private final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Overlay Window

final class OverlayWindow {
    private var windows: [NSWindow] = []
    private var completion: ((CGRect) -> Void)?
    private var cancellation: (() -> Void)?

    // SPX state preserved across click-to-hide → re-open cycle.
    // Wiped by dismiss() (Esc / mode switch / final pick).
    fileprivate var spxPreservedSegments: [SelectionView.SPXSegment] = []
    fileprivate var spxPreservedColorIndex: Int = 0
    /// AppDelegate hooks this to reset its capture-state machine when the user
    /// clicks to dismiss SPX while keeping segments alive.
    var onSPXPreserveHide: (() -> Void)?

    // MARK: Show methods

    func showFast(screenImages: [(displayID: CGDirectDisplayID, image: CGImage)], onComplete: @escaping (CGRect) -> Void, onCancel: @escaping () -> Void) {
        showOverlay(isSVG: false, screenImages: screenImages, onComplete: onComplete, onCancel: onCancel, immediate: true)
        preScanWordBoxes(level: .fast, screenImages: screenImages)
    }

    func showForSVG(screenImages: [(displayID: CGDirectDisplayID, image: CGImage)], onComplete: @escaping (CGRect) -> Void, onCancel: @escaping () -> Void) {
        showOverlay(isSVG: true, screenImages: screenImages, onComplete: onComplete, onCancel: onCancel, immediate: true)
    }

    func showForHEX(screenImages: [(displayID: CGDirectDisplayID, image: CGImage)], onColorPicked: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        showOverlay(isSVG: false, screenImages: screenImages, onComplete: { _ in }, onCancel: onCancel, immediate: true)
        let handler = wrappedColorPicked(onColorPicked)
        for window in windows {
            if let view = window.contentView as? SelectionView {
                view.isHEXMode = true
                view.onColorPicked = handler
            }
        }
    }

    func showForDOM(screenImages: [(displayID: CGDirectDisplayID, image: CGImage)], onElementPicked: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        showOverlay(isSVG: false, screenImages: screenImages, onComplete: { _ in }, onCancel: onCancel, immediate: true)
        let handler = wrappedDOMElementPicked(onElementPicked)
        for window in windows {
            if let view = window.contentView as? SelectionView {
                view.isDOMMode = true
                view.onDOMElementPicked = handler
            }
        }
    }

    func showForSPX(screenImages: [(displayID: CGDirectDisplayID, image: CGImage)], onSizePicked: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        showOverlay(isSVG: false, screenImages: screenImages, onComplete: { _ in }, onCancel: onCancel, immediate: true)
        let handler = wrappedSPXSizePicked(onSizePicked)
        for window in windows {
            if let view = window.contentView as? SelectionView {
                view.enableSPXMode(handler)
                view.onSPXHide = { [weak self] in self?.hidePreservingSPX() }
                restoreSPXState(into: view)
            }
        }
    }

    // MARK: Mode switching (mid-capture)

    func switchToOCRMode() {
        for window in windows {
            guard let view = window.contentView as? SelectionView else { continue }
            view.isSVGMode = false
            view.isHEXMode = false
            view.isDOMMode = false
            view.disableSPXMode()
            view.onColorPicked = nil
            view.onDOMElementPicked = nil
            view.needsDisplay = true
        }
    }

    func switchToSVGMode() {
        for window in windows {
            guard let view = window.contentView as? SelectionView else { continue }
            view.isSVGMode = true
            view.isHEXMode = false
            view.isDOMMode = false
            view.disableSPXMode()
            view.onColorPicked = nil
            view.onDOMElementPicked = nil
            view.needsDisplay = true
        }
    }

    func switchToHEXMode(onColorPicked: @escaping (String) -> Void) {
        let handler = wrappedColorPicked(onColorPicked)
        for window in windows {
            guard let view = window.contentView as? SelectionView else { continue }
            view.isSVGMode = false
            view.isHEXMode = true
            view.isDOMMode = false
            view.disableSPXMode()
            view.onColorPicked = handler
            view.onDOMElementPicked = nil
            view.needsDisplay = true
        }
    }

    func switchToDOMMode(onElementPicked: @escaping (String) -> Void) {
        let handler = wrappedDOMElementPicked(onElementPicked)
        for window in windows {
            guard let view = window.contentView as? SelectionView else { continue }
            view.isSVGMode = false
            view.isHEXMode = false
            view.isDOMMode = true
            view.disableSPXMode()
            view.onColorPicked = nil
            view.onDOMElementPicked = handler
            view.needsDisplay = true
        }
    }

    func switchToSPXMode(onSizePicked: @escaping (String) -> Void) {
        let handler = wrappedSPXSizePicked(onSizePicked)
        for window in windows {
            guard let view = window.contentView as? SelectionView else { continue }
            view.isSVGMode = false
            view.isHEXMode = false
            view.isDOMMode = false
            view.onColorPicked = nil
            view.onDOMElementPicked = nil
            view.enableSPXMode(handler)
            view.onSPXHide = { [weak self] in self?.hidePreservingSPX() }
            restoreSPXState(into: view)
        }
    }

    /// Hide the overlay without invoking the cancellation callback. Preserves
    /// SPX segments so the next showForSPX / switchToSPXMode restores them.
    func hidePreservingSPX() {
        if let view = windows.first?.contentView as? SelectionView, view.isSPXMode {
            spxPreservedSegments = view.spxCommitted
            spxPreservedColorIndex = view.spxColorIndex
        }
        for window in windows { window.orderOut(nil) }
        NSCursor.arrow.set()
        windows.removeAll()
        onSPXPreserveHide?()
    }

    /// Restore preserved SPX segments into a freshly-shown view. No-op when no
    /// segments are stashed (first SPX entry / after Esc).
    fileprivate func restoreSPXState(into view: SelectionView) {
        guard !spxPreservedSegments.isEmpty else { return }
        view.spxCommitted = spxPreservedSegments
        view.spxColorIndex = spxPreservedColorIndex
        view.needsDisplay = true
    }

    private func wrappedColorPicked(_ onColorPicked: @escaping (String) -> Void) -> (String) -> Void {
        return { [weak self] hex in
            self?.dismiss()
            onColorPicked(hex)
        }
    }

    private func wrappedDOMElementPicked(_ onElementPicked: @escaping (String) -> Void) -> (String) -> Void {
        return { [weak self] label in
            self?.dismiss()
            onElementPicked(label)
        }
    }

    private func wrappedSPXSizePicked(_ onSizePicked: @escaping (String) -> Void) -> (String) -> Void {
        return { [weak self] label in
            self?.dismiss()
            onSizePicked(label)
        }
    }

    func preScanWordBoxes(level: VNRequestTextRecognitionLevel, screenImages: [(displayID: CGDirectDisplayID, image: CGImage)]) {
        let imageByDisplay = Dictionary(uniqueKeysWithValues: screenImages.map { ($0.displayID, $0.image) })
        for window in windows {
            guard let view = window.contentView as? SelectionView,
                  let screen = window.screen,
                  let displayID = screen.deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")] as? CGDirectDisplayID,
                  let image = imageByDisplay[displayID] else { continue }
            let request = VNRecognizeTextRequest { [weak view] request, _ in
                guard let results = request.results as? [VNRecognizedTextObservation], !results.isEmpty else { return }
                var wordBoxes: [CGRect] = []
                for obs in results {
                    guard let candidate = obs.topCandidates(1).first else { continue }
                    let str = candidate.string
                    let words = str.split(separator: " ", omittingEmptySubsequences: true)
                    var searchStart = str.startIndex
                    for word in words {
                        guard let wordRange = str.range(of: word, range: searchStart..<str.endIndex) else { continue }
                        searchStart = wordRange.upperBound
                        if let bb = try? candidate.boundingBox(for: wordRange) {
                            wordBoxes.append(CGRect(
                                x: bb.boundingBox.minX * screen.frame.width,
                                y: bb.boundingBox.minY * screen.frame.height,
                                width: bb.boundingBox.width * screen.frame.width,
                                height: bb.boundingBox.height * screen.frame.height
                            ).insetBy(dx: -6, dy: -4))
                        }
                    }
                }
                DispatchQueue.main.async { view?.screenWordBoxes = wordBoxes; view?.needsDisplay = true }
            }
            request.recognitionLevel = level
            DispatchQueue.global(qos: .userInitiated).async {
                try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            }
        }
    }

    func setSVGBoxes(_ cgBoxes: [CGRect]) {
        let mainH = CGDisplayBounds(CGMainDisplayID()).height
        for window in windows {
            guard let view = window.contentView as? SelectionView else { continue }
            let screen = window.screen ?? NSScreen.main!
            view.screenSVGBoxes = cgBoxes.map { cg in
                CGRect(
                    x: cg.origin.x - screen.frame.origin.x,
                    y: mainH - cg.origin.y - cg.height - screen.frame.origin.y,
                    width: cg.width, height: cg.height
                ).insetBy(dx: -6, dy: -4)
            }
            view.needsDisplay = true
        }
    }

    func setDOMElements(_ elements: [DOMExtractor.Element]) {
        let mainH = CGDisplayBounds(CGMainDisplayID()).height
        for window in windows {
            guard let view = window.contentView as? SelectionView else { continue }
            let screen = window.screen ?? NSScreen.main!
            view.screenDOMElements = elements.map { el in
                let viewRect = CGRect(
                    x: el.rect.origin.x - screen.frame.origin.x,
                    y: mainH - el.rect.origin.y - el.rect.height - screen.frame.origin.y,
                    width: el.rect.width, height: el.rect.height
                )
                return DOMElementBox(rect: viewRect, label: el.label)
            }
            view.needsDisplay = true
        }
    }

    func dismiss() {
        for window in windows { window.orderOut(nil) }
        NSCursor.arrow.set()
        windows.removeAll()
        // Explicit dismiss (Esc, final pick, mode switch) wipes preserved SPX
        // state — only click-hide via hidePreservingSPX preserves it.
        spxPreservedSegments.removeAll()
        spxPreservedColorIndex = 0
    }

    // MARK: Private

    private func showOverlay(isSVG: Bool, screenImages: [(displayID: CGDirectDisplayID, image: CGImage)], onComplete: @escaping (CGRect) -> Void, onCancel: @escaping () -> Void, immediate: Bool) {
        NSCursor.crosshair.set()
        self.completion = onComplete
        self.cancellation = onCancel
        let imageByDisplay = Dictionary(uniqueKeysWithValues: screenImages.map { ($0.displayID, $0.image) })
        for screen in NSScreen.screens {
            let window = KeyWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .init(Int(CGShieldingWindowLevel()))
            window.isOpaque = true
            window.backgroundColor = .black
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            let view = SelectionView(frame: screen.frame)
            view.isSVGMode = isSVG
            if let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                view.backgroundImage = imageByDisplay[displayID]
            }
            view.onComplete = { [weak self] cgRect in
                guard let self else { return }
                self.dismiss()
                if immediate { self.completion?(cgRect) }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.completion?(cgRect) } }
            }
            view.onCancel = { [weak self] in self?.dismiss(); self?.cancellation?() }
            window.contentView = view
            windows.append(window)
            window.makeKeyAndOrderFront(nil)
            view.discardCursorRects()
            view.resetCursorRects()
        }
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeFirstResponder(windows.first?.contentView)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { NSCursor.crosshair.set() }
    }
}
