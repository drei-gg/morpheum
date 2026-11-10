import CoreText
import Foundation
import SwiftUI
import Testing
@testable import MorphText

@Suite struct Alignment {
    private func pairs(_ a: String, _ b: String) -> [String] {
        alignLetters(Array(a), Array(b)).map { i, j in
            let x = i.map { String(Array(a)[$0]) } ?? "_"
            let y = j.map { String(Array(b)[$0]) } ?? "_"
            return x + y
        }
    }

    // Expected pairs are what morphtext's Dart alignLetters gives.
    @Test func lettersMorphInPlaceOrKeepThemselves() {
        #expect(pairs("Amethyst", "Citrine") == ["AC", "mi", "e_", "tt", "hr", "yi", "sn", "te"])
        #expect(pairs("Ruby", "Rubies") == ["RR", "uu", "bb", "yi", "_e", "_s"])
    }

    @Test func aWordSlidesToKeepItsLetters() {
        #expect(pairs("Ruby", "bRuby") == ["_b", "RR", "uu", "bb", "yy"])
    }

    @Test func aLetterNeverMorphsIntoASpace() {
        #expect(!pairs("ab", "a ").contains("b "))
    }

    @Test func aWordGathersIntoOneGlyph() {
        let gathered = convergeLetters(Array("go on"), Array("→"))
        #expect(gathered.count == 5)
        #expect(gathered[2].0 == 2 && gathered[2].1 == nil)
        #expect(gathered.filter { $0.1 == 0 }.count == 4)
    }
}

@Suite struct Layout {
    @Test func everyLetterHasAPenAndAnOutline() {
        let layout = WordLayout("Hi o", style: MorphStyle.system(size: 40).geometry)
        #expect(layout.letters.map(\.character) == Array("Hi o"))
        #expect(layout.letters.allSatisfy { $0.pen != nil })
        #expect(layout.letters.map { $0.outline != nil } == [true, true, false, true])
        #expect(layout.letters[3].outline?.contourCount == 2)
        let pens = layout.letters.compactMap(\.pen)
        #expect(pens == pens.sorted())
        #expect(layout.baseline > 0 && layout.size.width > 0)
    }

    @Test func kerningWidensTheLine() {
        let tight = WordLayout("Morph", style: MorphStyle.system(size: 40).geometry)
        let loose = WordLayout("Morph", style: MorphStyle.system(size: 40, kerning: 10).geometry)
        #expect(abs(loose.size.width - tight.size.width - 50) < 0.5)
    }

    @Test func weightsHaveTheirOwnOutlines() throws {
        let light = WordLayout("o", style: MorphStyle.system(size: 40, weight: .ultraLight).geometry)
        let black = WordLayout("o", style: MorphStyle.system(size: 40, weight: .black).geometry)
        let thin = try #require(light.letters[0].outline).bounds
        let bold = try #require(black.letters[0].outline).bounds
        #expect(bold.width > thin.width)
    }

    @Test func outlinesSitOnTheBaselineInEms() throws {
        let layout = WordLayout("x", style: MorphStyle.system(size: 50).geometry)
        let bounds = try #require(layout.letters[0].outline).bounds
        // x rests on the baseline (y = 0) and rises about half an em.
        #expect(abs(bounds.maxY) < 0.02)
        #expect(bounds.minY < -0.4 && bounds.minY > -0.6)
    }
}

@Suite struct Morphing {
    @Test func theEndsMatchTheLines() throws {
        let morph = TextMorph("Light", from: .system(size: 48, weight: .ultraLight),
                              to: "Heavy", in: .system(size: 48, weight: .black))
        let size = CGSize(width: 300, height: 80)
        let start = morph.path(at: 0, in: size).boundingBoxOfPath
        let end = morph.path(at: 1, in: size).boundingBoxOfPath
        let (originA, originB) = morph.origins(in: size)
        let inkA = try lineInk(morph.a)
        let inkB = try lineInk(morph.b)
        #expect(abs(start.minX - (originA.x + inkA.minX)) < 0.5)
        #expect(abs(start.maxX - (originA.x + inkA.maxX)) < 0.5)
        #expect(abs(end.minX - (originB.x + inkB.minX)) < 0.5)
        #expect(abs(end.maxX - (originB.x + inkB.maxX)) < 0.5)
        #expect(morph.pairs.count == 5)
        #expect(morph.pairs.allSatisfy { $0.plan != nil })
    }

    @Test func aLongerWordGrowsItsExtraLetter() {
        let morph = TextMorph("Ruby", from: .system(size: 30), to: "Rubies", in: .system(size: 30))
        let alone = morph.pairs.filter { $0.from == nil }
        #expect(alone.count == 2)
        let size = morph.size(at: 0.5)
        #expect(size.width > morph.a.size.width && size.width < morph.b.size.width)
    }

    @Test func planningIsQuick() {
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            TextMorph("Morphing text", from: .system(size: 40, weight: .light),
                      to: "Into new words", in: .system(size: 40, weight: .heavy)).prepare()
        }
        // Thirteen letter pairs: about 25 ms optimised (on an Intel Mac VM);
        // a debug build is some twenty times slower.
        #if DEBUG
        let budget = Duration.seconds(3)
        #else
        let budget = Duration.milliseconds(150)
        #endif
        #expect(elapsed < budget, "planning took \(elapsed)")
    }

    /// The line's glyph ink, from its left edge and baseline, y down.
    private func lineInk(_ layout: WordLayout) throws -> CGRect {
        let ink = CTLineGetImageBounds(try #require(layout.line), nil)
        return CGRect(x: ink.minX, y: layout.baseline - ink.maxY, width: ink.width, height: ink.height)
    }
}
