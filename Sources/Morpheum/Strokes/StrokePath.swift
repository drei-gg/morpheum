// Ported from morphtext for Flutter (lib/src/stroke_path.dart, strokes
// branch): a line of discs as one outline to fill.

import CoreGraphics
import Foundation

/// Adds a line of discs (`xyr`: interleaved x, y, r in ems) to `path`, an
/// em `scale` points across with its corner at `origin`, as its outline:
/// one contour along its left edge, round its end, back along its right
/// edge and round its start.
///
/// One contour, not a disc and a hull per point: where the pieces of a
/// union meet edge to edge inside it, anti-aliasing leaves hairline seams,
/// and a stroke drawn that way is seamed every few pixels.
///
/// Discs closer than `spacing` (points) to the last one kept are skipped,
/// the ends always kept. Each radius shrinks by `inset` points.
func addStroke(_ path: CGMutablePath, _ xyr: [Double], origin: CGPoint, scale s: Double,
               spacing: Double = 2, inset: Double = 0) {
    let n = xyr.count / 3
    var xs: [Double] = [], ys: [Double] = [], rs: [Double] = []
    for i in 0..<n {
        let x = origin.x + xyr[3 * i] * s
        let y = origin.y + xyr[3 * i + 1] * s
        let r = max(0, xyr[3 * i + 2] * s - inset)
        if let lastX = xs.last, let lastY = ys.last, let lastR = rs.last {
            let d = hypot(x - lastX, y - lastY)
            let last = i == n - 1
            // Close to the last one kept, and not the end: skip it, unless the
            // radius changes by more than the gap would hide.
            if !last && d < spacing && abs(r - lastR) < 0.5 { continue }
            // Inside the last one kept: nothing to add.
            if d + r <= lastR { continue }
            // Holding the last ones kept: they add nothing.
            while let px = xs.last, let py = ys.last, let pr = rs.last {
                if hypot(x - px, y - py) + pr > r { break }
                xs.removeLast()
                ys.removeLast()
                rs.removeLast()
            }
        }
        xs.append(x)
        ys.append(y)
        rs.append(r)
    }
    let m = xs.count
    if m == 0 { return }
    if m == 1 {
        if rs[0] > 0 { addDisc(path, xs[0], ys[0], rs[0]) }
        return
    }
    // One contour, a closed line as well as an open one: its two round ends
    // meet over each other. (Not a ring of an outer contour and an inner one
    // wound against it: where a loop closes tight against another stroke,
    // the inner one folds and cuts a hole.)
    strokeOutline(path, xs, ys, rs)
}

/// A disc, wound as the strokes are (clockwise on a y-down screen).
func addDisc(_ path: CGMutablePath, _ x: Double, _ y: Double, _ r: Double) {
    path.move(to: CGPoint(x: x + r, y: y))
    path.addRelativeArc(center: CGPoint(x: x, y: y), radius: r, startAngle: 0, delta: 2 * .pi)
    path.closeSubpath()
}

/// One side's edge between two discs, from (x1, y1) to (x2, y2).
private struct Edge {
    let x1: Double, y1: Double, x2: Double, y2: Double
    var reversed: Edge { Edge(x1: x2, y1: y2, x2: x1, y2: y1) }
}

/// Adds the discs of a line as one contour: along its left edge, round its
/// end, back along its right edge, round its start.
private func strokeOutline(_ path: CGMutablePath, _ xs: [Double], _ ys: [Double], _ rs: [Double]) {
    let m = xs.count
    // Each piece between neighbouring discs: its edge on either side, from
    // tangent point to tangent point.
    var left: [Edge] = [], right: [Edge] = []
    for j in 0..<(m - 1) {
        let x1 = xs[j], y1 = ys[j], r1 = max(rs[j], 1e-3)
        let x2 = xs[j + 1], y2 = ys[j + 1], r2 = max(rs[j + 1], 1e-3)
        let dx = x2 - x1, dy = y2 - y1
        let d = (dx * dx + dy * dy).squareRoot()
        let ux = dx / d, uy = dy / d
        let vx = -uy, vy = ux
        let k = (r1 - r2) / d
        let c = max(0, 1 - k * k).squareRoot()
        let ax = k * ux + c * vx, ay = k * uy + c * vy
        let bx = k * ux - c * vx, by = k * uy - c * vy
        left.append(Edge(x1: x1 + r1 * ax, y1: y1 + r1 * ay, x2: x2 + r2 * ax, y2: y2 + r2 * ay))
        right.append(Edge(x1: x1 + r1 * bx, y1: y1 + r1 * by, x2: x2 + r2 * bx, y2: y2 + r2 * by))
    }
    var patches: [Int] = []
    var points = side(left, xs, ys, rs, &patches, mirrored: false)
    // Round the end, through the way the line was going.
    points += cap(xs, ys, rs, m - 1, left.last!, right.last!, forward: true)
    points += side(right.reversed().map(\.reversed), xs.reversed(), ys.reversed(), rs.reversed(), &patches, mirrored: true)
    points += cap(xs, ys, rs, 0, left[0], right[0], forward: false)
    addContour(path, points, positive: true)
    // Where a bend is too tight for its edge to turn inside one piece, the
    // edge doubles back; the disc there covers the notch.
    for i in patches { addDisc(path, xs[i], ys[i], rs[i]) }
}

