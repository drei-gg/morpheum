import CoreText
import SwiftUI

/// The morph from one line of text to another, letter by letter, outline
/// into outline: the engine behind `MorphText`, public for drawing it
/// anywhere (a `CAShapeLayer`, a `CGContext`, a custom renderer).
///
/// CoreText lays out both ends (kerning, fallback fonts, baseline and all)
/// and gives each letter's outline. Letters are paired by `alignLetters`;
/// each pair's contours are planned once, the first time a frame between
/// the ends is asked for, and kept.
///
/// Coordinates are points in a box of `size(at:)`, y down, each end centred
/// in it as it grows or shrinks.
public final class TextMorph {
    /// One letter of the start becoming one of the end. Either may be
    /// missing, for a letter that shrinks away or grows in.
    struct Pair {
        let from: Int?
        let to: Int?
        /// Nil for a letter with no outline (a space), or one that couldn't
        /// be planned.
        let plan: MorphOutlinePlan?
    }

    let a: WordLayout
    let b: WordLayout
    private var _pairs: [Pair]?

    /// The morph from `text` in `from` to `toText` in `to`.
    public convenience init(_ text: String, from: MorphStyle, to toText: String, in to: MorphStyle) {
        self.init(WordLayout(text, style: from.geometry), WordLayout(toText, style: to.geometry))
    }

    init(_ a: WordLayout, _ b: WordLayout) {
        self.a = a
        self.b = b
    }

    /// The start's text.
    public var fromText: String { a.text }
    /// The end's text.
    public var toText: String { b.text }

    /// The box at `t`: each end's line size, between them.
    public func size(at t: Double) -> CGSize {
        let t = CGFloat(min(max(t, 0), 1))
        return CGSize(
            width: a.size.width + (b.size.width - a.size.width) * t,
            height: a.size.height + (b.size.height - a.size.height) * t
        )
    }

    /// Each letter pair, planned on first use.
    var pairs: [Pair] {
        if let _pairs { return _pairs }
        let pairs = alignLetters(a.letters.map(\.character), b.letters.map(\.character)).map { i, j in
            let outlineA = i.flatMap { a.letters[$0].outline }
            let outlineB = j.flatMap { b.letters[$0].outline }
            // Alone, a letter morphs into itself, and the box shrinks or grows it.
            let plan: MorphOutlinePlan? = switch (i, j) {
            case (.some, .some): outlineA.flatMap { x in outlineB.flatMap { try? MorphOutlinePlan(from: x, to: $0) } }
            case (.some, nil): outlineA.flatMap { try? MorphOutlinePlan(from: $0, to: $0) }
            case (nil, .some): outlineB.flatMap { try? MorphOutlinePlan(from: $0, to: $0) }
            case (nil, nil): nil
            }
            return Pair(from: i, to: j, plan: plan)
        }
        _pairs = pairs
        return pairs
    }

    /// Plans every pair now rather than on the first frame between the ends.
    public func prepare() { _ = pairs }

    /// Where each end's line sits in a box of `size`: its top left.
    func origins(in size: CGSize) -> (a: CGPoint, b: CGPoint) {
        (centred(a.size, in: size), centred(b.size, in: size))
    }

    /// The letters' outlines at `t`, morphed and carried from their places
    /// in one line to their places in the other, in a box of `size`. Fill
    /// with the non-zero rule.
    ///
    /// Letters with no outline to morph (spaces, colour emoji) aren't in it;
    /// `MorphText` draws those as text.
    public func path(at t: Double, in size: CGSize) -> CGPath {
        let path = CGMutablePath()
        let (originA, originB) = origins(in: size)
        let pairs = self.pairs
        for k in pairs.indices {
            let pair = pairs[k]
            guard let plan = pair.plan, let placement = placement(k, pair, t, originA, originB) else { continue }
            var output = plan.allocateOutput()
            plan.interpolate(t, into: &output)
            let transform = CGAffineTransform(
                a: placement.em, b: 0, c: 0, d: placement.em,
                tx: placement.pen.x, ty: placement.pen.y
            )
            for points in output { addPolygon(points, to: path, transform: transform) }
        }
        return path
    }

    /// The letters with no outline, as (letter, font, pen on the baseline)
    /// at `t`: the nearer end's letter, carried between the two places.
    /// Spaces are left out.
    func lettersAsText(at t: Double, in size: CGSize) -> [(String, CTFont, CGPoint)] {
        let (originA, originB) = origins(in: size)
        let pairs = self.pairs
        return pairs.indices.compactMap { k in
            let pair = pairs[k]
            guard pair.plan == nil, let placement = placement(k, pair, t, originA, originB) else { return nil }
            let nearer = t < 0.5 ? pair.from.map { (a, $0) } : pair.to.map { (b, $0) }
            guard let (layout, index) = nearer else { return nil }
            let character = layout.letters[index].character
            if character.isWhitespace { return nil }
            return (String(character), layout.style.font, placement.pen)
        }
    }

    /// Where pair `k`'s letter is at `t`: its pen on the baseline and its em,
    /// each carried from one line's place to the other's. A letter missing
    /// from one end comes from (or goes to) a point at the next letter that
    /// is there; it is gone by halfway, or grows in from there, so it never
    /// lingers as small text beside the others. Nil when a line drew no glyph
    /// for it.
    private func placement(
        _ k: Int,
        _ pair: Pair,
        _ t: Double,
        _ originA: CGPoint,
        _ originB: CGPoint
    ) -> (pen: CGPoint, em: CGFloat)? {
        func end(_ layout: WordLayout, _ index: Int?, _ origin: CGPoint, start: Bool) -> (CGPoint, CGFloat)? {
            if let index {
                guard let pen = layout.letters[index].pen else { return nil }
                return (CGPoint(x: origin.x + pen, y: origin.y + layout.baseline), layout.letters[index].em)
            }
            let gap = next(k, layout, start: start)
            return (CGPoint(x: origin.x + gap.x, y: origin.y + gap.y), 0)
        }
        guard let (penA, emA) = end(a, pair.from, originA, start: true),
              let (penB, emB) = end(b, pair.to, originB, start: false) else { return nil }
        let along = CGFloat(
            pair.from == nil ? min(max((t - 0.5) * 2, 0), 1)
                : pair.to == nil ? min(max(t * 2, 0), 1)
                : t
        )
        return (
            CGPoint(x: penA.x + (penB.x - penA.x) * along, y: penA.y + (penB.y - penA.y) * along),
            emA + (emB - emA) * along
        )
    }

    /// Where, in `layout`, the letter of pair `k` would be if it were there:
    /// the place of the next letter that is, or the end of the line.
    private func next(_ k: Int, _ layout: WordLayout, start: Bool) -> CGPoint {
        let pairs = self.pairs
        for n in (k + 1)..<max(pairs.count, k + 1) {
            if let index = start ? pairs[n].from : pairs[n].to { return layout.gap(index) }
        }
        return layout.gap(layout.letters.count)
    }
}

/// Where something of `inner` size sits centred in `outer`.
func centred(_ inner: CGSize, in outer: CGSize) -> CGPoint {
    CGPoint(x: (outer.width - inner.width) / 2, y: (outer.height - inner.height) / 2)
}
