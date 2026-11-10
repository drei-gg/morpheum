// Ported from morphtext for Flutter (lib/src/strokes.dart, strokes branch).
//
// Letters as strokes: each glyph traced to its centrelines, a radius at every
// point (its medial axis), and two glyphs morphed stroke by stroke along
// their length.
//
// An outline morph pairs points around two outlines, so the two sides of a
// stem can wander apart in flight and a letter swells far past either end's
// weight. A stroke here is a line of discs: its radius at each point is
// between the radii of the strokes it comes from and goes to, so nothing in
// flight is ever thicker than the thicker end. The strokes bend between
// their two shapes (they curl and uncurl rather than cut across), and a
// stroke with no partner draws itself out of, or back into, the stroke it
// joins.
//
// It takes a glyph as closed polygons in ems (x from the pen, y down).

import Foundation

/// One stroke of a glyph: a centreline with a radius at each point, in ems.
/// A closed stroke (an o, the bowl of a b) joins its last point to its first.
struct Stroke {
    /// The centreline, in ems.
    let x: [Double], y: [Double]
    /// The radius at each point, in ems.
    let r: [Double]
    /// Whether the last point joins the first.
    let closed: Bool
    /// The distance along the centreline to each point (and, closed, back
    /// round to the first).
    private let along: [Double]

    /// A stroke through (`x`, `y`) with radius `r` at each point.
    init(_ x: [Double], _ y: [Double], _ r: [Double], closed: Bool = false) {
        self.x = x
        self.y = y
        self.r = r
        self.closed = closed
        let n = x.count
        let segments = closed ? n : n - 1
        var along = [Double](repeating: 0, count: segments + 1)
        for i in 0..<segments {
            let j = (i + 1) % n
            along[i + 1] = along[i] + hypot(x[j] - x[i], y[j] - y[i])
        }
        self.along = along
    }

    /// The centreline's length, in ems.
    var length: Double { along.last! }

    /// Its mean radius.
    var meanRadius: Double { r.reduce(0, +) / Double(r.count) }

    /// `n` points evenly along it, as interleaved x, y, r: from one end, or
    /// `cut` of the way round a closed stroke (which comes back round to
    /// where it started), backwards with `reversed`.
    func sample(_ n: Int, cut: Double = 0, reversed: Bool = false) -> [Double] {
        var out = [Double](repeating: 0, count: 3 * n)
        let length = self.length
        for k in 0..<n {
            let f = n == 1 ? 0.5 : Double(k) / Double(n - 1)
            let s: Double
            if closed {
                s = length == 0 ? 0 : positiveRemainder((cut + (reversed ? -f : f)) * length, length)
            } else {
                s = (reversed ? 1 - f : f) * length
            }
            at(s, &out, 3 * k)
        }
        return out
    }

    /// The point `s` along the centreline, into `out` at `o`.
    private func at(_ s: Double, _ out: inout [Double], _ o: Int) {
        let n = x.count
        if n == 1 || length == 0 {
            out[o] = x[0]
            out[o + 1] = y[0]
            out[o + 2] = r[0]
            return
        }
        var lo = 0, hi = along.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) >> 1
            if along[mid] <= s { lo = mid } else { hi = mid }
        }
        let span = along[lo + 1] - along[lo]
        let f = span <= 0 ? 0 : min(max((s - along[lo]) / span, 0), 1)
        let i = lo, j = (lo + 1) % n
        out[o] = x[i] + (x[j] - x[i]) * f
        out[o + 1] = y[i] + (y[j] - y[i]) * f
        out[o + 2] = r[i] + (r[j] - r[i]) * f
    }
}

/// A glyph as strokes: its outline traced to its medial axis, read two
/// ways.
struct StrokeGlyph {
    /// The strokes as a pen might draw them, in ems (x from the pen, y down):
    /// lines joined through each branch point where they run on (a T's bar
    /// through its stem, an M in one zigzag), serifs apart.
    let strokes: [Stroke]
    /// The same lines split at every branch point: steadier from weight to
    /// weight than `strokes`, whose joins are judgement calls.
    let pieces: [Stroke]
    /// The strokes with every loop round a hole kept whole (a gear's ring,
    /// not its teeth run into its rim): the best reading for turning one
    /// ring into another.
    let loops: [Stroke]
    /// Where y is measured from when comparing glyphs: the baseline, in the
    /// glyph's frame (Flutter's is the ascender, from the top).
    let ascender: Double
    /// The middle of the ink, across, in ems from the pen.
    let centre: Double

    /// Traces `polygons` (closed, interleaved x, y, in ems, filled non-zero)
    /// at `pixelsPerEm`; nil when there's nothing to fill.
    ///
    /// A branch that stands out from the stroke it leaves by less than
    /// `spur` of that stroke's radius, capped at `limit` ems (so a solid
    /// icon, its strokes a third of an em across, keeps its lobes), is
    /// dropped. Chosen by measurement in the Flutter package: the strokes
    /// rebuild a letter to within about one percent of its ink.
    static func trace(_ polygons: [[Double]], ascender: Double, pixelsPerEm: Double = 192,
                      spur: Double = 0.3, limit: Double = 0.02) -> StrokeGlyph? {
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        for p in polygons {
            for k in stride(from: 0, to: p.count - 1, by: 2) {
                minX = min(minX, p[k])
                maxX = max(maxX, p[k])
                minY = min(minY, p[k + 1])
                maxY = max(maxY, p[k + 1])
            }
        }
        guard maxX > minX, maxY > minY else { return nil }
        let h = 1 / pixelsPerEm
        let pad = 3
        let w = Int(((maxX - minX) / h).rounded(.up)) + 2 * pad
        let ht = Int(((maxY - minY) / h).rounded(.up)) + 2 * pad
        let ox = minX - Double(pad) * h, oy = minY - Double(pad) * h
        let mask = fillPolygons(polygons, w, ht, ox, oy, h)
        let (d2, nearest) = featureField(mask, w, ht)
        var skeleton = mask
        thinToSkeleton(&skeleton, d2, nearest, w, ht)
        let graph = SkeletonGraph.build(skeleton, d2, w, ht)
        graph.prune(spur, limit: limit * pixelsPerEm)
        graph.contract()
        let outline = OutlineEdges(polygons, cell: 8 * h)
        var refined: [Int: (Double, Double, Double)] = [:]
        func read(join: Bool, loops: Bool = false) -> [Stroke] {
            graph.chains(join: join, loops: loops).map { stroke($0, ox, oy, h, outline, &refined) }
        }
        let strokes = read(join: true)
        if strokes.isEmpty { return nil }
        return StrokeGlyph(strokes: strokes, pieces: read(join: false), loops: read(join: true, loops: true),
                           ascender: ascender, centre: (minX + maxX) / 2)
    }

