import CoreGraphics

/// A filled outline that `MorphOutlinePlan` can morph: a glyph, a symbol, any
/// `CGPath`, or several of them placed as one with `combine`.
///
/// Fill it with the non-zero rule. Contours are sampled once, when the
/// outline is made (16 points per curve, 64 to 2048 per contour, as
/// morphnext samples glyphs); `placed` and `combine` move those points
/// rather than sampling again.
public struct MorphOutline: Sendable {
    let shape: MorphShape

    init(shape: MorphShape) { self.shape = shape }

    /// The outline of `path`, in its own coordinates. Nil when it has no
    /// closed area to fill (a space, a lone line).
    ///
    /// Every contour is closed back to its start, open ones included, and
    /// sampled. Throws when the path's points aren't finite.
    public init?(path: CGPath) throws {
        var contours: [CubicContour] = []
        var builder = CubicContourBuilder()
        var failure: Error?
        func finish() {
            guard builder.hasSegment else {
                builder = CubicContourBuilder()
                return
            }
            do { contours.append(try builder.close()) } catch { failure = error }
        }
        // Where the current subpath began: after a close, CoreGraphics goes on
        // from there without a move.
        var start = CGPoint.zero
        func begin() {
            if builder.isEmpty { builder.move(to: start.x, start.y) }
        }
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            let p = element.points
            switch element.type {
            case .moveToPoint:
                finish()
                start = p[0]
                builder.move(to: p[0].x, p[0].y)
            case .addLineToPoint:
                begin()
                builder.line(to: p[0].x, p[0].y)
            case .addQuadCurveToPoint:
                begin()
                builder.quadratic(p[0].x, p[0].y, to: p[1].x, p[1].y)
            case .addCurveToPoint:
                begin()
                builder.cubic(p[0].x, p[0].y, p[1].x, p[1].y, to: p[2].x, p[2].y)
            case .closeSubpath:
                finish()
            @unknown default:
                break
            }
        }
        finish()
        if let failure { throw failure }
        guard !contours.isEmpty else { return nil }
        shape = try sampleOutlineContours(contours)
    }

    /// This outline scaled about its origin by `scale`, then moved by
    /// `offset`. A positive scale keeps each contour's direction, nesting and
    /// order.
    public func placed(at offset: CGPoint, scale: CGFloat = 1) -> MorphOutline {
        precondition(scale.isFinite && scale > 0, "scale must be finite and positive")
        let dx = Double(offset.x), dy = Double(offset.y), s = Double(scale)
        func move(_ points: [Double]) -> [Double] {
            var moved = points
            for i in stride(from: 0, to: points.count, by: 2) {
                moved[i] = dx + points[i] * s
                moved[i + 1] = dy + points[i + 1] * s
            }
            return moved
        }
        // The inputs were valid, and moving them keeps them so.
        return MorphOutline(shape: MorphShape(
            shape.contours.map {
                try! SampledContour(
                    move($0.points),
                    signedArea: $0.signedArea * s * s,
                    depth: $0.depth,
                    parent: $0.parent,
                    isHole: $0.isHole
                )
            },
            exactContours: shape.exactContours.map { $0.map { try! CubicContour(move($0.points)) } },
            fillRule: shape.fillRule
        ))
    }

    /// Several outlines as one, so a whole word morphs as one shape. Place
    /// each part first. Nil when `parts` is empty.
    public static func combine(_ parts: [MorphOutline]) throws -> MorphOutline? {
        guard !parts.isEmpty else { return nil }
        return MorphOutline(shape: try sampledShape(
            fromPointBuffers: parts.flatMap { $0.shape.contours.map(\.points) },
            fillRule: .nonZero,
            exactContours: parts.flatMap { $0.shape.exactContours ?? [] }
        ))
    }

    /// How many closed contours it has (o has two, i two, B three).
    public var contourCount: Int { shape.contours.count }

    /// The smallest rectangle around its sampled points.
    public var bounds: CGRect {
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        for contour in shape.contours {
            for i in stride(from: 0, to: contour.points.count, by: 2) {
                minX = min(minX, contour.points[i])
                maxX = max(maxX, contour.points[i])
                minY = min(minY, contour.points[i + 1])
                maxY = max(maxY, contour.points[i + 1])
            }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// The morph from one `MorphOutline` to another: contours paired by role
/// (fills with fills, holes with holes) at least cost, any left over growing
/// from or shrinking to a point, and each pair turned, scaled and moved
/// along the way.
///
/// Planning is the expensive step; keep the plan and call `interpolate` (or
/// `path(at:)`) for each frame.
public struct MorphOutlinePlan: Sendable {
    let plan: MorphPlan

    /// Plans the morph from `from` to `to`.
    public init(from: MorphOutline, to: MorphOutline) throws {
        plan = try MorphPlan(from: from.shape, to: to.shape)
    }

    /// How many contour pairs the morph draws.
    public var contourCount: Int { plan.items.count }

    /// Whether every contour of each outline paired with exactly one of the
    /// other: nothing grew from or shrank to a point.
    public var isOneToOne: Bool {
        plan.items.allSatisfy { !$0.sourceCollapsed && !$0.targetCollapsed }
    }

    /// One buffer per contour pair, for `interpolate`.
    public func allocateOutput() -> [[Double]] { plan.allocateOutput() }

    /// Writes the outline at `t` (0 is `from`, 1 is `to`) into `output`, one
    /// closed polygon per contour pair as interleaved x, y. Up to 0.25 past
    /// either end extrapolates, as a spring overshoots; further is clamped.
    public func interpolate(_ t: Double, into output: inout [[Double]]) {
        plan.interpolate(t, into: &output)
    }

    /// The outline at `t` as a path, each point mapped by `transform`. Fill
    /// it with the non-zero rule.
    public func path(at t: Double, transform: CGAffineTransform = .identity) -> CGPath {
        var output = allocateOutput()
        interpolate(t, into: &output)
        let path = CGMutablePath()
        for points in output { addPolygon(points, to: path, transform: transform) }
        return path
    }
}

/// Adds one closed polygon, interleaved x, y, to `path`.
func addPolygon(_ points: [Double], to path: CGMutablePath, transform: CGAffineTransform) {
    guard points.count >= 4 else { return }
    path.move(to: CGPoint(x: points[0], y: points[1]).applying(transform))
    for i in stride(from: 2, to: points.count, by: 2) {
        path.addLine(to: CGPoint(x: points[i], y: points[i + 1]).applying(transform))
    }
    path.closeSubpath()
}
