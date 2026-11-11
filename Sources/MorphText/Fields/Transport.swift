// Morphs by optimal transport: ink as mass, carried the cheapest way from
// one shape to the other, so nothing is made or lost on the way and every
// bit of the start travels to somewhere in the end.

import Accelerate
import Foundation

/// One shape into another along the cheapest flow of ink between them.
///
/// Each end is sampled as equal grains of ink, and the transport plan
/// between the two (entropic, by Sinkhorn's iterations, in the log domain)
/// says where each grain of the start goes in the end, and where each grain
/// of the end came from. A frame carries both ends along that flow, the
/// start forward by `t` and the end back by `1 - t`, so the two lie over
/// each other, and blends their (warped) distance fields: one clean
/// outline, the start's letters sliding and merging into the end's shape.
/// At 0 and 1 the warp is nothing and the field is each end's own.
final class TransportMorph: @unchecked Sendable {
    // @unchecked: immutable after init.
    private let a: Field, b: Field
    private let centreA: (Double, Double), centreB: (Double, Double)
    /// Grains of each end, about its ink's centre, with where each goes (or
    /// came from) on the other side, about that one's centre.
    private let grainsA: [(x: Double, y: Double, dx: Double, dy: Double)]
    private let grainsB: [(x: Double, y: Double, dx: Double, dy: Double)]
    /// The grains' spacing, in ems.
    private let spacing: Double
    /// How finely its fields and frames are sampled.
    private let pixelsPerEm: Double
    private let reach: (Double, Double, Double, Double)

    /// The morph from `from` to `to` (closed polygons in ems, non-zero, in
    /// one frame); nil when either is empty.
    /// Sampled at `pixelsPerEm`: about a screen pixel each, so an outline
    /// as it lands is smooth (`pixelsPerEm(points:)`).
    init?(from: [[Double]], to: [[Double]], grainsPerEm: Double = 20, pixelsPerEm: Double = fieldPixelsPerEm) {
        guard let fa = distanceField(of: from, pad: 0.12, pixelsPerEm: pixelsPerEm),
              let fb = distanceField(of: to, pad: 0.12, pixelsPerEm: pixelsPerEm) else { return nil }
        self.pixelsPerEm = pixelsPerEm
        a = fa
        b = fb
        let s = 1 / grainsPerEm
        spacing = s
        // Grains: a lattice over each field, where it's inside.
        func grains(_ f: Field) -> [(Double, Double)] {
            var out: [(Double, Double)] = []
            let x1 = f.x0 + Double(f.w - 1) * f.step, y1 = f.y0 + Double(f.h - 1) * f.step
            var y = f.y0 + s / 2
            while y < y1 {
                var x = f.x0 + s / 2
                while x < x1 {
                    if f.sample(x, y, outside: 1) < 0 { out.append((x, y)) }
                    x += s
                }
                y += s
            }
            return out
        }
        let pa = grains(fa), pb = grains(fb)
        guard !pa.isEmpty, !pb.isEmpty else { return nil }
        func centre(_ p: [(Double, Double)]) -> (Double, Double) {
            (p.reduce(0) { $0 + $1.0 } / Double(p.count), p.reduce(0) { $0 + $1.1 } / Double(p.count))
        }
        let ca = centre(pa), cb = centre(pb)
        centreA = ca
        centreB = cb
        let qa = pa.map { ($0.0 - ca.0, $0.1 - ca.1) }
        let qb = pb.map { ($0.0 - cb.0, $0.1 - cb.1) }
        // Twenty grains to the em: the flow is as smooth as at twenty-eight,
        // and the plan a quarter of the work.
        let (forward, backward) = transport(qa, qb, epsilon: (1.2 * s) * (1.2 * s))
        grainsA = zip(qa, forward).map { (p, q) in (p.0, p.1, q.0 - p.0, q.1 - p.1) }
        grainsB = zip(qb, backward).map { (p, q) in (p.0, p.1, q.0 - p.0, q.1 - p.1) }
        // Everything a frame can reach, about the moving centre.
        var r = (Double.infinity, Double.infinity, -Double.infinity, -Double.infinity)
        for (f, c) in [(fa, ca), (fb, cb)] {
            r.0 = min(r.0, f.x0 - c.0); r.1 = min(r.1, f.y0 - c.1)
            r.2 = max(r.2, f.x0 + Double(f.w - 1) * f.step - c.0); r.3 = max(r.3, f.y0 + Double(f.h - 1) * f.step - c.1)
        }
        reach = r
    }