/// One side of an open line, its `edges` joined at each disc between them:
/// where the side bends inward, at the point where neighbouring edges
/// cross; where it bends outward, round the disc. Disc indices whose bends
/// are too tight go in `patches`. `mirrored` when the discs were reversed
/// for this side (patch indices are then counted from the other end).
private func side(_ edges: [Edge], _ xs: [Double], _ ys: [Double], _ rs: [Double], _ patches: inout [Int],
                  mirrored: Bool) -> [Double] {
    var out: [Double] = []
    let n = edges.count
    out += [edges[0].x1, edges[0].y1]
    for j in 0..<(n - 1) {
        let a = edges[j], b = edges[j + 1]
        // The disc they share.
        let i = j + 1
        let cx = xs[i], cy = ys[i], r = rs[i]
        // Where the two edges' lines cross: a + s (a's direction), b + t (b's).
        let adx = a.x2 - a.x1, ady = a.y2 - a.y1
        let bdx = b.x2 - b.x1, bdy = b.y2 - b.y1
        let den = adx * bdy - ady * bdx
        let gap = hypot(b.x1 - a.x2, b.y1 - a.y2)
        if abs(den) < 1e-9 || gap < 1e-6 {
            out += [a.x2, a.y2]
            continue
        }
        let s = ((b.x1 - a.x1) * bdy - (b.y1 - a.y1) * bdx) / den
        let t = ((b.x1 - a.x1) * ady - (b.y1 - a.y1) * adx) / den
        if s <= 1 && t >= 0 {
            // Bending inward: the edges overlap; meet where they cross.
            if s >= 0 && t <= 1 {
                out += [a.x1 + adx * s, a.y1 + ady * s]
            } else {
                out += [a.x2, a.y2, b.x1, b.y1]
                patches.append(mirrored ? xs.count - 1 - i : i)
            }
            continue
        }
        // Bending outward: round the disc, the short way.
        out += [a.x2, a.y2]
        let from = atan2(a.y2 - cy, a.x2 - cx)
        let turn = wrapAngle(atan2(b.y1 - cy, b.x1 - cx) - from)
        arc(&out, cx, cy, r, from, turn)
        out += [b.x1, b.y1]
    }
    out += [edges[n - 1].x2, edges[n - 1].y2]
    return out
}

/// The round cap at disc `i`, from the left edge's end to the right
/// edge's (`forward`, at the line's end), or from the right edge's start
/// to the left edge's (at its start): the way that passes in front of the
/// line, or behind it. Its ends are the edges' points, already added.
private func cap(_ xs: [Double], _ ys: [Double], _ rs: [Double], _ i: Int, _ left: Edge, _ right: Edge,
                 forward: Bool) -> [Double] {
    let cx = xs[i], cy = ys[i], r = rs[i]
    let (px, py) = forward ? (left.x2, left.y2) : (right.x1, right.y1)
    let (qx, qy) = forward ? (right.x2, right.y2) : (left.x1, left.y1)
    let from = atan2(py - cy, px - cx)
    let to = atan2(qy - cy, qx - cx)
    // The way the line runs here, and so the side the cap goes round.
    let j = forward ? i - 1 : i + 1
    let dir = atan2(cy - ys[j], cx - xs[j])
    var turn = wrapAngle(to - from)
    let middle = wrapAngle(dir - from)
    // Through the line's direction: same sign as the turn, and within it.
    let passes = turn >= 0 ? (middle >= 0 && middle <= turn) : (middle <= 0 && middle >= turn)
    if !passes { turn = turn >= 0 ? turn - 2 * .pi : turn + 2 * .pi }
    var out: [Double] = []
    arc(&out, cx, cy, r, from, turn)
    return out
}

/// The points strictly between the ends of an arc round (cx, cy), radius
/// `r`, from angle `from` turning by `turn`: one every fifteenth of a
/// half turn, or two points along it, whichever is closer.
private func arc(_ out: inout [Double], _ cx: Double, _ cy: Double, _ r: Double, _ from: Double, _ turn: Double) {
    let steps = max(1, Int(max(abs(turn) / (.pi / 15), abs(turn) * r / 2).rounded(.up)))
    for k in 1..<max(steps, 1) {
        let a = from + turn * Double(k) / Double(steps)
        out += [cx + r * cos(a), cy + r * sin(a)]
    }
}

/// Adds `points` as one closed contour, wound clockwise on a y-down
/// screen when `positive`, else the other way.
func addContour(_ path: CGMutablePath, _ points: [Double], positive: Bool) {
    let n = points.count / 2
    if n < 3 { return }
    let forwards = (doubledArea(points) >= 0) == positive
    for k in 0..<n {
        let i = forwards ? k : n - 1 - k
        let p = CGPoint(x: points[2 * i], y: points[2 * i + 1])
        if k == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    path.closeSubpath()
}

/// Twice the signed area of a polygon (interleaved x, y): positive when
/// clockwise on a y-down screen.
func doubledArea(_ p: [Double]) -> Double {
    let n = p.count / 2
    var area = 0.0
    for j in 0..<n {
        let l = (j + 1) % n
        area += p[2 * j] * p[2 * l + 1] - p[2 * l] * p[2 * j + 1]
    }
    return area
}

/// `a` wrapped into -π...π.
private func wrapAngle(_ a: Double) -> Double {
    positiveRemainder(a + .pi, 2 * .pi) - .pi
}