    /// A traced chain in ems: smoothed out of its pixel steps, then each
    /// point moved across the stroke to where it is furthest from the
    /// `outline` (the true middle, which a pixel can miss by half its width)
    /// and given that distance as its radius. Read off the pixels instead,
    /// every disc comes out half a pixel or more too small: a hairline loses
    /// a fifth of its ink.
    private static func stroke(_ c: SkeletonLine, _ ox: Double, _ oy: Double, _ h: Double,
                               _ outline: OutlineEdges, _ refined: inout [Int: (Double, Double, Double)]) -> Stroke {
        // Every other pixel (the ends kept): strokes are sampled every two
        // pixels' length anyway.
        let keep = c.xs.indices.filter { $0 % 2 == 0 || $0 == c.xs.count - 1 }
        let n = keep.count
        var xs = keep.map { ox + (c.xs[$0] + 0.5) * h }
        var ys = keep.map { oy + (c.ys[$0] + 0.5) * h }
        var rs = keep.map { c.rs[$0] * h }
        smooth(&xs, c.closed)
        smooth(&ys, c.closed)
        let cx = xs, cy = ys
        for i in 0..<n {
            // A pixel read once, whichever reading of the glyph meets it first.
            let key = Int((c.xs[keep[i]] * 8).rounded()) * 65536 + Int((c.ys[keep[i]] * 8).rounded())
            if let known = refined[key] {
                (xs[i], ys[i], rs[i]) = known
                continue
            }
            let reach = rs[i] + 2 * h
            let a = c.closed ? (i - 1 + n) % n : max(0, i - 1)
            let b = c.closed ? (i + 1) % n : min(n - 1, i + 1)
            var tx = cx[b] - cx[a], ty = cy[b] - cy[a]
            let length = hypot(tx, ty)
            if length > 0 {
                tx /= length
                ty /= length
                // The distance across a stroke rises to its middle and falls away:
                // a tent, whose peak a golden-section search finds.
                func across(_ s: Double) -> Double { outline.distance(cx[i] - ty * s, cy[i] + tx * s, reach) }
                let g = 0.6180339887498949
                var lo = -1.5 * h, hi = 1.5 * h
                var m1 = hi - g * (hi - lo), m2 = lo + g * (hi - lo)
                var d1 = across(m1), d2 = across(m2)
                for _ in 0..<10 {
                    if d1 < d2 {
                        lo = m1
                        m1 = m2
                        d1 = d2
                        m2 = lo + g * (hi - lo)
                        d2 = across(m2)
                    } else {
                        hi = m2
                        m2 = m1
                        d2 = d1
                        m1 = hi - g * (hi - lo)
                        d1 = across(m1)
                    }
                }
                let s = (lo + hi) / 2
                xs[i] = cx[i] - ty * s
                ys[i] = cy[i] + tx * s
            }
            rs[i] = outline.distance(xs[i], ys[i], reach)
            refined[key] = (xs[i], ys[i], rs[i])
        }
        // A line that comes back to where it started (the ring of a Q, from the
        // junction with its tail round to the same junction) is a loop: free to
        // open wherever it best lines up with its partner, not only there.
        if !c.closed, n > 4, hypot(xs[0] - xs[n - 1], ys[0] - ys[n - 1]) < 2 * h {
            return Stroke(Array(xs[0..<(n - 1)]), Array(ys[0..<(n - 1)]), Array(rs[0..<(n - 1)]), closed: true)
        }
        return Stroke(xs, ys, rs, closed: c.closed)
    }
}

/// A glyph's outline as its edges, binned on a grid, for the distance from
/// any point to the nearest edge.
private final class OutlineEdges {
    let cell: Double
    private var edges: [Double] = []
    private let x0: Double, y0: Double
    private let w: Int, h: Int
    private var bins: [[Int]]

    init(_ polygons: [[Double]], cell: Double) {
        self.cell = cell
        for p in polygons {
            let n = p.count / 2
            for k in 0..<n {
                let l = (k + 1) % n
                edges += [p[2 * k], p[2 * k + 1], p[2 * l], p[2 * l + 1]]
            }
        }
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        for e in stride(from: 0, to: edges.count, by: 2) {
            minX = min(minX, edges[e])
            maxX = max(maxX, edges[e])
            minY = min(minY, edges[e + 1])
            maxY = max(maxY, edges[e + 1])
        }
        x0 = minX
        y0 = minY
        w = Int(((maxX - minX) / cell).rounded(.down)) + 1
        h = Int(((maxY - minY) / cell).rounded(.down)) + 1
        bins = Array(repeating: [], count: w * h)
        for e in stride(from: 0, to: edges.count, by: 4) {
            let i0 = col(min(edges[e], edges[e + 2])), i1 = col(max(edges[e], edges[e + 2]))
            let j0 = row(min(edges[e + 1], edges[e + 3])), j1 = row(max(edges[e + 1], edges[e + 3]))
            for j in j0...j1 {
                for i in i0...i1 { bins[j * w + i].append(e) }
            }
        }
    }

    private func col(_ x: Double) -> Int { min(max(Int(((x - x0) / cell).rounded(.down)), 0), w - 1) }
    private func row(_ y: Double) -> Int { min(max(Int(((y - y0) / cell).rounded(.down)), 0), h - 1) }

    /// The distance from (x, y) to the nearest edge, looking no further than
    /// `reach` (beyond it, `reach`).
    func distance(_ x: Double, _ y: Double, _ reach: Double) -> Double {
        var best = reach * reach
        let i0 = col(x - reach), i1 = col(x + reach)
        let j0 = row(y - reach), j1 = row(y + reach)
        for j in j0...j1 {
            for i in i0...i1 {
                for e in bins[j * w + i] {
                    let ax = edges[e], ay = edges[e + 1]
                    let dx = edges[e + 2] - ax, dy = edges[e + 3] - ay
                    let len2 = dx * dx + dy * dy
                    var t = len2 == 0 ? 0 : ((x - ax) * dx + (y - ay) * dy) / len2
                    t = min(max(t, 0), 1)
                    let ex = ax + dx * t - x, ey = ay + dy * t - y
                    let d = ex * ex + ey * ey
                    if d < best { best = d }
                }
            }
        }
        return best.squareRoot()
    }
}

/// A rider's contact with its parent: the parent's track and point, and
/// its own point.
private typealias Contact = (track: Int, point: Int, own: Int)

private struct PairKey: Hashable {
    let a: Int, b: Int
    init(_ x: Int, _ y: Int) {
        a = min(x, y)
        b = max(x, y)
    }
}

private struct AnchorKey: Hashable {
    let key: AnyHashable, end: Bool
}

/// The morph from one `StrokeGlyph` to another, stroke by stroke.
///
/// Each stroke moves point for point, along its length, from its shape at
/// one end to its partner's at the other, its radius at every point
/// between the two: so it bends, stretches and thins, and is never thicker
/// in flight than the thicker of the two. A stroke with no partner draws
/// itself back into the stroke it joins, or out of it.
///
/// A reference type with reused buffers: `at(_:)` writes into them.
final class StrokeMorph {
    /// The `from` glyph's ascender (its reference line), in ems.
    let fromAscender: Double
    /// The `to` glyph's, in ems.
    let toAscender: Double
    /// What leaving a stroke without a partner costs, per em of its length:
    /// about how far a stroke may travel to its partner instead.
    let alone: Double
    /// Whether strokes without a partner go, and come, in turn: see `init`.
    let gather: Bool

