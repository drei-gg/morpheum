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

    /// Field into field, experimental: each end is a distance field, the
    /// two are carried toward each other's place and size, what only the
    /// start has drains into the end and what only the end has fills in.
    /// Every frame is one clean outline, but the two ends read as overlaid
    /// rather than one becoming the other.
    case fields

    /// Ink as mass, carried the cheapest way from one shape to the other
    /// (optimal transport): each end sampled as grains, each grain's way to
    /// the other end planned, each end's outline warped along that flow, and
    /// one handed to the other as they meet. The start's letters slide and
    /// merge into the end: nothing is made or lost, so nothing is left to
    /// vanish or tear off. About 20 ms to plan and 2 to 5 ms a frame.
    case transport

    /// Each letter pair (or a word and a symbol, as one) as whichever morphs
    /// it best: outlines for the same letter at another weight (every
    /// counter kept) and a hollow shape filling in; transport for anything
    /// else: one letter into another, a word gathering into a symbol, art
    /// whose pieces don't pair up (a QR glyph into a logo).
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
    ///
    /// Flattened from its own curves, eight points a curve, as the Flutter
    /// package flattens a glyph: the tracer's thresholds were chosen on
    /// those. (The morph's evenly resampled contours trace differently: a
    /// C's spine splits at a spur that should have been pruned.)
    var polygons: [[Double]] {
        guard let exact = shape.exactContours, exact.count == shape.contours.count else {
            return shape.contours.map(\.points)
        }
        return exact.map { contour in
            let p = contour.points
            var out: [Double] = []
            out.reserveCapacity(contour.segmentCount * 16)
            for s in 0..<contour.segmentCount {
                let o = 6 * s
                for k in 0..<8 {
                    let t = Double(k) / 8, u = 1 - t
                    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
                    out.append(a * p[o] + b * p[o + 2] + c * p[o + 4] + d * p[o + 6])
                    out.append(a * p[o + 1] + b * p[o + 3] + c * p[o + 5] + d * p[o + 7])
                }
            }
            return out
        }
    }
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
