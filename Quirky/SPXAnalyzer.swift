import Cocoa

/// Pixel-level analyzer for SPX mode.
/// Holds a tightly-packed RGBA copy of a CGImage plus lazy edge / run-length maps.
///
/// Primitives:
///   - `elementBboxAt(x:y:minEdgeLength:)` — raycast in 4 directions from `(x,y)`
///     until hitting a "long" edge in each axis. Long-edge filtering ignores text
///     strokes and short artefacts, snapping the bbox to the nearest enclosing
///     UI element (window, panel, card, button).
///   - `snapToEdge(near:radius:)` — spiral search for the nearest high-gradient
///     pixel (used for free ruler endpoints, if/when added back).
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

    // MARK: - Element bbox (raycast over long edges)

    /// Returns the bounding rect of the smallest enclosing UI element around
    /// `(x, y)`, or `nil` if the rays cover more than `maxArea` fraction of the
    /// canvas (e.g., when the cursor is on a uniform desktop background).
    ///
    /// `minEdgeLength` is the perpendicular run length an edge must have to be
    /// considered a "real" boundary. ~16 px filters out body text strokes while
    /// keeping buttons / cards / windows.
    func elementBboxAt(x: Int, y: Int, minEdgeLength: Int = 16, maxArea: Double = 0.85) -> CGRect? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        if vRunLen == nil || hRunLen == nil { buildRunMaps() }
        guard let v = vRunLen, let h = hRunLen else { return nil }

        let minLen = UInt8(min(255, max(1, minEdgeLength)))
        let w = width

        // Ray right: find smallest x' > x where vRunLen[(y, x')] >= minLen.
        var right = width - 1
        if x < width - 1 {
            for xi in (x + 1)..<width where v[y * w + xi] >= minLen {
                right = xi; break
            }
        }

        // Ray left.
        var left = 0
        if x > 0 {
            var xi = x - 1
            while xi >= 0 {
                if v[y * w + xi] >= minLen { left = xi; break }
                xi -= 1
            }
        }

        // Ray down (image y grows downward).
        var bottom = height - 1
        if y < height - 1 {
            for yi in (y + 1)..<height where h[yi * w + x] >= minLen {
                bottom = yi; break
            }
        }

        // Ray up.
        var top = 0
        if y > 0 {
            var yi = y - 1
            while yi >= 0 {
                if h[yi * w + x] >= minLen { top = yi; break }
                yi -= 1
            }
        }

        let wOut = right - left + 1
        let hOut = bottom - top + 1
        guard wOut > 3, hOut > 3 else { return nil }
        if Double(wOut * hOut) > Double(width * height) * maxArea { return nil }
        return CGRect(x: left, y: top, width: wOut, height: hOut)
    }

    // MARK: - Rect snap (drag a frame → snap each edge to detected edges)

    /// Given a user-drawn rectangle in image pixels, snap each edge to the
    /// strongest nearby edge in a perpendicular band of width `2*tolerance`.
    /// The score for a candidate row/column is the number of pixels along the
    /// rect's opposite axis whose run-length is at least `minRunLength` — this
    /// prefers long, continuous edges (window/card borders) over short ones
    /// (text strokes).
    ///
    /// If the best candidate's score is below `minAcceptableFraction` of the
    /// edge length, that edge isn't snapped (keeps the user's intent in
    /// edge-poor regions).
    func snapRect(_ rect: CGRect,
                  tolerance: Int = 18,
                  minRunLength: Int = 8,
                  minAcceptableFraction: Double = 0.12) -> CGRect {
        if vRunLen == nil || hRunLen == nil { buildRunMaps() }
        guard let v = vRunLen, let h = hRunLen else { return rect }

        let xMin = max(0, min(width - 1, Int(rect.minX.rounded())))
        let xMax = max(0, min(width - 1, Int(rect.maxX.rounded())))
        let yMin = max(0, min(height - 1, Int(rect.minY.rounded())))
        let yMax = max(0, min(height - 1, Int(rect.maxY.rounded())))
        guard xMax > xMin + 1, yMax > yMin + 1 else { return rect }

        let minRun = UInt8(min(255, max(1, minRunLength)))
        let w = width

        let edgeLenX = xMax - xMin + 1
        let edgeLenY = yMax - yMin + 1
        let minHScore = max(2, Int(Double(edgeLenX) * minAcceptableFraction))
        let minVScore = max(2, Int(Double(edgeLenY) * minAcceptableFraction))

        @inline(__always) func scoreRow(_ y: Int) -> Int {
            let row = y * w
            var s = 0
            for x in xMin...xMax where h[row + x] >= minRun { s += 1 }
            return s
        }
        @inline(__always) func scoreCol(_ x: Int) -> Int {
            var s = 0
            for y in yMin...yMax where v[y * w + x] >= minRun { s += 1 }
            return s
        }

        // Snap top: search [yMin - tol, yMin + tol], prefer rows closer to the user's edge on ties.
        var bestTop = yMin, bestTopScore = -1, bestTopDist = Int.max
        let topLo = max(0, yMin - tolerance)
        let topHi = min(height - 1, yMin + tolerance)
        if topLo <= topHi {
            for cy in topLo...topHi {
                let s = scoreRow(cy)
                let dist = abs(cy - yMin)
                if s > bestTopScore || (s == bestTopScore && dist < bestTopDist) {
                    bestTopScore = s; bestTop = cy; bestTopDist = dist
                }
            }
        }
        if bestTopScore < minHScore { bestTop = yMin }

        // Snap bottom.
        var bestBot = yMax, bestBotScore = -1, bestBotDist = Int.max
        let botLo = max(0, yMax - tolerance)
        let botHi = min(height - 1, yMax + tolerance)
        if botLo <= botHi {
            for cy in botLo...botHi {
                let s = scoreRow(cy)
                let dist = abs(cy - yMax)
                if s > bestBotScore || (s == bestBotScore && dist < bestBotDist) {
                    bestBotScore = s; bestBot = cy; bestBotDist = dist
                }
            }
        }
        if bestBotScore < minHScore { bestBot = yMax }

        // Snap left.
        var bestLeft = xMin, bestLeftScore = -1, bestLeftDist = Int.max
        let lLo = max(0, xMin - tolerance)
        let lHi = min(width - 1, xMin + tolerance)
        if lLo <= lHi {
            for cx in lLo...lHi {
                let s = scoreCol(cx)
                let dist = abs(cx - xMin)
                if s > bestLeftScore || (s == bestLeftScore && dist < bestLeftDist) {
                    bestLeftScore = s; bestLeft = cx; bestLeftDist = dist
                }
            }
        }
        if bestLeftScore < minVScore { bestLeft = xMin }

        // Snap right.
        var bestRight = xMax, bestRightScore = -1, bestRightDist = Int.max
        let rLo = max(0, xMax - tolerance)
        let rHi = min(width - 1, xMax + tolerance)
        if rLo <= rHi {
            for cx in rLo...rHi {
                let s = scoreCol(cx)
                let dist = abs(cx - xMax)
                if s > bestRightScore || (s == bestRightScore && dist < bestRightDist) {
                    bestRightScore = s; bestRight = cx; bestRightDist = dist
                }
            }
        }
        if bestRightScore < minVScore { bestRight = xMax }

        if bestRight <= bestLeft || bestBot <= bestTop { return rect }
        return CGRect(x: bestLeft, y: bestTop,
                      width: bestRight - bestLeft,
                      height: bestBot - bestTop)
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
