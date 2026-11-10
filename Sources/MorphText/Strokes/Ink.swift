// Ported from morphtext for Flutter (lib/src/ink.dart, strokes branch):
// measuring ink (the thickest point of a shape, its holes, its pieces), and
// a stroke's discs stamped as pixels to measure.

import Foundation

private func polygonBounds(_ polygons: [[Double]]) -> (Double, Double, Double, Double)? {
    var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
    for p in polygons {
        for k in stride(from: 0, to: p.count - 1, by: 2) {
            minX = min(minX, p[k])
            maxX = max(maxX, p[k])
            minY = min(minY, p[k + 1])
            maxY = max(maxY, p[k + 1])
        }
    }
    return maxX > minX && maxY > minY ? (minX, minY, maxX, maxY) : nil
}

/// Ink as pixels, to measure several ways at once: its thickest point,
/// its holes and its pieces.
struct Ink {
    private let mask: [UInt8]
    private let w: Int, h: Int
    private let px: Double

    /// `polygons` (closed, interleaved x, y in ems, filled non-zero) at
    /// `pixelsPerEm`.
    init(polygons: [[Double]], pixelsPerEm: Double) {
        let (minX, minY, maxX, maxY) = polygonBounds(polygons) ?? (0, 0, 0, 0)
        let h = 1 / pixelsPerEm
        let w = Int(((maxX - minX) / h).rounded(.up)) + 4
        let ht = Int(((maxY - minY) / h).rounded(.up)) + 4
        mask = fillPolygons(polygons, w, ht, minX - 2 * h, minY - 2 * h, h)
        self.w = w
        self.h = ht
        px = h
    }

    /// Lines of discs (`lines`, each interleaved x, y, r in ems) at
    /// `pixelsPerEm`, stamped straight in: no polygons.
    init(strokes lines: [[Double]], pixelsPerEm: Double) {
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for l in lines {
            for k in stride(from: 0, to: l.count - 2, by: 3) {
                minX = min(minX, l[k] - l[k + 2])
                maxX = max(maxX, l[k] + l[k + 2])
                minY = min(minY, l[k + 1] - l[k + 2])
                maxY = max(maxY, l[k + 1] + l[k + 2])
            }
        }
        let h = 1 / pixelsPerEm
        px = h
        guard maxX > minX else {
            mask = [0]
            w = 1
            self.h = 1
            return
        }
        let w = Int(((maxX - minX) / h).rounded(.up)) + 4
        let ht = Int(((maxY - minY) / h).rounded(.up)) + 4
        let ox = minX - 2 * h, oy = minY - 2 * h
        var mask = [UInt8](repeating: 0, count: w * ht)
        for l in lines {
            let n = l.count / 3
            for k in 0..<n {
                // The piece from this disc to the next: every pixel whose centre
                // is within the radius there of the line between them.
                let j = min(k + 1, n - 1)
                let x0 = l[3 * k], y0 = l[3 * k + 1], r0 = l[3 * k + 2]
                let x1 = l[3 * j], y1 = l[3 * j + 1], r1 = l[3 * j + 2]
                let r = max(r0, r1)
                if r <= 0 { continue }
                let i0 = max(0, Int(((min(x0, x1) - r - ox) / h).rounded(.down)))
                let i1 = min(w - 1, Int(((max(x0, x1) + r - ox) / h).rounded(.up)))
                let j0 = max(0, Int(((min(y0, y1) - r - oy) / h).rounded(.down)))
                let j1 = min(ht - 1, Int(((max(y0, y1) + r - oy) / h).rounded(.up)))
                if i0 > i1 || j0 > j1 { continue }
                let dx = x1 - x0, dy = y1 - y0
                let len2 = dx * dx + dy * dy
                for jj in j0...j1 {
                    let py = oy + (Double(jj) + 0.5) * h
                    for ii in i0...i1 {
                        let p = jj * w + ii
                        if mask[p] == 1 { continue }
                        let px = ox + (Double(ii) + 0.5) * h
                        let s = len2 == 0 ? 0 : min(max(((px - x0) * dx + (py - y0) * dy) / len2, 0), 1)
                        let ex = x0 + dx * s - px, ey = y0 + dy * s - py
                        let rs = r0 + (r1 - r0) * s
                        if ex * ex + ey * ey <= rs * rs { mask[p] = 1 }
                    }
                }
            }
        }
        self.mask = mask
        self.w = w
        self.h = ht
    }