    private var tracks: [Track] = []
    private var out: [[Double]] = []

    /// Pairs `from`'s strokes with `to`'s: each with the stroke at the other
    /// end it lies closest to along its length, or with none.
    ///
    /// Each glyph is read as whole strokes or as pieces split at their
    /// branch points (`StrokeGlyph.pieces`), whichever pairs up better: one
    /// weight of a letter into another, piece for piece; an M into an o, its
    /// zigzag into the loop.
    ///
    /// With `gather` (a word gathering into an icon, or opening out of
    /// one), strokes left without a partner go and come in turn rather than
    /// together: the start's draw back over the first half, the end's grow
    /// over the second, so only what pairs carries through the middle and the
    /// two never show at once.
    init(_ from: StrokeGlyph, _ to: StrokeGlyph, alone: Double = 0.5, gather: Bool = false) {
        fromAscender = from.ascender
        toAscender = to.ascender
        self.alone = alone
        self.gather = gather
        var best: StrokePlan?
        for readingA in [from.strokes, from.pieces, from.loops] {
            for readingB in [to.strokes, to.pieces, to.loops] {
                let plan = StrokePlan(readingA, from, readingB, to, alone)
                if best == nil || plan.cost < best!.cost { best = plan }
            }
        }
        build(best!)
        out = tracks.map { [Double](repeating: 0, count: 3 * $0.n) }
        shrink = out.map { [Double](repeating: 0, count: $0.count / 3) }
        boxes = [Double](repeating: 0, count: 4 * out.count)
        attached = Set(riding.flatMap { rider in
            [rider.start, rider.end].compactMap { $0.map { PairKey(rider.track, $0.track) } }
        } + tracks.indices.compactMap { k in tracks[k].anchor.map { PairKey(k, $0.track) } })
        widest = tracks.reduce(0) { widest, track in
            ([track.a] + (track.b.map { [$0] } ?? [])).reduce(widest) { w, p in
                stride(from: 2, to: p.count, by: 3).reduce(w) { max($0, p[$1]) }
            }
        }
    }

    /// How many strokes the morph draws.
    var trackCount: Int { tracks.count }

    /// How many strokes found a partner at the other end.
    var pairCount: Int { tracks.filter { $0.b != nil }.count }

    /// The length, in ems, of the longest stroke left without a partner (0
    /// when every stroke has one).
    var leftoverLength: Double {
        var longest = 0.0
        for t in tracks where t.b == nil {
            var length = 0.0
            for k in stride(from: 3, to: t.a.count, by: 3) {
                length += hypot(t.a[k] - t.a[k - 3], t.a[k + 1] - t.a[k - 2])
            }
            longest = max(longest, length)
        }
        return longest
    }

    /// The strokes at `t` (0 is `from`, 1 is `to`), each as interleaved x, y,
    /// r in ems: a line of discs. The buffers are reused by the next call;
    /// copy them to keep them.
    func at(_ t: Double) -> [[Double]] {
        for k in tracks.indices where tracks[k].b != nil {
            Self.pair(tracks[k], t, &out[k])
        }
        glue(t)
        ride(t)
        // Strokes on their own follow the stroke they join, so draw them once
        // the pairs are placed.
        for k in tracks.indices where tracks[k].b == nil {
            solo(tracks[k], t, k)
        }
        slim(t)
        return out
    }

    /// The pairs of tracks attached on purpose: a rider and its parents, a
    /// stroke on its own and the one it joins.
    private var attached: Set<PairKey> = []

    /// The widest any stroke is, at either end: the thickest the ink may be
    /// anywhere in flight.
    private var widest = 0.0

    /// How thick discs `i` of track `k` and `j` of track `l` make the ink
    /// together at rest: at the start, at the end, and between at `t`.
    private func restBand(_ k: Int, _ i: Int, _ l: Int, _ j: Int, _ t: Double) -> Double {
        func band(_ p: [Double], _ q: [Double]) -> Double {
            if i + 2 >= p.count || j + 2 >= q.count { return 0 }
            let d = hypot(q[j] - p[i], q[j + 1] - p[i + 1])
            let r = p[i + 2], s = q[j + 2]
            if d >= r + s || d <= abs(r - s) { return max(r, s) }
            return (d + r + s) / 2
        }
        let x = tracks[k], y = tracks[l]
        let start = band(x.a, y.a)
        let end = band(x.b ?? x.a, y.b ?? y.a)
        return start + (end - start) * min(max(t, 0), 1)
    }

    /// Where two strokes run alongside each other, overlapping, together
    /// they make a band thicker than either: two of radius r, d apart, are
    /// r + d / 2 thick. Each stroke is bounded by its ends; this bounds the
    /// ink. Discs of different strokes that overlap side by side shrink
    /// until the band they make is no thicker than `widest`, the more the
    /// more nearly parallel the strokes run there (two crossing square-on, an
    /// X, are no thicker than either), and not at all at either end of the
    /// morph, where the ink is the letter's own.
    private func slim(_ t: Double) {
        let ramp = sin(Double.pi * min(max(t, 0), 1))
        if ramp <= 0 || widest <= 0 { return }
        let limit = widest
        let n = out.count
        // Each track's bounds, discs and all; only tracks whose bounds meet
        // can make a band.
        for k in 0..<n {
            let o = out[k]
            var x0 = Double.infinity, y0 = Double.infinity, x1 = -Double.infinity, y1 = -Double.infinity
            for i in stride(from: 0, to: o.count, by: 3) {
                let r = o[i + 2]
                x0 = min(x0, o[i] - r)
                x1 = max(x1, o[i] + r)
                y0 = min(y0, o[i + 1] - r)
                y1 = max(y1, o[i + 1] + r)
            }
            boxes[4 * k] = x0
            boxes[4 * k + 1] = y0
            boxes[4 * k + 2] = x1
            boxes[4 * k + 3] = y1
            for i in shrink[k].indices { shrink[k][i] = 0 }
        }
        var near: [Int] = []
        for k in 0..<n {
            for l in (k + 1)..<max(n, k + 1) {
                // The overlap of the two bounds, if any.
                let x0 = max(boxes[4 * k], boxes[4 * l]), y0 = max(boxes[4 * k + 1], boxes[4 * l + 1])
                let x1 = min(boxes[4 * k + 2], boxes[4 * l + 2]), y1 = min(boxes[4 * k + 3], boxes[4 * l + 3])
                if x0 > x1 || y0 > y1 { continue }
                let p = out[k], q = out[l]
                let isAttached = attached.contains(PairKey(k, l))
                // The second track's discs inside the overlap, once. Every other
                // disc, on both sides: they're closer together than a band needs;
                // the ones skipped take their neighbours' thinning.
                near.removeAll(keepingCapacity: true)
                for j in stride(from: 0, to: q.count, by: 6) {
                    let s = q[j + 2]
                    if s > 0, q[j] + s >= x0, q[j] - s <= x1, q[j + 1] + s >= y0, q[j + 1] - s <= y1 {
                        near.append(j)
                    }
                }
                if near.isEmpty { continue }
                for i in stride(from: 0, to: p.count, by: 6) {
                    let x = p[i], y = p[i + 1], r = p[i + 2]
                    if r <= 0 || x + r < x0 || x - r > x1 || y + r < y0 || y - r > y1 { continue }
                    for j in near {
                        let s = q[j + 2]
                        let dx = q[j] - x, dy = q[j + 1] - y
                        if abs(dx) >= r + s || abs(dy) >= r + s { continue }
                        let d = (dx * dx + dy * dy).squareRoot()
                        // Overlapping, and not one inside the other.
                        if d >= r + s || d <= abs(r - s) { continue }
                        let band = (d + r + s) / 2
                        if band <= limit { continue }
                        // The more nearly parallel they run, the more: two crossing
                        // square-on (an X) are no thicker than either.
                        let along = Self.cosine(p, i, q, j)
                        let weight = along * along
                        if (band - limit) * weight < 1e-5 { continue }
                        // Past what the same two discs make at rest, at either end (in
                        // between, between the two): a letter's own junctions are as
                        // thick as the letter, and stay so.
                        let excess = band - max(limit, restBand(k, i, l, j, t))
                        if excess <= 0 { continue }
                        var cut = excess * weight
                        // Strokes attached on purpose (a serif on its stem) keep half
                        // their overlap, and stay touching; others may part.
                        if isAttached { cut = min(cut, (r + s - d) / 4) }
                        if cut > shrink[k][i / 3] { shrink[k][i / 3] = cut }
                        if cut > shrink[l][j / 3] { shrink[l][j / 3] = cut }
                    }
                }
            }
        }
        for k in 0..<n {
            // The discs skipped take the more of their neighbours'.
            let count = shrink[k].count
            for i in stride(from: 1, to: count, by: 2) {
                shrink[k][i] = max(shrink[k][i - 1], i + 1 < count ? shrink[k][i + 1] : 0)
            }
            for i in 0..<count where shrink[k][i] != 0 {
                let r = out[k][3 * i + 2]
                // Never below half its width: thinned to nothing, a stroke would
                // part in two.
                out[k][3 * i + 2] = max(r / 2, r - shrink[k][i] * ramp)
            }
        }
    }

