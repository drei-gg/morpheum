// Morphs by optimal transport: ink as mass, carried the cheapest way from
// one shape to the other, so nothing is made or lost on the way and every
// bit of the start travels to somewhere in the end.

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
    private let reach: (Double, Double, Double, Double)

    /// The morph from `from` to `to` (closed polygons in ems, non-zero, in
    /// one frame); nil when either is empty.
    init?(from: [[Double]], to: [[Double]], grainsPerEm: Double = 28) {
        guard let fa = distanceField(of: from, pad: 0.12), let fb = distanceField(of: to, pad: 0.12) else { return nil }
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
        let t = min(max(t, 0), 1)
        let c = (centreA.0 + (centreB.0 - centreA.0) * t, centreA.1 + (centreB.1 - centreA.1) * t)
        // The flow at `t`, on a coarse grid about the moving centre: each
        // grain's displacement, spread where the grain is now.
        let coarse = spacing
        let gx0 = reach.0, gy0 = reach.1
        let gw = Int(((reach.2 - reach.0) / coarse).rounded(.up)) + 1, gh = Int(((reach.3 - reach.1) / coarse).rounded(.up)) + 1
        func flow(_ grains: [(x: Double, y: Double, dx: Double, dy: Double)], _ along: Double) -> (dx: [Double], dy: [Double]) {
            var w1 = [Double](repeating: 0, count: gw * gh), w2 = w1
            var x1 = w1, y1 = w1, x2 = w1, y2 = w1
            let sigma1 = 2.0, sigma2 = 5.0
            for g in grains {
                let px = (g.x + g.dx * along - gx0) / coarse, py = (g.y + g.dy * along - gy0) / coarse
                let r = Int((3 * sigma2).rounded(.up))
                let ci = Int(px.rounded()), cj = Int(py.rounded())
                for j in max(0, cj - r)...min(gh - 1, cj + r) {
                    for i in max(0, ci - r)...min(gw - 1, ci + r) {
                        let d2 = (Double(i) - px) * (Double(i) - px) + (Double(j) - py) * (Double(j) - py)
                        let k2 = exp(-d2 / (2 * sigma2 * sigma2))
                        let k = j * gw + i
                        w2[k] += k2; x2[k] += k2 * g.dx; y2[k] += k2 * g.dy
                        if d2 < 9 * sigma1 * sigma1 {
                            let k1 = exp(-d2 / (2 * sigma1 * sigma1))
                            w1[k] += k1; x1[k] += k1 * g.dx; y1[k] += k1 * g.dy
                        }
                    }
                }
            }
            // Near grains, theirs; further out, a wider average of them.
            var dx = w1, dy = w1
            for k in 0..<(gw * gh) {
                let wa = w1[k], wb = 0.05 * w2[k]
                let total = wa + wb
                dx[k] = total > 1e-12 ? (x1[k] + 0.05 * x2[k]) / total : 0
                dy[k] = total > 1e-12 ? (y1[k] + 0.05 * y2[k]) / total : 0
            }
            return (dx, dy)
        }
        let forward = flow(grainsA, t), backward = flow(grainsB, 1 - t)
        func at(_ field: [Double], _ x: Double, _ y: Double) -> Double {
            let f = Field(values: field, w: gw, h: gh, x0: gx0, y0: gy0, step: coarse)
            return f.sample(min(max(x, gx0), gx0 + Double(gw - 1) * coarse), min(max(y, gy0), gy0 + Double(gh - 1) * coarse), outside: 0)
        }
        // The frame, finely, about the moving centre.
        let step = 1 / fieldPixelsPerEm
        let x0 = reach.0, y0 = reach.1
        let w = Int(((reach.2 - reach.0) / step).rounded(.up)) + 1, h = Int(((reach.3 - reach.1) / step).rounded(.up)) + 1
        var values = [Double](repeating: 0, count: w * h)
        // The start's field leads until the two have nearly met, then hands
        // over: blended while they still lie apart, both would show.
        let u = min(max((t - 0.35) / 0.55, 0), 1)
        let blend = u * u * (3 - 2 * u)
        for j in 0..<h {
            let y = y0 + Double(j) * step
            for i in 0..<w {
                let x = x0 + Double(i) * step
                // Back along the flow to where this point was in each end.
                let ax = x - t * at(forward.dx, x, y), ay = y - t * at(forward.dy, x, y)
                let bx = x - (1 - t) * at(backward.dx, x, y), by = y - (1 - t) * at(backward.dy, x, y)
                let da = a.distance(ax + centreA.0, ay + centreA.1)
                let db = b.distance(bx + centreB.0, by + centreB.1)
                values[j * w + i] = (1 - blend) * da + blend * db
            }
        }
        // Back from about the centre to the frame the ends were given in.
        return Field(values: values, w: w, h: h, x0: x0 + c.0, y0: y0 + c.1, step: step).contours()
    }
}

