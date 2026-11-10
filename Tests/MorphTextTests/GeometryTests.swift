import CoreGraphics
import Testing
@testable import MorphText

/// A square of side `side` at (`x`, `y`), wound clockwise in a y-down frame
/// or anticlockwise when `reversed`.
private func square(_ x: Double, _ y: Double, _ side: Double, reversed: Bool = false) -> CGPath {
    let path = CGMutablePath()
    let corners = [
        CGPoint(x: x, y: y), CGPoint(x: x + side, y: y),
        CGPoint(x: x + side, y: y + side), CGPoint(x: x, y: y + side),
    ]
    let ordered = reversed ? Array(corners.reversed()) : corners
    path.addLines(between: ordered)
    path.closeSubpath()
    return path
}

private func ring() -> CGPath {
    let path = CGMutablePath()
    path.addArc(center: CGPoint(x: 0.5, y: 0.5), radius: 0.5, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
    path.closeSubpath()
    // The hole winds the other way, as a font's holes do.
    path.addArc(center: CGPoint(x: 0.5, y: 0.5), radius: 0.25, startAngle: 2 * .pi, endAngle: 0, clockwise: true)
    path.closeSubpath()
    return path
}

/// The largest distance from any point of `a` to the nearest point of `b`.
private func hausdorff(_ a: CGPath, _ b: CGPath) -> Double {
    func points(_ path: CGPath) -> [CGPoint] {
        var result: [CGPoint] = []
        path.applyWithBlock { element in
            if element.pointee.type == .moveToPoint || element.pointee.type == .addLineToPoint {
                result.append(element.pointee.points[0])
            }
        }
        return result
    }
    let pa = points(a), pb = points(b)
    return pa.map { p in pb.map { hypot($0.x - p.x, $0.y - p.y) }.min()! }.max()!
}

@Suite struct Sampling {
    @Test func aSquareKeepsItsCorners() throws {
        let outline = try #require(try MorphOutline(path: square(0, 0, 1)))
        #expect(outline.contourCount == 1)
        let points = outline.shape.contours[0].points
        #expect(points.count == 2 * 64)
        let corners: Set<[Double]> = [[0, 0], [1, 0], [1, 1], [0, 1]]
        let sampled = Set(stride(from: 0, to: points.count, by: 2).map { [points[$0], points[$0 + 1]] })
        #expect(corners.isSubset(of: sampled))
    }

    @Test func aRingHasAHole() throws {
        let outline = try #require(try MorphOutline(path: ring()))
        #expect(outline.contourCount == 2)
        #expect(outline.shape.contours.map(\.isHole) == [false, true])
        #expect(outline.shape.contours[1].parent == 0)
    }

    @Test func windingIsMadeCanonical() throws {
        let a = try #require(try MorphOutline(path: square(0, 0, 1)))
        let b = try #require(try MorphOutline(path: square(0, 0, 1, reversed: true)))
        #expect(a.shape.contours[0].signedArea.sign == b.shape.contours[0].signedArea.sign)
    }

    @Test func nothingToFillIsNil() throws {
        let line = CGMutablePath()
        line.move(to: .zero)
        #expect(try MorphOutline(path: line) == nil)
        #expect(try MorphOutline(path: CGMutablePath()) == nil)
    }

    @Test func placingMovesAndScales() throws {
        let outline = try #require(try MorphOutline(path: square(0, 0, 1)))
        let placed = outline.placed(at: CGPoint(x: 10, y: 20), scale: 2)
        #expect(placed.bounds == CGRect(x: 10, y: 20, width: 2, height: 2))
    }
}

@Suite struct Planning {
    @Test func theEndsAreExact() throws {
        let from = try #require(try MorphOutline(path: square(0, 0, 1)))
        let to = try #require(try MorphOutline(path: ring()))
        let plan = try MorphOutlinePlan(from: from, to: to)
        // The square's own sampled points, and its partner hole a point inside.
        #expect(hausdorff(outlinePath(from), plan.path(at: 0)) < 1e-9)
        let end = plan.path(at: 1)
        // The ring's outer contour, and its hole grown from a point.
        #expect(abs(end.boundingBoxOfPath.width - 1) < 1e-3)
        #expect(plan.contourCount == 2)
        #expect(!plan.isOneToOne)
    }

    @Test func aShapeIntoItselfStaysPut() throws {
        let outline = try #require(try MorphOutline(path: ring()))
        let plan = try MorphOutlinePlan(from: outline, to: outline)
        #expect(plan.isOneToOne)
        #expect(hausdorff(plan.path(at: 0.5), plan.path(at: 0)) < 1e-9)
    }

    @Test func aMovedSquareTravelsInAStraightLine() throws {
        let from = try #require(try MorphOutline(path: square(0, 0, 1)))
        let to = try #require(try MorphOutline(path: square(4, 0, 1)))
        let plan = try MorphOutlinePlan(from: from, to: to)
        let half = plan.path(at: 0.5).boundingBoxOfPath
        #expect(abs(half.minX - 2) < 1e-9 && abs(half.width - 1) < 1e-9)
    }

    @Test func overshootIsClampedToAQuarter() throws {
        let from = try #require(try MorphOutline(path: square(0, 0, 1)))
        let to = try #require(try MorphOutline(path: square(4, 0, 1)))
        let plan = try MorphOutlinePlan(from: from, to: to)
        #expect(abs(plan.path(at: 1.25).boundingBoxOfPath.minX - 5) < 1e-9)
        #expect(abs(plan.path(at: 3).boundingBoxOfPath.minX - 5) < 1e-9)
    }
}

/// What a spare contour (one with no partner) does on its way out.
@Suite struct Collapsing {
    /// `extra` beside a unit square at the origin, as one outline.
    private func withSpare(_ extra: CGPath) throws -> MorphOutline {
        let path = CGMutablePath()
        path.addPath(square(0, 0, 1))
        path.addPath(extra, transform: CGAffineTransform(translationX: 4, y: 0))
        return try #require(try MorphOutline(path: path))
    }

    /// Each contour's box at `t`, keyed by whether it sits right of x = 1.5
    /// at the start, so the spare is told from the square that stays.
    private func spareBoxes(_ plan: MorphOutlinePlan, at t: Double) -> [CGRect] {
        var start = plan.allocateOutput(), output = plan.allocateOutput()
        plan.interpolate(0, into: &start)
        plan.interpolate(t, into: &output)
        return output.indices.filter { centroid(start[$0]).x > 1.5 }.map { index in
            let xs = stride(from: 0, to: output[index].count, by: 2).map { output[index][$0] }
            let ys = stride(from: 1, to: output[index].count, by: 2).map { output[index][$0] }
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
    }

    @Test func aSpareShrinksSteadilyIntoItsPlace() throws {
        let from = try withSpare(square(0, 0, 1))
        let to = try #require(try MorphOutline(path: square(0, 0, 1)))
        let plan = try MorphOutlinePlan(from: from, to: to)
        // Halfway it is half its size, halfway to the square's centre.
        let half = try #require(spareBoxes(plan, at: 0.5).first)
        #expect(abs(half.width - 0.5) < 1e-6 && abs(half.midX - 2.5) < 1e-6 && abs(half.midY - 0.5) < 1e-6)
        // Past the end it stays a point instead of turning inside out.
        let past = try #require(spareBoxes(plan, at: 1.2).first)
        #expect(past.width < 1e-9 && abs(past.midX - 0.5) < 1e-6)
    }

    @Test func morphnextsCollapseIsQuick() throws {
        let from = try withSpare(square(0, 0, 1))
        let to = try #require(try MorphOutline(path: square(0, 0, 1)))
        let plan = try MorphOutlinePlan(from: from, to: to, collapse: .morphnext)
        #expect(try #require(spareBoxes(plan, at: 0.5).first).width < 0.01)
    }

    @Test func aSpareLettersCounterShrinksWithIt() throws {
        let from = try withSpare(ring())
        let to = try #require(try MorphOutline(path: square(0, 0, 1)))
        let plan = try MorphOutlinePlan(from: from, to: to)
        /// The counter's box in units of the ring's.
        func counter(at t: Double) -> CGRect {
            let boxes = spareBoxes(plan, at: t).sorted { $0.width > $1.width }
            let (ring, hole) = (boxes[0], boxes[1])
            return CGRect(x: (hole.minX - ring.minX) / ring.width, y: (hole.minY - ring.minY) / ring.height,
                          width: hole.width / ring.width, height: hole.height / ring.height)
        }
        let start = counter(at: 0)
        for t in stride(from: 0.1, through: 0.9, by: 0.1) {
            #expect(spareBoxes(plan, at: t).count == 2)
            // Both scale about one point, so the counter keeps its place in
            // the ring, and its share of the ring's size.
            let now = counter(at: t)
            #expect(abs(now.minX - start.minX) + abs(now.minY - start.minY) + abs(now.width - start.width) < 1e-6, "at \(t)")
        }
    }
}

/// An outline's sampled points as a path.
private func outlinePath(_ outline: MorphOutline) -> CGPath {
    let path = CGMutablePath()
    for contour in outline.shape.contours {
        addPolygon(contour.points, to: path, transform: .identity)
    }
    return path
}
