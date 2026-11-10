import CoreText
import SwiftUI

/// How letters change shape in flight.
public enum MorphEngine: Sendable, Hashable {
    /// Outline into outline: morphnext's engine pairs the points around each
    /// letter's outline with the other's. Exact at both ends; between two
    /// different letters, the sides of a stroke can drift apart and the
    /// letter smears, far thicker than either end, and pieces with no
    /// partner (a word's spare letters gathering into a symbol) shrink away
    /// almost at once.
    case outline

    /// Stroke into stroke: each letter is traced to its centrelines, a width
    /// at every point, and each stroke bends, turns and thins into its
    /// partner along its length. Serifs ride the stems they hang from, pieces
    /// that meet stay met, and strokes passing alongside each other thin, so
    /// the ink in flight keeps to the thicker letter's weight. A stroke with
    /// no partner draws back into the stroke it joins, or out of it; a word
    /// gathering into a symbol does that in turn, the word's spare strokes
    /// over the first half, the symbol's over the second.
    case strokes

    /// Each letter pair (or a word and a symbol, as one) as whichever of
    /// `outline` and `strokes` morphs it better: strokes take a letter into
    /// a different one; outlines keep the counters of a weight change, and
    /// fill a hollow symbol in place. The same letter in another font is
    /// judged by measuring a few frames of each.
    case auto
}

extension EnvironmentValues {
    /// How `MorphText`, `MorphBetween` and `AnimatedMorph` change letters'
    /// shapes.
    @Entry public var morphEngine: MorphEngine = .auto
}

extension View {
    /// Sets how the morphs inside change letters' shapes.
    public func morphEngine(_ engine: MorphEngine) -> some View {
        environment(\.morphEngine, engine)
    }
}

/// Each letter traced to strokes, and what its strokes miss of it, by font
/// and letter: tracing is the slow part, and a letter is traced once
/// whatever it morphs into.
final class StrokeCache: @unchecked Sendable {
    // @unchecked: every access holds `lock`.
    static let shared = StrokeCache()

    private let lock = NSLock()
    private var glyphs: [String: StrokeGlyph?] = [:]
    private var corners: [String: Corners] = [:]
    private var order: [String] = []
    private let limit = 512

    /// `outline` (a letter of the font `face` names) traced to strokes, or
    /// nil when there's nothing to trace. Without a `face`, traced afresh.
    func glyph(_ face: String?, _ outline: MorphOutline) -> StrokeGlyph? {
        guard let face else { return StrokeGlyph.trace(outline.polygons, ascender: 0) }
        if let known = lock.withLock({ glyphs[face] }) { return known }
        let traced = StrokeGlyph.trace(outline.polygons, ascender: 0)
        lock.withLock {
            if glyphs[face] == nil { order.append(face) }
            glyphs[face] = .some(traced)
            if order.count > limit {
                let oldest = order.removeFirst()
                glyphs[oldest] = nil
                corners[oldest] = nil
            }
        }
        return traced
    }

    /// What `glyph`'s strokes miss of `outline` (its corners), kept for
    /// `face` as `glyph(_:_:)` is.
    func corners(_ face: String?, _ outline: MorphOutline, _ glyph: StrokeGlyph) -> Corners {
        guard let face else { return Corners.of(outline.polygons, glyph) }
        if let known = lock.withLock({ corners[face] }) { return known }
        let found = Corners.of(outline.polygons, glyph)
        lock.withLock { corners[face] = found }
        return found
    }
}

extension MorphOutline {
    /// The outline as closed polygons in ems, interleaved x, y, filled
    /// non-zero: what the stroke tracer and the judge read.
    var polygons: [[Double]] { shape.contours.map(\.points) }
}

/// A name for the font that draws a letter and the letter, to cache its
/// strokes by: the font's PostScript name and, for a variable font, where on
/// its axes.
func strokeCacheKey(_ font: CTFont, _ character: Character) -> String {
    let name = CTFontCopyPostScriptName(font) as String
    let variation = (CTFontCopyVariation(font) as? [NSNumber: NSNumber])
        .map { $0.sorted { $0.key.intValue < $1.key.intValue }.map { "\($0.key)=\($0.value)" }.joined(separator: ",") } ?? ""
    return "\(name)|\(variation)|\(character)"
}