    /// Bounds of each track, as drawn this frame (x0, y0, x1, y1).
    private var boxes: [Double] = []
    /// How much to thin each disc this frame.
    private var shrink: [[Double]] = []

    /// The cosine of the angle between the ways lines of discs `p` and `q`
    /// run at discs `i` and `j` (indices into them): each from the disc
    /// before to the one after.
    private static func cosine(_ p: [Double], _ i: Int, _ q: [Double], _ j: Int) -> Double {
        let pi = max(0, i - 3), pj = min(p.count - 3, i + 3)
        let qi = max(0, j - 3), qj = min(q.count - 3, j + 3)
        let ax = p[pj] - p[pi], ay = p[pj + 1] - p[pi + 1]
        let bx = q[qj] - q[qi], by = q[qj + 1] - q[qi + 1]
        let norms = (ax * ax + ay * ay) * (bx * bx + by * by)
        return norms == 0 ? 0 : (ax * bx + ay * by) / norms.squareRoot()
    }

    /// For each of `points` (x, y in ems, at the start, or with `end` at the
    /// end), the nearest point of a paired stroke there: what it rides.
    /// Remembered for `key` (a glyph's corners).
    func anchors(_ key: AnyHashable, _ points: [(Double, Double)], end: Bool) -> [(track: Int, point: Int)] {
        let cacheKey = AnchorKey(key: key, end: end)
        if let known = anchorCache[cacheKey] { return known }
        let found = points.map { nearest($0.0, $0.1, end: end) }
        anchorCache[cacheKey] = found
        return found
    }

    private var anchorCache: [AnchorKey: [(track: Int, point: Int)]] = [:]

    /// The nearest point to (x, y) of a paired stroke at rest at the start
    /// (or with `end`, the end).
    private func nearest(_ x: Double, _ y: Double, end: Bool) -> (track: Int, point: Int) {
        var best = (track: -1, point: 0)
        var bestD = Double.infinity
        for k in tracks.indices where tracks[k].b != nil {
            guard let rest = end ? tracks[k].b : tracks[k].a else { continue }
            for i in stride(from: 0, to: rest.count, by: 3) {
                let d = hypot(rest[i] - x, rest[i + 1] - y)
                if d < bestD {
                    bestD = d
                    best = (k, i / 3)
                }
            }
        }
        return best
    }

    /// How far point `p` of track `k` has moved from where it rests at the
    /// start (or with `end`, the end), as last drawn, in ems.
    func drift(_ k: Int, _ p: Int, end: Bool) -> (Double, Double) {
        if k < 0 { return (0, 0) }
        guard let rest = end ? tracks[k].b : tracks[k].a else { return (0, 0) }
        let now = out[k]
        return (now[3 * p] - rest[3 * p], now[3 * p + 1] - rest[3 * p + 1])
    }

    /// The spacing of a stroke's discs, in ems.
    static let step = 1.0 / 96

    /// Points per stroke when comparing two.
    static let probe = 24

    private func build(_ plan: StrokePlan) {
        for (a, b, fit) in plan.pairs {
            let count = max(2, Int((max(a.length, b.length) / Self.step).rounded(.up)) + 1)
            tracks.append(Track(pair: a.sample(count, cut: fit.cutA, reversed: fit.reverseA),
                                b.sample(count, cut: fit.cutB, reversed: fit.reverseB)))
        }
        joints()
        riders()
        // The middle of each end's ink, which a stroke joining nothing drifts
        // into as it goes (a word's last letters gathering into an icon).
        for (strokes, i) in [(plan.pairs.map(\.a) + plan.leftA, 0), (plan.pairs.map(\.b) + plan.leftB, 1)] {
            var sx = 0.0, sy = 0.0, n = 0
            for stroke in strokes {
                for k in stroke.x.indices {
                    sx += stroke.x[k]
                    sy += stroke.y[k]
                    n += 1
                }
            }
            if n > 0 { middles[i] = (sx / Double(n), sy / Double(n)) }
        }
        // Strokes on their own, those touching a pair first, then those
        // touching one of those, and so on; the rest stand alone.
        for (left, fromA) in [(plan.leftA, true), (plan.leftB, false)] {
            var placed: [(Int, [Double])] = plan.pairs.indices.map { k in (k, fromA ? tracks[k].a : tracks[k].b!) }
            var waiting = left
            while !waiting.isEmpty {
                var later: [Stroke] = []
                var joined: [Track] = []
                for stroke in waiting {
                    let track = Track(solo: stroke, placed: placed, fromA: fromA)
                    if track.anchor == nil { later.append(stroke) } else { joined.append(track) }
                }
                for track in joined {
                    placed.append((tracks.count, track.a))
                    tracks.append(track)
                }
                if joined.isEmpty {
                    for stroke in later { tracks.append(Track(solo: stroke, placed: [], fromA: fromA)) }
                    break
                }
                waiting = later
            }
        }
    }

    /// Short pairs that ride a longer one (a serif on its stem): each one's
    /// track, and where it touches its parent at the start and at the end,
    /// longest first.
    private var riding: [(track: Int, start: Contact?, end: Contact?)] = []