    /// The shape at `t` (0 is `from`, 1 is `to`), as closed polygons in ems.
    func polygons(at t: Double) -> [[Double]] {
        // Past either end (a spring's overshoot), each grain carries on along
        // its way and comes back, as the outline engine's points do: the end
        // snaps into place rather than stopping dead. Placement and the
        // hand-over keep to 0...1.
        let raw = min(max(t, -0.25), 1.25)
        let t = min(max(t, 0), 1)
        let c = (centreA.0 + (centreB.0 - centreA.0) * t, centreA.1 + (centreB.1 - centreA.1) * t)
        // The flow at `t`, on a coarse grid (a grain's spacing) about the
        // moving centre: each grain's displacement, spread where the grain
        // is now. Near grains, theirs; further out, a wider average.
        let coarse = spacing
        let gx0 = reach.0, gy0 = reach.1
        let gw = Int(((reach.2 - reach.0) / coarse).rounded(.up)) + 1, gh = Int(((reach.3 - reach.1) / coarse).rounded(.up)) + 1
        // The flow is only as smooth as the grains it's read from, and an end
        // warped by a bumpy flow has a wavy edge. Near either end the warp is
        // small, and smoothness matters more than precision: each end's flow
        // is blurred more the nearer that end is, so its outline settles
        // straight rather than crawling in.
        func near(_ x: Double) -> Double {
            let u = min(max(x / 0.5, 0), 1)
            return 2 + 5 * (1 - u * u * (3 - 2 * u))
        }
        let forward = flow(grainsA, along: t, gx0, gy0, gw, gh, coarse, sharpness: near(t))
        let backward = flow(grainsB, along: 1 - t, gx0, gy0, gw, gh, coarse, sharpness: near(1 - t))
        // The start's field leads until the two have nearly met, then hands
        // over: blended while they still lie apart, both would show.
        let u = min(max((t - 0.35) / 0.55, 0), 1)
        let blend = u * u * (3 - 2 * u)
        /// The frame's field at (x, y), about the moving centre: back along
        /// the flow to where the point was in each end, and blended. Raw
        /// buffers: this runs for every sample near the edge, every frame.
        let fdx = forward.dx, fdy = forward.dy, bdx = backward.dx, bdy = backward.dy
        let fieldA = a, fieldB = b
        let ca = centreA, cb = centreB
        func value(_ x: Double, _ y: Double) -> Double {
            let fx = min(max((x - gx0) / coarse, 0), Double(gw - 1)), fy = min(max((y - gy0) / coarse, 0), Double(gh - 1))
            let i = min(Int(fx), gw - 2), j = min(Int(fy), gh - 2)
            let p = fx - Double(i), q = fy - Double(j)
            let k = j * gw + i
            let w00 = (1 - p) * (1 - q), w10 = p * (1 - q), w01 = (1 - p) * q, w11 = p * q
            var total = 0.0
            if blend < 1 {
                let (ux, uy) = fdx.withUnsafeBufferPointer { dx in fdy.withUnsafeBufferPointer { dy in
                    (dx[k] * w00 + dx[k + 1] * w10 + dx[k + gw] * w01 + dx[k + gw + 1] * w11,
                     dy[k] * w00 + dy[k + 1] * w10 + dy[k + gw] * w01 + dy[k + gw + 1] * w11)
                } }
                total += (1 - blend) * fieldA.distance(x - raw * ux + ca.0, y - raw * uy + ca.1)
            }
            if blend > 0 {
                let (vx, vy) = bdx.withUnsafeBufferPointer { dx in bdy.withUnsafeBufferPointer { dy in
                    (dx[k] * w00 + dx[k + 1] * w10 + dx[k + gw] * w01 + dx[k + gw + 1] * w11,
                     dy[k] * w00 + dy[k + 1] * w10 + dy[k + gw] * w01 + dy[k + gw + 1] * w11)
                } }
                total += blend * fieldB.distance(x - (1 - raw) * vx + cb.0, y - (1 - raw) * vy + cb.1)
            }
            return total
        }
        // Coarse first, four fine steps a sample; fine only near the edge,
        // where a coarse cell's corners come within its size of zero. (The
        // field is about a distance, so further out the sign can't change.)
        let step = 1 / pixelsPerEm, ratio = 4
        let x0 = reach.0, y0 = reach.1
        let cw = Int(((reach.2 - reach.0) / (step * Double(ratio))).rounded(.up)) + 2
        let ch = Int(((reach.3 - reach.1) / (step * Double(ratio))).rounded(.up)) + 2
        var rough = [Double](repeating: 0, count: cw * ch)
        for j in 0..<ch {
            for i in 0..<cw { rough[j * cw + i] = value(x0 + Double(i * ratio) * step, y0 + Double(j * ratio) * step) }
        }
        let w = (cw - 1) * ratio + 1, h = (ch - 1) * ratio + 1
        var values = [Double](repeating: 0, count: w * h)
        let near = 1.5 * step * Double(ratio)
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
        // Back from about the centre to the frame the ends were given in.
        return Field(values: values, w: w, h: h, x0: x0 + c.0, y0: y0 + c.1, step: step).contours()
    }
}

