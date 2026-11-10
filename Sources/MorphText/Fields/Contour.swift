// Shapes as fields: a value at every point of a grid, negative inside,
// and the closed outlines where it crosses zero.

import Foundation

/// A scalar field sampled on a grid: `w` by `h` values, sample (i, j) at
/// (`x0` + i·`step`, `y0` + j·`step`), negative inside the shape.
struct Field {
    var values: [Double]
    let w: Int, h: Int
    let x0: Double, y0: Double, step: Double

    /// The value at (x, y), bilinear between samples; `outside` beyond the grid.
    @inline(__always)
    func sample(_ x: Double, _ y: Double, outside: Double) -> Double {
        let fx = (x - x0) / step, fy = (y - y0) / step
        if !(fx >= 0 && fy >= 0 && fx <= Double(w - 1) && fy <= Double(h - 1)) { return outside }
        let i = min(Int(fx), w - 2), j = min(Int(fy), h - 2)
        let u = fx - Double(i), v = fy - Double(j)
        return values.withUnsafeBufferPointer { values in
            let k = j * w + i
            return (values[k] * (1 - u) + values[k + 1] * u) * (1 - v) + (values[k + w] * (1 - u) + values[k + w + 1] * u) * v
        }
    }

    /// A signed distance at (x, y): sampled within the grid, and beyond it
    /// the grid's nearest value plus how far beyond (about right for a
    /// distance field whose shape is inside the grid).
    @inline(__always)
    func distance(_ x: Double, _ y: Double) -> Double {
        let cx = min(max(x, x0), x0 + Double(w - 1) * step)
        let cy = min(max(y, y0), y0 + Double(h - 1) * step)
        let inner = sample(cx, cy, outside: 0)
        return cx == x && cy == y ? inner : inner + hypot(x - cx, y - cy)
    }

    /// The closed outlines where the field crosses zero (marching squares,
    /// each crossing placed by linear interpolation), as polygons of
    /// interleaved x, y: each wound with the inside on the same side, so
    /// holes wind against their outlines and the whole fills non-zero.
    func contours() -> [[Double]] {
        guard w >= 2, h >= 2 else { return [] }
        // A crossing on each grid edge where the sign changes: horizontal
        // edge (i, j)–(i+1, j) is 2(jw + i), vertical (i, j)–(i, j+1) is
        // 2(jw + i) + 1.
        func inside(_ i: Int, _ j: Int) -> Bool { values[j * w + i] < 0 }
        func point(_ edge: Int) -> (Double, Double) {
            let cell = edge / 2, i = cell % w, j = cell / w
            let (i2, j2) = edge % 2 == 0 ? (i + 1, j) : (i, j + 1)
            let a = values[j * w + i], b = values[j2 * w + i2]
            let f = a == b ? 0.5 : a / (a - b)
            return (x0 + (Double(i) + Double(i2 - i) * f) * step, y0 + (Double(j) + Double(j2 - j) * f) * step)
        }
        var segments: [(Int, Int)] = []
        for j in 0..<(h - 1) {
            for i in 0..<(w - 1) {
                let a = inside(i, j), b = inside(i + 1, j), c = inside(i + 1, j + 1), d = inside(i, j + 1)
                if a == b && b == c && c == d { continue }
                let top = 2 * (j * w + i), bottom = 2 * ((j + 1) * w + i)
                let left = 2 * (j * w + i) + 1, right = 2 * (j * w + i + 1) + 1
                var crossing: [Int] = []
                if a != b { crossing.append(top) }
                if b != c { crossing.append(right) }
                if c != d { crossing.append(bottom) }
                if d != a { crossing.append(left) }
                if crossing.count == 2 {
                    segments.append((crossing[0], crossing[1]))
                } else {
                    // A saddle: the middle decides which corners join.
                    let middle = (values[j * w + i] + values[j * w + i + 1] + values[(j + 1) * w + i] + values[(j + 1) * w + i + 1]) / 4
                    let joinAC = a == c && (middle < 0) == a
                    if joinAC {
                        // a and c's kind connects through the middle: cut off b and d.
                        segments.append((top, right))
                        segments.append((bottom, left))
                    } else {
                        segments.append((left, top))
                        segments.append((right, bottom))
                    }
                }
            }
        }
        // Link the segments end to end into loops.
        var byEdge: [Int: [Int]] = [:]
        for (k, s) in segments.enumerated() {
            byEdge[s.0, default: []].append(k)
            byEdge[s.1, default: []].append(k)
        }
        var used = [Bool](repeating: false, count: segments.count)
        var loops: [[Double]] = []
        for start in segments.indices where !used[start] {
            used[start] = true
            var edges = [segments[start].0]
            var current = segments[start].1
            while current != edges[0] {
                edges.append(current)
                guard let next = byEdge[current]?.first(where: { !used[$0] }) else { break }
                used[next] = true
                current = segments[next].0 == current ? segments[next].1 : segments[next].0
            }
            if edges.count < 3 { continue }
            var points: [Double] = []
            points.reserveCapacity(2 * edges.count)
            for e in edges {
                let (x, y) = point(e)
                points += [x, y]
            }
            loops.append(oriented(points))
        }
        return loops
    }

    /// `points` wound with the inside to the right of its way on a y-down
    /// screen (as the strokes and the outlines' fills are).
    private func oriented(_ points: [Double]) -> [Double] {
        let n = points.count / 2
        // At the middle of its longest edge, a little to each side.
        var best = 0, longest = -1.0
        for k in 0..<n {
            let l = (k + 1) % n
            let d = hypot(points[2 * l] - points[2 * k], points[2 * l + 1] - points[2 * k + 1])
            if d > longest {
                longest = d
                best = k
            }
        }
        let l = (best + 1) % n
        let dx = points[2 * l] - points[2 * best], dy = points[2 * l + 1] - points[2 * best + 1]
        let mx = (points[2 * l] + points[2 * best]) / 2, my = (points[2 * l + 1] + points[2 * best + 1]) / 2
        let e = 0.25 * step / max(longest, 1e-12)
        // Right of the way, y down: (-dy, dx).
        let right = sample(mx - dy * e, my + dx * e, outside: 1)
        let left = sample(mx + dy * e, my - dx * e, outside: 1)
        if right <= left { return points }
        return (0..<n).reversed().flatMap { [points[2 * $0], points[2 * $0 + 1]] }
    }
}

/// The signed distance, in pixels, from each pixel's centre to the edge of
/// `mask` (1 inside): negative inside, positive out, exact (Euclidean).
func signedDistance(_ mask: [UInt8], _ w: Int, _ h: Int) -> [Double] {
    let inside = featureField(mask, w, h).distances
    let outside = featureField(mask.map { 1 - $0 }, w, h).distances
    return (0..<(w * h)).map { mask[$0] == 1 ? -(inside[$0].squareRoot() - 0.5) : outside[$0].squareRoot() - 0.5 }
}