    /// Finds the riders: pairs under three tenths of an em, at the start or
    /// the end, that touch a longer pair there, anywhere along it.
    private func riders() {
        let pairs = tracks.count
        func length(_ p: [Double]) -> Double {
            var l = 0.0
            for i in stride(from: 3, to: p.count, by: 3) { l += hypot(p[i] - p[i - 3], p[i + 1] - p[i - 2]) }
            return l
        }
        let lengthsA = tracks.map { length($0.a) }
        let lengthsB = tracks.map { length($0.b!) }
        let lengths = (0..<pairs).map { max(lengthsA[$0], lengthsB[$0]) }
        // Where it's short, at that end: the z's long base, which becomes the
        // n's foot serif, rides the n's stem as it gets there.
        func contact(_ k: Int, start: Bool) -> Contact? {
            let own = start ? tracks[k].a : tracks[k].b!
            let lengths = start ? lengthsA : lengthsB
            if lengths[k] >= 0.3 { return nil }
            var best: Contact?
            var bestD = 0.01
            for j in 0..<pairs {
                if j == k || lengths[j] <= lengths[k] { continue }
                let other = start ? tracks[j].a : tracks[j].b!
                for p in stride(from: 0, to: other.count, by: 3) {
                    for i in stride(from: 0, to: own.count, by: 3) {
                        // Edge to edge.
                        let d = hypot(other[p] - own[i], other[p + 1] - own[i + 1]) - other[p + 2] - own[i + 2]
                        if d < bestD {
                            bestD = d
                            best = (j, p / 3, i / 3)
                        }
                    }
                }
            }
            return best
        }
        var found: [(track: Int, start: Contact?, end: Contact?)] = []
        for k in 0..<pairs {
            let a = contact(k, start: true), b = contact(k, start: false)
            if a != nil || b != nil { found.append((k, a, b)) }
        }
        // Parents before their riders.
        found.sort { lengths[$0.track] > lengths[$1.track] }
        riding = found
    }

    /// A pair's point `f` (a fractional index) as drawn now.
    private func point(_ k: Int, _ f: Double) -> (Double, Double) {
        let o = out[k]
        let n = o.count / 3
        let x = min(max(f, 0), Double(n - 1))
        let lo = Int(x.rounded(.down)), hi = min(lo + 1, n - 1)
        let w = x - Double(lo)
        return (o[3 * lo] + (o[3 * hi] - o[3 * lo]) * w, o[3 * lo + 1] + (o[3 * hi + 1] - o[3 * lo + 1]) * w)
    }

    /// Carries each rider with its parent: its point of contact kept on the
    /// parent's, sliding along the parent from where it touched at the start
    /// to where it touches at the end; or, touching different parents,
    /// handing over from one to the other; or easing off one it leaves (on
    /// to one it joins).
    private func ride(_ t: Double) {
        let w = ease(min(max(t, 0), 1))
        // How far apart the rider's point and its parent's lie at rest: kept,
        // so a rider stays where it sat (touching), not pulled onto the
        // parent's middle.
        func rest(_ c: Contact, _ k: Int, start: Bool) -> (Double, Double) {
            let parent = start ? tracks[c.track].a : tracks[c.track].b!
            let own = start ? tracks[k].a : tracks[k].b!
            return (parent[3 * c.point] - own[3 * c.own], parent[3 * c.point + 1] - own[3 * c.own + 1])
        }
        for (k, a, b) in riding {
            var dx = 0.0, dy = 0.0
            if let a, let b, a.track == b.track {
                let (px, py) = point(a.track, Double(a.point) + Double(b.point - a.point) * t)
                let (qx, qy) = point(k, Double(a.own) + Double(b.own - a.own) * t)
                let (ax, ay) = rest(a, k, start: true)
                let (bx, by) = rest(b, k, start: false)
                dx = px - qx - (ax + (bx - ax) * t)
                dy = py - qy - (ay + (by - ay) * t)
            } else {
                for (contact, weight, start) in [(a, 1 - w, true), (b, w, false)] {
                    guard let contact else { continue }
                    let (px, py) = point(contact.track, Double(contact.point))
                    let (qx, qy) = point(k, Double(contact.own))
                    let (ox, oy) = rest(contact, k, start: start)
                    dx += (px - qx - ox) * weight
                    dy += (py - qy - oy) * weight
                }
            }
            for i in stride(from: 0, to: out[k].count, by: 3) {
                out[k][i] += dx
                out[k][i + 1] += dy
            }
        }
    }

    /// The middle of the ink at the start and at the end.
    private var middles: [(Double, Double)] = [(0, 0), (0, 0)]

    /// For each end of each pair (end 2k is pair k's start, 2k + 1 its
    /// end), the joint it belongs to at the start and at the end: the ends
    /// that meet there. -1 for an end that meets none.
    private var jointA: [Int] = [], jointB: [Int] = []
    /// How many ends meet at each joint, at the start and the end.
    private var sizeA: [Int] = [], sizeB: [Int] = []
    /// Where each joint is now, summed, while gluing.
    private var sumA: [Double] = [], sumB: [Double] = []

    /// Finds the joints: pair ends that meet (within a hundredth of an em)
    /// at the start, and at the end.
    private func joints() {
        let pairs = tracks.count
        func cluster(start: Bool) -> ([Int], [Int]) {
            var ids = [Int](repeating: -1, count: 2 * pairs)
            var sizes: [Int] = []
            for e in 0..<(2 * pairs) where ids[e] == -1 {
                let (x, y) = endAt(e, start: start)
                var members = [e]
                for f in (e + 1)..<max(2 * pairs, e + 1) where ids[f] == -1 {
                    let (fx, fy) = endAt(f, start: start)
                    if hypot(fx - x, fy - y) < 0.01 { members.append(f) }
                }
                if members.count < 2 { continue }
                for m in members { ids[m] = sizes.count }
                sizes.append(members.count)
            }
            return (ids, sizes)
        }
        (jointA, sizeA) = cluster(start: true)
        (jointB, sizeB) = cluster(start: false)
        sumA = [Double](repeating: 0, count: 2 * sizeA.count)
        sumB = [Double](repeating: 0, count: 2 * sizeB.count)
    }

    /// Where pair end `e` is at the start (or the end).
    private func endAt(_ e: Int, start: Bool) -> (Double, Double) {
        let track = tracks[e / 2]
        let p = start ? track.a : track.b!
        let i = e % 2 == 0 ? 0 : p.count - 3
        return (p[i], p[i + 1])
    }