/// The entropic transport plan between equal grains `a` and `b` (each with
/// mass 1/count), with blur `epsilon` (squared ems), by Sinkhorn's
/// iterations in the log domain, annealed from a wide blur down to it. For
/// each grain of `a`, the mean of where its mass goes in `b`; for each of
/// `b`, the mean of where its mass came from.
func transport(_ a: [(Double, Double)], _ b: [(Double, Double)], epsilon: Double)
    -> (forward: [(Double, Double)], backward: [(Double, Double)]) {
    let n = a.count, m = b.count
    var cost = [Double](repeating: 0, count: n * m)
    for i in 0..<n {
        for j in 0..<m {
            let dx = a[i].0 - b[j].0, dy = a[i].1 - b[j].1
            cost[i * m + j] = dx * dx + dy * dy
        }
    }
    let logA = log(1 / Double(n)), logB = log(1 / Double(m))
    var f = [Double](repeating: 0, count: n), g = [Double](repeating: 0, count: m)
    var eps = max(epsilon, cost.max()! / 4)
    var row = [Double](repeating: 0, count: max(n, m))
    while true {
        for _ in 0..<40 {
            // f_i = eps (log a_i - logsumexp_j (g_j - C_ij) / eps)
            for i in 0..<n {
                var top = -Double.infinity
                for j in 0..<m { row[j] = (g[j] - cost[i * m + j]) / eps; top = max(top, row[j]) }
                var sum = 0.0
                for j in 0..<m { sum += exp(row[j] - top) }
                f[i] = eps * (logA - (top + log(sum)))
            }
            for j in 0..<m {
                var top = -Double.infinity
                for i in 0..<n { row[i] = (f[i] - cost[i * m + j]) / eps; top = max(top, row[i]) }
                var sum = 0.0
                for i in 0..<n { sum += exp(row[i] - top) }
                g[j] = eps * (logB - (top + log(sum)))
            }
        }
        if eps <= epsilon { break }
        eps = max(epsilon, eps / 3)
    }
    // The plan P_ij = exp((f_i + g_j - C_ij) / eps), read row by row and
    // column by column.
    var forward = [(Double, Double)](repeating: (0, 0), count: n)
    var backward = [(Double, Double)](repeating: (0, 0), count: m)
    var colX = [Double](repeating: 0, count: m), colY = colX, colW = colX
    for i in 0..<n {
        var sx = 0.0, sy = 0.0, sw = 0.0
        for j in 0..<m {
            let p = exp((f[i] + g[j] - cost[i * m + j]) / eps)
            sx += p * b[j].0; sy += p * b[j].1; sw += p
            colX[j] += p * a[i].0; colY[j] += p * a[i].1; colW[j] += p
        }
        forward[i] = sw > 0 ? (sx / sw, sy / sw) : a[i]
    }
    for j in 0..<m { backward[j] = colW[j] > 0 ? (colX[j] / colW[j], colY[j] / colW[j]) : b[j] }
    return (forward, backward)
}