    /// The ink's width and height, in ems.
    var extent: (Double, Double) {
        var x0 = w, y0 = h, x1 = -1, y1 = -1
        for i in mask.indices where mask[i] != 0 {
            let x = i % w, y = i / w
            x0 = min(x0, x)
            x1 = max(x1, x)
            y0 = min(y0, y)
            y1 = max(y1, y)
        }
        return x1 < 0 ? (0, 0) : (Double(x1 - x0 + 1) * px, Double(y1 - y0 + 1) * px)
    }

    /// The ink's area, in square ems.
    var area: Double { Double(mask.reduce(0) { $0 + Int($1) }) * px * px }

    /// The radius of the largest disc inside, in ems.
    var thickest: Double {
        let best = distanceField(mask, w, h).max() ?? 0
        return max(0, best.squareRoot() - 0.5) * px
    }

    /// How many holes (pieces of the outside not reaching the picture's
    /// edge, four-connected), of at least `minimum` square ems.
    func holes(minimum: Double = 2e-4) -> Int { regions(0, minimum, diagonal: false, edges: false) }

    /// How many pieces of ink (eight-connected), of at least `minimum`
    /// square ems.
    func pieces(minimum: Double = 2e-4) -> Int { regions(1, minimum, diagonal: true, edges: true) }

    private func regions(_ value: UInt8, _ minimum: Double, diagonal: Bool, edges: Bool) -> Int {
        var seen = [UInt8](repeating: 0, count: w * h)
        var queue: [Int] = []
        var count = 0
        let least = minimum / (px * px)
        for start in 0..<(w * h) {
            if mask[start] != value || seen[start] == 1 { continue }
            queue.removeAll(keepingCapacity: true)
            queue.append(start)
            seen[start] = 1
            var touches = false
            var i = 0
            while i < queue.count {
                let p = queue[i]
                i += 1
                let x = p % w, y = p / w
                if x == 0 || y == 0 || x == w - 1 || y == h - 1 { touches = true }
                for dy in -1...1 {
                    for dx in -1...1 {
                        if dx == 0 && dy == 0 { continue }
                        if !diagonal && dx != 0 && dy != 0 { continue }
                        let nx = x + dx, ny = y + dy
                        if nx < 0 || ny < 0 || nx >= w || ny >= h { continue }
                        let q = ny * w + nx
                        if mask[q] == value && seen[q] == 0 {
                            seen[q] = 1
                            queue.append(q)
                        }
                    }
                }
            }
            if Double(queue.count) < least { continue }
            if edges || !touches { count += 1 }
        }
        return count
    }
}