    /// Keeps the joints together in flight. Each pair moves on its own, so
    /// two pieces that meet (the halves of an a's bowl) drift apart: its
    /// counter leaks out, and closes. So each end is pulled to where its
    /// joint is now, the pull fading along the stroke: fully for ends that
    /// meet at both the start and the end, easing off over the morph for
    /// ends that only meet at the start (an o opening into a c), and in for
    /// ends that only meet at the end.
    private func glue(_ t: Double) {
        let pairs = jointA.count / 2
        if sizeA.isEmpty && sizeB.isEmpty { return }
        let w = min(max(t, 0), 1)
        for i in sumA.indices { sumA[i] = 0 }
        for i in sumB.indices { sumB[i] = 0 }
        for e in 0..<(2 * pairs) {
            let o = out[e / 2]
            let i = e % 2 == 0 ? 0 : o.count - 3
            let ja = jointA[e], jb = jointB[e]
            if ja >= 0 {
                sumA[2 * ja] += o[i]
                sumA[2 * ja + 1] += o[i + 1]
            }
            if jb >= 0 {
                sumB[2 * jb] += o[i]
                sumB[2 * jb + 1] += o[i + 1]
            }
        }
        for k in 0..<pairs {
            let last = out[k].count - 3
            var dx0 = 0.0, dy0 = 0.0, dx1 = 0.0, dy1 = 0.0
            for end in [0, 1] {
                let e = 2 * k + end
                let i = end == 0 ? 0 : last
                let x = out[k][i], y = out[k][i + 1]
                let ja = jointA[e], jb = jointB[e]
                if ja < 0 && jb < 0 { continue }
                let ax = ja < 0 ? x : sumA[2 * ja] / Double(sizeA[ja])
                let ay = ja < 0 ? y : sumA[2 * ja + 1] / Double(sizeA[ja])
                let bx = jb < 0 ? x : sumB[2 * jb] / Double(sizeB[jb])
                let by = jb < 0 ? y : sumB[2 * jb + 1] / Double(sizeB[jb])
                let dx = ax + (bx - ax) * w - x, dy = ay + (by - ay) * w - y
                if end == 0 {
                    dx0 = dx
                    dy0 = dy
                } else {
                    dx1 = dx
                    dy1 = dy
                }
            }
            if dx0 == 0, dy0 == 0, dx1 == 0, dy1 == 0 { continue }
            let n = out[k].count / 3
            for i in 0..<n {
                let f = n == 1 ? 0 : Double(i) / Double(n - 1)
                out[k][3 * i] += dx0 * (1 - f) + dx1 * f
                out[k][3 * i + 1] += dy0 * (1 - f) + dy1 * f
            }
        }
    }

    /// A pair at `t`: its middle moving straight from one end's to the
    /// other's, its shape blending from one to the other, and the whole
    /// turning by its turn as it goes.
    private static func pair(_ track: Track, _ t: Double, _ out: inout [Double]) {
        let a = track.a, b = track.b!
        let (ax, ay) = track.centreA
        let (bx, by) = track.centreB
        let turn = track.turn
        if turn == 0 {
            for k in stride(from: 0, to: out.count, by: 3) {
                out[k] = a[k] + (b[k] - a[k]) * t
                out[k + 1] = a[k + 1] + (b[k + 1] - a[k + 1]) * t
                out[k + 2] = radius(a[k + 2], b[k + 2], t)
            }
            return
        }
        // The end's shape turned back to the start's, blended, turned by t.
        let cb = cos(-turn), sb = sin(-turn)
        let ct = cos(turn * t), st = sin(turn * t)
        let cx = ax + (bx - ax) * t, cy = ay + (by - ay) * t
        for k in stride(from: 0, to: out.count, by: 3) {
            let px = a[k] - ax, py = a[k + 1] - ay
            let qx = b[k] - bx, qy = b[k + 1] - by
            let rx = qx * cb - qy * sb, ry = qx * sb + qy * cb
            let sx = px + (rx - px) * t, sy = py + (ry - py) * t
            out[k] = cx + sx * ct - sy * st
            out[k + 1] = cy + sx * st + sy * ct
            out[k + 2] = radius(a[k + 2], b[k + 2], t)
        }
    }

    /// Between `ra` and `rb` at `t`, and never past the larger of the two
    /// (a spring may carry `t` past either end).
    private static func radius(_ ra: Double, _ rb: Double, _ t: Double) -> Double {
        min(max(ra + (rb - ra) * t, 0), max(ra, rb))
    }

    /// Where point `p` (at rest) of track `k` is now: a pair's, as drawn; a
    /// stroke on its own's, moved as it was, or its nearest point still
    /// showing.
    private func now(_ k: Int, _ p: Int) -> (Double, Double) {
        let track = tracks[k]
        if track.b != nil { return (out[k][3 * p], out[k][3 * p + 1]) }
        let a = track.a, n = track.n
        let f = min(max(n == 1 ? 0 : Double(p) / Double(n - 1), track.shown), track.shown + track.showing)
        let s = f * Double(n - 1)
        let lo = min(max(Int(s.rounded(.down)), 0), n - 1), hi = min(lo + 1, n - 1)
        let w = s - Double(lo)
        return (a[3 * lo] + (a[3 * hi] - a[3 * lo]) * w + track.dx,
                a[3 * lo + 1] + (a[3 * hi + 1] - a[3 * lo + 1]) * w + track.dy)
    }

    private func solo(_ track: Track, _ t: Double, _ index: Int) {
        // Drawn back in over the first three quarters, or out over the last;
        // gathering, over the first half, or the last.
        let span = gather ? 0.5 : 0.75
        let u = ease(track.fromA ? 1 - min(max(t / span, 0), 1) : min(max((t - (1 - span)) / span, 0), 1))
        let a = track.a, n = track.n
        // The part showing closes in on the point where it joins (or its
        // middle, joining none, when it only shrinks).
        let start = track.at * (1 - u)
        let taper = track.anchor == nil ? u : min(1, 2 * u)
        var dx = 0.0, dy = 0.0
        let j = Int((track.at * Double(n - 1)).rounded())
        if let anchor = track.anchor {
            // Carried with the point it joins, and slid onto it as it goes.
            let other = tracks[anchor.track]
            let rest = other.b == nil ? other.a : (track.fromA ? other.a : other.b!)
            let (nx, ny) = now(anchor.track, anchor.point)
            let p = anchor.point
            dx = nx - rest[3 * p] + (rest[3 * p] - a[3 * j]) * (1 - u)
            dy = ny - rest[3 * p + 1] + (rest[3 * p + 1] - a[3 * j + 1]) * (1 - u)
        } else {
            // Joined to nothing: drifts, as it shrinks, onto the nearest stroke
            // that carries on (a word's last letters into the stroke that
            // becomes the icon), not into a pile in the middle.
            if track.toward == nil { track.toward = nearest(a[3 * j], a[3 * j + 1], end: !track.fromA) }
            let (k, p) = track.toward!
            let (mx, my) = k < 0 ? middles[track.fromA ? 1 : 0] : now(k, p)
            dx = (mx - a[3 * j]) * (1 - u)
            dy = (my - a[3 * j + 1]) * (1 - u)
        }
        track.dx = dx
        track.dy = dy
        track.shown = start
        track.showing = u
        for i in 0..<n {
            let s = (start + u * (n == 1 ? 0 : Double(i) / Double(n - 1))) * Double(n - 1)
            let lo = min(max(Int(s.rounded(.down)), 0), n - 1), hi = min(lo + 1, n - 1)
            let f = s - Double(lo)
            out[index][3 * i] = a[3 * lo] + (a[3 * hi] - a[3 * lo]) * f + dx
            out[index][3 * i + 1] = a[3 * lo + 1] + (a[3 * hi + 1] - a[3 * lo + 1]) * f + dy
            out[index][3 * i + 2] = (a[3 * lo + 2] + (a[3 * hi + 2] - a[3 * lo + 2]) * f) * taper
        }
    }
}

