// Morphs as fields. A shape is a signed distance field, and each frame is
// drawn where a field crosses zero: one closed, clean outline whatever
// happens in between, never a stroke torn off or a hairline left behind.

import Foundation

/// Pixels per em the field morphs and the cleanup pass work at.
let fieldPixelsPerEm = 160.0

/// Smooths a grid of values with a 1-2-1 kernel both ways, `passes` times:
/// takes the pixel staircase out of a distance field read off a mask.
func soften(_ v: inout [Double], _ w: Int, _ h: Int, passes: Int = 1) {
    var tmp = v
    for _ in 0..<passes {
        for j in 0..<h {
            for i in 0..<w {
                let l = v[j * w + max(i - 1, 0)], r = v[j * w + min(i + 1, w - 1)]
                tmp[j * w + i] = (l + 2 * v[j * w + i] + r) / 4
            }
        }
        for j in 0..<h {
            for i in 0..<w {
                let u = tmp[max(j - 1, 0) * w + i], d = tmp[min(j + 1, h - 1) * w + i]
                v[j * w + i] = (u + 2 * tmp[j * w + i] + d) / 4
            }
        }
    }
}

/// Ink as a mask on a grid: lines of discs (interleaved x, y, r) and
/// polygons, in ems, over the box they cover plus `pad` ems, at
/// `pixelsPerEm`.
func inkMask(_ lines: [[Double]], _ polygons: [[Double]], pad: Double, pixelsPerEm: Double)
    -> (mask: [UInt8], w: Int, h: Int, ox: Double, oy: Double, px: Double)? {
    var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
    for l in lines {
        for k in stride(from: 0, to: l.count - 2, by: 3) where l[k + 2] > 0 {
            minX = min(minX, l[k] - l[k + 2]); maxX = max(maxX, l[k] + l[k + 2])
            minY = min(minY, l[k + 1] - l[k + 2]); maxY = max(maxY, l[k + 1] + l[k + 2])
        }
    }
    for p in polygons {
        for k in stride(from: 0, to: p.count - 1, by: 2) {
            minX = min(minX, p[k]); maxX = max(maxX, p[k]); minY = min(minY, p[k + 1]); maxY = max(maxY, p[k + 1])
        }
    }
    guard maxX > minX, maxY > minY else { return nil }
    let px = 1 / pixelsPerEm
    let ox = minX - pad, oy = minY - pad
    let w = Int(((maxX - minX + 2 * pad) / px).rounded(.up)) + 1
    let h = Int(((maxY - minY + 2 * pad) / px).rounded(.up)) + 1
    var mask = polygons.isEmpty ? [UInt8](repeating: 0, count: w * h) : fillPolygons(polygons, w, h, ox, oy, px)
    for l in lines {
        let n = l.count / 3
        for k in 0..<n {
            let j = min(k + 1, n - 1)
            let x0 = l[3 * k], y0 = l[3 * k + 1], r0 = l[3 * k + 2]
            let x1 = l[3 * j], y1 = l[3 * j + 1], r1 = l[3 * j + 2]
            let r = max(r0, r1)
            if r <= 0 { continue }
            let i0 = max(0, Int(((min(x0, x1) - r - ox) / px).rounded(.down)))
            let i1 = min(w - 1, Int(((max(x0, x1) + r - ox) / px).rounded(.up)))
            let j0 = max(0, Int(((min(y0, y1) - r - oy) / px).rounded(.down)))
            let j1 = min(h - 1, Int(((max(y0, y1) + r - oy) / px).rounded(.up)))
            if i0 > i1 || j0 > j1 { continue }
            let dx = x1 - x0, dy = y1 - y0, len2 = dx * dx + dy * dy
            for jj in j0...j1 {
                let py = oy + (Double(jj) + 0.5) * px
                for ii in i0...i1 where mask[jj * w + ii] == 0 {
                    let pxx = ox + (Double(ii) + 0.5) * px
                    let s = len2 == 0 ? 0 : min(max(((pxx - x0) * dx + (py - y0) * dy) / len2, 0), 1)
                    let ex = x0 + dx * s - pxx, ey = y0 + dy * s - py, rs = r0 + (r1 - r0) * s
                    if ex * ex + ey * ey <= rs * rs { mask[jj * w + ii] = 1 }
                }
            }
        }
    }
    return (mask, w, h, ox, oy, px)
}

/// A stroke frame's ink, cleaned: pieces that nearly meet are joined, and
/// anything thinner than a hair is gone. A morphological closing (grow by
/// `close` ems, shrink back) seals the gaps where two strokes pull apart at
/// a join; an opening (shrink by `open` ems, grow back) takes out the
/// whiskers a stroke trails as it draws back. As closed polygons in ems.
func cleanedInk(_ lines: [[Double]], _ polygons: [[Double]], close: Double, open: Double) -> [[Double]] {
    let pad = close + open + 3 / fieldPixelsPerEm
    guard let grid = inkMask(lines, polygons, pad: pad, pixelsPerEm: fieldPixelsPerEm) else { return [] }
    let (w, h) = (grid.w, grid.h)
    let r = close * fieldPixelsPerEm, q = open * fieldPixelsPerEm
    var field = signedDistance(grid.mask, w, h)
    if r > 0.05 {
        let grown = signedDistance(field.map { $0 <= r ? 1 : 0 }, w, h)
        field = grown.map { $0 + r }
    }
    if q > 0.05 {
        let shrunk = signedDistance(field.map { $0 <= -q ? 1 : 0 }, w, h)
        field = shrunk.map { $0 - q }
    }
    soften(&field, w, h)
    let f = Field(values: field, w: w, h: h, x0: grid.ox + 0.5 * grid.px, y0: grid.oy + 0.5 * grid.px, step: grid.px)
    return f.contours()
}

