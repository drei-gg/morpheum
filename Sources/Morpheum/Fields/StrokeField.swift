// A stroke frame as one outline: the strokes (lines of discs) and the
// corners they carry, as one distance field, drawn where it crosses zero.

import Foundation

/// The outline of `lines` (each interleaved x, y, r in ems: a line of
/// discs, read as tapered capsules between neighbours) and `polygons`
/// (closed, ems), as closed polygons in ems: one outline for all of it, so
/// where pieces meet there is no seam.
///
/// Different strokes join with a soft union `join` ems wide: two that pass
/// within it fuse with a fillet, as ink would, instead of touching at a
/// hairline or leaving one. Within a stroke the union is exact.
///
/// The distance is measured to the capsules themselves, not read off
/// pixels, so the outline is smooth at any size; sampled at `pixelsPerEm`,
/// coarse first and finely only near the edge.
func strokeOutline(_ lines: [[Double]], _ polygons: [[Double]], join: Double, pixelsPerEm: Double) -> [[Double]] {
    // Each capsule: its stroke, ends and radii.
    struct Capsule { let stroke: Int; let x0, y0, r0, x1, y1, r1: Double }
    var capsules: [Capsule] = []
    var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
    // Every third disc, ends kept: tapered capsules between them follow a
    // stroke's curve to well under a pixel, at a third of the work.
    let every = 3
    for (s, l) in lines.enumerated() {
        let n = l.count / 3
        for k in Swift.stride(from: 0, to: n, by: every) {
            let j = min(k + every, n - 1)
            if l[3 * k + 2] <= 0 && l[3 * j + 2] <= 0 { continue }
            if k == j && n > 1 { continue }
            let c = Capsule(stroke: s, x0: l[3 * k], y0: l[3 * k + 1], r0: max(l[3 * k + 2], 0),
                            x1: l[3 * j], y1: l[3 * j + 1], r1: max(l[3 * j + 2], 0))
            capsules.append(c)
            let r = max(c.r0, c.r1)
            minX = min(minX, min(c.x0, c.x1) - r); maxX = max(maxX, max(c.x0, c.x1) + r)
            minY = min(minY, min(c.y0, c.y1) - r); maxY = max(maxY, max(c.y0, c.y1) + r)
        }
    }
    for p in polygons {
        for k in stride(from: 0, to: p.count - 1, by: 2) {
            minX = min(minX, p[k]); maxX = max(maxX, p[k]); minY = min(minY, p[k + 1]); maxY = max(maxY, p[k + 1])
        }
    }
    guard maxX > minX, maxY > minY else { return [] }
    let step = 1 / pixelsPerEm, ratio = 4, coarse = step * Double(ratio)
    let pad = join + 2 * coarse
    let x0 = minX - pad, y0 = minY - pad
    // Capsules binned on a grid, each in every cell within `reach` of it.
    let cell = max(0.04, 2 * coarse), reach = 2 * coarse + join
    let bw = Int(((maxX - minX + 2 * pad) / cell).rounded(.up)) + 1, bh = Int(((maxY - minY + 2 * pad) / cell).rounded(.up)) + 1
    var bins = [[Int32]](repeating: [], count: bw * bh)
    for (k, c) in capsules.enumerated() {
        let r = max(c.r0, c.r1) + reach
        let i0 = max(0, Int((min(c.x0, c.x1) - r - x0) / cell)), i1 = min(bw - 1, Int((max(c.x0, c.x1) + r - x0) / cell))
        let j0 = max(0, Int((min(c.y0, c.y1) - r - y0) / cell)), j1 = min(bh - 1, Int((max(c.y0, c.y1) + r - y0) / cell))
        if i0 > i1 || j0 > j1 { continue }
        for j in j0...j1 { for i in i0...i1 { bins[j * bw + i].append(Int32(k)) } }
    }
    let strokeCount = lines.count
    var perStroke = [Double](repeating: .infinity, count: max(strokeCount, 1))
    var touched: [Int] = []
    // The corners: their boxes, to skip them from afar.
    let boxes = polygons.map { p -> (Double, Double, Double, Double) in
        var a = (Double.infinity, Double.infinity, -Double.infinity, -Double.infinity)
        for k in stride(from: 0, to: p.count - 1, by: 2) { a = (min(a.0, p[k]), min(a.1, p[k + 1]), max(a.2, p[k]), max(a.3, p[k + 1])) }
        return a
    }
    /// The field at (x, y): the strokes' soft union, and the corners.
    func value(_ x: Double, _ y: Double) -> Double {
        let bi = min(max(Int((x - x0) / cell), 0), bw - 1), bj = min(max(Int((y - y0) / cell), 0), bh - 1)
        for k in bins[bj * bw + bi] {
            let c = capsules[Int(k)]
            let dx = c.x1 - c.x0, dy = c.y1 - c.y0
            let len2 = dx * dx + dy * dy
            let s = len2 == 0 ? 0 : min(max(((x - c.x0) * dx + (y - c.y0) * dy) / len2, 0), 1)
            let d = hypot(x - (c.x0 + dx * s), y - (c.y0 + dy * s)) - (c.r0 + (c.r1 - c.r0) * s)
            if perStroke[c.stroke] == .infinity { touched.append(c.stroke) }
            if d < perStroke[c.stroke] { perStroke[c.stroke] = d }
        }
        // Strokes join softly (a polynomial smooth minimum), each once.
        var field = reach
        for s in touched {
            let d = perStroke[s]
            perStroke[s] = .infinity
            if join > 0 {
                let h = max(join - abs(field - d), 0) / join
                field = min(field, d) - h * h * join / 4
            } else {
                field = min(field, d)
            }
        }
        touched.removeAll(keepingCapacity: true)
        // Corners: exactly, where near one.
        for (n, p) in polygons.enumerated() {
            let b = boxes[n]
            // Outside its box, a corner is at least that far away: no nearer
            // than the strokes already are, it can't change anything.
            let ox = max(b.0 - x, 0, x - b.2), oy = max(b.1 - y, 0, y - b.3)
            if hypot(ox, oy) >= field || field < -reach { continue }
            var best = Double.infinity, winding = 0
            let count = p.count / 2
            for k in 0..<count {
                let l = (k + 1) % count
                let ax = p[2 * k], ay = p[2 * k + 1], bx = p[2 * l], by = p[2 * l + 1]
                let ex = bx - ax, ey = by - ay, len2 = ex * ex + ey * ey
                let s = len2 == 0 ? 0 : min(max(((x - ax) * ex + (y - ay) * ey) / len2, 0), 1)
                best = min(best, hypot(x - (ax + ex * s), y - (ay + ey * s)))
                if (ay <= y) != (by <= y) {
                    let cross = ax + (y - ay) * ex / ey
                    if cross > x { winding += by > ay ? 1 : -1 }
                }
            }
            field = min(field, winding != 0 ? -best : best)
        }
        return field
    }
    // Coarse first; finely only where a coarse cell's corners come near zero.
    let cw = Int(((maxX - minX + 2 * pad) / coarse).rounded(.up)) + 2
    let ch = Int(((maxY - minY + 2 * pad) / coarse).rounded(.up)) + 2
    var rough = [Double](repeating: 0, count: cw * ch)
    for j in 0..<ch { for i in 0..<cw { rough[j * cw + i] = value(x0 + Double(i) * coarse, y0 + Double(j) * coarse) } }
    let w = (cw - 1) * ratio + 1, h = (ch - 1) * ratio + 1
    var values = [Double](repeating: 0, count: w * h)
    let near = 1.5 * coarse
    for cj in 0..<(ch - 1) {
        for ci in 0..<(cw - 1) {
            let v00 = rough[cj * cw + ci], v10 = rough[cj * cw + ci + 1]
            let v01 = rough[(cj + 1) * cw + ci], v11 = rough[(cj + 1) * cw + ci + 1]
            let exact = min(min(abs(v00), abs(v10)), min(abs(v01), abs(v11))) < near
            for dj in 0...ratio {
                for di in 0...ratio {
                    let k = (cj * ratio + dj) * w + ci * ratio + di
                    if exact {
                        values[k] = value(x0 + Double(ci * ratio + di) * step, y0 + Double(cj * ratio + dj) * step)
                    } else {
                        let p = Double(di) / Double(ratio), q = Double(dj) / Double(ratio)
                        values[k] = (v00 * (1 - p) + v10 * p) * (1 - q) + (v01 * (1 - p) + v11 * p) * q
                    }
                }
            }
        }
    }
    return Field(values: values, w: w, h: h, x0: x0, y0: y0, step: step).contours()
}
