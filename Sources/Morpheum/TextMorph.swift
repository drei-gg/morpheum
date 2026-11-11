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
///
/// Planning (`prepare()`) may run on any thread, once; draw a frame from
/// one thread at a time.
public final class TextMorph: @unchecked Sendable {
    // @unchecked: planning holds `lock`; drawing is one thread's at a time.
    /// One letter of the start becoming one of the end. Either may be
    /// missing, for a letter that shrinks away or grows in.
    struct Pair {
        let from: Int?
        let to: Int?
        /// Its morph; nil for a letter with no outline (a space), or one that
        /// couldn't be planned.
        let morpher: (any Morpher)?

        var plan: MorphOutlinePlan? { (morpher as? OutlineMorpher)?.plan }
        var strokes: StrokeMorph? { (morpher as? StrokeMorpher)?.morph }
        var flow: TransportMorph? { morpher as? TransportMorph }
        var field: FieldMorph? { morpher as? FieldMorph }
    }

    /// A word and a single glyph morphing as one.
    struct Whole {
        let morpher: any Morpher

        var plan: MorphOutlinePlan? { (morpher as? OutlineMorpher)?.plan }
        var strokes: StrokeMorph? { (morpher as? StrokeMorpher)?.morph }
        var corners: (Corners, Corners) { (morpher as? StrokeMorpher)?.corners ?? (Corners.none, Corners.none) }
        var flow: TransportMorph? { morpher as? TransportMorph }
        var field: FieldMorph? { morpher as? FieldMorph }
    }

    let a: WordLayout
    let b: WordLayout
    /// Whether a single glyph at one end (a symbol, a shape) gathers every
    /// letter of the other.
    let converge: Bool
    /// How letters change shape.
    public let engine: MorphEngine
    private var _pairs: [Pair]?
    private var _whole: Whole??
    private let lock = NSRecursiveLock()

    /// The morph from `text` in `from` to `toText` in `to`.
    public convenience init(_ text: String, from: MorphStyle, to toText: String, in to: MorphStyle,
                            engine: MorphEngine = .auto) {
        self.init(WordLayout(text, style: from.geometry), WordLayout(toText, style: to.geometry), engine: engine)
    }

    /// The morph from `from` to `to`, text or symbols, for a screen of
    /// `displayScale` pixels per point (where a symbol's pixels fall).
    @MainActor
    public convenience init(from: MorphContent, to: MorphContent, displayScale: CGFloat = 2,
                            engine: MorphEngine = .auto) {
        self.init(from: from.kind, to: to.kind, scale: displayScale, engine: engine)
    }

    @MainActor
    convenience init(from: MorphContent.Kind, to: MorphContent.Kind, scale: CGFloat, engine: MorphEngine = .auto) {
        self.init(from.layout(scale: scale), to.layout(scale: scale), converge: from.isGlyph || to.isGlyph,
                  engine: engine)
    }

    init(_ a: WordLayout, _ b: WordLayout, converge: Bool = false, engine: MorphEngine = .auto) {
        self.a = a
        self.b = b
        self.converge = converge
        self.engine = engine
    }

    /// Whether a word gathers into a single glyph here (or one opens into
    /// a word), as one shape.
    var gathers: Bool { converge && (a.letters.count == 1) != (b.letters.count == 1) }

