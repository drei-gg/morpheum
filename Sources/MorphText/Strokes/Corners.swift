// Ported from morphtext for Flutter (lib/src/corners.dart, strokes branch).

import CoreGraphics
import Foundation

/// What a glyph's strokes miss of the glyph: its square corners and flat
/// ends (a union of discs can only round them), as pieces, each with the
/// point it grows from.
///
/// A morph drawn as strokes grows the end glyph's pieces in over its last
/// stretch, and shrinks the start glyph's away over its first, so at
/// either end the strokes and their corners are the glyph's own outline,
/// and the plain text takes over with nothing to settle.
final class Corners: Sendable {
    /// The pieces, closed polygons wound as the strokes are (interleaved x,
    /// y, in thousandths of an em: path operations lose precision on shapes
    /// an em across), each with its middle.
    let pieces: [(points: [Double], centre: CGPoint)]

    private init(_ pieces: [(points: [Double], centre: CGPoint)]) { self.pieces = pieces }

    /// No corners at all.
    static let none = Corners([])

    /// The scale `pieces` are drawn at: thousandths of an em.
    static let scale = 1000.0

    /// How far a piece reaches into the strokes, in thousandths of an em.
    private static let overlap = 16.0

    /// How far strokes may fall short of an edge, in thousandths of an em,
    /// without leaving a corner: about a pixel at 192 to the em.
    private static let sliver = 5.0

    /// The pieces of `polygons` (the glyph, closed, interleaved x, y in ems)
    /// that `glyph`'s strokes don't cover, and that matter: slivers along an
    /// edge, where the strokes and the outline differ by a fraction of a
    /// pixel, have no area to speak of and are dropped.
    ///
    /// Each piece reaches a hair into the strokes, so that drawn in the same
    /// path as them it shares no edge with them (anti-aliasing seams where
    /// two shapes meet edge to edge); its outer edge is the glyph's own.
    static func of(_ polygons: [[Double]], _ glyph: StrokeGlyph) -> Corners {
        // Nudged by a fraction of a pixel, in case one geometry trips the
        // path operations up (Skia's do, now and then; CoreGraphics' may).
        for (nudge, spacing) in [(0.0, 1.0), (0.37, 1.3), (-0.29, 1.7), (1.1, 2.3), (-0.9, 3.1)] {
            if let corners = of(polygons, glyph, nudge: nudge, spacing: spacing) { return corners }
        }
        return none
    }

    private static func of(_ polygons: [[Double]], _ glyph: StrokeGlyph, nudge: Double, spacing: Double) -> Corners? {
        let outline = CGMutablePath()
        for p in polygons where p.count >= 6 {
            outline.move(to: CGPoint(x: p[0] * scale, y: p[1] * scale))
            for k in stride(from: 2, to: p.count, by: 2) {
                outline.addLine(to: CGPoint(x: p[k] * scale, y: p[k + 1] * scale))
            }
            outline.closeSubpath()
        }
        func strokes(inset: Double) -> CGPath {
            let path = CGMutablePath()
            for s in glyph.strokes {
                addStroke(path, s.sample(Int((s.length * 192).rounded(.up)) + 2), origin: .zero, scale: scale,
                          spacing: spacing, inset: inset + nudge)
            }
            return path
        }
        // Where the strokes fall short: the corners' cores. Against strokes a
        // few thousandths of an em fuller than they are: where they follow an
        // edge a hair inside it, all along a letter (an S), CoreGraphics
        // leaves one long sliver round it, with area enough to pass for a
        // corner, drawn as a hairline ghost of the letter as it moves.
        let missed = outline.subtracting(strokes(inset: -sliver), using: .winding)
        let cores = CGMutablePath()
        var any = false
        for points in contours(missed) {
            // A corner has area: at least an eightieth of an em squared.
            if abs(doubledArea(points)) < 2 * 160 { continue }
            add(cores, grown(wound(points), overlap * 2))
            any = true
        }
        if !any { return none }
        // The glyph less the strokes shrunk by the overlap, near the cores.
        let cut = outline.subtracting(strokes(inset: overlap), using: .winding)
            .intersection(cores, using: .winding)
        var pieces: [(points: [Double], centre: CGPoint)] = []
        for points in contours(cut) {
            if abs(doubledArea(points)) < 2 * 40 { continue }
            let piece = wound(points)
            var cx = 0.0, cy = 0.0
            for k in stride(from: 0, to: piece.count, by: 2) {
                cx += piece[k]
                cy += piece[k + 1]
            }
            let n = Double(piece.count / 2)
            pieces.append((piece, CGPoint(x: cx / n, y: cy / n)))
        }
        if pieces.contains(where: { $0.points.contains { !$0.isFinite } }) { return nil }
        return Corners(pieces)
    }

    /// Each piece's middle, in ems.
    var middles: [(Double, Double)] { pieces.map { ($0.centre.x / Self.scale, $0.centre.y / Self.scale) } }