/// The grains' displacements at `along` of the way, spread on a `gw` by
/// `gh` grid from (`gx0`, `gy0`), `cell` apart: each grain splatted where it
/// is now, then blurred twice (separably) and the two mixed, near grains
/// counting most.
private func flow(_ grains: [(x: Double, y: Double, dx: Double, dy: Double)], along: Double,
                  _ gx0: Double, _ gy0: Double, _ gw: Int, _ gh: Int, _ cell: Double,
                  sharpness sigma: Double = 2) -> (dx: [Double], dy: [Double]) {
    var w = [Double](repeating: 0, count: gw * gh), x = w, y = w
    for g in grains {
        let px = min(max((g.x + g.dx * along - gx0) / cell, 0), Double(gw - 1) - 1e-9)
        let py = min(max((g.y + g.dy * along - gy0) / cell, 0), Double(gh - 1) - 1e-9)
        let i = Int(px), j = Int(py), p = px - Double(i), q = py - Double(j)
        for (k, weight) in [(j * gw + i, (1 - p) * (1 - q)), (j * gw + i + 1, p * (1 - q)),
                            (j * gw + i + gw, (1 - p) * q), (j * gw + i + gw + 1, p * q)] {
            w[k] += weight; x[k] += weight * g.dx; y[k] += weight * g.dy
        }
    }
    func blurred(_ v: [Double], _ sigma: Double) -> [Double] {
        let r = Int((3 * sigma).rounded(.up))
        let kernel = (-r...r).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        var tmp = [Double](repeating: 0, count: gw * gh), out = tmp
        for j in 0..<gh {
            for i in 0..<gw {
                var sum = 0.0
                for d in max(-r, -i)...min(r, gw - 1 - i) { sum += kernel[d + r] * v[j * gw + i + d] }
                tmp[j * gw + i] = sum
            }
        }
        for j in 0..<gh {
            for i in 0..<gw {
                var sum = 0.0
                for d in max(-r, -j)...min(r, gh - 1 - j) { sum += kernel[d + r] * tmp[(j + d) * gw + i] }
                out[j * gw + i] = sum
            }
        }
        return out
    }
    let w1 = blurred(w, sigma), x1 = blurred(x, sigma), y1 = blurred(y, sigma)
    let wide = max(5, 2 * sigma)
    let w2 = blurred(w, wide), x2 = blurred(x, wide), y2 = blurred(y, wide)
    var dx = w, dy = w
    for k in 0..<(gw * gh) {
        let total = w1[k] + 0.05 * w2[k]
        dx[k] = total > 1e-12 ? (x1[k] + 0.05 * x2[k]) / total : 0
        dy[k] = total > 1e-12 ? (y1[k] + 0.05 * y2[k]) / total : 0
    }
    return (dx, dy)
}

/// Field samples to the em for an em `points` across: two a point (on a
/// 3x screen, an outline's chords are a pixel and a half, and its curves
/// land smooth), and never fewer than 160.
func pixelsPerEm(points: Double) -> Double { max(fieldPixelsPerEm, 2 * points) }

