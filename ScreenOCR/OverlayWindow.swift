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
    var isSVGMode = false
    var isHEXMode = false
    var isDOMMode = false
    var isSPXMode = false
    var backgroundImage: CGImage? {
        didSet {
            if let img = backgroundImage, isSPXMode { spxAnalyzer = SPXAnalyzer(image: img) }
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

    // SPX mode state
    private var spxAnalyzer: SPXAnalyzer?
    private var spxPoint: NSPoint = .zero
    private var spxBbox: NSRect?               // view-local
    private var spxRulerActive = false
    private var spxRulerStart: NSPoint = .zero // view-local
    private var spxRulerEnd: NSPoint = .zero
    private var spxRulerStartRaw: NSPoint = .zero  // before snap
    private var spxLastFloodAt: NSPoint = NSPoint(x: -1000, y: -1000)
    private var spxLastFloodTolerance: Int = -1

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
            spxPoint = point
            updateSPXBbox()
            needsDisplay = true
            return
        }
        guard !isSelecting else { return }
        hoveredBox = activeBoxes.first(where: { $0.contains(point) })
        needsDisplay = true
    }

    override func flagsChanged(with event: NSEvent) {
        if isSPXMode && !spxRulerActive {
            updateSPXBbox(force: true)
            needsDisplay = true
        }
        super.flagsChanged(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if isHEXMode || isDOMMode { return }
        startPoint = convert(event.locationInWindow, from: nil)
        if isSPXMode {
            isSelecting = true
            isDragging = false
            spxRulerActive = false
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
            if !isDragging {
                if hypot(current.x - startPoint.x, current.y - startPoint.y) > 3 {
                    isDragging = true
                    spxRulerActive = true
                    spxRulerStartRaw = startPoint
                    let snapStart = snapViewPoint(startPoint, radius: 8)
                    spxRulerStart = snapStart
                    spxBbox = nil
                } else { return }
            }
            let noSnap = NSEvent.modifierFlags.contains(.command)
            spxRulerEnd = noSnap ? current : snapViewPoint(current, radius: 8)
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
            defer { isSelecting = false; isDragging = false; spxRulerActive = false }
            if isDragging {
                let s = spxRulerStart, e = spxRulerEnd
                let dx = abs(e.x - s.x), dy = abs(e.y - s.y)
                let label: String
                if dy < 3 {
                    label = "\(Int(dx.rounded())) px"
                } else if dx < 3 {
                    label = "\(Int(dy.rounded())) px"
                } else {
                    let len = Int(hypot(dx, dy).rounded())
                    label = "\(len) px"
                }
                onSPXSizePicked?(label)
            } else if let bbox = spxBbox {
                let label = "\(Int(bbox.width.rounded()))×\(Int(bbox.height.rounded()))"
                onSPXSizePicked?(label)
            } else {
                onCancel?()
            }
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
        if event.keyCode == 53 { onCancel?() }
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
        spxBbox = nil
        spxRulerActive = false
        spxLastFloodAt = NSPoint(x: -1000, y: -1000)
        spxLastFloodTolerance = -1
        needsDisplay = true
    }

    func disableSPXMode() {
        isSPXMode = false
        spxAnalyzer = nil
        spxBbox = nil
        spxRulerActive = false
        onSPXSizePicked = nil
    }

    // MARK: SPX helpers

    private var spxBaseTolerance: Int {
        let stored = UserDefaults.standard.integer(forKey: "spxTolerance")
        return stored > 0 ? stored : 10
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

    private func imageRectToView(_ r: CGRect) -> NSRect {
        guard let image = backgroundImage else { return .zero }
        let sx = bounds.width / CGFloat(image.width)
        let sy = bounds.height / CGFloat(image.height)
        let x = r.minX * sx
        let w = r.width * sx
        let h = r.height * sy
        let y = bounds.height - (r.minY + r.height) * sy
        return NSRect(x: x, y: y, width: w, height: h)
    }

    private func imagePixelToView(_ px: Int, _ py: Int) -> NSPoint {
        guard let image = backgroundImage else { return .zero }
        let sx = bounds.width / CGFloat(image.width)
        let sy = bounds.height / CGFloat(image.height)
        return NSPoint(x: CGFloat(px) * sx, y: bounds.height - CGFloat(py) * sy)
    }

    private func snapViewPoint(_ p: NSPoint, radius: Int) -> NSPoint {
        guard let analyzer = spxAnalyzer, let (px, py) = viewToImagePixel(p) else { return p }
        let (snapX, snapY) = analyzer.snapToEdge(near: px, py, radius: radius)
        return imagePixelToView(snapX, snapY)
    }

    private func updateSPXBbox(force: Bool = false) {
        guard let analyzer = spxAnalyzer, let (px, py) = viewToImagePixel(spxPoint) else {
            spxBbox = nil; return
        }
        let outerMode = NSEvent.modifierFlags.contains(.shift)
        let tolerance = outerMode ? spxBaseTolerance * 2 : spxBaseTolerance
        if !force, spxLastFloodTolerance == tolerance,
           abs(spxPoint.x - spxLastFloodAt.x) < 1, abs(spxPoint.y - spxLastFloodAt.y) < 1 {
            return
        }
        spxLastFloodAt = spxPoint
        spxLastFloodTolerance = tolerance
        if let bbox = analyzer.floodBox(at: px, py, tolerance: tolerance) {
            spxBbox = imageRectToView(bbox)
        } else {
            spxBbox = nil
        }
    }

    private func drawSPXHUD(context: CGContext) {
        let hex = UserDefaults.standard.string(forKey: "highlightColorHex") ?? "FFD60A"
        let highlightColor = NSColor(hex: hex)
        let white = NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1).cgColor
        let dimColor = NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 0.65).cgColor

        if spxRulerActive {
            drawSPXRuler(context: context, highlightColor: highlightColor, textColor: white, hintColor: dimColor)
        } else if let bbox = spxBbox {
            drawSPXBbox(context: context, rect: bbox, highlightColor: highlightColor, textColor: white)
        }
    }

    private func drawSPXBbox(context: CGContext, rect: NSRect, highlightColor: NSColor, textColor: CGColor) {
        let dashPattern: [CGFloat] = [4.0, 4.0]
        let cornerRadius: CGFloat = 4
        highlightColor.setStroke()
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        path.setLineDash(dashPattern, count: 2, phase: dashPhase)
        path.lineWidth = 2.5
        path.stroke()
        highlightColor.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()

        let label = "\(Int(rect.width.rounded()))×\(Int(rect.height.rounded()))"
        let line = SelectionView.makeCTLine(label, font: SelectionView.spxLabelFont, color: textColor)
        let lb = CTLineGetBoundsWithOptions(line, [])
        let hPad: CGFloat = 8, vPad: CGFloat = 5
        let labelW = lb.width + hPad * 2
        let labelH = lb.height + vPad * 2

        // Centered horizontally on bbox, prefer above; fall back below; clamp to bounds.
        var x = rect.midX - labelW / 2
        var y = rect.maxY + 6
        if y + labelH > bounds.height - 8 { y = rect.minY - labelH - 6 }
        if y < 8 { y = rect.midY - labelH / 2 } // overlay on top if no room
        x = max(8, min(bounds.width - labelW - 8, x))

        let bgRect = CGRect(x: x, y: y, width: labelW, height: labelH)
        context.saveGState()
        context.addPath(CGPath(roundedRect: bgRect, cornerWidth: 4, cornerHeight: 4, transform: nil))
        context.setFillColor(NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 0.82).cgColor)
        context.fillPath()
        context.restoreGState()

        context.textPosition = CGPoint(x: x + hPad - lb.minX, y: y + vPad - lb.minY)
        CTLineDraw(line, context)
    }

    private func drawSPXRuler(context: CGContext, highlightColor: NSColor, textColor: CGColor, hintColor: CGColor) {
        let s = spxRulerStart, e = spxRulerEnd
        let dx = e.x - s.x, dy = e.y - s.y
        let len = hypot(dx, dy)
        guard len > 0.5 else { return }

        // Line
        highlightColor.setStroke()
        let path = NSBezierPath()
        path.move(to: s)
        path.line(to: e)
        path.lineWidth = 2
        path.stroke()

        // Endpoint markers (small crosshair circles)
        for p in [s, e] {
            let dot = NSRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
            highlightColor.setFill()
            NSBezierPath(ovalIn: dot).fill()
            NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 0.6).setStroke()
            let outline = NSBezierPath(ovalIn: dot)
            outline.lineWidth = 1
            outline.stroke()
        }

        // Distance label
        let label: String
        if abs(dy) < 3 { label = "\(Int(abs(dx).rounded())) px" }
        else if abs(dx) < 3 { label = "\(Int(abs(dy).rounded())) px" }
        else { label = "\(Int(len.rounded())) px" }

        let line = SelectionView.makeCTLine(label, font: SelectionView.spxLabelFont, color: textColor)
        let lb = CTLineGetBoundsWithOptions(line, [])
        let hPad: CGFloat = 8, vPad: CGFloat = 5
        let labelW = lb.width + hPad * 2
        let labelH = lb.height + vPad * 2

        // Position label perpendicular to the line, near its midpoint, on the side with more room.
        let midX = (s.x + e.x) / 2
        let midY = (s.y + e.y) / 2
        let normal: NSPoint = len > 0
            ? NSPoint(x: -dy / len, y: dx / len)
            : NSPoint(x: 0, y: 1)
        let offset: CGFloat = 18
        var lx = midX + normal.x * offset - labelW / 2
        var ly = midY + normal.y * offset - labelH / 2
        if lx < 8 || lx + labelW > bounds.width - 8 || ly < 8 || ly + labelH > bounds.height - 8 {
            lx = midX - normal.x * offset - labelW / 2
            ly = midY - normal.y * offset - labelH / 2
        }
        lx = max(8, min(bounds.width - labelW - 8, lx))
        ly = max(8, min(bounds.height - labelH - 8, ly))

        let bgRect = CGRect(x: lx, y: ly, width: labelW, height: labelH)
        context.saveGState()
        context.addPath(CGPath(roundedRect: bgRect, cornerWidth: 4, cornerHeight: 4, transform: nil))
        context.setFillColor(NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 0.82).cgColor)
        context.fillPath()
        context.restoreGState()

        context.textPosition = CGPoint(x: lx + hPad - lb.minX, y: ly + vPad - lb.minY)
        CTLineDraw(line, context)
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
        }
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
