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
    private var spxToleranceIndex: Int = 2
    private var spxDragOrigin: NSPoint = .zero
    private var spxMoveLast: NSPoint = .zero    // for Space-to-move during a drag
    private var spxIsDragging: Bool = false
    private var spxLiveDragRect: NSRect = .zero  // raw during drag; lerped during snap-on-release
    private var spxIsSnapAnimating: Bool = false
    private var spxSnapAnimTimer: Timer?
    private var spxSnapAnimFrom: NSRect = .zero
    private var spxSnapAnimTo: NSRect = .zero
    private var spxSnapAnimStart: Date = .distantPast
    private let spxSnapAnimDuration: TimeInterval = 0.18
    var spxIsGhost: Bool = false                  // OverlayWindow flips this via setSPXGhost

    /// Identifies a draggable handle on a committed segment.
    fileprivate struct SPXHandle: Equatable {
        let segmentIndex: Int
        /// 0=start endpoint, 1=end endpoint for lines; rect uses 0..3 corners.
        let cornerIndex: Int
    }
    private var spxHoveredHandle: SPXHandle?
    private var spxActiveHandle: SPXHandle?
    // Hover-to-reveal close (×) button on a committed segment.
    private var spxHoverSegIndex: Int?
    private var spxCloseTimer: Timer?
    private var spxShowCloseForIndex: Int?
    private let spxCloseRevealDelay: TimeInterval = 1.5
    private let spxCloseBtnSize: CGFloat = 20

    fileprivate struct SPXTolerance {
        let edgeThreshold: UInt8   // gradient strength — lower catches softer edges
        let minRun: Int            // perpendicular run length to qualify as an edge
    }
    /// 8 monotonic steps. Edge-pixel threshold is kept low (6) at every level
    /// so faint anti-aliased borders (icon-button strokes, low-contrast cards)
    /// always make it into the run-length map. T controls only minRun — the
    /// minimum length of contiguous edge a ray will stop at — so the slider
    /// is really "ignore objects smaller than N pixels". T1 = window-scale
    /// only; T8 = catch even single-character glyphs.
    fileprivate static let spxToleranceLevels: [SPXTolerance] = [
        SPXTolerance(edgeThreshold: 6, minRun: 80),
        SPXTolerance(edgeThreshold: 6, minRun: 50),
        SPXTolerance(edgeThreshold: 6, minRun: 30),    // default
        SPXTolerance(edgeThreshold: 6, minRun: 18),
        SPXTolerance(edgeThreshold: 6, minRun: 10),
        SPXTolerance(edgeThreshold: 6, minRun:  6),
        SPXTolerance(edgeThreshold: 5, minRun:  3),
        SPXTolerance(edgeThreshold: 4, minRun:  2)
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
    /// All committed SPX segments use the user's highlight color so the
    /// markings have a single visual identity. Falls back to yellow.
    fileprivate var spxSegmentColor: NSColor {
        let hex = UserDefaults.standard.string(forKey: "highlightColorHex") ?? "FFD60A"
        return NSColor(hex: hex)
    }

    var screenWordBoxes: [CGRect] = []
    var screenSVGBoxes: [CGRect] = []
    var screenDOMElements: [DOMElementBox] = []

    override var acceptsFirstResponder: Bool { true }

    private var activeBoxes: [CGRect] {
        isSVGMode ? screenSVGBoxes : screenWordBoxes
    }

    // MARK: SPX handle hit-test

    /// Anchor points of a committed segment in view coords.
    /// Lines: 2 endpoints. Rects: 4 corners (0–3) + 4 edge midpoints (4–7):
    /// 4=left, 5=right, 6=bottom, 7=top.
    fileprivate func spxHandlePoints(for seg: SPXSegment) -> [NSPoint] {
        if seg.axis == .rect {
            let x0 = seg.start.x, x1 = seg.end.x
            let y0 = seg.start.y, y1 = seg.end.y
            let mx = (x0 + x1) / 2, my = (y0 + y1) / 2
            return [
                NSPoint(x: x0, y: y0),   // 0
                NSPoint(x: x1, y: y0),   // 1
                NSPoint(x: x0, y: y1),   // 2
                NSPoint(x: x1, y: y1),   // 3
                NSPoint(x: x0, y: my),   // 4 left edge
                NSPoint(x: x1, y: my),   // 5 right edge
                NSPoint(x: mx, y: y0),   // 6 bottom edge
                NSPoint(x: mx, y: y1)    // 7 top edge
            ]
        }
        return [seg.start, seg.end]
    }

    private func spxHandleHitTest(at p: NSPoint, radius: CGFloat = 8) -> SPXHandle? {
        // Most-recent segments win (drawn on top).
        for i in stride(from: spxCommitted.count - 1, through: 0, by: -1) {
            let points = spxHandlePoints(for: spxCommitted[i])
            for (j, hp) in points.enumerated() {
                if hypot(hp.x - p.x, hp.y - p.y) <= radius {
                    return SPXHandle(segmentIndex: i, cornerIndex: j)
                }
            }
        }
        return nil
    }

    /// Tracks which segment the cursor is dwelling on and arms a timer to
    /// reveal its close (×) button after `spxCloseRevealDelay`. Keeping the
    /// button visible while the cursor is over the button itself is handled
    /// in `spxCloseButtonContains`.
    private func updateSPXCloseHover(at p: NSPoint) {
        // Don't dismiss the button while the cursor is on it.
        if let shown = spxShowCloseForIndex,
           let r = spxCloseButtonRect(for: shown),
           r.insetBy(dx: -4, dy: -4).contains(p) {
            return
        }
        let seg = spxSegmentHitTest(at: p)
        if seg == spxHoverSegIndex { return }
        spxHoverSegIndex = seg
        spxShowCloseForIndex = nil
        spxCloseTimer?.invalidate()
        spxCloseTimer = nil
        guard let idx = seg else { needsDisplay = true; return }
        let t = Timer(timeInterval: spxCloseRevealDelay, repeats: false) { [weak self] _ in
            guard let self, self.spxHoverSegIndex == idx else { return }
            self.spxShowCloseForIndex = idx
            self.needsDisplay = true
        }
        spxCloseTimer = t
        RunLoop.current.add(t, forMode: .common)
        needsDisplay = true
    }

    /// Topmost committed segment whose body is under `p` (rect interior, or
    /// near a line). Used for the hover-to-reveal close button.
    private func spxSegmentHitTest(at p: NSPoint) -> Int? {
        for i in stride(from: spxCommitted.count - 1, through: 0, by: -1) {
            let seg = spxCommitted[i]
            if seg.axis == .rect {
                let r = NSRect(x: seg.start.x, y: seg.start.y,
                               width: seg.end.x - seg.start.x,
                               height: seg.end.y - seg.start.y).insetBy(dx: -6, dy: -6)
                if r.contains(p) { return i }
            } else {
                // Distance from p to the axis-aligned segment.
                let a = seg.start, b = seg.end
                let near: Bool
                if abs(a.y - b.y) < 0.5 {        // horizontal
                    near = p.x >= min(a.x, b.x) - 6 && p.x <= max(a.x, b.x) + 6
                        && abs(p.y - a.y) <= 6
                } else {                          // vertical
                    near = p.y >= min(a.y, b.y) - 6 && p.y <= max(a.y, b.y) + 6
                        && abs(p.x - a.x) <= 6
                }
                if near { return i }
            }
        }
        return nil
    }

    /// View-space rect of the close (×) button for segment `i`. Default is the
    /// top-right corner of the segment's bounds; if that's too close to a
    /// screen edge, pick the corner with the most surrounding room.
    private func spxCloseButtonRect(for i: Int) -> NSRect? {
        guard i < spxCommitted.count else { return nil }
        let seg = spxCommitted[i]
        let b: NSRect
        if seg.axis == .rect {
            b = NSRect(x: seg.start.x, y: seg.start.y,
                       width: seg.end.x - seg.start.x,
                       height: seg.end.y - seg.start.y)
        } else {
            b = NSRect(x: min(seg.start.x, seg.end.x),
                       y: min(seg.start.y, seg.end.y),
                       width: abs(seg.end.x - seg.start.x),
                       height: abs(seg.end.y - seg.start.y))
        }
        let s = spxCloseBtnSize
        let gap: CGFloat = 6
        let margin: CGFloat = 8
        // Candidate centers just outside each corner of the bounds.
        // (corner offset, scored by free space toward that corner).
        let candidates: [(center: NSPoint, score: CGFloat)] = [
            // top-right
            (NSPoint(x: b.maxX + gap + s/2, y: b.maxY + gap + s/2),
             (bounds.width - b.maxX) + (bounds.height - b.maxY)),
            // top-left
            (NSPoint(x: b.minX - gap - s/2, y: b.maxY + gap + s/2),
             b.minX + (bounds.height - b.maxY)),
            // bottom-right
            (NSPoint(x: b.maxX + gap + s/2, y: b.minY - gap - s/2),
             (bounds.width - b.maxX) + b.minY),
            // bottom-left
            (NSPoint(x: b.minX - gap - s/2, y: b.minY - gap - s/2),
             b.minX + b.minY)
        ]
        // Prefer top-right (index 0) unless it doesn't fit; otherwise the
        // highest-scoring corner that fits on screen.
        func fits(_ c: NSPoint) -> Bool {
            c.x - s/2 >= margin && c.x + s/2 <= bounds.width - margin
                && c.y - s/2 >= margin && c.y + s/2 <= bounds.height - margin
        }
        if fits(candidates[0].center) {
            let c = candidates[0].center
            return NSRect(x: c.x - s/2, y: c.y - s/2, width: s, height: s)
        }
        let best = candidates.filter { fits($0.center) }.max { $0.score < $1.score }
            ?? candidates[0]
        let c = best.center
        return NSRect(x: c.x - s/2, y: c.y - s/2, width: s, height: s)
    }

    /// Update segment endpoint/corner during a resize drag. Snaps the dragged
    /// anchor to the nearest detected edge on release.
    private func updateActiveHandle(to p: NSPoint, shiftHeld: Bool = false, finalize: Bool) {
        guard let h = spxActiveHandle, h.segmentIndex < spxCommitted.count else { return }
        let seg = spxCommitted[h.segmentIndex]
        let snapped = finalize ? snapViewPoint(p, radius: 18) : p

        if seg.axis == .rect {
            var minX = seg.start.x, minY = seg.start.y
            var maxX = seg.end.x,   maxY = seg.end.y

            // Shift on a corner handle locks the aspect ratio against the
            // opposite (anchor) corner — like Figma/Photoshop. Edges (4-7)
            // are already single-axis, so Shift is a no-op there.
            let isCorner = h.cornerIndex < 4
            if shiftHeld && isCorner {
                let segW = seg.end.x - seg.start.x
                let segH = seg.end.y - seg.start.y
                let aspect = abs(segW) / max(1, abs(segH))
                let anchorX: CGFloat
                let anchorY: CGFloat
                switch h.cornerIndex {
                case 0: anchorX = seg.end.x;   anchorY = seg.end.y       // anchor BR
                case 1: anchorX = seg.start.x; anchorY = seg.end.y       // anchor BL
                case 2: anchorX = seg.end.x;   anchorY = seg.start.y     // anchor TR
                default: anchorX = seg.start.x; anchorY = seg.start.y    // anchor TL
                }
                let dx = snapped.x - anchorX
                let dy = snapped.y - anchorY
                let signX: CGFloat = dx >= 0 ? 1 : -1
                let signY: CGFloat = dy >= 0 ? 1 : -1
                // Project the moving corner onto the diagonal of the
                // original aspect ratio. Pick the dominant axis so the
                // user always feels the cursor lead, never the lock.
                var newDx = dx
                var newDy = dy
                if abs(dx) > abs(dy) * aspect {
                    newDy = signY * abs(dx) / aspect
                } else {
                    newDx = signX * abs(dy) * aspect
                }
                let nx = anchorX + newDx
                let ny = anchorY + newDy
                switch h.cornerIndex {
                case 0: minX = nx; minY = ny
                case 1: maxX = nx; minY = ny
                case 2: minX = nx; maxY = ny
                default: maxX = nx; maxY = ny
                }
            } else {
                switch h.cornerIndex {
                case 0: minX = snapped.x; minY = snapped.y     // corner TL
                case 1: maxX = snapped.x; minY = snapped.y     // corner TR
                case 2: minX = snapped.x; maxY = snapped.y     // corner BL
                case 3: maxX = snapped.x; maxY = snapped.y     // corner BR
                case 4: minX = snapped.x                       // left edge
                case 5: maxX = snapped.x                       // right edge
                case 6: minY = snapped.y                       // bottom edge
                default: maxY = snapped.y                      // top edge
                }
            }
            if maxX < minX { swap(&minX, &maxX) }
            if maxY < minY { swap(&minY, &maxY) }
            let newRect = NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            guard let image = backgroundImage else { return }
            let sx = CGFloat(image.width) / bounds.width
            let sy = CGFloat(image.height) / bounds.height
            let pxW = Int((newRect.width * sx).rounded())
            let pxH = Int((newRect.height * sy).rounded())
            spxCommitted[h.segmentIndex] = SPXSegment(
                axis: .rect,
                start: NSPoint(x: minX, y: minY),
                end: NSPoint(x: maxX, y: maxY),
                pxLength: pxW, pxHeight: pxH, color: seg.color
            )
        } else {
            // Constrain motion to the segment's axis so H stays horizontal, V vertical.
            let newStart: NSPoint
            let newEnd: NSPoint
            if seg.axis == .horizontal {
                let y = seg.start.y
                if h.cornerIndex == 0 { newStart = NSPoint(x: snapped.x, y: y); newEnd = seg.end }
                else { newStart = seg.start; newEnd = NSPoint(x: snapped.x, y: y) }
            } else {
                let x = seg.start.x
                if h.cornerIndex == 0 { newStart = NSPoint(x: x, y: snapped.y); newEnd = seg.end }
                else { newStart = seg.start; newEnd = NSPoint(x: x, y: snapped.y) }
            }
            let lengthPxImage: Int = { () -> Int in
                guard let image = backgroundImage else {
                    return Int(hypot(newEnd.x - newStart.x, newEnd.y - newStart.y).rounded())
                }
                let sx = CGFloat(image.width) / bounds.width
                let sy = CGFloat(image.height) / bounds.height
                let dx = abs(newEnd.x - newStart.x) * sx
                let dy = abs(newEnd.y - newStart.y) * sy
                return Int((dx + dy).rounded())  // axis-aligned, one term is 0
            }()
            spxCommitted[h.segmentIndex] = SPXSegment(
                axis: seg.axis,
                start: newStart, end: newEnd,
                pxLength: lengthPxImage, pxHeight: 0, color: seg.color
            )
        }
        if finalize { copySPXLengthOrSizeToPasteboard(spxCommitted[h.segmentIndex]) }
        needsDisplay = true
    }

    private func copySPXLengthOrSizeToPasteboard(_ seg: SPXSegment) {
        let s = seg.axis == .rect ? "\(seg.pxLength) × \(seg.pxHeight) px" : "\(seg.pxLength) px"
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    private func snapViewPoint(_ p: NSPoint, radius: Int) -> NSPoint {
        guard let analyzer = spxAnalyzer, let (px, py) = viewToImagePixel(p) else { return p }
        let (snapX, snapY) = analyzer.snapToEdge(near: px, py, radius: radius)
        return imagePixelToView(snapX, snapY)
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
            // Hit-test resize handles first — if hovering one, hide the live
            // crosshair so it doesn't fight the handle.
            let newHover = spxHandleHitTest(at: point)
            if newHover != spxHoveredHandle {
                spxHoveredHandle = newHover
                if newHover != nil { spxLiveH = nil; spxLiveV = nil }
            }
            if newHover == nil { recomputeSPXLiveSegments() }
            updateSPXCloseHover(at: point)
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
            // Close (×) button takes priority over everything else.
            if let shown = spxShowCloseForIndex,
               let cr = spxCloseButtonRect(for: shown),
               cr.insetBy(dx: -3, dy: -3).contains(point) {
                deleteSPXSegment(at: shown)
                return
            }
            if let h = spxHandleHitTest(at: point) {
                // Double-click a rect's corner → re-run magnetism on the
                // segment's current bounds, animate the rect to fit content.
                if event.clickCount >= 2,
                   h.segmentIndex < spxCommitted.count,
                   spxCommitted[h.segmentIndex].axis == .rect {
                    magnetizeRectSegment(at: h.segmentIndex)
                    return
                }
                spxActiveHandle = h
                spxCursor = point
                return
            }
            spxDragOrigin = point
            spxMoveLast = point
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
            if spxActiveHandle != nil {
                updateActiveHandle(to: current, shiftHeld: event.modifierFlags.contains(.shift), finalize: false)
                return
            }
            if !spxIsDragging && hypot(current.x - spxDragOrigin.x, current.y - spxDragOrigin.y) > 3 {
                spxIsDragging = true
            }
            if spxIsDragging {
                // Hold Space mid-drag to move the whole selection (OCR-style).
                // Only honored once a real rectangle exists, so a stray Space
                // reading at drag-start can't collapse the box to zero.
                let hasRealRect = spxLiveDragRect.width > 8 && spxLiveDragRect.height > 8
                if spaceDown && hasRealRect {
                    let dx = current.x - spxMoveLast.x
                    let dy = current.y - spxMoveLast.y
                    spxDragOrigin.x += dx
                    spxDragOrigin.y += dy
                }
                spxMoveLast = current
                // Free drag — no snapping while the button is held. Magnetic
                // snap is animated on release in mouseUp.
                spxLiveDragRect = NSRect(
                    x: min(spxDragOrigin.x, current.x),
                    y: min(spxDragOrigin.y, current.y),
                    width: abs(current.x - spxDragOrigin.x),
                    height: abs(current.y - spxDragOrigin.y)
                )
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
            if spxActiveHandle != nil {
                let current = convert(event.locationInWindow, from: nil)
                updateActiveHandle(to: current, shiftHeld: event.modifierFlags.contains(.shift), finalize: true)
                spxActiveHandle = nil
                recomputeSPXLiveSegments()
                needsDisplay = true
                return
            }
            if spxIsDragging {
                let current = convert(event.locationInWindow, from: nil)
                let raw = NSRect(
                    x: min(spxDragOrigin.x, current.x),
                    y: min(spxDragOrigin.y, current.y),
                    width: abs(current.x - spxDragOrigin.x),
                    height: abs(current.y - spxDragOrigin.y)
                )
                spxIsDragging = false
                let target = snappedDragRect(start: spxDragOrigin, end: current)
                if rectsApproximatelyEqual(raw, target) {
                    commitSPXRect(raw)
                    spxLiveDragRect = .zero
                    recomputeSPXLiveSegments()
                    needsDisplay = true
                } else {
                    spxLiveDragRect = raw
                    animateSPXSnap(from: raw, to: target) { [weak self] in
                        guard let self else { return }
                        self.commitSPXRect(target)
                        self.spxLiveDragRect = .zero
                        self.recomputeSPXLiveSegments()
                        self.needsDisplay = true
                    }
                }
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
            // Match the live-drag highlight rule: include only words whose
            // CENTER lies inside the selection rect, then tighten finalRect
            // to the union of those words. The previous `intersects()` test
            // grew finalRect into adjacent lines on any pixel-level overlap,
            // causing the OCR result to include text the user didn't select.
            var contained: [CGRect] = []
            for box in screenWordBoxes {
                if inflated.contains(NSPoint(x: box.midX, y: box.midY)) {
                    contained.append(box)
                }
            }
            if !contained.isEmpty {
                finalRect = contained.reduce(contained[0]) { $0.union($1) }
            }
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

        // In SPX ghost mode, skip the screenshot so the user sees the live
        // underlying screen with markings floating on top.
        let skipBackground = isSPXMode && spxIsGhost
        if !skipBackground {
            if let bg = backgroundImage {
                NSImage(cgImage: bg, size: bounds.size).draw(in: bounds)
            } else {
                // Window is non-opaque (needed for ghost). If the screenshot
                // hasn't arrived yet, fill with black so the borderless window
                // still receives mouse clicks instead of passing them through.
                context.setFillColor(NSColor.black.cgColor)
                context.fill(bounds)
            }
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
            // Strict "center inside selection" hit-test instead of bare
            // intersects() — a 1-pixel overlap on an adjacent line used to
            // light up that whole line's word and then include it in the
            // OCR crop, surprising users who clearly only selected one line.
            let hitBoxes = activeBoxes.filter { box in
                selectionRect.contains(NSPoint(x: box.midX, y: box.midY))
            }
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
        spxIsGhost = false
        spxHoveredHandle = nil
        spxActiveHandle = nil
        // NB: spxCommitted / spxColorIndex are intentionally NOT cleared here.
        // The OverlayWindow restores prior segments via setSPXState(...) right
        // after this call when the user re-enters SPX. Esc → dismiss() wipes.
        // Restore the tolerance index from UserDefaults (clamped).
        let stored = UserDefaults.standard.object(forKey: "spxToleranceIndex") as? Int
        let n = SelectionView.spxToleranceLevels.count
        if let s = stored, s >= 0, s < n { spxToleranceIndex = s }
        else { spxToleranceIndex = 2 }
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
        spxIsGhost = false
        spxHoveredHandle = nil
        spxActiveHandle = nil
        spxSnapAnimTimer?.invalidate()
        spxSnapAnimTimer = nil
        spxIsSnapAnimating = false
        spxLiveDragRect = .zero
        spxHoverSegIndex = nil
        spxShowCloseForIndex = nil
        spxCloseTimer?.invalidate()
        spxCloseTimer = nil
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
            // Committed rects are obstacles too — clip the ray to their edges.
            let (lx, rx) = clipHorizontalAgainstRects(vy: s.y, cursorX: spxCursor.x,
                                                      left: s.x, right: e.x)
            let cs = NSPoint(x: lx, y: s.y), ce = NSPoint(x: rx, y: e.y)
            spxLiveH = SPXLiveSegment(start: cs, end: ce,
                                      pxLength: viewLengthToImagePx(lx, rx, axisX: true))
        } else { spxLiveH = nil }
        if let v = analyzer.verticalExtent(at: px, y: py, minEdgeLength: spxMinEdgeLength) {
            let s = imagePixelToView(px, v.top)
            let e = imagePixelToView(px, v.bottom)
            let (ty, by) = clipVerticalAgainstRects(vx: s.x, cursorY: spxCursor.y,
                                                    top: max(s.y, e.y), bottom: min(s.y, e.y))
            let cs = NSPoint(x: s.x, y: ty), ce = NSPoint(x: e.x, y: by)
            spxLiveV = SPXLiveSegment(start: cs, end: ce,
                                      pxLength: viewLengthToImagePx(by, ty, axisX: false))
        } else { spxLiveV = nil }
    }

    /// Returns the committed rects in view coords (skips lines).
    private var spxCommittedRects: [NSRect] {
        spxCommitted.compactMap { seg in
            guard seg.axis == .rect else { return nil }
            return NSRect(x: seg.start.x, y: seg.start.y,
                          width: seg.end.x - seg.start.x,
                          height: seg.end.y - seg.start.y)
        }
    }

    /// Convert a view-space span on one axis to image pixels (rounded).
    private func viewLengthToImagePx(_ a: CGFloat, _ b: CGFloat, axisX: Bool) -> Int {
        guard let image = backgroundImage else { return Int(abs(b - a).rounded()) }
        let scale = axisX ? CGFloat(image.width) / bounds.width
                          : CGFloat(image.height) / bounds.height
        return Int((abs(b - a) * scale).rounded())
    }

    /// Clip a horizontal ruler at view-row `vy` to the nearest committed rect
    /// edge on each side of `cursorX`. If the cursor is inside a rect, the
    /// ruler is bounded by that rect's own left/right edges.
    private func clipHorizontalAgainstRects(vy: CGFloat, cursorX: CGFloat,
                                            left: CGFloat, right: CGFloat) -> (CGFloat, CGFloat) {
        var l = left, r = right
        for rect in spxCommittedRects {
            guard vy >= rect.minY, vy <= rect.maxY else { continue }
            if rect.maxX <= cursorX {
                if rect.maxX > l { l = rect.maxX }
            } else if rect.minX >= cursorX {
                if rect.minX < r { r = rect.minX }
            } else {
                if rect.minX > l { l = rect.minX }
                if rect.maxX < r { r = rect.maxX }
            }
        }
        return (l, r)
    }

    /// Vertical analogue. `top` is the larger view-y, `bottom` the smaller.
    private func clipVerticalAgainstRects(vx: CGFloat, cursorY: CGFloat,
                                          top: CGFloat, bottom: CGFloat) -> (CGFloat, CGFloat) {
        var t = top, b = bottom
        for rect in spxCommittedRects {
            guard vx >= rect.minX, vx <= rect.maxX else { continue }
            if rect.maxY <= cursorY {
                if rect.maxY > b { b = rect.maxY }
            } else if rect.minY >= cursorY {
                if rect.minY < t { t = rect.minY }
            } else {
                if rect.maxY < t { t = rect.maxY }
                if rect.minY > b { b = rect.minY }
            }
        }
        return (t, b)
    }

    private func commitSPXAxis(_ axis: SPXSegment.Axis) {
        let live: SPXLiveSegment? = (axis == .horizontal) ? spxLiveH : spxLiveV
        guard let seg = live, seg.pxLength > 1 else { return }
        let color = spxSegmentColor
        spxCommitted.append(SPXSegment(axis: axis, start: seg.start, end: seg.end,
                                       pxLength: seg.pxLength, pxHeight: 0, color: color))
        copySPXLengthToPasteboard(seg.pxLength)
        needsDisplay = true
    }

    /// During a drag, the user picks "anywhere inside the element". We then
    /// (1) probe the element bbox around the center of the rubber-band, and
    /// (2) if that bbox overlaps the user's rect, use it. Otherwise we fall
    /// back to per-edge snap of the user's drawn rect.
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
        let viewSX = bounds.width / CGFloat(image.width)
        let viewSY = bounds.height / CGFloat(image.height)

        @inline(__always) func toView(_ r: CGRect) -> NSRect {
            NSRect(x: r.minX * viewSX,
                   y: bounds.height - (r.minY + r.height) * viewSY,
                   width: r.width * viewSX,
                   height: r.height * viewSY)
        }

        // Shrink-to-content magnetism. We tighten the user's drawn rect
        // around the visible content it encloses; the snap never grows past
        // the original drag. A small inset ignores edge pixels that touch
        // the rect border itself.
        let inset: CGFloat = 2
        let scanRect = imgRect.insetBy(dx: inset, dy: inset)
        guard scanRect.width > 4, scanRect.height > 4 else { return raw }
        guard let inner = analyzer.contentBoundsIn(scanRect, minGradient: 12) else {
            return raw
        }
        // Don't accept a snap that collapses the rect to nothing — that means
        // we hit only noise; better to keep the user's rect intact.
        let userArea = imgRect.width * imgRect.height
        let innerArea = inner.width * inner.height
        guard innerArea > max(64, userArea * 0.02) else { return raw }
        // Pad by 1 px so the rect hugs content without clipping outer pixels,
        // but clamp to the user's original rect (shrink-only).
        let pX0 = max(imgRect.minX, inner.minX - 1)
        let pY0 = max(imgRect.minY, inner.minY - 1)
        let pX1 = min(imgRect.maxX, inner.maxX + 1)
        let pY1 = min(imgRect.maxY, inner.maxY + 1)
        let padded = CGRect(x: pX0, y: pY0, width: pX1 - pX0, height: pY1 - pY0)
        return toView(padded)
    }

    private func rectsApproximatelyEqual(_ a: NSRect, _ b: NSRect, tol: CGFloat = 1.0) -> Bool {
        abs(a.minX - b.minX) < tol && abs(a.minY - b.minY) < tol
            && abs(a.width  - b.width)  < tol
            && abs(a.height - b.height) < tol
    }

    /// Smoothly lerps spxLiveDragRect from `from` to `to` over ~180 ms with an
    /// ease-out cubic, then invokes `completion` on the main thread. Cancels
    /// any in-flight snap animation.
    private func animateSPXSnap(from: NSRect, to: NSRect, completion: @escaping () -> Void) {
        spxSnapAnimTimer?.invalidate()
        spxSnapAnimTimer = nil
        spxSnapAnimFrom = from
        spxSnapAnimTo = to
        spxSnapAnimStart = Date()
        spxIsSnapAnimating = true
        let duration = spxSnapAnimDuration
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let now = Date().timeIntervalSince(self.spxSnapAnimStart)
            let p = min(1.0, max(0.0, now / duration))
            let eased = 1.0 - pow(1.0 - p, 3)            // ease-out cubic
            let f = self.spxSnapAnimFrom
            let g = self.spxSnapAnimTo
            self.spxLiveDragRect = NSRect(
                x: f.minX + (g.minX - f.minX) * CGFloat(eased),
                y: f.minY + (g.minY - f.minY) * CGFloat(eased),
                width:  f.width  + (g.width  - f.width)  * CGFloat(eased),
                height: f.height + (g.height - f.height) * CGFloat(eased)
            )
            self.needsDisplay = true
            if p >= 1.0 {
                timer.invalidate()
                self.spxSnapAnimTimer = nil
                self.spxIsSnapAnimating = false
                completion()
            }
        }
        spxSnapAnimTimer = t
        RunLoop.current.add(t, forMode: .common)
    }

    /// Re-shrink a committed rect segment to its enclosed content. Animates
    /// the rect bounds in place so the user sees the corner snap toward what
    /// they really meant to measure.
    private func magnetizeRectSegment(at index: Int) {
        guard index < spxCommitted.count else { return }
        let seg = spxCommitted[index]
        guard seg.axis == .rect else { return }
        let current = NSRect(
            x: seg.start.x, y: seg.start.y,
            width: seg.end.x - seg.start.x,
            height: seg.end.y - seg.start.y
        )
        let target = snappedDragRect(start: NSPoint(x: current.minX, y: current.minY),
                                     end:   NSPoint(x: current.maxX, y: current.maxY))
        guard !rectsApproximatelyEqual(current, target) else { return }
        animateSegmentRect(at: index, from: current, to: target)
    }

    /// Lerps a rect-typed segment in place (used by magnetize-on-double-click).
    private func animateSegmentRect(at index: Int, from: NSRect, to: NSRect) {
        spxSnapAnimTimer?.invalidate()
        spxSnapAnimTimer = nil
        let start = Date()
        let duration = spxSnapAnimDuration
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            guard index < self.spxCommitted.count else { t.invalidate(); return }
            let now = Date().timeIntervalSince(start)
            let p = min(1.0, max(0.0, now / duration))
            let eased = 1.0 - pow(1.0 - p, 3)
            let r = NSRect(
                x: from.minX + (to.minX - from.minX) * CGFloat(eased),
                y: from.minY + (to.minY - from.minY) * CGFloat(eased),
                width:  from.width  + (to.width  - from.width)  * CGFloat(eased),
                height: from.height + (to.height - from.height) * CGFloat(eased)
            )
            let seg = self.spxCommitted[index]
            var pxW = Int(r.width.rounded())
            var pxH = Int(r.height.rounded())
            if let img = self.backgroundImage {
                pxW = Int((r.width  * CGFloat(img.width)  / self.bounds.width).rounded())
                pxH = Int((r.height * CGFloat(img.height) / self.bounds.height).rounded())
            }
            self.spxCommitted[index] = SPXSegment(
                axis: .rect,
                start: NSPoint(x: r.minX, y: r.minY),
                end:   NSPoint(x: r.maxX, y: r.maxY),
                pxLength: pxW, pxHeight: pxH, color: seg.color
            )
            self.needsDisplay = true
            if p >= 1.0 {
                t.invalidate()
                self.spxSnapAnimTimer = nil
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString("\(pxW) × \(pxH) px", forType: .string)
            }
        }
        spxSnapAnimTimer = timer
        RunLoop.current.add(timer, forMode: .common)
    }

    private func commitSPXRect(_ rect: NSRect) {
        guard let image = backgroundImage, rect.width > 2, rect.height > 2 else { return }
        let sx = CGFloat(image.width) / bounds.width
        let sy = CGFloat(image.height) / bounds.height
        let pxW = Int((rect.width * sx).rounded())
        let pxH = Int((rect.height * sy).rounded())
        let color = spxSegmentColor
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

    private func deleteSPXSegment(at index: Int) {
        guard index < spxCommitted.count else { return }
        spxCommitted.remove(at: index)
        if spxColorIndex > 0 { spxColorIndex -= 1 }
        spxHoverSegIndex = nil
        spxShowCloseForIndex = nil
        spxCloseTimer?.invalidate()
        spxCloseTimer = nil
        recomputeSPXLiveSegments()
        needsDisplay = true
    }

    private func copySPXLengthToPasteboard(_ px: Int) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("\(px) px", forType: .string)
    }

    // MARK: SPX drawing

    private func drawSPXHUD(context: CGContext) {
        let ghost = spxIsGhost
        if !ghost {
            // Subtle dim so colored markings pop on busy screens.
            context.saveGState()
            context.setFillColor(NSColor.black.withAlphaComponent(0.08).cgColor)
            context.fill(bounds)
            context.restoreGState()
        }

        let segColor = spxSegmentColor

        // 1) Committed segments — single shared color, slightly translucent in ghost.
        let strongAlpha: CGFloat = ghost ? 0.65 : 1.0
        for (i, seg) in spxCommitted.enumerated() {
            let isHovered = (spxHoveredHandle?.segmentIndex == i)
            let activeIdx = (spxActiveHandle?.segmentIndex == i) ? spxActiveHandle?.cornerIndex : nil
            if seg.axis == .rect {
                let r = NSRect(x: seg.start.x, y: seg.start.y,
                               width: seg.end.x - seg.start.x,
                               height: seg.end.y - seg.start.y)
                drawSPXRect(context: context, rect: r, color: segColor,
                            label: seg.label, alpha: strongAlpha, lineW: 1.6, drawHandles: !ghost,
                            hoveredHandle: isHovered ? spxHoveredHandle?.cornerIndex : nil,
                            activeHandle: activeIdx)
            } else {
                drawSPXSegmentLine(context: context, start: seg.start, end: seg.end,
                                   color: segColor, label: seg.label,
                                   alpha: strongAlpha, lineW: 1.6, drawHandles: !ghost,
                                   hoveredHandle: isHovered ? spxHoveredHandle?.cornerIndex : nil,
                                   activeHandle: activeIdx)
            }
        }

        // 2) Live preview & crosshair — only in interactive mode.
        if !ghost {
            if (spxIsDragging || spxIsSnapAnimating) && spxLiveDragRect.width > 1 && spxLiveDragRect.height > 1 {
                let pxW: Int, pxH: Int
                if let image = backgroundImage {
                    pxW = Int((spxLiveDragRect.width * CGFloat(image.width) / bounds.width).rounded())
                    pxH = Int((spxLiveDragRect.height * CGFloat(image.height) / bounds.height).rounded())
                } else { pxW = Int(spxLiveDragRect.width); pxH = Int(spxLiveDragRect.height) }
                drawSPXRect(context: context, rect: spxLiveDragRect, color: segColor,
                            label: "\(pxW)×\(pxH)", alpha: 0.7, lineW: 1.0,
                            drawHandles: false, hoveredHandle: nil, activeHandle: nil)
            } else if spxActiveHandle == nil {
                if let h = spxLiveH {
                    drawSPXSegmentLine(context: context, start: h.start, end: h.end,
                                       color: segColor, label: "\(h.pxLength)",
                                       alpha: 0.7, lineW: 1.0, drawHandles: false,
                                       hoveredHandle: nil, activeHandle: nil)
                }
                if let v = spxLiveV {
                    drawSPXSegmentLine(context: context, start: v.start, end: v.end,
                                       color: segColor, label: "\(v.pxLength)",
                                       alpha: 0.7, lineW: 1.0, drawHandles: false,
                                       hoveredHandle: nil, activeHandle: nil)
                }
            }

            if spxCursor.x > 0 || spxCursor.y > 0, spxActiveHandle == nil, !spxIsDragging {
                context.saveGState()
                context.setFillColor(segColor.cgColor)
                let r: CGFloat = 2.5
                context.fillEllipse(in: CGRect(x: spxCursor.x - r, y: spxCursor.y - r,
                                               width: r * 2, height: r * 2))
                context.restoreGState()
            }

            drawSPXToleranceChip(context: context)

            // Hover-revealed close (×) button.
            if let idx = spxShowCloseForIndex, let cr = spxCloseButtonRect(for: idx) {
                drawSPXCloseButton(context: context, rect: cr)
            }
        }
    }

    private func drawSPXCloseButton(context: CGContext, rect: NSRect) {
        context.saveGState()
        // Circular dark chip.
        context.setFillColor(NSColor(deviceRed: 0.12, green: 0.12, blue: 0.13,
                                     alpha: 0.95).cgColor)
        context.fillEllipse(in: rect)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.25).cgColor)
        context.setLineWidth(1)
        context.strokeEllipse(in: rect)
        // The × glyph.
        let inset: CGFloat = rect.width * 0.32
        let p1 = CGRect(x: rect.minX + inset, y: rect.minY + inset,
                        width: rect.width - inset * 2, height: rect.height - inset * 2)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(1.8)
        context.setLineCap(.round)
        context.move(to: CGPoint(x: p1.minX, y: p1.minY))
        context.addLine(to: CGPoint(x: p1.maxX, y: p1.maxY))
        context.move(to: CGPoint(x: p1.minX, y: p1.maxY))
        context.addLine(to: CGPoint(x: p1.maxX, y: p1.minY))
        context.strokePath()
        context.restoreGState()
    }

    /// Rounded rectangle measurement with corner handles for resizing.
    private func drawSPXRect(context: CGContext, rect: NSRect, color: NSColor,
                             label: String, alpha: CGFloat, lineW: CGFloat,
                             drawHandles: Bool, hoveredHandle: Int?, activeHandle: Int?) {
        guard rect.width >= 1, rect.height >= 1 else { return }
        let drawColor = color.withAlphaComponent(alpha)

        // Translucent interior fill in the same hue.
        context.saveGState()
        context.setFillColor(color.withAlphaComponent(0.18 * alpha).cgColor)
        context.fill(rect)
        context.restoreGState()

        // Halo for outline legibility on busy backgrounds.
        context.saveGState()
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.4 * alpha).cgColor)
        context.setLineWidth(lineW + 1.5)
        context.setLineJoin(.miter)
        context.stroke(rect)
        context.restoreGState()

        // Main square outline.
        context.saveGState()
        context.setStrokeColor(drawColor.cgColor)
        context.setLineWidth(lineW)
        context.setLineJoin(.miter)
        context.stroke(rect)
        context.restoreGState()

        // Corner handles (0–3) + edge-midpoint handles (4–7), same order as
        // spxHandlePoints so hover/active indices line up.
        if drawHandles {
            let pts = [
                rect.origin,                                   // 0
                NSPoint(x: rect.maxX, y: rect.minY),           // 1
                NSPoint(x: rect.minX, y: rect.maxY),           // 2
                NSPoint(x: rect.maxX, y: rect.maxY),           // 3
                NSPoint(x: rect.minX, y: rect.midY),           // 4 left
                NSPoint(x: rect.maxX, y: rect.midY),           // 5 right
                NSPoint(x: rect.midX, y: rect.minY),           // 6 bottom
                NSPoint(x: rect.midX, y: rect.maxY)            // 7 top
            ]
            for (i, c) in pts.enumerated() {
                drawHandle(context: context, at: c, color: drawColor,
                           hovered: i == hoveredHandle, active: i == activeHandle)
            }
        }

        let labelCenter = rect.minY > 22
            ? NSPoint(x: rect.midX, y: rect.minY - 12)
            : NSPoint(x: rect.midX, y: rect.maxY + 12)
        let white = NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1).cgColor
        drawSPXPill(context: context, near: labelCenter, text: label,
                    textColor: white, bgColor: drawColor)
    }

    /// Small filled circle marking a resize handle. Grows on hover/active.
    private func drawHandle(context: CGContext, at p: NSPoint, color: NSColor,
                            hovered: Bool, active: Bool) {
        let r: CGFloat = active ? 6 : (hovered ? 5 : 4)
        let outerR = r + 1.5
        context.saveGState()
        context.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        context.fillEllipse(in: CGRect(x: p.x - outerR, y: p.y - outerR,
                                       width: outerR * 2, height: outerR * 2))
        context.setFillColor(NSColor.white.cgColor)
        context.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r,
                                       width: r * 2, height: r * 2))
        context.setFillColor(color.cgColor)
        let inner = r - 1.5
        context.fillEllipse(in: CGRect(x: p.x - inner, y: p.y - inner,
                                       width: inner * 2, height: inner * 2))
        context.restoreGState()
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

    /// Axis-aligned measurement line with rounded caps and endpoint handles.
    private func drawSPXSegmentLine(context: CGContext, start: NSPoint, end: NSPoint,
                                    color: NSColor, label: String,
                                    alpha: CGFloat, lineW: CGFloat,
                                    drawHandles: Bool, hoveredHandle: Int?, activeHandle: Int?) {
        let isHorizontal = abs(end.y - start.y) < 0.5
        let isVertical = abs(end.x - start.x) < 0.5
        guard isHorizontal || isVertical else { return }

        let drawColor = color.withAlphaComponent(alpha)

        // Halo.
        context.saveGState()
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.4 * alpha).cgColor)
        context.setLineWidth(lineW + 1.5)
        context.setLineCap(.round)
        context.move(to: start); context.addLine(to: end)
        context.strokePath()
        context.restoreGState()

        // Main line with rounded caps.
        context.saveGState()
        context.setStrokeColor(drawColor.cgColor)
        context.setLineWidth(lineW)
        context.setLineCap(.round)
        context.move(to: start); context.addLine(to: end)
        context.strokePath()
        context.restoreGState()

        if drawHandles {
            drawHandle(context: context, at: start, color: drawColor,
                       hovered: hoveredHandle == 0, active: activeHandle == 0)
            drawHandle(context: context, at: end, color: drawColor,
                       hovered: hoveredHandle == 1, active: activeHandle == 1)
        }

        // Label pill perpendicular-offset from the midpoint.
        let mid = NSPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let labelCenter: NSPoint = isHorizontal
            ? NSPoint(x: mid.x, y: mid.y - 14)
            : NSPoint(x: mid.x + 24, y: mid.y)
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
    /// Toggles SPX overlay between opaque-interactive and ghost (click-through,
    /// no background image, segments rendered translucent over the live screen).
    func setSPXGhost(_ ghost: Bool) {
        for window in windows {
            guard let view = window.contentView as? SelectionView, view.isSPXMode else { continue }
            window.ignoresMouseEvents = ghost
            view.spxIsGhost = ghost
            view.needsDisplay = true
        }
        if ghost {
            NSCursor.arrow.set()
            windows.first?.resignKey()
        } else {
            NSCursor.crosshair.set()
            windows.first?.makeKeyAndOrderFront(nil)
        }
    }

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

    #if !MAS_BUILD
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
    #endif

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
            window.isOpaque = false                     // allow per-pixel alpha (needed for SPX ghost mode)
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
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