    /// Adds the pieces to `path`, an em `size` points across with its
    /// corner at `origin`, each grown to `grown` of its size (0...1) about
    /// its middle, and moved by `drift` (in ems, by the piece's index):
    /// carried with the stroke it belongs to.
    func add(to path: CGMutablePath, origin: CGPoint, size: Double, grown: Double,
             drift: ((Int) -> (Double, Double))? = nil) {
        if grown <= 0 || pieces.isEmpty { return }
        let k = size / Self.scale
        for (n, (piece, centre)) in pieces.enumerated() {
            let (dx, dy) = drift?(n) ?? (0, 0)
            let ox = origin.x + k * dx * Self.scale, oy = origin.y + k * dy * Self.scale
            func point(_ i: Int) -> CGPoint {
                CGPoint(x: ox + k * (centre.x + (piece[i] - centre.x) * grown),
                        y: oy + k * (centre.y + (piece[i + 1] - centre.y) * grown))
            }
            path.move(to: point(0))
            for i in stride(from: 2, to: piece.count, by: 2) { path.addLine(to: point(i)) }
            path.closeSubpath()
        }
    }

    /// Each closed contour of `path` as points, about one every unit along
    /// it.
    private static func contours(_ path: CGPath) -> [[Double]] {
        var polylines: [[CGPoint]] = []
        var current: [CGPoint] = []
        var start = CGPoint.zero
        func flush() {
            if current.count >= 3 { polylines.append(current) }
            current = []
        }
        path.applyWithBlock { element in
            let p = element.pointee.points
            let last = current.last ?? start
            switch element.pointee.type {
            case .moveToPoint:
                flush()
                start = p[0]
                current = [p[0]]
            case .addLineToPoint:
                current.append(p[0])
            case .addQuadCurveToPoint:
                for k in 1...12 {
                    let t = CGFloat(k) / 12, u = 1 - t
                    current.append(CGPoint(x: u * u * last.x + 2 * u * t * p[0].x + t * t * p[1].x,
                                            y: u * u * last.y + 2 * u * t * p[0].y + t * t * p[1].y))
                }
            case .addCurveToPoint:
                for k in 1...16 {
                    let t = CGFloat(k) / 16, u = 1 - t
                    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
                    current.append(CGPoint(x: a * last.x + b * p[0].x + c * p[1].x + d * p[2].x,
                                            y: a * last.y + b * p[0].y + c * p[1].y + d * p[2].y))
                }
            case .closeSubpath:
                flush()
            @unknown default:
                break
            }
        }
        flush()
        return polylines.map { line in
            // Evenly along the closed line, about a unit apart.
            var along = [0.0]
            for i in 0..<line.count {
                let a = line[i], b = line[(i + 1) % line.count]
                along.append(along.last! + hypot(b.x - a.x, b.y - a.y))
            }
            let length = along.last!
            let n = max(3, Int(length.rounded(.up)))
            var out = [Double](repeating: 0, count: 2 * n)
            var segment = 0
            for i in 0..<n {
                let s = length * Double(i) / Double(n)
                while segment < line.count - 1 && along[segment + 1] < s { segment += 1 }
                let a = line[segment], b = line[(segment + 1) % line.count]
                let span = along[segment + 1] - along[segment]
                let f = span > 0 ? (s - along[segment]) / span : 0
                out[2 * i] = a.x + (b.x - a.x) * f
                out[2 * i + 1] = a.y + (b.y - a.y) * f
            }
            return out
        }
    }

    /// `p`, wound as the strokes are.
    private static func wound(_ p: [Double]) -> [Double] {
        if doubledArea(p) >= 0 { return p }
        let n = p.count / 2
        return (0..<n).reversed().flatMap { [p[2 * $0], p[2 * $0 + 1]] }
    }

    /// `p` (wound as the strokes are) pushed out `by` along its edges' normals.
    private static func grown(_ p: [Double], _ by: Double) -> [Double] {
        let n = p.count / 2
        var out = [Double](repeating: 0, count: 2 * n)
        for i in 0..<n {
            let a = (i - 1 + n) % n, b = (i + 1) % n
            // Outward, for this winding: (dy, -dx) along the neighbouring edges.
            var nx = p[2 * b + 1] - p[2 * a + 1]
            var ny = -(p[2 * b] - p[2 * a])
            let d = (nx * nx + ny * ny).squareRoot()
            if d > 0 {
                nx /= d
                ny /= d
            }
            out[2 * i] = p[2 * i] + nx * by
            out[2 * i + 1] = p[2 * i + 1] + ny * by
        }
        return out
    }

    private static func add(_ path: CGMutablePath, _ p: [Double]) {
        path.move(to: CGPoint(x: p[0], y: p[1]))
        for i in stride(from: 2, to: p.count, by: 2) { path.addLine(to: CGPoint(x: p[i], y: p[i + 1])) }
        path.closeSubpath()
    }
}
