// Ported from morphnext (KickNext, MIT, github.com/KickNext/morphnext),
// lib/src/geometry/shape.dart at 0.7.1. See THIRD_PARTY_NOTICES.md.

/// How an outline's overlapping contours fill.
enum FillRule: Sendable {
    case nonZero, evenOdd
}

/// Why an outline can't be read or morphed.
public struct MorphGeometryError: Error, CustomStringConvertible, Sendable {
    public let description: String
    init(_ description: String) { self.description = description }
}

/// A closed contour packed as one start point followed by cubic segments:
/// `[p0, c1, c2, p1, c1, c2, p2, ...]` as interleaved x, y.
struct CubicContour: Sendable {
    let points: [Double]

    init(_ points: [Double]) throws {
        guard points.count >= 8, (points.count - 2) % 6 == 0 else {
            throw MorphGeometryError("Invalid packed cubic contour")
        }
        guard points.allSatisfy(\.isFinite) else {
            throw MorphGeometryError("Non-finite cubic contour")
        }
        self.points = points
    }

    /// Number of cubic segments in this contour.
    var segmentCount: Int { (points.count - 2) / 6 }
}

/// Builds one closed `CubicContour`, lines and quadratics raised exactly to
/// cubics.
struct CubicContourBuilder {
    private var points: [Double] = []

    var isEmpty: Bool { points.isEmpty }

    /// Whether at least one segment has been added.
    var hasSegment: Bool { points.count >= 8 }

    private var x: Double { points[points.count - 2] }
    private var y: Double { points[points.count - 1] }

    mutating func move(to x: Double, _ y: Double) {
        points = [x, y]
    }

    mutating func line(to x: Double, _ y: Double) {
        let x0 = self.x, y0 = self.y
        cubic(
            x0 + (x - x0) / 3, y0 + (y - y0) / 3,
            x0 + 2 * (x - x0) / 3, y0 + 2 * (y - y0) / 3,
            to: x, y
        )
    }

    mutating func quadratic(_ cx: Double, _ cy: Double, to x: Double, _ y: Double) {
        let x0 = self.x, y0 = self.y
        cubic(
            x0 + 2 * (cx - x0) / 3, y0 + 2 * (cy - y0) / 3,
            x + 2 * (cx - x) / 3, y + 2 * (cy - y) / 3,
            to: x, y
        )
    }

    mutating func cubic(
        _ c1x: Double, _ c1y: Double,
        _ c2x: Double, _ c2y: Double,
        to x: Double, _ y: Double
    ) {
        points += [c1x, c1y, c2x, c2y, x, y]
    }

    /// Closes the contour back to its start and returns it.
    mutating func close() throws -> CubicContour {
        guard hasSegment else {
            throw MorphGeometryError("A contour needs at least one segment")
        }
        if x != points[0] || y != points[1] {
            line(to: points[0], points[1])
        }
        defer { points = [] }
        return try CubicContour(points)
    }
}

/// A contour sampled at a fixed number of points, with its place in the
/// filled shape: what contains it and whether it cuts a hole.
struct SampledContour: Sendable {
    /// Alternating x, y coordinates.
    let points: [Double]
    /// Signed polygon area.
    let signedArea: Double
    /// How many contours contain it.
    let depth: Int
    /// The index of the nearest containing contour, if any.
    let parent: Int?
    /// Whether it cuts a hole from its parent.
    let isHole: Bool

    init(_ points: [Double], signedArea: Double, depth: Int, parent: Int?, isHole: Bool? = nil) throws {
        guard points.count >= 2, points.count % 2 == 0 else {
            throw MorphGeometryError("Invalid sampled contour")
        }
        guard points.allSatisfy(\.isFinite), signedArea.isFinite else {
            throw MorphGeometryError("Non-finite sampled contour")
        }
        guard depth >= 0 else { throw MorphGeometryError("Negative contour depth") }
        self.points = points
        self.signedArea = signedArea
        self.depth = depth
        self.parent = parent
        self.isHole = isHole ?? (depth % 2 == 1)
    }
}

/// Sampled contours forming one filled outline.
struct MorphShape: Sendable {
    /// Contours in deterministic topology order.
    let contours: [SampledContour]
    /// The cubic contours they were sampled from, when known.
    let exactContours: [CubicContour]?
    /// How the original outline filled.
    let fillRule: FillRule

    init(_ contours: [SampledContour], exactContours: [CubicContour]? = nil, fillRule: FillRule = .evenOdd) {
        self.contours = contours
        self.exactContours = exactContours
        self.fillRule = fillRule
    }
}