/// The entropic transport plan between equal grains `a` and `b` (each with
/// mass 1/count), with blur `epsilon` (squared ems), by Sinkhorn's
/// iterations in the log domain, annealed from a wide blur down to it, each
/// stage until its potentials settle. For each grain of `a`, the mean of
/// where its mass goes in `b`; for each of `b`, the mean of where its mass
/// came from.
///
/// Vectorised with Accelerate, in single precision: the potentials settle
/// to well within a grain's spacing.
func transport(_ a: [(Double, Double)], _ b: [(Double, Double)], epsilon: Double)
    -> (forward: [(Double, Double)], backward: [(Double, Double)]) {
    let n = a.count, m = b.count
    // The costs both ways round, so rows and columns are each contiguous.
    var cost = [Float](repeating: 0, count: n * m), costT = cost
    for i in 0..<n {
        for j in 0..<m {
            let dx = Float(a[i].0 - b[j].0), dy = Float(a[i].1 - b[j].1)
            let c = dx * dx + dy * dy
            cost[i * m + j] = c
            costT[j * n + i] = c
        }
    }
    let logA = Float(log(1 / Double(n))), logB = Float(log(1 / Double(m)))
    var f = [Float](repeating: 0, count: n), g = [Float](repeating: 0, count: m)
    var scratch = [Float](repeating: 0, count: max(n, m))
    var largest: Float = 0
    vDSP_maxv(cost, 1, &largest, vDSP_Length(n * m))
    let target = Float(epsilon)
    var eps = max(target, largest / 4)
    /// One half step: for each row r of `costs` (length `len`), out[r] =
    /// eps (logMass - logsumexp_k (other[k] - costs[r, k]) / eps).
    func halfStep(_ costs: [Float], _ other: [Float], _ out: inout [Float], rows: Int, len: Int, logMass: Float) -> Float {
        var change: Float = 0
        let inverse = 1 / eps
        costs.withUnsafeBufferPointer { c in
            other.withUnsafeBufferPointer { o in
                scratch.withUnsafeMutableBufferPointer { s in
                    let s = s.baseAddress!
                    var count = Int32(len)
                    for r in 0..<rows {
                        // (other - cost_r) / eps
                        vDSP_vsub(c.baseAddress! + r * len, 1, o.baseAddress!, 1, s, 1, vDSP_Length(len))
                        var scale = inverse
                        vDSP_vsmul(s, 1, &scale, s, 1, vDSP_Length(len))
                        var top: Float = 0
                        vDSP_maxv(s, 1, &top, vDSP_Length(len))
                        var shift = -top
                        vDSP_vsadd(s, 1, &shift, s, 1, vDSP_Length(len))
                        vvexpf(s, s, &count)
                        var sum: Float = 0
                        vDSP_sve(s, 1, &sum, vDSP_Length(len))
                        let value = eps * (logMass - (top + log(sum)))
                        change = max(change, abs(value - out[r]))
                        out[r] = value
                    }
                }
            }
        }
        return change
    }
    while true {
        // Each stage until its potentials move by under a hundredth of the
        // blur (the last, a thousandth), or long enough.
        let last = eps <= target
        let tolerance = eps * (last ? 1e-3 : 1e-2)
        for _ in 0..<(last ? 200 : 60) {
            let df = halfStep(cost, g, &f, rows: n, len: m, logMass: logA)
            let dg = halfStep(costT, f, &g, rows: m, len: n, logMass: logB)
            if max(df, dg) < tolerance { break }
        }
        if last { break }
        eps = max(target, eps / 4)
    }
    // The plan P_ij = exp((f_i + g_j - C_ij) / eps), read row by row and
    // column by column.
    var forward = [(Double, Double)](repeating: (0, 0), count: n)
    var backward = [(Double, Double)](repeating: (0, 0), count: m)
    var colX = [Double](repeating: 0, count: m), colY = colX, colW = colX
    var row = [Float](repeating: 0, count: m)
    var count = Int32(m)
    for i in 0..<n {
        for j in 0..<m { row[j] = (f[i] + g[j] - cost[i * m + j]) / eps }
        vvexpf(&row, row, &count)
        var sx = 0.0, sy = 0.0, sw = 0.0
        for j in 0..<m {
            let p = Double(row[j])
            sx += p * b[j].0; sy += p * b[j].1; sw += p
            colX[j] += p * a[i].0; colY[j] += p * a[i].1; colW[j] += p
        }
        forward[i] = sw > 0 ? (sx / sw, sy / sw) : a[i]
    }
    for j in 0..<m { backward[j] = colW[j] > 0 ? (colX[j] / colW[j], colY[j] / colW[j]) : b[j] }
    return (forward, backward)
}
