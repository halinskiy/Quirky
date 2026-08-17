import Cocoa

/// Pixel-level analyzer for SPX mode.
/// Holds a tightly-packed RGBA copy of a CGImage plus lazy edge / run-length maps.
///
/// Primitives:
///   - `horizontalExtent(at:y:minEdgeLength:)` / `verticalExtent(...)` — cast a
///     ray from `(x, y)` until it hits a "long" edge. Long-edge filtering is what
///     makes a ruler stop on a card border instead of on a letter stroke.
///   - `contentBoundsIn(_:minGradient:)` — tight bounds of the visible content
///     inside a rect, used to shrink a drawn selection onto what it encloses.
///   - `snapToEdge(near:radius:)` — spiral search for the nearest high-gradient
///     pixel; snaps a dragged ruler endpoint onto a real edge.
///
/// All coordinates are image pixels, origin top-left.
final class SPXAnalyzer {
    let width: Int
    let height: Int

    private let pixels: UnsafeMutablePointer<UInt8>
    private let bytesPerRow: Int
    private var gradient: UnsafeMutablePointer<UInt8>?
    // For each pixel, the length of the contiguous high-gradient run it
    // belongs to, capped at 255. `vRunLen` measures along the vertical axis
    // (so it identifies vertical edges); `hRunLen` along the horizontal.
    private var vRunLen: UnsafeMutablePointer<UInt8>?
    private var hRunLen: UnsafeMutablePointer<UInt8>?

    /// Pixels with a gradient ≥ this value count as "edge pixels". Lower
    /// catches softer borders (low-alpha strokes, anti-aliased rounded
    /// rectangles, shadows). Changing it invalidates the run-length maps so
    /// they get rebuilt on next access.
    var edgeThreshold: UInt8 = 24 {
        didSet {
            guard oldValue != edgeThreshold else { return }
            if let v = vRunLen { UnsafeMutableRawPointer(v).deallocate(); vRunLen = nil }
            if let h = hRunLen { UnsafeMutableRawPointer(h).deallocate(); hRunLen = nil }
        }
    }

    init?(image: CGImage) {
        self.width = image.width
        self.height = image.height
        guard width > 0, height > 0 else { return nil }
        self.bytesPerRow = width * 4
        let totalBytes = bytesPerRow * height
        let raw = UnsafeMutableRawPointer.allocate(byteCount: totalBytes, alignment: 4)
        self.pixels = raw.bindMemory(to: UInt8.self, capacity: totalBytes)
        let space = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
        guard let ctx = CGContext(
            data: raw, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: space, bitmapInfo: bitmapInfo
        ) else {
            raw.deallocate()
            return nil
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    deinit {
        UnsafeMutableRawPointer(pixels).deallocate()
        if let g = gradient { UnsafeMutableRawPointer(g).deallocate() }
        if let v = vRunLen { UnsafeMutableRawPointer(v).deallocate() }
        if let h = hRunLen { UnsafeMutableRawPointer(h).deallocate() }
    }

    // MARK: - Horizontal / vertical extents (rays from a point to long edges)

    /// Extends a horizontal ray at row `y` left and right from column `x` until
    /// it hits a "long" vertical edge in each direction. Returns the column
    /// indices in image pixels. If no edge is found in a direction, returns
    /// the canvas border (0 or width - 1).
    func horizontalExtent(at x: Int, y: Int, minEdgeLength: Int = 12) -> (left: Int, right: Int)? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        if vRunLen == nil { buildRunMaps() }
        guard let v = vRunLen else { return nil }
        let minLen = UInt8(min(255, max(1, minEdgeLength)))
        let w = width
        let row = y * w

        var left = 0
        if x > 0 {
            var xi = x - 1
            while xi >= 0 {
                if v[row + xi] >= minLen { left = xi; break }
                xi -= 1
            }
        }

        var right = width - 1
        if x < width - 1 {
            for xi in (x + 1)..<width where v[row + xi] >= minLen {
                right = xi; break
            }
        }
        return (left, right)
    }

    /// Vertical analogue of `horizontalExtent`.
    func verticalExtent(at x: Int, y: Int, minEdgeLength: Int = 12) -> (top: Int, bottom: Int)? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        if hRunLen == nil { buildRunMaps() }
        guard let h = hRunLen else { return nil }
        let minLen = UInt8(min(255, max(1, minEdgeLength)))
        let w = width

        var top = 0
        if y > 0 {
            var yi = y - 1
            while yi >= 0 {
                if h[yi * w + x] >= minLen { top = yi; break }
                yi -= 1
            }
        }

        var bottom = height - 1
        if y < height - 1 {
            for yi in (y + 1)..<height where h[yi * w + x] >= minLen {
                bottom = yi; break
            }
        }
        return (top, bottom)
    }

    // MARK: - Content bounds inside a rect (shrink-only magnetism)

