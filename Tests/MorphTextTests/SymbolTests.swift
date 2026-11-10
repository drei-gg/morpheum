import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import MorphText

@MainActor
@Suite struct Symbols {
    /// Renders `view` at 4x into RGBA pixels.
    private func pixels(_ view: some View) throws -> (width: Int, height: Int, alpha: [UInt8]) {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .light).environment(\.displayScale, 4))
        renderer.scale = 4
        let image = try #require(renderer.cgImage)
        let width = image.width, height = image.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &rgba, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (width, height, stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] })
    }

    /// The outline read from SwiftUI's PDF is the symbol `Image(systemName:)`
    /// draws, cut-outs (a soft mask) and badges included, within 3/4 of a
    /// point of its place; and at rest the morph draws that outline exactly
    /// where its first frame does, so it leaves and lands without a step.
    @Test(arguments: [
        "heart.fill", "star", "checkmark.circle.fill", "gearshape.2",
        "person.crop.circle.badge.plus", "trash.slash.fill", "wifi", "paperplane.fill",
    ])
    func theOutlineIsTheSymbol(_ name: String) throws {
        // Both centred in one frame, so they land on the same pixels.
        let image = try pixels(
            Image(systemName: name).font(.system(size: 48, weight: .regular)).foregroundStyle(.black)
                .frame(width: 100, height: 80)
        )
        let morph = try pixels(
            MorphBetween(from: .symbol(name, size: 48, color: .black), to: .text("x", style: .system(size: 48)), progress: 0)
                .frame(width: 100, height: 80)
        )
        #expect(image.width == morph.width && image.height == morph.height, "\(name)")
        guard image.width == morph.width, image.height == morph.height else { return }
        // What the morph draws as its first frame, on the same pixels.
        let firstFrame = try pixels(
            MorphBetween(from: .symbol(name, size: 48, color: .black), to: .text("x", style: .system(size: 48)), progress: 1e-9)
                .morphEngine(.outline)
                .frame(width: 100, height: 80)
        )
        var both = 0, either = 0
        for i in morph.alpha.indices {
            let a = morph.alpha[i] > 127, b = firstFrame.alpha[i] > 127
            if a && b { both += 1 }
            if a || b { either += 1 }
        }
        let overlap = Double(both) / Double(max(either, 1))
        // SwiftUI places a symbol's ink by up to 3/4 of a point differently
        // depending on where the symbol sits (paperplane.fill: 3.5 pt into its
        // box alone, 4.25 pt in a frame), so no fixed outline lands on its
        // pixels everywhere. The first frame is the same shape within that:
        // best overlap with it moved by up to 3 pixels at 4x, looked for
        // around the ink only.
        var rows = Int.max, rowsEnd = 0, columns = Int.max, columnsEnd = 0
        for y in 0..<image.height {
            for x in 0..<image.width where image.alpha[y * image.width + x] > 127 || firstFrame.alpha[y * image.width + x] > 127 {
                rows = min(rows, y); rowsEnd = max(rowsEnd, y)
                columns = min(columns, x); columnsEnd = max(columnsEnd, x)
            }
        }
        rows = max(rows, 3); columns = max(columns, 3)
        rowsEnd = min(rowsEnd, image.height - 4); columnsEnd = min(columnsEnd, image.width - 4)
        var handover = 0.0
        for dy in -3...3 {
            for dx in -3...3 {
                var shared = 0, inked = 0
                for y in rows...rowsEnd {
                    for x in columns...columnsEnd {
                        let a = image.alpha[y * image.width + x] > 127
                        let b = firstFrame.alpha[(y + dy) * image.width + x + dx] > 127
                        if a && b { shared += 1 }
                        if a || b { inked += 1 }
                    }
                }
                handover = max(handover, Double(shared) / Double(max(inked, 1)))
            }
        }
        #expect(handover > 0.98, "\(name): the first frame shares \(handover) of the symbol's ink")
        #expect(overlap > 0.99, "\(name): at rest and the first frame share \(overlap) of the ink")
    }

    @Test func aSymbolSitsOnTheBaseline() throws {
        let layout = MorphContent.Kind.symbol("heart.fill", size: 48, weight: .regular).layout()
        #expect(layout.letters.count == 1)
        let outline = try #require(layout.letters[0].outline)
        #expect(layout.baseline > 0 && layout.baseline < layout.size.height)
        // A heart stands on the baseline, its point a little below, about a
        // cap height tall.
        #expect(outline.bounds.maxY > 0 && outline.bounds.maxY < 0.15)
        #expect(outline.bounds.minY < -0.6 && outline.bounds.minY > -0.9)
    }

    @Test func anUnknownSymbolIsEmpty() {
        let layout = MorphContent.Kind.symbol("no.such.symbol.anywhere", size: 48, weight: .regular).layout()
        #expect(layout.letters.isEmpty)
        #expect(layout.size == .zero)
        let morph = TextMorph(from: .symbol("no.such.symbol.anywhere", size: 48), to: .text("Hi", style: .system(size: 48)))
        morph.prepare()
        // "Hi" grows in from the second half on.
        #expect(!morph.path(at: 0.75, in: morph.size(at: 0.75)).isEmpty)
    }

    @Test func aWordGathersIntoASymbolAsOneShape() throws {
        let morph = TextMorph(
            from: .text("Send it", style: .system(size: 40, weight: .semibold)),
            to: .symbol("paperplane.fill", size: 40, weight: .semibold),
            engine: .outline
        )
        let whole = try #require(morph.whole?.plan)
        // Every letter's contours (S, e, n, d, i's two, t) into the plane's.
        #expect(whole.contourCount >= 7)
        #expect(morph.lettersAsText(at: 0.5, in: morph.size(at: 0.5)).isEmpty)
        let size = morph.size(at: 0)
        let start = morph.path(at: 0, in: size).boundingBoxOfPath
        let (origin, _) = morph.origins(in: size)
        let ink = CTLineGetImageBounds(morph.a.line!, nil)
        #expect(abs(start.minX - (origin.x + ink.minX)) < 0.5)
        #expect(abs(start.width - ink.width) < 0.5)
    }

    @Test func oneSymbolIntoAnother() throws {
        let morph = TextMorph(from: .symbol("heart", size: 40), to: .symbol("heart.fill", size: 40), engine: .outline)
        #expect(morph.whole == nil)
        #expect(morph.pairs.count == 1)
        let plan = try #require(morph.pairs[0].plan)
        // The outline's hole closes up: it shrinks to a point.
        #expect(!plan.isOneToOne)
    }

    @Test func framesFromAWordToASymbol() throws {
        let from = MorphContent.text("Send", style: .system(size: 40, weight: .semibold, color: .black))
        let to = MorphContent.symbol("paperplane.fill", size: 40, weight: .semibold, color: .black)
        var frames: [CGImage] = []
        for t in stride(from: 0.0, through: 1.0, by: 0.25) {
            let renderer = ImageRenderer(content: MorphBetween(from: from, to: to, progress: t).environment(\.colorScheme, .light))
            renderer.scale = 2
            frames.append(try #require(renderer.cgImage))
        }
        try saveStrip(frames, name: "send-plane")
        let hearts = try [0.0, 0.25, 0.5, 0.75, 1.0].map { t in
            let renderer = ImageRenderer(content: MorphBetween(
                from: .symbol("heart", size: 48, color: .black),
                to: .symbol("star.fill", size: 48, color: .black),
                progress: t
            ).environment(\.colorScheme, .light))
            renderer.scale = 2
            return try #require(renderer.cgImage)
        }
        try saveStrip(hearts, name: "heart-star")
    }
}