/// How alike `a` and `b` are as silhouettes (each with its holes filled),
/// measured together at `pixelsPerEm`: the share of their union both
/// cover, and each one's holes as a share of its silhouette.
func silhouettes(_ a: [[Double]], _ b: [[Double]], pixelsPerEm: Double = 64) -> (Double, Double, Double) {
    guard let (minX, minY, maxX, maxY) = polygonBounds(a + b) else { return (0, 0, 0) }
    let h = 1 / pixelsPerEm
    let w = Int(((maxX - minX) / h).rounded(.up)) + 4
    let ht = Int(((maxY - minY) / h).rounded(.up)) + 4
    func solid(_ p: [[Double]]) -> ([UInt8], Int, Int) {
        let mask = fillPolygons(p, w, ht, minX - 2 * h, minY - 2 * h, h)
        // The outside: everything reachable from the picture's edge.
        var outside = [UInt8](repeating: 0, count: w * ht)
        var queue = [0]
        outside[0] = 1
        var i = 0
        while i < queue.count {
            let q = queue[i]
            i += 1
            let x = q % w, y = q / w
            var next: [Int] = []
            if x > 0 { next.append(q - 1) }
            if x < w - 1 { next.append(q + 1) }
            if y > 0 { next.append(q - w) }
            if y < ht - 1 { next.append(q + w) }
            for n in next where mask[n] == 0 && outside[n] == 0 {
                outside[n] = 1
                queue.append(n)
            }
        }
        var ink = 0, filled = 0
        var shape = [UInt8](repeating: 0, count: w * ht)
        for i in 0..<(w * ht) {
            ink += Int(mask[i])
            if outside[i] == 0 {
                shape[i] = 1
                filled += 1
            }
        }
        return (shape, filled, filled - ink)
    }
    let (sa, fa, ha) = solid(a)
    let (sb, fb, hb) = solid(b)
    var both = 0, either = 0
    for i in 0..<(w * ht) {
        both += Int(sa[i] & sb[i])
        either += Int(sa[i] | sb[i])
    }
    return (either == 0 ? 0 : Double(both) / Double(either),
            fa == 0 ? 0 : Double(ha) / Double(fa),
            fb == 0 ? 0 : Double(hb) / Double(fb))
}

/// A line of discs (`xyr`, interleaved x, y, r in ems) as polygons, all
/// wound the same way: a 24-gon a disc and the hull between neighbours.
func strokePolygons(_ xyr: [Double]) -> [[Double]] {
    var out: [[Double]] = []
    let n = xyr.count / 3
    for i in 0..<n {
        let x = xyr[3 * i], y = xyr[3 * i + 1], r = xyr[3 * i + 2]
        if r <= 0 { continue }
        out.append((0..<24).flatMap { k -> [Double] in
            let a = 2 * Double.pi * Double(k) / 24
            return [x + r * cos(a), y + r * sin(a)]
        })
        if i == 0 { continue }
        let x1 = xyr[3 * i - 3], y1 = xyr[3 * i - 2], r1 = xyr[3 * i - 1]
        let dx = x - x1, dy = y - y1
        let d = hypot(dx, dy)
        if d == 0 || d <= abs(r1 - r) { continue }
        let ux = dx / d, uy = dy / d, vx = -uy, vy = ux
        let k = (r1 - r) / d, c = max(0, 1 - k * k).squareRoot()
        let ax = k * ux + c * vx, ay = k * uy + c * vy
        let bx = k * ux - c * vx, by = k * uy - c * vy
        let quad = [x1 + r1 * ax, y1 + r1 * ay, x + r * ax, y + r * ay, x + r * bx, y + r * by, x1 + r1 * bx, y1 + r1 * by]
        out.append(doubledArea(quad) < 0 ? [quad[6], quad[7], quad[4], quad[5], quad[2], quad[3], quad[0], quad[1]] : quad)
    }
    return out
}

/// How far two inks differ, measured at `pixelsPerEm`: the pixels only `a`
/// covers, only `b` covers, and `a`'s area (polygons filled non-zero).
func inkDifference(_ a: [[Double]], _ b: [[Double]], pixelsPerEm: Double = 192) -> (Int, Int, Int) {
    guard let (minX, minY, maxX, maxY) = polygonBounds(a + b) else { return (0, 0, 0) }
    let h = 1 / pixelsPerEm
    let w = Int(((maxX - minX) / h).rounded(.up)) + 2
    let ht = Int(((maxY - minY) / h).rounded(.up)) + 2
    let ma = fillPolygons(a, w, ht, minX - h, minY - h, h)
    let mb = fillPolygons(b, w, ht, minX - h, minY - h, h)
    var onlyA = 0, onlyB = 0, area = 0
    for i in 0..<(w * ht) {
        area += Int(ma[i])
        if ma[i] == 1 && mb[i] == 0 { onlyA += 1 }
        if mb[i] == 1 && ma[i] == 0 { onlyB += 1 }
    }
    return (onlyA, onlyB, area)
}