    /// Between two QR codes, module by module, whatever the engine: planned
    /// on first use.
    private lazy var qrMorph: QRMorph? = {
        guard let qa = a.qr, let qb = b.qr else { return nil }
        return QRMorph(from: qa, to: qb)
    }()

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
        lock.lock()
        defer { lock.unlock() }
        if let _pairs { return _pairs }
        let characters = (a.letters.map(\.character), b.letters.map(\.character))
        let aligned = converge ? convergeLetters(characters.0, characters.1) : alignLetters(characters.0, characters.1)
        // A word gathering into a glyph morphs as one (`whole`); its letters
        // only stand in until then, as outlines.
        let engine = gathers ? .outline : self.engine
        let pairs = aligned.map { i, j in
            // Alone, a letter morphs into itself, and the box shrinks or grows it.
            switch (i, j) {
            case let (i?, j?): letterPair(i, j, a.letters[i], b.letters[j], engine: engine)
            case let (i?, nil): letterPair(i, nil, a.letters[i], a.letters[i], engine: engine, alone: true)
            case let (nil, j?): letterPair(nil, j, b.letters[j], b.letters[j], engine: engine, alone: true)
            case (nil, nil): Pair(from: nil, to: nil, morpher: nil)
            }
        }
        _pairs = pairs
        return pairs
    }

    /// One letter into another by `engine` (for auto, whichever morphs it
    /// best). A letter alone shrinks or grows as its own outline (or its own
    /// strokes); an engine that can't plan a pair falls back to outlines.
    private func letterPair(_ i: Int?, _ j: Int?, _ x: WordLayout.Letter, _ y: WordLayout.Letter,
                            engine: MorphEngine, alone: Bool = false) -> Pair {
        func pair(_ morpher: (any Morpher)?) -> Pair { Pair(from: i, to: j, morpher: morpher) }
        guard let outlineA = x.outline, let outlineB = y.outline else { return pair(nil) }
        let points = Double(max(x.em, y.em))
        func outlines() -> OutlineMorpher? { (try? MorphOutlinePlan(from: outlineA, to: outlineB)).map(OutlineMorpher.init) }
        func transport() -> TransportMorph? {
            TransportMorph(from: outlineA.polygons, to: outlineB.polygons, pixelsPerEm: pixelsPerEm(points: points))
        }
        func strokes() -> StrokeMorpher? {
            // Each end traced once, kept by font and letter.
            guard let ga = StrokeCache.shared.glyph(x.strokeKey, outlineA),
                  let gb = alone ? ga : StrokeCache.shared.glyph(y.strokeKey, outlineB) else { return nil }
            let corners = alone ? (Corners.none, Corners.none)
                : (StrokeCache.shared.corners(x.strokeKey, outlineA, ga), StrokeCache.shared.corners(y.strokeKey, outlineB, gb))
            return StrokeMorpher(StrokeMorph(ga, gb), corners: corners, pointsPerEm: points)
        }
        switch engine.builtIn {
        case .outline:
            return pair(outlines())
        case .fields:
            return pair(alone ? outlines() : FieldMorph(from: outlineA.polygons, to: outlineB.polygons) ?? outlines())
        case .ink:
            return pair(alone ? outlines() : transport() ?? outlines())
        case .strokes:
            return pair(strokes() ?? outlines())
        case nil:
            let context = MorphEngine.Context(pointsPerEm: points, gathering: false)
            return pair(alone ? outlines() : engine.make?(outlineA, outlineB, context) ?? outlines())
        case .auto:
            // Alone, or the same letter in the same family at another weight:
            // outlines keep its counters, and have every time it was measured.
            if alone || (x.character == y.character && x.family != nil && x.family == y.family) {
                return pair(outlines())
            }
            // A shape filling in or hollowing out, or a solid one: outlines
            // fill it in place.
            if keepsOutlines(outlineA.polygons, outlineB.polygons) { return pair(outlines()) }
            // Anything else (one letter into another, a letter in another
            // font, art whose pieces don't pair up) by transport: one clean
            // outline every frame, nothing matched, so nothing to tear or
            // seam.
            return pair(transport() ?? outlines())
        }
    }

    /// When a word gathers into a symbol (or a symbol opens into a word): the
    /// whole of each end as one outline, each letter where its line puts it,
    /// in units of the larger em from the end's top left, and the morph
    /// between them by `engine` (for auto, transport: the word flows into the
    /// symbol whole, nothing left to vanish). Nil otherwise, or when either
    /// end has nothing to draw.
    var whole: Whole? {
        lock.lock()
        defer { lock.unlock() }
        if let _whole { return _whole }
        var whole: Whole?
        if gathers {
            let unit = max(a.em, b.em)
            func shape(_ layout: WordLayout) -> MorphOutline? {
                let parts = layout.letters.compactMap { letter -> MorphOutline? in
                    guard let pen = letter.pen, let outline = letter.outline else { return nil }
                    return outline.placed(at: CGPoint(x: pen / unit, y: layout.baseline / unit), scale: letter.em / unit)
                }
                return (try? MorphOutline.combine(parts)) ?? nil
            }
            if let from = shape(a), let to = shape(b) {
                let points = Double(unit)
                func outlines() -> OutlineMorpher? { (try? MorphOutlinePlan(from: from, to: to)).map(OutlineMorpher.init) }
                let morpher: (any Morpher)? = switch engine.builtIn {
                case .outline: outlines()
                case .ink, .auto:
                    TransportMorph(from: from.polygons, to: to.polygons, pixelsPerEm: pixelsPerEm(points: points)) ?? outlines()
                case .fields: FieldMorph(from: from.polygons, to: to.polygons) ?? outlines()
                case .strokes:
                    {
                        guard let ga = StrokeGlyph.trace(from.polygons, ascender: 0),
                              let gb = StrokeGlyph.trace(to.polygons, ascender: 0) else { return outlines() }
                        return StrokeMorpher(StrokeMorph(ga, gb, gather: true),
                                             corners: (Corners.of(from.polygons, ga), Corners.of(to.polygons, gb)), pointsPerEm: points)
                    }()
                case nil: engine.make?(from, to, MorphEngine.Context(pointsPerEm: points, gathering: true)) ?? outlines()
                }
                whole = morpher.map(Whole.init)
            }
        }
        _whole = .some(whole)
        return whole
    }

    /// Plans every pair now rather than on the first frame between the ends.
    public func prepare() {
        lock.lock()
        defer { lock.unlock() }
        if qrMorph != nil { return }
        _ = whole
        _ = pairs
    }

    /// Plans every pair on a background queue, so a morph that starts later
    /// finds it done: tracing letters to strokes takes a few milliseconds a
    /// letter. A frame asked for meanwhile waits for it.
    public func prepareInBackground() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.prepare()
            self.warm()
        }
    }

    /// Traces each end's letters to strokes ahead of any morph that needs
    /// them (cached by font and letter): a morph that starts from this one's
    /// ends, an `AnimatedMorph` at rest changing to new content, then only
    /// pairs them, without tracing on the first frame.
    func warm() {
        guard engine == .strokes else { return }
        for letter in a.letters + b.letters {
            if let outline = letter.outline, letter.strokeKey != nil {
                _ = StrokeCache.shared.glyph(letter.strokeKey, outline)
            }
        }
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
        func add(_ polygons: [[Double]], origin: CGPoint, em: CGFloat) {
            let transform = CGAffineTransform(a: em, b: 0, c: 0, d: em, tx: origin.x, ty: origin.y)
            // A contour collapsing to a point piles its points into a pixel:
            // points a tenth of a point apart are dropped.
            for points in polygons { addPolygon(points, to: path, transform: transform, spacing: 0.1) }
        }
        lock.lock()
        let qr = qrMorph
        lock.unlock()
        if let qr {
            // Two QR codes: the unit square carried from one code's box to the
            // other's, growing or shrinking between their sizes.
            let side = a.size.width + (b.size.width - a.size.width) * CGFloat(min(max(t, 0), 1))
            let origin = CGPoint(x: originA.x + (originB.x - originA.x) * t, y: originA.y + (originB.y - originA.y) * t)
            add(qr.polygons(at: t), origin: origin, em: side)
            return path
        }
        if let whole {
            // One shape, carried from one end's place in the box to the other's.
            let origin = CGPoint(x: originA.x + (originB.x - originA.x) * t, y: originA.y + (originB.y - originA.y) * t)
            add(whole.morpher.polygons(at: t), origin: origin, em: max(a.em, b.em))
            return path
        }
        let pairs = self.pairs
        for k in pairs.indices {
            let pair = pairs[k]
            guard let morpher = pair.morpher, let placement = placement(k, pair, t, originA, originB) else { continue }
            add(morpher.polygons(at: t), origin: placement.pen, em: placement.em)
        }
        return path
    }

    /// The letters with no outline, as (letter, font, pen on the baseline)
    /// at `t`: the nearer end's letter, carried between the two places.
    /// Spaces are left out.
    func lettersAsText(at t: Double, in size: CGSize) -> [(String, CTFont, CGPoint)] {
        if a.qr != nil && b.qr != nil { return [] }
        if whole != nil { return [] }
        let (originA, originB) = origins(in: size)
        let pairs = self.pairs
        return pairs.indices.compactMap { k in
            let pair = pairs[k]
            guard pair.morpher == nil, let placement = placement(k, pair, t, originA, originB) else { return nil }
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
