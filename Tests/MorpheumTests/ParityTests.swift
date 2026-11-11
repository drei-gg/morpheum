import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import Morpheum

/// The port against the original: morphnext 0.7.1 (Dart) planned these
/// letter pairs from the same font files and wrote out each frame
/// (`Fixtures/morphnext-0.7.1-frames.json`, to 1e-4 em). Here CoreText reads
/// the glyphs, and the Swift plan must draw the same shapes.
///
/// Shapes, not points: CoreText may start a contour at another point than
/// morphnext's font reader, so the samples fall elsewhere along the same
/// outline. Each point of one must lie on the other's edges: within 0.005 em
/// at the ends, 0.02 em between.
@Suite struct Parity {
    struct Case: Decodable {
        let from: String, fromChar: String, to: String, toChar: String
        let pairs: Int
        let oneToOne: Bool
        let frames: [String: [[Double]]]
    }

    static let cases: [Case] = {
        let url = Bundle.module.url(forResource: "morphnext-0.7.1-frames", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
    }()

    /// A glyph's outline as morphnext reads it: in ems, y down, baseline 0.
    static func outline(_ file: String, _ character: String) throws -> MorphOutline {
        let url = try #require(Bundle.module.url(forResource: file, withExtension: nil, subdirectory: "Fixtures"))
        let provider = try #require(CGDataProvider(url: url as CFURL))
        let font = CTFontCreateWithGraphicsFont(try #require(CGFont(provider)), 1000, nil, nil)
        var units = Array(character.utf16)
        var glyph: CGGlyph = 0
        #expect(CTFontGetGlyphsForCharacters(font, &units, &glyph, 1))
        var flip = CGAffineTransform(a: 1.0 / 1000, b: 0, c: 0, d: -1.0 / 1000, tx: 0, ty: 0)
        let path = try #require(CTFontCreatePathForGlyph(font, glyph, &flip))
        return try #require(try MorphOutline(path: path))
    }

    @Test(arguments: cases.indices)
    func sameShapesAsMorphnext(_ index: Int) throws {
        let reference = Self.cases[index]
        let from = try Self.outline(reference.from, reference.fromChar)
        let to = try Self.outline(reference.to, reference.toChar)
        let plan = try MorphOutlinePlan(from: from, to: to)
        let name = "\(reference.fromChar)→\(reference.toChar)"
        #expect(plan.contourCount == reference.pairs, "\(name)")
        #expect(plan.isOneToOne == reference.oneToOne, "\(name)")
        var output = plan.allocateOutput()
        for (key, expected) in reference.frames {
            plan.interpolate(Double(key)!, into: &output)
            #expect(output.map { $0.count } == expected.map { $0.count }, "\(name) at \(key)")
            let distance = max(shapeDistance(output, expected), shapeDistance(expected, output))
            // The ends are the glyphs themselves. Between them, a contour that
            // starts elsewhere pairs its points a little differently (i→e
            // differs by 0.01 em, half a pixel at 48 pt).
            let t = Double(key)!
            let tolerance = t == 0 || t == 1 ? 0.005 : 0.02
            #expect(distance < tolerance, "\(name) at t=\(key): \(distance) em apart")
        }
    }
}

/// The furthest any point of `a` lies from the edges of the polygon of `b`
/// paired with it (the same contour pair, by index).
private func shapeDistance(_ a: [[Double]], _ b: [[Double]]) -> Double {
    var worst = 0.0
    for (points, polygon) in zip(a, b) {
        let n = polygon.count / 2
        for i in stride(from: 0, to: points.count, by: 2) {
            let (px, py) = (points[i], points[i + 1])
            var best = Double.infinity
            for k in 0..<n {
                let j = (k + 1) % n
                best = min(best, segmentDistance(px, py, polygon[2 * k], polygon[2 * k + 1], polygon[2 * j], polygon[2 * j + 1]))
            }
            worst = max(worst, best)
        }
    }
    return worst
}

private func segmentDistance(_ px: Double, _ py: Double, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> Double {
    let dx = x1 - x0, dy = y1 - y0
    let lengthSquared = dx * dx + dy * dy
    let u = lengthSquared > 0 ? min(max(((px - x0) * dx + (py - y0) * dy) / lengthSquared, 0), 1) : 0
    return hypot(px - (x0 + u * dx), py - (y0 + u * dy))
}