/// Which strokes of one glyph pair with which of another, and what it
/// costs in all.
private struct StrokePlan {
    var pairs: [(a: Stroke, b: Stroke, fit: StrokeFit)] = []
    var leftA: [Stroke] = [], leftB: [Stroke] = []
    var cost = 0.0

    init(_ readingA: [Stroke], _ a: StrokeGlyph, _ readingB: [Stroke], _ b: StrokeGlyph, _ alone: Double) {
        let n = readingA.count, m = readingB.count
        // Compared with the baselines and the middles of the ink lined up.
        let probesA = readingA.map { StrokeProbes($0, a.centre, a.ascender) }
        let probesB = readingB.map { StrokeProbes($0, b.centre, b.ascender) }
        func lone(_ s: Stroke) -> Double { alone * (s.length + 2 * s.meanRadius) }
        let big = 1e9
        let size = n + m
        var matrix = [[Double]](repeating: [Double](repeating: 0, count: size), count: size)
        var fits = [[StrokeFit?]](repeating: [StrokeFit?](repeating: nil, count: m), count: n)
        for i in 0..<size {
            for j in 0..<size {
                if i < n, j < m {
                    let fit = StrokeFit.best(probesA[i], probesB[j])
                    fits[i][j] = fit
                    matrix[i][j] = fit.cost
                } else if i < n {
                    matrix[i][j] = j - m == i ? lone(readingA[i]) : big
                } else if j < m {
                    matrix[i][j] = i - n == j ? lone(readingB[j]) : big
                }
            }
        }
        let pick = assign(matrix)
        var taken = Set<Int>()
        for i in 0..<n {
            let j = pick[i]
            if j < m {
                pairs.append((readingA[i], readingB[j], fits[i][j]!))
                taken.insert(j)
                cost += fits[i][j]!.cost
            } else {
                leftA.append(readingA[i])
                cost += lone(readingA[i])
            }
        }
        for j in 0..<m where !taken.contains(j) {
            leftB.append(readingB[j])
            cost += lone(readingB[j])
        }
    }
}

/// Eases `x`, 0...1, in and out.
private func ease(_ x: Double) -> Double { x * x * (3 - 2 * x) }

/// One stroke the morph draws: a pair, both ends sampled to the same
/// points, or one on its own (`b` nil).
private final class Track {
    /// For a stroke on its own, as last drawn: how far it's moved, and the
    /// share of it showing (from `shown` along, `showing` long).
    var dx = 0.0, dy = 0.0, shown = 0.0, showing = 1.0
    /// For a pair: each end's middle, and how far the stroke turns from one
    /// to the other, in radians.
    var centreA = (0.0, 0.0), centreB = (0.0, 0.0)
    var turn = 0.0
    /// For a stroke on its own joined to nothing: the paired stroke's point
    /// it drifts onto as it goes (or comes from).
    var toward: (track: Int, point: Int)?
    /// For a stroke on its own: how far along it (0...1) it joins its anchor,
    /// the point it shrinks to or grows from.
    var at = 0.5
    /// The start (for a stroke on its own, the stroke itself).
    var a: [Double]
    /// The end; nil for a stroke on its own.
    let b: [Double]?
    /// Whether a stroke on its own is in the start (else it grows in).
    let fromA: Bool
    /// For a stroke on its own: the track it joins and the point on it.
    var anchor: (track: Int, point: Int)?

    var n: Int { a.count / 3 }

    init(pair a: [Double], _ b: [Double]) {
        self.a = a
        self.b = b
        fromA = true
        // The turn that best lays the end's shape over the start's, about each
        // one's middle (Procrustes): moving each point straight to its partner
        // would cut a turning stroke through its own middle. Weighted by
        // length, so a stroke that's nearly a point doesn't spin.
        let n = a.count / 3
        var ax = 0.0, ay = 0.0, bx = 0.0, by = 0.0
        for i in 0..<n {
            ax += a[3 * i]
            ay += a[3 * i + 1]
            bx += b[3 * i]
            by += b[3 * i + 1]
        }
        let count = Double(n)
        ax /= count
        ay /= count
        bx /= count
        by /= count
        var dot = 0.0, cross = 0.0, spread = 0.0
        for i in 0..<n {
            let px = a[3 * i] - ax, py = a[3 * i + 1] - ay
            let qx = b[3 * i] - bx, qy = b[3 * i + 1] - by
            dot += px * qx + py * qy
            cross += px * qy - py * qx
            spread += ((px * px + py * py) * (qx * qx + qy * qy)).squareRoot()
        }
        centreA = (ax, ay)
        centreB = (bx, by)
        // Only a clear turn: a near-point or a straight line flipping end for
        // end has no meaningful one.
        if spread > 1e-9, (dot * dot + cross * cross).squareRoot() > 0.5 * spread {
            turn = atan2(cross, dot)
        }
    }

    /// A stroke on its own, joined to the nearest of `placed` (each a track's
    /// index and its points at rest) it touches: a paired stroke, or another
    /// on its own placed before it (a serif on a leg that grows in too).
    init(solo stroke: Stroke, placed: [(Int, [Double])], fromA: Bool) {
        b = nil
        self.fromA = fromA
        let n = max(2, Int((stroke.length / StrokeMorph.step).rounded(.up)) + 1)
        // Where it comes nearest: a serif's middle, a tail's end.
        let own = stroke.sample(n)
        var best: (track: Int, point: Int)?
        var bestD = Double.infinity, bestAt = 0
        for (k, other) in placed {
            for p in 0..<(other.count / 3) {
                for q in 0..<n {
                    // Measured edge to edge.
                    let d = hypot(other[3 * p] - own[3 * q], other[3 * p + 1] - own[3 * q + 1])
                        - other[3 * p + 2] - own[3 * q + 2]
                    if d < bestD {
                        bestD = d
                        best = (k, p)
                        bestAt = q
                    }
                }
            }
        }
        a = own
        // Joined: touching, give or take a fiftieth of an em.
        guard let best, bestD <= 0.02 else { return }
        anchor = best
        if stroke.closed {
            // A loop opens from there.
            a = stroke.sample(n, cut: Double(bestAt) / Double(n - 1))
            bestAt = 0
        }
        at = Double(bestAt) / Double(n - 1)
    }
}

/// A stroke sampled coarsely for comparing, in shared coordinates: x from
/// the middle of the ink, y from the reference line.
private struct StrokeProbes {
    let stroke: Stroke
    /// Every way to read it: from each cut (a closed stroke), each way round.
    var samples: [(cut: Double, reversed: Bool, points: [Double])] = []

    init(_ stroke: Stroke, _ centre: Double, _ ascender: Double) {
        self.stroke = stroke
        let variants = stroke.closed ? StrokeMorph.probe : 1
        for c in 0..<variants {
            for reversed in [false, true] {
                var p = stroke.sample(StrokeMorph.probe, cut: Double(c) / Double(variants), reversed: reversed)
                for k in stride(from: 0, to: p.count, by: 3) {
                    p[k] -= centre
                    p[k + 1] -= ascender
                }
                samples.append((Double(c) / Double(variants), reversed, p))
            }
        }
    }
}

