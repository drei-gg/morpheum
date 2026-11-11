import CoreText
import SwiftUI

/// Text that morphs letter by letter, outline into outline, from `text` in
/// `from` at progress 0 to `toText` in `to` at progress 1: weight, size,
/// letter spacing, one font into another, one word into another, as one
/// shape.
///
/// At 0 and 1 it is plain text, drawn by CoreText. Between, each letter's
/// outline morphs into its partner's, carried from its place in one line to
/// its place in the other.
///
/// `progress` animates: change it inside `withAnimation` (a spring may
/// overshoot either end a little, and the outlines follow), or drive it from
/// a gesture, a scroll position or a transition.
///
/// ```swift
/// MorphText("Light", toText: "Heavy",
///           from: .system(size: 48, weight: .ultraLight),
///           to: .system(size: 48, weight: .black),
///           progress: on ? 1 : 0)
///     .animation(.spring, value: on)
/// ```
///
/// For SF Symbols at either end, see `MorphBetween`.
public struct MorphText: View {
    /// The text at progress 0.
    public var text: String
    /// The text at progress 1.
    public var toText: String
    /// The style at progress 0.
    public var from: MorphStyle
    /// The style at progress 1.
    public var to: MorphStyle
    /// How far from `from` to `to`.
    public var progress: Double

    /// The morph from `text` in `from` to `toText` (the same text when nil)
    /// in `to`, at `progress`.
    public init(
        _ text: String,
        toText: String? = nil,
        from: MorphStyle,
        to: MorphStyle,
        progress: Double
    ) {
        self.text = text
        self.toText = toText ?? text
        self.from = from
        self.to = to
        self.progress = progress
    }

    // Not Animatable itself: the MorphBetween inside animates `progress`.
    public var body: some View {
        MorphBetween(from: .text(text, style: from), to: .text(toText, style: to), progress: progress)
    }
}

/// `from` at progress 0 morphing into `to` at progress 1, outline into
/// outline: text into text (as `MorphText`), a word into an SF Symbol or a
/// shape of your own, or one symbol or shape into another.
///
/// When one end is a single symbol or shape and the other a word, the whole
/// word and the symbol morph as one shape, each letter from its place in the
/// word.
///
/// At exactly 0 and 1 it draws `from` or `to` as they are: text as CoreText
/// draws it, a symbol or a shape as its outline filled, exactly where the
/// morph's last frame put them.
///
/// ```swift
/// MorphBetween(from: .text("Send", style: .system(size: 28, weight: .semibold)),
///              to: .symbol("paperplane.fill", size: 28, weight: .semibold),
///              progress: sent ? 1 : 0)
/// ```
public struct MorphBetween: View, Animatable {
    /// What shows at progress 0.
    public var from: MorphContent
    /// What shows at progress 1.
    public var to: MorphContent
    /// How far from `from` to `to`.
    public var progress: Double

    /// Where `AnimatedMorph` reads the progress drawn mid-animation.
    private let shown: ShownProgress?

    @State private var store = TextMorphStore()
    @Environment(\.displayScale) private var displayScale
    @Environment(\.morphEngine) private var engine

    /// The morph from `from` to `to`, at `progress`.
    public init(from: MorphContent, to: MorphContent, progress: Double) {
        self.init(from: from, to: to, progress: progress, shown: nil)
    }

    init(from: MorphContent, to: MorphContent, progress: Double, shown: ShownProgress?) {
        self.from = from
        self.to = to
        self.progress = progress
        self.shown = shown
    }

    nonisolated public var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    public var body: some View {
        let morph = store.morph(from.kind, to.kind, scale: displayScale, engine: engine)
        // A spring may carry it a quarter past either end; anything further
        // is that end.
        let raw = progress.isFinite ? progress : 0
        let t = raw < -0.25 ? 0 : raw > 1.25 ? 1 : raw
        // A view builder takes declarations, not statements.
        let _ = shown.map { $0.value = t }
        let size = morph.size(at: t)
        let colors = (from.color, to.color)
        let label = t < 0.5 ? from.label : to.label
        // A symbol at rest is its own outline filled, not `Image(systemName:)`:
        // SwiftUI places an image's pixels by up to 3/4 of a point
        // differently depending on where it sits, so swapping to one as the
        // morph lands moved the symbol with a visible step.
        Canvas(rendersAsynchronously: false) { context, box in
            drawMorph(morph, at: t, colors: colors, in: &context, size: box)
        }
        .frame(width: size.width, height: size.height)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityHidden(label.isEmpty)
    }
}

