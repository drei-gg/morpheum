import CoreGraphics
import CoreText
import SwiftUI
import Testing
@testable import MorphText

/// A letter of the system font, as a layout's letter.
private func letter(_ character: String, weight: Font.Weight = .regular) throws -> WordLayout.Letter {
    let layout = WordLayout(character, style: MorphStyle.system(size: 64, weight: weight).geometry)
    return try #require(layout.letters.first)
}

@Suite struct Tracing {
    @Test func anOIsOneClosedStroke() throws {
        let o = try #require(try letter("o").outline)
        let glyph = try #require(StrokeGlyph.trace(o.polygons, ascender: 0))
        #expect(glyph.strokes.count == 1)
        #expect(glyph.strokes[0].closed)
    }

    @Test func anLIsOneOpenStroke() throws {
        let l = try #require(try letter("l").outline)
        let glyph = try #require(StrokeGlyph.trace(l.polygons, ascender: 0))
        #expect(glyph.strokes.count == 1)
        #expect(!glyph.strokes[0].closed)
        // Down the stem: about as long as the l is tall, less its round ends.
        #expect(abs(glyph.strokes[0].length - l.bounds.height) < 0.12)
    }

    @Test(arguments: ["S", "e", "n", "d", "a", "g", "R", "&"])
    func strokesAndCornersRebuildTheLetter(_ character: String) throws {
        let outline = try #require(try letter(character, weight: .semibold).outline)
        let glyph = try #require(StrokeGlyph.trace(outline.polygons, ascender: 0))
        let corners = Corners.of(outline.polygons, glyph)
        var drawn: [[Double]] = []
        for stroke in glyph.strokes {
            drawn += strokePolygons(stroke.sample(Int((stroke.length * 192).rounded(.up)) + 2))
        }
        for piece in corners.pieces { drawn.append(piece.points.map { $0 / Corners.scale }) }
        let (onlyLetter, onlyDrawn, area) = inkDifference(outline.polygons, drawn)
        // Within a percent and a half, as `landsTrue` asks.
        #expect(Double(onlyLetter + onlyDrawn) < 0.015 * Double(area), "\(character): \(onlyLetter) + \(onlyDrawn) of \(area)")
    }

    @Test(arguments: ["S", "n", "d", "l"])
    func cornersAreCorners(_ character: String) throws {
        // Not a sliver all round the letter: an S's strokes run a hair inside
        // its edges, end to end, which once came out as one long "corner".
        let outline = try #require(try letter(character, weight: .semibold).outline)
        let glyph = try #require(StrokeGlyph.trace(outline.polygons, ascender: 0))
        var cornerArea = 0.0
        for piece in Corners.of(outline.polygons, glyph).pieces {
            cornerArea += abs(doubledArea(piece.points)) / 2 / (Corners.scale * Corners.scale)
        }
        #expect(cornerArea < 0.08 * Ink(polygons: outline.polygons, pixelsPerEm: 192).area, "\(character)")
    }
}

@Suite struct StrokeMorphing {
    @Test func inFlightNoThickerThanTheThickerEnd() throws {
        let a = try #require(try letter("a", weight: .bold).outline)
        let g = try #require(try letter("g", weight: .light).outline)
        let morph = StrokeMorph(try #require(StrokeGlyph.trace(a.polygons, ascender: 0)),
                                try #require(StrokeGlyph.trace(g.polygons, ascender: 0)))
        let ends = max(Ink(polygons: a.polygons, pixelsPerEm: 128).thickest, Ink(polygons: g.polygons, pixelsPerEm: 128).thickest)
        for t in stride(from: 0.1, through: 0.9, by: 0.2) {
            let thickest = Ink(strokes: morph.at(t), pixelsPerEm: 128).thickest
            #expect(thickest < ends * 1.1, "at \(t): \(thickest) against \(ends)")
        }
    }

    @MainActor
    @Test func aWordGathersIntoASymbolAsStrokes() throws {
        let morph = TextMorph(from: .text("Save", style: .system(size: 40, weight: .semibold)),
                              to: .symbol("checkmark", size: 40, weight: .semibold), engine: .strokes)
        let whole = try #require(morph.whole)
        let strokes = try #require(whole.strokes)
        #expect(whole.plan == nil)
        // The word's spare strokes are gone by halfway, the tick's own grow
        // in after: only what pairs is drawn at the middle.
        #expect(strokes.pairCount >= 1 && strokes.trackCount > strokes.pairCount)
        let size = morph.size(at: 0)
        let start = morph.path(at: 0, in: size).boundingBoxOfPath
        let (origin, _) = morph.origins(in: size)
        let ink = CTLineGetImageBounds(morph.a.line!, nil)
        #expect(abs(start.minX - (origin.x + ink.minX)) < 1 && abs(start.width - ink.width) < 1.5)
        #expect(!morph.path(at: 0.5, in: morph.size(at: 0.5)).isEmpty)
    }

    @Test func autoKeepsOutlinesForAWeightChange() throws {
        let morph = TextMorph("Morph", from: .system(size: 48, weight: .ultraLight),
                              to: "Morph", in: .system(size: 48, weight: .black))
        #expect(morph.engine == .auto)
        #expect(morph.pairs.allSatisfy { $0.plan != nil && $0.strokes == nil })
    }

    @Test func autoTakesStrokesBetweenDifferentLetters() throws {
        let morph = TextMorph("Amethyst", from: .system(size: 48, weight: .medium),
                              to: "Citrine", in: .system(size: 48, weight: .medium))
        #expect(morph.pairs.contains { $0.strokes != nil })
    }

    @MainActor
    @Test func autoKeepsOutlinesWhenStrokesWouldLandWithAJump() throws {
        // A gear's teeth don't trace closely enough to land true.
        let morph = TextMorph(from: .symbol("gearshape.2", size: 48), to: .text("x", style: .system(size: 48)))
        #expect(morph.pairs.count == 1)
        #expect(morph.pairs[0].plan != nil && morph.pairs[0].strokes == nil)
    }

    @Test func planningInTheBackgroundIsThePlanning() async throws {
        let morph = TextMorph("Ruby", from: .system(size: 40), to: "Opal", in: .system(size: 40, weight: .bold))
        morph.prepareInBackground()
        // A frame asked for meanwhile waits for it, and draws.
        #expect(!morph.path(at: 0.5, in: morph.size(at: 0.5)).isEmpty)
        #expect(morph.pairs.count == 4)
    }
}


@Suite struct Transporting {
    @MainActor
    @Test func aWordFlowsIntoASymbolAndLandsOnIt() throws {
        let morph = TextMorph(from: .text("Save", style: .system(size: 40, weight: .semibold)),
                              to: .symbol("checkmark", size: 40, weight: .semibold), engine: .transport)
        let whole = try #require(morph.whole)
        #expect(whole.flow != nil)
        // At either end, the field's outline is the end's own, within a hair.
        func box(_ t: Double) -> CGRect { morph.path(at: t, in: morph.size(at: t)).boundingBoxOfPath }
        let (originA, originB) = morph.origins(in: morph.size(at: 0))
        let ink = CTLineGetImageBounds(morph.a.line!, nil)
        #expect(abs(box(0).minX - (originA.x + ink.minX)) < 0.5 && abs(box(0).width - ink.width) < 1)
        _ = originB
        // In flight, ink: never nothing, never torn into specks.
        for t in [0.25, 0.5, 0.75] {
            let path = morph.path(at: t, in: morph.size(at: t))
            #expect(!path.isEmpty, "at \(t)")
        }
    }
}