/// How one stroke best lines up with another, and what that costs.
private struct StrokeFit {
    let cost: Double
    let cutA: Double, cutB: Double
    let reverseA: Bool, reverseB: Bool

    /// The best way to read `a` and `b` point for point. The cost is how far
    /// the points move on average, over the strokes' length, plus how much
    /// they stretch or thin.
    static func best(_ a: StrokeProbes, _ b: StrokeProbes) -> StrokeFit {
        // Hold one still and turn the other every way: the closed one, when
        // only one is.
        let turnA = a.stroke.closed && !b.stroke.closed
        let fixed = turnA ? b.samples[0] : a.samples[0]
        let turning = turnA ? a.samples : b.samples
        var best = Double.infinity
        var pick = turning[0]
        for v in turning {
            let d = travel(fixed.points, v.points)
            if d < best {
                best = d
                pick = v
            }
        }
        let la = a.stroke.length, lb = b.stroke.length
        let ra = a.stroke.meanRadius, rb = b.stroke.meanRadius
        // A tenth of an em on top: a fleck flying across the letter is as
        // noticeable as a stroke.
        let span = (la + lb) / 2 + ra + rb + 0.1
        var cost = best * span + 0.3 * abs(la - lb) + 0.5 * abs(ra - rb) * span
        // A serif or a terminal flying across the letter to become another
        // floats free of everything mid-flight; left unpaired, it draws back
        // into the stroke it hangs from (and the other's draws out of its own).
        // So a short stroke pays extra for every em it travels.
        if max(la, lb) < 0.3 { cost += best * 0.4 }
        return turnA
            ? StrokeFit(cost: cost, cutA: pick.cut, cutB: 0, reverseA: pick.reversed, reverseB: false)
            : StrokeFit(cost: cost, cutA: 0, cutB: pick.cut, reverseA: false, reverseB: pick.reversed)
    }

    /// How far the points of `p` go to their partners in `q` (each
    /// interleaved x, y, r), moved as a pair moves (see Track): their
    /// middle straight across, the whole turning by the turn that best lays
    /// one over the other, and the shape the turn can't account for
    /// blending. A mirror image, which no turn lays over its original, costs
    /// what it would cutting through its own middle; a true turn costs only
    /// the turning.
    static func travel(_ p: [Double], _ q: [Double]) -> Double {
        let n = p.count / 3
        let count = Double(n)
        var px = 0.0, py = 0.0, qx = 0.0, qy = 0.0
        for i in 0..<n {
            px += p[3 * i]
            py += p[3 * i + 1]
            qx += q[3 * i]
            qy += q[3 * i + 1]
        }
        px /= count
        py /= count
        qx /= count
        qy /= count
        var dot = 0.0, cross = 0.0, spread = 0.0, reach = 0.0
        for i in 0..<n {
            let ax = p[3 * i] - px, ay = p[3 * i + 1] - py
            let bx = q[3 * i] - qx, by = q[3 * i + 1] - qy
            dot += ax * bx + ay * by
            cross += ax * by - ay * bx
            spread += ((ax * ax + ay * ay) * (bx * bx + by * by)).squareRoot()
            reach += (hypot(ax, ay) + hypot(bx, by)) / 2
        }
        let turn = spread > 1e-9 && hypot(dot, cross) > 0.5 * spread ? atan2(cross, dot) : 0
        let c = cos(turn), s = sin(turn)
        var left = 0.0, middle = 0.0, ends = 0.0
        for i in 0..<n {
            let ax = p[3 * i] - px, ay = p[3 * i + 1] - py
            let bx = q[3 * i] - qx, by = q[3 * i + 1] - qy
            left += hypot(bx - (ax * c - ay * s), by - (ax * s + ay * c))
            // Halfway, in the start's frame: the end turned back, blended.
            let ux = bx * c + by * s, uy = -bx * s + by * c
            middle += ((ax + ux) * (ax + ux) + (ay + uy) * (ay + uy)) / 4
            ends += (ax * ax + ay * ay + bx * bx + by * by) / 2
        }
        // How far the stroke shrinks halfway: nothing for a true turn, a third
        // for a ring blended into its mirror image, flattening as it goes.
        let shrink = ends > 0 ? max(0, 1 - (middle / ends).squareRoot()) : 0
        return hypot(qx - px, qy - py) + left / count
            // A turn reads as less motion than its arc of travel: a ring that
            // turns barely seems to move.
            + 0.5 * abs(turn) * reach / count
            + 3 * shrink * reach / count
    }
}

/// The cheapest assignment of rows to columns of the square `cost` matrix
/// (Kuhn–Munkres): for each row, its column.
private func assign(_ cost: [[Double]]) -> [Int] {
    let n = cost.count
    var u = [Double](repeating: 0, count: n + 1), v = [Double](repeating: 0, count: n + 1)
    var p = [Int](repeating: 0, count: n + 1), way = [Int](repeating: 0, count: n + 1)
    if n == 0 { return [] }
    for i in 1...n {
        p[0] = i
        var j0 = 0
        var minv = [Double](repeating: .infinity, count: n + 1)
        var used = [Bool](repeating: false, count: n + 1)
        repeat {
            used[j0] = true
            let i0 = p[j0]
            var delta = Double.infinity
            var j1 = 0
            for j in 1...n where !used[j] {
                let cur = cost[i0 - 1][j - 1] - u[i0] - v[j]
                if cur < minv[j] {
                    minv[j] = cur
                    way[j] = j0
                }
                if minv[j] < delta {
                    delta = minv[j]
                    j1 = j
                }
            }
            for j in 0...n {
                if used[j] {
                    u[p[j]] += delta
                    v[j] -= delta
                } else {
                    minv[j] -= delta
                }
            }
            j0 = j1
        } while p[j0] != 0
        repeat {
            let j1 = way[j0]
            p[j0] = p[j1]
            j0 = j1
        } while j0 != 0
    }
    var rows = [Int](repeating: 0, count: n)
    for j in 1...n { rows[p[j] - 1] = j - 1 }
    return rows
}

/// Smooths the staircase out of a traced line: three passes of 1-2-1,
/// keeping the ends of an open one where they are.
private func smooth(_ v: inout [Double], _ closed: Bool) {
    let n = v.count
    if n < 3 { return }
    var tmp = [Double](repeating: 0, count: n)
    for _ in 0..<3 {
        for i in 0..<n {
            if !closed && (i == 0 || i == n - 1) {
                tmp[i] = v[i]
                continue
            }
            tmp[i] = (v[(i - 1 + n) % n] + 2 * v[i] + v[(i + 1) % n]) / 4
        }
        v = tmp
    }
}

/// `x` modulo `m`, never negative (Dart's `%`).
func positiveRemainder(_ x: Double, _ m: Double) -> Double {
    let r = x.truncatingRemainder(dividingBy: m)
    return r < 0 ? r + m : r
}