/// Keeps one view's morph while its ends stay the same (colours aside).
@MainActor
final class TextMorphStore {
    private var morph: TextMorph?
    private var key: (MorphContent.Kind, MorphContent.Kind, CGFloat, MorphEngine)?

    func morph(_ from: MorphContent.Kind, _ to: MorphContent.Kind, scale: CGFloat, engine: MorphEngine) -> TextMorph {
        if let morph, let key, key == (from, to, scale, engine) { return morph }
        let morph = TextMorph(from: from, to: to, scale: scale, engine: engine)
        // Usually built at rest, a moment before it moves.
        morph.prepareInBackground()
        self.morph = morph
        key = (from, to, scale, engine)
        return morph
    }
}

/// Draws `morph` at `t` into `context`: the nearer end as it is at either
/// end, the morphed outlines between.
@MainActor
func drawMorph(
    _ morph: TextMorph,
    at t: Double,
    colors: (Color, Color),
    in context: inout GraphicsContext,
    size: CGSize
) {
    let resolvedA = colors.0.resolve(in: context.environment)
    let resolvedB = colors.1.resolve(in: context.environment)
    let within = Float(min(max(t, 0), 1))
    let color = Color.Resolved(
        red: resolvedA.red + (resolvedB.red - resolvedA.red) * within,
        green: resolvedA.green + (resolvedB.green - resolvedA.green) * within,
        blue: resolvedA.blue + (resolvedB.blue - resolvedA.blue) * within,
        opacity: resolvedA.opacity + (resolvedB.opacity - resolvedA.opacity) * within
    )
    // As it is only exactly at an end: a spring passes through and back past
    // either end, and the outlines follow it there (up to a quarter), rather
    // than flicking to text and back.
    if t == 0 || t == 1 {
        let end = t == 1 ? morph.b : morph.a
        let origin = centred(end.size, in: size)
        if let line = end.line {
            context.withCGContext { cg in
                drawLine(line, at: CGPoint(x: origin.x, y: origin.y + end.baseline), color: color.cgColor, in: cg)
            }
        } else if let vector = end.vector {
            var placed = CGAffineTransform(translationX: origin.x, y: origin.y)
            if let path = vector.copy(using: &placed) {
                context.fill(Path(path), with: .color(Color(color)))
            }
        }
        return
    }
    context.fill(Path(morph.path(at: t, in: size)), with: .color(Color(color)))
    let loose = morph.lettersAsText(at: t, in: size)
    if !loose.isEmpty {
        context.withCGContext { cg in
            for (letter, font, pen) in loose {
                let line = WordLayout.line(letter, style: .init(font: font, kerning: 0))
                drawLine(line, at: pen, color: color.cgColor, in: cg)
            }
        }
    }
}

/// Draws `line` with its baseline's left end at `pen`, in a y-down context.
///
/// Exactly where the morph's outlines would be, so it lands without a step:
/// glyphs placed at their fractional positions, not rounded to the pixel
/// (which moved a word by up to a pixel as the text took over), and no
/// macOS font smoothing (which drew it some 7% heavier than its outline).
func drawLine(_ line: CTLine, at pen: CGPoint, color: CGColor, in cg: CGContext) {
    cg.saveGState()
    cg.setShouldSmoothFonts(false)
    cg.setAllowsFontSubpixelPositioning(true)
    cg.setShouldSubpixelPositionFonts(true)
    cg.setAllowsFontSubpixelQuantization(true)
    cg.setShouldSubpixelQuantizeFonts(false)
    cg.setFillColor(color)
    cg.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    cg.textPosition = pen
    CTLineDraw(line, cg)
    cg.restoreGState()
}

#Preview("Light into Heavy") {
    @Previewable @State var on = false
    VStack(spacing: 24) {
        MorphText(
            "Light",
            toText: "Heavy",
            from: .system(size: 56, weight: .ultraLight),
            to: .system(size: 56, weight: .black),
            progress: on ? 1 : 0
        )
        Button(on ? "Back" : "Morph") {
            withAnimation(.spring(duration: 0.6)) { on.toggle() }
        }
    }
    .padding(40)
}

#Preview("Send into a paper plane") {
    @Previewable @State var sent = false
    MorphBetween(
        from: .text("Send", style: .system(size: 40, weight: .semibold, color: .blue)),
        to: .symbol("paperplane.fill", size: 40, weight: .semibold, color: .blue),
        progress: sent ? 1 : 0
    )
    .onTapGesture { withAnimation(.spring(duration: 0.6)) { sent.toggle() } }
    .padding(40)
}