    /// Returns the tight bounding box of high-gradient pixels strictly inside
    /// `rect`. Used to shrink a user-drawn selection to the visible content
    /// it encloses — never expands outside the original rect.
    /// `minGradient` controls what counts as content; lower picks up softer
    /// anti-aliased edges, higher only hard contrasts.
    func contentBoundsIn(_ rect: CGRect, minGradient: UInt8 = 12) -> CGRect? {
        if gradient == nil { buildGradientMap() }
        guard let g = gradient else { return nil }
        let xMin = max(0, Int(rect.minX.rounded()))
        let xMax = min(width - 1, Int(rect.maxX.rounded()))
        let yMin = max(0, Int(rect.minY.rounded()))
        let yMax = min(height - 1, Int(rect.maxY.rounded()))
        guard xMax > xMin, yMax > yMin else { return nil }

        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for y in yMin...yMax {
            let row = y * width
            for x in xMin...xMax where g[row + x] >= minGradient {
                if x < minX { minX = x }
                if y < minY { minY = y }
                if x > maxX { maxX = x }
                if y > maxY { maxY = y }
            }
        }
        if minX == Int.max { return nil }
        return CGRect(x: minX, y: minY,
                      width: maxX - minX + 1,
                      height: maxY - minY + 1)
    }

    // MARK: - Edge snap (kept for potential ruler use)

    func snapToEdge(near x: Int, _ y: Int, radius: Int, threshold: Int = 36) -> (Int, Int) {
        guard radius > 0 else { return (x, y) }
        if gradient == nil { buildGradientMap() }
        guard let map = gradient else { return (x, y) }

        for r in 0...radius {
            if r == 0 {
                if x > 0, y > 0, x < width - 1, y < height - 1,
                   Int(map[y * width + x]) >= threshold {
                    return (x, y)
                }
                continue
            }
            for dx in -r...r {
                let dy = r - abs(dx)
                let candidates: [Int] = dy == 0 ? [y] : [y - dy, y + dy]
                for ny in candidates {
                    let nx = x + dx
                    guard nx > 0, ny > 0, nx < width - 1, ny < height - 1 else { continue }
                    if Int(map[ny * width + nx]) >= threshold {
                        return (nx, ny)
                    }
                }
            }
        }
        return (x, y)
    }

    // MARK: - Map builders

    private func buildGradientMap() {
        let count = width * height
        let raw = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 1)
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: count)
        let map = raw.bindMemory(to: UInt8.self, capacity: count)
        let bpr = bytesPerRow
        let pxPtr = pixels
        @inline(__always) func lum(_ x: Int, _ y: Int) -> Int {
            let i = y * bpr + x * 4
            return Int(pxPtr[i]) + Int(pxPtr[i + 1]) + Int(pxPtr[i + 2])
        }
        for y in 1..<height - 1 {
            for x in 1..<width - 1 {
                let gx = abs(lum(x - 1, y) - lum(x + 1, y))
                let gy = abs(lum(x, y - 1) - lum(x, y + 1))
                let g = (gx + gy) / 6
                map[y * width + x] = UInt8(min(255, g))
            }
        }
        gradient = map
    }

    /// Fills `vRunLen` and `hRunLen` with the length of the high-gradient run
    /// each pixel belongs to in its respective axis. Capped at 255.
    private func buildRunMaps() {
        if gradient == nil { buildGradientMap() }
        guard let grad = gradient else { return }

        let count = width * height
        let vRaw = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 1)
        vRaw.initializeMemory(as: UInt8.self, repeating: 0, count: count)
        let v = vRaw.bindMemory(to: UInt8.self, capacity: count)
        let hRaw = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 1)
        hRaw.initializeMemory(as: UInt8.self, repeating: 0, count: count)
        let h = hRaw.bindMemory(to: UInt8.self, capacity: count)

        let t = edgeThreshold
        let w = width
        // Allow up to gapTol consecutive sub-threshold pixels inside a run.
        // Soft edges (anti-aliased rounded card borders) have minor dips that
        // would otherwise break the run into useless fragments.
        let gapTol = 2

        // Vertical runs — scan each column top-to-bottom.
        for x in 0..<width {
            var y = 0
            while y < height {
                if grad[y * w + x] < t { y += 1; continue }
                var endY = y + 1
                var gap = 0
                while endY < height {
                    if grad[endY * w + x] >= t {
                        endY += 1; gap = 0
                    } else if gap < gapTol {
                        endY += 1; gap += 1
                    } else {
                        break
                    }
                }
                // Trim trailing gap pixels so the run ends on an edge pixel.
                let runEnd = endY - gap
                if runEnd > y {
                    let runLen = UInt8(min(255, runEnd - y))
                    for i in y..<runEnd { v[i * w + x] = runLen }
                }
                y = max(y + 1, runEnd)
            }
        }

        // Horizontal runs — scan each row left-to-right.
        for y in 0..<height {
            let row = y * w
            var x = 0
            while x < width {
                if grad[row + x] < t { x += 1; continue }
                var endX = x + 1
                var gap = 0
                while endX < width {
                    if grad[row + endX] >= t {
                        endX += 1; gap = 0
                    } else if gap < gapTol {
                        endX += 1; gap += 1
                    } else {
                        break
                    }
                }
                let runEnd = endX - gap
                if runEnd > x {
                    let runLen = UInt8(min(255, runEnd - x))
                    for i in x..<runEnd { h[row + i] = runLen }
                }
                x = max(x + 1, runEnd)
            }
        }

        vRunLen = v
        hRunLen = h
    }
}
