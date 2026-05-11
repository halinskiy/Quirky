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

    private let edgeThreshold: UInt8 = 24

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

        // Vertical runs — scan each column top-to-bottom.
        for x in 0..<width {
            var y = 0
            while y < height {
                if grad[y * w + x] >= t {
                    var endY = y
                    while endY < height && grad[endY * w + x] >= t { endY += 1 }
                    let runLen = UInt8(min(255, endY - y))
                    for i in y..<endY { v[i * w + x] = runLen }
                    y = endY
                } else {
                    y += 1
                }
            }
        }

        // Horizontal runs — scan each row left-to-right.
        for y in 0..<height {
            let row = y * w
            var x = 0
            while x < width {
                if grad[row + x] >= t {
                    var endX = x
                    while endX < width && grad[row + endX] >= t { endX += 1 }
                    let runLen = UInt8(min(255, endX - x))
                    for i in x..<endX { h[row + i] = runLen }
                    x = endX
                } else {
                    x += 1
                }
            }
        }

        vRunLen = v
        hRunLen = h
    }
}
