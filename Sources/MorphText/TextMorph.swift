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
        /// Nil for a letter with no outline (a space), one that couldn't be
        /// planned, or one drawn as strokes.
        let plan: MorphOutlinePlan?
        /// The morph between their strokes, when strokes draw it (in place of
        /// `plan`).
        var strokes: StrokeMorph? = nil
        /// The fields' morph, when fields draw it.
        var field: FieldMorph? = nil
        /// The transport morph, when it draws it.
        var flow: TransportMorph? = nil
        /// What the strokes miss of the start's letter (its corners), and of
        /// the end's: grown back as the morph leaves one and reaches the other.
        var cornersFrom = Corners.none, cornersTo = Corners.none
    }

    /// How a word and a single glyph morph as one: as outlines or as
    /// strokes, and what the strokes miss of each end.
    struct Whole {
        var plan: MorphOutlinePlan?
        var strokes: StrokeMorph?
        var field: FieldMorph?
        var flow: TransportMorph?
        var corners = (Corners.none, Corners.none)
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

    /// Whether stroke frames go through `cleanedInk` in flight. Off: it
    /// seals only gaps narrower than its radius, and the tears that show
    /// are wider.
    static let cleansStrokes = false

    /// Whether a stroke frame is drawn as one outline from its distance
    /// field (`strokeOutline`), seamless, rather than an outline a stroke.
    static let strokesAsOneOutline = true

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
            case (nil, nil): Pair(from: nil, to: nil, plan: nil)
            }
        }
        _pairs = pairs
        return pairs
    }

    /// One letter into another by `engine`: its outlines, or its strokes
    /// (outlines when it has no strokes to trace), or, for auto, whichever
    /// morphs it better. A letter alone shrinks or grows as its own outline,
    /// or its own strokes.
    private func letterPair(_ i: Int?, _ j: Int?, _ x: WordLayout.Letter, _ y: WordLayout.Letter,
                            engine: MorphEngine, alone: Bool = false) -> Pair {
        guard let outlineA = x.outline, let outlineB = y.outline else { return Pair(from: i, to: j, plan: nil) }
        func outlines() -> MorphOutlinePlan? { try? MorphOutlinePlan(from: outlineA, to: outlineB) }
        // Each end traced once (art has no font to keep its strokes by).
        var traced: (StrokeGlyph, StrokeGlyph)??
        func glyphs() -> (StrokeGlyph, StrokeGlyph)? {
            if let traced { return traced }
            let ga = StrokeCache.shared.glyph(x.strokeKey, outlineA)
            let gb = alone ? ga : StrokeCache.shared.glyph(y.strokeKey, outlineB)
            let both = ga.flatMap { a in gb.map { (a, $0) } }
            traced = .some(both)
            return both
        }
        func strokes() -> StrokeMorph? { glyphs().map { StrokeMorph($0.0, $0.1) } }
        func drawn(_ strokes: StrokeMorph) -> Pair {
            var pair = Pair(from: i, to: j, plan: nil, strokes: strokes)
            if !alone, let (ga, gb) = glyphs() {
                pair.cornersFrom = StrokeCache.shared.corners(x.strokeKey, outlineA, ga)
                pair.cornersTo = StrokeCache.shared.corners(y.strokeKey, outlineB, gb)
            }
            return pair
        }
        func transport() -> TransportMorph? {
            TransportMorph(from: outlineA.polygons, to: outlineB.polygons,
                           pixelsPerEm: pixelsPerEm(points: Double(max(x.em, y.em))))
        }
        func fields() -> Pair {
            if let field = FieldMorph(from: outlineA.polygons, to: outlineB.polygons) {
                var pair = Pair(from: i, to: j, plan: nil)
                pair.field = field
                return pair
            }
            return Pair(from: i, to: j, plan: outlines())
        }
        switch engine {
        case .outline:
            return Pair(from: i, to: j, plan: outlines())
        case .fields:
            return alone ? Pair(from: i, to: j, plan: outlines()) : fields()
        case .transport:
            if !alone, let flow = transport() {
                var pair = Pair(from: i, to: j, plan: nil)
                pair.flow = flow
                return pair
            }
            return Pair(from: i, to: j, plan: outlines())
        case .strokes:
            if let strokes = strokes() { return drawn(strokes) }
            return Pair(from: i, to: j, plan: outlines())
        case .auto:
            // Alone, or the same letter in the same family at another weight:
            // outlines keep its counters, and have every time it was measured.
            if alone || (x.character == y.character && x.family != nil && x.family == y.family) {
                return Pair(from: i, to: j, plan: outlines())
            }
            guard let plan = outlines() else { return Pair(from: i, to: j, plan: nil) }
            // A shape filling in or hollowing out, or a solid one: outlines
            // fill it in place.
            if keepsOutlines(outlineA.polygons, outlineB.polygons) { return Pair(from: i, to: j, plan: plan) }
            // Anything else (one letter into another, a letter in another
            // font, art whose pieces don't pair up) by transport: one clean
            // outline every frame, nothing matched, so nothing to tear or
            // seam. Strokes, the other way to morph unlike letters, tear
            // where their pieces part and seam where they meet.
            if let flow = transport() {
                var pair = Pair(from: i, to: j, plan: nil)
                pair.flow = flow
                return pair
            }
            return Pair(from: i, to: j, plan: plan)
        }
    }

    /// When a word gathers into a symbol (or a symbol opens into a word): the
    /// whole of each end as one outline, each letter where its line puts it,
    /// in units of the larger em from the end's top left. Nil otherwise, or
    /// when either end has nothing to draw.
    ///
    /// As outlines, or as strokes (by `engine`; for auto, whichever morphs it
    /// better: a word gathering into a solid shape fills in better as
    /// outlines).
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
            // A word gathering into a symbol, unless asked otherwise: by
            // transport, the word flows into it whole, nothing left to vanish.
            if let from = shape(a), let to = shape(b), engine == .transport || engine == .auto,
               let flow = TransportMorph(from: from.polygons, to: to.polygons, pixelsPerEm: pixelsPerEm(points: Double(unit))) {
                whole = Whole(plan: nil, strokes: nil, field: nil, flow: flow)
            } else if let from = shape(a), let to = shape(b), engine == .fields,
               let field = FieldMorph(from: from.polygons, to: to.polygons) {
                // A word gathering into a symbol: matching leaves most of the
                // word to vanish or trail off; fields flow it in whole.
                whole = Whole(plan: nil, strokes: nil, field: field)
            } else if let from = shape(a), let to = shape(b) {
                let plan = try? MorphOutlinePlan(from: from, to: to)
                var strokes: StrokeMorph?
                var corners = (Corners.none, Corners.none)
                // For auto, a word gathering into a solid shape (or one filling
                // in) fills in better as outlines: no need to trace it.
                if engine == .strokes || (engine == .auto && !keepsOutlines(from.polygons, to.polygons)),
                   let ga = StrokeGlyph.trace(from.polygons, ascender: 0),
                   let gb = StrokeGlyph.trace(to.polygons, ascender: 0) {
                    strokes = StrokeMorph(ga, gb, gather: true)
                    // One morph for the whole word, so it's worth judging by its
                    // frames.
                    if engine == .auto, let plan, let candidate = strokes,
                       !strokesWin(plan, candidate, from.polygons, to.polygons) {
                        strokes = nil
                    }
                    if let candidate = strokes {
                        corners = (Corners.of(from.polygons, ga), Corners.of(to.polygons, gb))
                        if engine == .auto, !landsTrue(candidate, corners, from.polygons, to.polygons) {
                            strokes = nil
                            corners = (Corners.none, Corners.none)
                        }
                    }
                }
                whole = strokes != nil ? Whole(plan: nil, strokes: strokes, corners: corners) : plan.map { Whole(plan: $0) }
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
        guard engine != .outline else { return }
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
        // The share of each end over which a letter drawn as strokes grows its
        // corners back, or loses them.
        let cornering = 0.2
        func ease(_ x: Double) -> Double { x * x * (3 - 2 * x) }
        let arriving = ease(min(max((t - (1 - cornering)) / cornering, 0), 1))
        let leaving = 1 - ease(min(max(t / cornering, 0), 1))
        // Strokes and the corners they miss, as one fill: discs wound as the
        // outlines' fills are, so overlaps add up.
        func add(_ polygons: [[Double]], origin: CGPoint, em: CGFloat) {
            let transform = CGAffineTransform(a: em, b: 0, c: 0, d: em, tx: origin.x, ty: origin.y)
            for points in polygons { addPolygon(points, to: path, transform: transform) }
        }
        // In flight, a stroke frame is cleaned: joins that pull apart sealed,
        // trailing hairlines taken out. Not at all at either end.
        let cleaning = Self.cleansStrokes ? sin(Double.pi * min(max(t, 0), 1)) : 0
        func draw(_ strokes: StrokeMorph, _ corners: (Corners, Corners), origin: CGPoint, em: CGFloat) {
            if Self.strokesAsOneOutline, t > 0, t < 1 {
                let lines = strokes.at(t)
                var pieces: [[Double]] = []
                for (c, grown, end) in [(corners.0, leaving, false), (corners.1, arriving, true)] where grown > 0 && !c.pieces.isEmpty {
                    let anchors = strokes.anchors(ObjectIdentifier(c), c.middles, end: end)
                    pieces += c.polygons(grown: grown) { n in strokes.drift(anchors[n].track, anchors[n].point, end: end) }
                }
                // The soft join between strokes fades in and out with the
                // flight: none at either end, where the ink is the letter's.
                let join = 0.03 * sin(Double.pi * t)
                add(strokeOutline(lines, pieces, join: join, pixelsPerEm: pixelsPerEm(points: Double(em))), origin: origin, em: em)
                return
            }
            if cleaning > 1e-3 {
                let lines = strokes.at(t)
                var pieces: [[Double]] = []
                for (c, grown, end) in [(corners.0, leaving, false), (corners.1, arriving, true)] where grown > 0 && !c.pieces.isEmpty {
                    let anchors = strokes.anchors(ObjectIdentifier(c), c.middles, end: end)
                    pieces += c.polygons(grown: grown) { n in strokes.drift(anchors[n].track, anchors[n].point, end: end) }
                }
                add(cleanedInk(lines, pieces, close: 0.03 * cleaning, open: 0.015 * cleaning), origin: origin, em: em)
                return
            }
            for line in strokes.at(t) { addStroke(path, line, origin: origin, scale: em) }
            // Each corner rides the stroke it belongs to.
            for (c, grown, end) in [(corners.0, leaving, false), (corners.1, arriving, true)] {
                if grown <= 0 || c.pieces.isEmpty { continue }
                let anchors = strokes.anchors(ObjectIdentifier(c), c.middles, end: end)
                c.add(to: path, origin: origin, size: em, grown: grown) { n in
                    strokes.drift(anchors[n].track, anchors[n].point, end: end)
                }
            }
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
            let unit = max(a.em, b.em)
            let origin = CGPoint(x: originA.x + (originB.x - originA.x) * t, y: originA.y + (originB.y - originA.y) * t)
            if let flow = whole.flow {
                add(flow.polygons(at: t), origin: origin, em: unit)
            } else if let field = whole.field {
                add(field.polygons(at: t), origin: origin, em: unit)
            } else if let strokes = whole.strokes {
                draw(strokes, whole.corners, origin: origin, em: unit)
            } else if let plan = whole.plan {
                var output = plan.allocateOutput()
                plan.interpolate(t, into: &output)
                let transform = CGAffineTransform(a: unit, b: 0, c: 0, d: unit, tx: origin.x, ty: origin.y)
                for points in output { addPolygon(points, to: path, transform: transform, spacing: 0.1) }
            }
            return path
        }
        let pairs = self.pairs
        for k in pairs.indices {
            let pair = pairs[k]
            guard let placement = placement(k, pair, t, originA, originB) else { continue }
            if let strokes = pair.strokes {
                draw(strokes, (pair.cornersFrom, pair.cornersTo), origin: placement.pen, em: placement.em)
                continue
            }
            if let field = pair.field {
                add(field.polygons(at: t), origin: placement.pen, em: placement.em)
                continue
            }
            if let flow = pair.flow {
                add(flow.polygons(at: t), origin: placement.pen, em: placement.em)
                continue
            }
            guard let plan = pair.plan else { continue }
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
        if a.qr != nil && b.qr != nil { return [] }
        if whole != nil { return [] }
        let (originA, originB) = origins(in: size)
        let pairs = self.pairs
        return pairs.indices.compactMap { k in
            let pair = pairs[k]
            guard pair.plan == nil, pair.strokes == nil, pair.field == nil, pair.flow == nil, let placement = placement(k, pair, t, originA, originB) else { return nil }
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