/// The signed distance field of `polygons` (closed, ems, non-zero), in ems,
/// over their box plus `pad` ems.
func distanceField(of polygons: [[Double]], pad: Double) -> Field? {
    guard let grid = inkMask([], polygons, pad: pad, pixelsPerEm: fieldPixelsPerEm) else { return nil }
    var field = signedDistance(grid.mask, grid.w, grid.h).map { $0 * grid.px }
    soften(&field, grid.w, grid.h)
    return Field(values: field, w: grid.w, h: grid.h, x0: grid.ox + 0.5 * grid.px, y0: grid.oy + 0.5 * grid.px, step: grid.px)
}

/// One shape into another as fields: no parts matched, nothing left over.
///
/// Each end is carried toward the other's place and size as one (a word
/// gathers into its symbol's area, the symbol starts at the word's), and
/// what the two share stays put. What only the start has drains into the
/// end: it goes in order of its distance from the end's shape, the farthest
/// first, so a stroke retracts toward the end at its full width rather than
/// thinning to a hair. What only the end has fills in from the start: it
/// comes in order of its distance from the start's shape, the nearest
/// first. Every frame is where one field crosses zero, so it's one clean
/// outline, and at 0 and 1 it is each end.
final class FieldMorph: @unchecked Sendable {
    // @unchecked: immutable after init.
    private let a: Field, b: Field
    private let centreA: (Double, Double), centreB: (Double, Double)
    /// The start's scale at the end, so it covers the end's area.
    private let scale: Double
    private let boxA: (Double, Double, Double, Double), boxB: (Double, Double, Double, Double)

    /// The morph from `from` to `to` (closed polygons in ems, non-zero, in
    /// one frame); nil when either is empty.
    init?(from: [[Double]], to: [[Double]]) {
        func box(_ polygons: [[Double]]) -> (Double, Double, Double, Double)? {
            var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
            for p in polygons {
                for k in stride(from: 0, to: p.count - 1, by: 2) {
                    minX = min(minX, p[k]); maxX = max(maxX, p[k]); minY = min(minY, p[k + 1]); maxY = max(maxY, p[k + 1])
                }
            }
            return maxX > minX && maxY > minY ? (minX, minY, maxX, maxY) : nil
        }
        guard let ba = box(from), let bb = box(to),
              let fa = distanceField(of: from, pad: 0.1), let fb = distanceField(of: to, pad: 0.1) else { return nil }
        a = fa
        b = fb
        boxA = ba
        boxB = bb
        centreA = ((ba.0 + ba.2) / 2, (ba.1 + ba.3) / 2)
        centreB = ((bb.0 + bb.2) / 2, (bb.1 + bb.3) / 2)
        // To the end's area: a wide word narrows to about the symbol's size,
        // and the two overlap most of the way.
        let sx = (bb.2 - bb.0) / (ba.2 - ba.0), sy = (bb.3 - bb.1) / (ba.3 - ba.1)
        scale = (sx * sy).squareRoot()
    }

    /// The shape at `t` (0 is `from`, 1 is `to`), as closed polygons in ems.
    func polygons(at t: Double) -> [[Double]] {
        let t = min(max(t, 0), 1)
        let c = (centreA.0 + (centreB.0 - centreA.0) * t, centreA.1 + (centreB.1 - centreA.1) * t)
        let sa = 1 + (scale - 1) * t, sb = sa / scale
        func placed(_ box: (Double, Double, Double, Double), _ centre: (Double, Double), _ s: Double) -> (Double, Double, Double, Double) {
            (c.0 + (box.0 - centre.0) * s, c.1 + (box.1 - centre.1) * s, c.0 + (box.2 - centre.0) * s, c.1 + (box.3 - centre.1) * s)
        }
        let pa = placed(boxA, centreA, sa), pb = placed(boxB, centreB, sb)
        let pad = 3 / fieldPixelsPerEm
        let x0 = min(pa.0, pb.0) - pad, y0 = min(pa.1, pb.1) - pad
        let x1 = max(pa.2, pb.2) + pad, y1 = max(pa.3, pb.3) + pad
        let step = 1 / fieldPixelsPerEm
        let w = Int(((x1 - x0) / step).rounded(.up)) + 1, h = Int(((y1 - y0) / step).rounded(.up)) + 1
        // Each end's signed distance at every sample, in ems where it is now.
        var fa = [Double](repeating: 0, count: w * h), fb = fa
        var reachA = 0.0, reachB = 0.0
        for j in 0..<h {
            let y = y0 + Double(j) * step
            for i in 0..<w {
                let x = x0 + Double(i) * step
                let da = sa * a.distance(centreA.0 + (x - c.0) / sa, centreA.1 + (y - c.1) / sa)
                let db = sb * b.distance(centreB.0 + (x - c.0) / sb, centreB.1 + (y - c.1) / sb)
                fa[j * w + i] = da
                fb[j * w + i] = db
                // How far the start's ink reaches from the end's, and the
                // end's from the start's.
                if da < 0 { reachA = max(reachA, db) }
                if db < 0 { reachB = max(reachB, da) }
            }
        }
        reachA += step
        reachB += step
        var values = [Double](repeating: 0, count: w * h)
        for k in 0..<(w * h) {
            let da = fa[k], db = fb[k]
            // Both: always. Only the start's: while nearer the end than the
            // receding front. Only the end's: once nearer the start than the
            // advancing one.
            let shared = max(da, db)
            let draining = max(da, max(db, 0) - (1 - t) * reachA)
            let filling = max(db, max(da, 0) - t * reachB)
            values[k] = min(shared, min(draining, filling))
        }
        return Field(values: values, w: w, h: h, x0: x0, y0: y0, step: step).contours()
    }
}
