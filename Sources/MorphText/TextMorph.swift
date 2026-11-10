import CoreText
import SwiftUI

/// The morph from one line of text to another, letter by letter, outline
/// into outline, or between text and an SF Symbol: the engine behind
/// `MorphText` and `MorphBetween`, public for drawing it anywhere (a
/// `CAShapeLayer`, a `CGContext`, a custom renderer).
///
/// CoreText lays out both ends (kerning, fallback fonts, baseline and all)
/// and gives each letter's outline. Letters are paired by `alignLetters`;
/// each pair's contours are planned once, the first time a frame between
/// the ends is asked for, and kept.
///
/// With a symbol at one end and a word at the other, the whole word and the
/// symbol morph as one shape instead, each letter's outline from its place
/// in the word. (One shape, not a copy of the symbol per letter: copies
/// drifting apart would cover each other's holes.)
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
    /// Whether a single glyph at one end (a symbol) gathers every letter of
    /// the other.
    let converge: Bool
    private var _pairs: [Pair]?
    private var _whole: MorphOutlinePlan??

    /// The morph from `text` in `from` to `toText` in `to`.
    public convenience init(_ text: String, from: MorphStyle, to toText: String, in to: MorphStyle) {
        self.init(WordLayout(text, style: from.geometry), WordLayout(toText, style: to.geometry))
    }

    /// The morph from `from` to `to`, text or symbols, for a screen of
    /// `displayScale` pixels per point (where a symbol's pixels fall).
    @MainActor
    public convenience init(from: MorphContent, to: MorphContent, displayScale: CGFloat = 2) {
        self.init(from: from.kind, to: to.kind, scale: displayScale)
    }

    @MainActor
    convenience init(from: MorphContent.Kind, to: MorphContent.Kind, scale: CGFloat) {
        let symbol = { (kind: MorphContent.Kind) in if case .symbol = kind { true } else { false } }
        self.init(from.layout(scale: scale), to.layout(scale: scale), converge: symbol(from) || symbol(to))
    }

    init(_ a: WordLayout, _ b: WordLayout, converge: Bool = false) {
        self.a = a
        self.b = b
        self.converge = converge
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
        let characters = (a.letters.map(\.character), b.letters.map(\.character))
        let aligned = converge ? convergeLetters(characters.0, characters.1) : alignLetters(characters.0, characters.1)
        let pairs = aligned.map { i, j in
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

    /// When a word gathers into a symbol (or a symbol opens into a word): the
    /// whole of each end as one outline, each letter where its line puts it,
    /// in units of the larger em from the end's top left. Nil otherwise, or
    /// when either end has nothing to draw.
    var whole: MorphOutlinePlan? {
        if let _whole { return _whole }
        var plan: MorphOutlinePlan?
        if converge, (a.letters.count == 1) != (b.letters.count == 1) {
            let unit = max(a.em, b.em)
            func shape(_ layout: WordLayout) -> MorphOutline? {
                let parts = layout.letters.compactMap { letter -> MorphOutline? in
                    guard let pen = letter.pen, let outline = letter.outline else { return nil }
                    return outline.placed(at: CGPoint(x: pen / unit, y: layout.baseline / unit), scale: letter.em / unit)
                }
                return (try? MorphOutline.combine(parts)) ?? nil
            }
            if let from = shape(a), let to = shape(b) {
                plan = try? MorphOutlinePlan(from: from, to: to)
            }
        }
        _whole = .some(plan)
        return plan
    }

    /// Plans every pair now rather than on the first frame between the ends.
    public func prepare() {
        _ = pairs
        _ = whole
    }

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
        if let whole {
            // One shape, carried from one end's place in the box to the other's.
            let unit = max(a.em, b.em)
            var output = whole.allocateOutput()
            whole.interpolate(t, into: &output)
            let transform = CGAffineTransform(
                a: unit, b: 0, c: 0, d: unit,
                tx: originA.x + (originB.x - originA.x) * t,
                ty: originA.y + (originB.y - originA.y) * t
            )
            for points in output { addPolygon(points, to: path, transform: transform, spacing: 0.1) }
            return path
        }
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
            for points in output { addPolygon(points, to: path, transform: transform, spacing: 0.1) }
        }
        return path
    }

    /// The letters with no outline, as (letter, font, pen on the baseline)
    /// at `t`: the nearer end's letter, carried between the two places.
    /// Spaces are left out.
    func lettersAsText(at t: Double, in size: CGSize) -> [(String, CTFont, CGPoint)] {
        if whole != nil { return [] }
        let (originA, originB) = origins(in: size)
        let pairs = self.pairs
        return pairs.indices.compactMap { k in
            let pair = pairs[k]
            guard pair.plan == nil, let placement = placement(k, pair, t, originA, originB) else { return nil }
            let nearer = t < 0.5 ? pair.from.map { (a, $0) } : pair.to.map { (b, $0) }
            guard let (layout, index) = nearer else { return nil }
            let character = layout.letters[index].character
            guard !character.isWhitespace, let style = layout.style else { return nil }
            return (String(character), style.font, placement.pen)
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
