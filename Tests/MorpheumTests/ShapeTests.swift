import CoreGraphics
import SwiftUI
import Testing
@testable import Morpheum

@Suite struct SVGPaths {
    private func box(_ data: String) throws -> CGRect { try SVG.path(data).boundingBoxOfPath }

    @Test func absoluteAndRelativeCommands() throws {
        #expect(try box("M0 0H10V10H0Z") == CGRect(x: 0, y: 0, width: 10, height: 10))
        #expect(try box("m2 3h10v10h-10z") == CGRect(x: 2, y: 3, width: 10, height: 10))
        #expect(try box("M0 0L10 0L10 5z") == CGRect(x: 0, y: 0, width: 10, height: 5))
    }

    @Test func numbersRunTogether() throws {
        // "-1-2" is two numbers, ".5.5" too, and pairs after a move are lines.
        #expect(try box("M-1-2 .5.5 3 3") == CGRect(x: -1, y: -2, width: 4, height: 5))
        #expect(try box("M0,0 L1e1,0 L10,1E1z") == CGRect(x: 0, y: 0, width: 10, height: 10))
    }

    @Test func curves() throws {
        // A cubic and its smooth twin; a quadratic and its smooth twin.
        let cubic = try box("M0 0C0 10 10 10 10 0S20-10 20 0")
        #expect(abs(cubic.minY + 7.5) < 0.01 && abs(cubic.maxY - 7.5) < 0.01)
        let quad = try box("M0 0Q5 10 10 0T20 0")
        #expect(abs(quad.maxY - 5) < 0.01 && abs(quad.minY + 5) < 0.01)
    }

    @Test func arcs() throws {
        // A half circle of radius 5 from (0,0) to (10,0), either side.
        let one = try box("M0 0A5 5 0 0 1 10 0")
        let other = try box("M0 0A5 5 0 0 0 10 0")
        #expect(abs(one.width - 10) < 0.01 && abs(one.height - 5) < 0.01)
        #expect(abs(other.height - 5) < 0.01)
        #expect(abs(one.midY + other.midY) < 0.01, "the two flags bow opposite ways")
        // Flags written together, radii too small scaled up to reach.
        #expect(abs(try box("M0 0a1 1 0 0110 0").height - 5) < 0.01)
    }

    @Test func badDataThrows() {
        #expect(throws: MorphGeometryError.self) { try SVG.path("10 10") }
        #expect(throws: MorphGeometryError.self) { try SVG.path("M0 0L5") }
        #expect(throws: MorphGeometryError.self) { try SVG.path("M0 0 X 3") }
    }

    @Test func transformsApplyInOrder() throws {
        // translate then scale, as SVG reads it: scale first, then move.
        let t = try SVG.transform("translate(10 20) scale(2)")
        #expect(CGPoint(x: 1, y: 1).applying(t) == CGPoint(x: 12, y: 22))
        let m = try SVG.transform("matrix(1 0 0 1 5 6)")
        #expect(CGPoint.zero.applying(m) == CGPoint(x: 5, y: 6))
    }
}

@Suite struct SVGDocuments {
    let document = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 50">
      <defs>
        <linearGradient id="g"><stop offset="0" stop-color="#000"/></linearGradient>
        <path id="hidden" d="M0 0H100V50H0Z"/>
      </defs>
      <g fill="#d11f16" fill-rule="evenodd" transform="translate(10 0)">
        <path d="M0 0H30V30H0Z M10 10H20V20H10Z"/>
        <path d="M40 0h30v30h-30z" transform="translate(0 10)"/>
        <path d="M0 40H80V50H0Z" fill="url(#g)"/>
        <path d="M0 40H80V50H0Z" fill="none"/>
      </g>
    </svg>
    """

    @Test func readsTheSolidShape() throws {
        let (path, viewBox) = try SVG.document(document)
        #expect(viewBox == CGRect(x: 0, y: 0, width: 100, height: 50))
        // Two squares, one moved by its own transform, both by the group's.
        #expect(path.boundingBoxOfPath == CGRect(x: 10, y: 0, width: 70, height: 40))
        // The even-odd hole stays a hole once made non-zero.
        #expect(!path.contains(CGPoint(x: 25, y: 15), using: .winding))
        #expect(path.contains(CGPoint(x: 12, y: 2), using: .winding))
        // The gradient bar, the unfilled bar and the defs are left out.
        #expect(!path.contains(CGPoint(x: 50, y: 45), using: .winding))
    }

    @Test func aShapeFitsItsBox() throws {
        let content = try MorphContent.shape(svg: document, size: CGSize(width: 200, height: 200))
        guard case .shape(let shape) = content.kind else { Issue.record("not a shape"); return }
        // A 100 by 50 viewBox fits 200 wide, centred in 200 tall.
        #expect(abs(shape.path.boundingBoxOfPath.minY - 50) < 0.01)
        #expect(abs(shape.path.boundingBoxOfPath.minX - 20) < 0.01)
    }

    @Test func nothingSolidThrows() {
        #expect(throws: MorphGeometryError.self) {
            try SVG.document(#"<svg viewBox="0 0 1 1"><path d="M0 0H1V1z" fill="none"/></svg>"#)
        }
    }
}

@MainActor
@Suite struct ShapeMorphs {
    let ring = MorphContent.shape(
        { let p = CGMutablePath()
          p.addEllipse(in: CGRect(x: 0, y: 0, width: 60, height: 60))
          p.addEllipse(in: CGRect(x: 15, y: 15, width: 30, height: 30))
          return p.normalized(using: .evenOdd) }(),
        size: CGSize(width: 60, height: 60)
    )
    let square = MorphContent.shape(CGPath(rect: CGRect(x: 10, y: 10, width: 40, height: 40), transform: nil), size: CGSize(width: 60, height: 60))

    @Test func aShapeIntoAShape() throws {
        let morph = TextMorph(from: ring, to: square, engine: .outline)
        #expect(morph.whole == nil)
        let plan = try #require(morph.pairs.first?.plan)
        // The ring's hole closes as it squares up.
        #expect(plan.contourCount == 2 && !plan.isOneToOne)
        let start = morph.path(at: 0, in: morph.size(at: 0)).boundingBoxOfPath
        #expect(abs(start.width - 60) < 0.5)
        let end = morph.path(at: 1, in: morph.size(at: 1)).boundingBoxOfPath
        #expect(abs(end.minX - 10) < 0.5 && abs(end.width - 40) < 0.5)
    }

    @Test func aWordIntoAShapeIsOneShape() throws {
        let morph = TextMorph(from: .text("Go", style: .system(size: 40, weight: .bold)), to: ring, engine: .outline)
        let whole = try #require(morph.whole?.plan)
        #expect(whole.contourCount >= 3)
    }

    @Test func atRestItIsTheShapeFilled() throws {
        let renderer = ImageRenderer(content: MorphBetween(from: square, to: ring, progress: 0).environment(\.colorScheme, .light))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        #expect(image.width == 60 && image.height == 60)
        var pixels = [UInt8](repeating: 0, count: 60 * 60 * 4)
        let context = CGContext(data: &pixels, width: 60, height: 60, bitsPerComponent: 8, bytesPerRow: 240,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 60, height: 60))
        let inked = stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] > 127 }.count
        #expect(abs(inked - 1600) < 80, "\(inked) pixels inked; the square is 40 by 40")
    }
}
