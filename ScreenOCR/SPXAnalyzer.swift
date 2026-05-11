import Cocoa

/// Pixel-level analyzer for SPX mode.
/// Holds a tightly-packed RGBA copy of a CGImage plus a lazy gradient map,
/// and offers two primitives:
///   - `floodBox(at:tolerance:)`  — scanline 4-connected flood fill, returns bbox
///   - `snapToEdge(near:radius:)` — spiral search for the nearest high-gradient pixel
///
/// Coordinates are image pixels with origin top-left.
final class SPXAnalyzer {
    let width: Int
    let height: Int

    private let pixels: UnsafeMutablePointer<UInt8>
    private let bytesPerRow: Int
    private var gradient: UnsafeMutablePointer<UInt8>?

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
    }

    // MARK: - Flood fill

    /// Scanline 4-connected flood fill at `(startX, startY)`.
    /// Returns bbox in image pixel coords or `nil` if the region exceeds `maxPixels`
    /// (used to avoid filling the entire desktop background by accident).
    func floodBox(at startX: Int, _ startY: Int, tolerance: Int, maxPixels: Int = 300_000) -> CGRect? {
        guard startX >= 0, startY >= 0, startX < width, startY < height else { return nil }

        let bpr = bytesPerRow
        let pxPtr = pixels

        let seedR = pxPtr[startY * bpr + startX * 4]
        let seedG = pxPtr[startY * bpr + startX * 4 + 1]
        let seedB = pxPtr[startY * bpr + startX * 4 + 2]
        let tol = UInt8(max(0, min(255, tolerance)))

        @inline(__always) func match(_ x: Int, _ y: Int) -> Bool {
            let i = y * bpr + x * 4
            let r = pxPtr[i], g = pxPtr[i + 1], b = pxPtr[i + 2]
            let dr = r > seedR ? r - seedR : seedR - r
            let dg = g > seedG ? g - seedG : seedG - g
            let db = b > seedB ? b - seedB : seedB - b
            return max(dr, max(dg, db)) <= tol
        }

        var visited = [Bool](repeating: false, count: width * height)
        var stack: [(Int, Int)] = []
        stack.reserveCapacity(128)
        stack.append((startX, startY))

        var minX = startX, maxX = startX, minY = startY, maxY = startY
        var filled = 0

        while let (sx, y) = stack.popLast() {
            let rowOffset = y * width
            if visited[rowOffset + sx] { continue }

            var lx = sx
            while lx >= 0, !visited[rowOffset + lx], match(lx, y) { lx -= 1 }
            lx += 1

            var rx = sx
            while rx < width, !visited[rowOffset + rx], match(rx, y) { rx += 1 }
            rx -= 1

            for i in lx...rx { visited[rowOffset + i] = true }
            filled += rx - lx + 1
            if filled > maxPixels { return nil }

            if lx < minX { minX = lx }
            if rx > maxX { maxX = rx }
            if y < minY { minY = y }
            if y > maxY { maxY = y }

            for ny in [y - 1, y + 1] where ny >= 0 && ny < height {
                let nyOffset = ny * width
                var i = lx
                while i <= rx {
                    if !visited[nyOffset + i], match(i, ny) {
                        var j = i
                        while j <= rx, !visited[nyOffset + j], match(j, ny) { j += 1 }
                        stack.append((j - 1, ny))
                        i = j + 1
                    } else {
                        i += 1
                    }
                }
            }
        }

        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    // MARK: - Edge snap

    /// Snap `(x, y)` to the nearest pixel whose gradient magnitude exceeds `threshold`,
    /// searching outward to `radius`. Returns the original point if nothing is found.
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
}
