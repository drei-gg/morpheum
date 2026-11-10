import CoreText
import SwiftUI

/// How shapes change in flight: one of the built-in engines, `auto` to pick
/// among them, or one of your own (`custom`).
///
/// ```swift
/// MorphBetween(from: send, to: plane, progress: t)
///     .morphEngine(.transport)
/// ```
public struct MorphEngine: Hashable, @unchecked Sendable {
    // @unchecked: a custom engine's maker is the caller's to make safe to
    // call from a background queue (where planning runs).

    /// What a custom engine is told about the morph it plans.
    public struct Context: Sendable {
        /// How many points an em of the outlines is on screen: how finely
        /// it's worth sampling them.
        public let pointsPerEm: Double
        /// Whether it's a whole word gathering into a single glyph (a symbol,
        /// a shape) or opening out of one, as one outline, rather than one
        /// letter into another.
        public let gathering: Bool
    }

    enum BuiltIn: Hashable { case outline, strokes, fields, transport, auto }

    /// Its name: equal names are the same engine.
    public let name: String
    let builtIn: BuiltIn?
    let make: (@Sendable (MorphOutline, MorphOutline, Context) -> (any Morpher)?)?

    public static func == (lhs: MorphEngine, rhs: MorphEngine) -> Bool { lhs.name == rhs.name }
    public func hash(into hasher: inout Hasher) { hasher.combine(name) }

    /// Outline into outline: morphnext's engine pairs the points around each
    /// letter's outline with the other's. Exact at both ends, every counter
    /// kept through a weight change, and a lively scatter between two icons;
    /// between two different letters a stroke's sides can drift apart, and
    /// pieces with no partner shrink away almost at once.
    public static let outline = MorphEngine(name: "outline", builtIn: .outline, make: nil)

    /// Ink as mass, carried the cheapest way from one shape to the other
    /// (optimal transport): each end sampled as grains, each grain's way to
    /// the other end planned, each end's outline warped along that flow, and
    /// one handed to the other as they meet. The start's letters slide and
    /// merge into the end: nothing is made or lost, so nothing is left to
    /// vanish or tear off. About 20 ms to plan and 2 to 5 ms a frame.
    public static let transport = MorphEngine(name: "transport", builtIn: .transport, make: nil)

    /// Stroke into stroke, experimental: each letter traced to its
    /// centrelines, a width at every point, each stroke bending and thinning
    /// into its partner, serifs riding their stems; drawn as one outline a
    /// frame. A calligraphic look between letters; a stroke that grows in
    /// can part from its letter for a frame or two.
    public static let strokes = MorphEngine(name: "strokes", builtIn: .strokes, make: nil)

    /// Field into field, experimental: what only the start has drains into
    /// the end, what only the end has fills in. Every frame is one clean
    /// outline, but the two ends read as overlaid rather than one becoming
    /// the other.
    public static let fields = MorphEngine(name: "fields", builtIn: .fields, make: nil)

    /// Each letter pair (or a word and a symbol, as one) as whichever morphs
    /// it best: outlines for the same letter at another weight (every
    /// counter kept) and a hollow shape filling in; transport for anything
    /// else: one letter into another, a word gathering into a symbol, art
    /// whose pieces don't pair up (a QR glyph into a logo). Two QR codes
    /// morph module by module, whatever the engine.
    public static let auto = MorphEngine(name: "auto", builtIn: .auto, make: nil)

    /// An engine of your own, called `name`: `make` plans the morph between
    /// two outlines (in ems, y down, in one frame) and returns a `Morpher`
    /// that draws any frame of it, or nil to fall back to outlines. It runs
    /// once per letter pair (or once for a word gathering into a symbol),
    /// maybe on a background queue.
    public static func custom(
        _ name: String,
        _ make: @escaping @Sendable (_ from: MorphOutline, _ to: MorphOutline, _ context: Context) -> (any Morpher)?
    ) -> MorphEngine {
        MorphEngine(name: name, builtIn: nil, make: make)
    }
}

/// One morph between two shapes, planned once, that draws any frame of
/// itself: what an engine makes. Conform to it to write an engine of your
/// own (`MorphEngine.custom`).
///
/// A frame is asked for from one thread at a time, so a morpher may keep
/// buffers between frames.
public protocol Morpher: AnyObject {
    /// The shape at `t` (0 the start, 1 the end; a spring may carry it a
    /// little past either) as closed polygons, each interleaved x, y, in the
    /// ems the outlines were given in, filled non-zero. At 0 and 1 it should
    /// be each end's own outline, so the text that takes over at rest lands
    /// on it without a step.
    func polygons(at t: Double) -> [[Double]]
}

/// The outline engine as a `Morpher`.
final class OutlineMorpher: Morpher {
    let plan: MorphOutlinePlan
    private var output: [[Double]]
    init(_ plan: MorphOutlinePlan) {
        self.plan = plan
        output = plan.allocateOutput()
    }
    func polygons(at t: Double) -> [[Double]] {
        plan.interpolate(t, into: &output)
        return output
    }
}

/// The strokes engine as a `Morpher`: the strokes and the corners they
/// miss, drawn as one outline.
final class StrokeMorpher: Morpher {
    let morph: StrokeMorph
    let corners: (Corners, Corners)
    /// Field samples to the em.
    let samples: Double
    init(_ morph: StrokeMorph, corners: (Corners, Corners), pointsPerEm: Double) {
        self.morph = morph
        self.corners = corners
        samples = pixelsPerEm(points: pointsPerEm)
    }
    func polygons(at t: Double) -> [[Double]] {
        // The share of each end over which the corners grow back, or go.
        let cornering = 0.2
        func ease(_ x: Double) -> Double { x * x * (3 - 2 * x) }
        let arriving = ease(min(max((t - (1 - cornering)) / cornering, 0), 1))
        let leaving = 1 - ease(min(max(t / cornering, 0), 1))
        let lines = morph.at(t)
        var pieces: [[Double]] = []
        for (c, grown, end) in [(corners.0, leaving, false), (corners.1, arriving, true)] where grown > 0 && !c.pieces.isEmpty {
            let anchors = morph.anchors(ObjectIdentifier(c), c.middles, end: end)
            pieces += c.polygons(grown: grown) { n in self.morph.drift(anchors[n].track, anchors[n].point, end: end) }
        }
        // Strokes join softly in flight, not at all at either end.
        let join = 0.03 * sin(Double.pi * min(max(t, 0), 1))
        return strokeOutline(lines, pieces, join: join, pixelsPerEm: samples)
    }
}

extension TransportMorph: Morpher {}
extension FieldMorph: Morpher {}
extension QRMorph: Morpher {}

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
    /// non-zero (holes wound against their outlines): what an engine reads.
    ///
    /// Flattened from its own curves, eight points a curve, as the Flutter
    /// package flattens a glyph: the tracer's thresholds were chosen on
    /// those. (The morph's evenly resampled contours trace differently: a
    /// C's spine splits at a spur that should have been pruned.)
    public var polygons: [[Double]] {
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
