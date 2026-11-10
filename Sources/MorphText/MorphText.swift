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
public struct MorphText: View, Animatable {
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

    @State private var store = TextMorphStore()

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

    nonisolated public var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    public var body: some View {
        let morph = store.morph(text, from.geometry, toText, to.geometry)
        // A spring may carry it a quarter past either end; anything further
        // is that end.
        let raw = progress.isFinite ? progress : 0
        let t = raw < -0.25 ? 0 : raw > 1.25 ? 1 : raw
        let size = morph.size(at: t)
        let colors = (from.color, to.color)
        Canvas(rendersAsynchronously: false) { context, box in
            drawMorph(morph, at: t, colors: colors, in: &context, size: box)
        }
        .frame(width: size.width, height: size.height)
        .accessibilityElement()
        .accessibilityLabel(t < 0.5 ? text : toText)
        .accessibilityAddTraits(.isStaticText)
    }
}

/// Keeps one view's morph while its text and fonts stay the same.
@MainActor
final class TextMorphStore {
    private var morph: TextMorph?
    private var key: (String, MorphStyle.Geometry, String, MorphStyle.Geometry)?

    func morph(
        _ text: String,
        _ from: MorphStyle.Geometry,
        _ toText: String,
        _ to: MorphStyle.Geometry
    ) -> TextMorph {
        if let morph, let key, key == (text, from, toText, to) { return morph }
        let morph = TextMorph(WordLayout(text, style: from), WordLayout(toText, style: to))
        self.morph = morph
        key = (text, from, toText, to)
        return morph
    }
}

/// Draws `morph` at `t` into `context`: the nearer end as plain text at
/// either end, the morphed outlines between.
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
    // Plain text only exactly at an end: a spring passes through and back
    // past either end, and the outlines follow it there (up to a quarter),
    // rather than flicking to text and back.
    if t == 0 || t == 1 {
        let end = t == 1 ? morph.b : morph.a
        let origin = centred(end.size, in: size)
        context.withCGContext { cg in
            drawLine(end.line, at: CGPoint(x: origin.x, y: origin.y + end.baseline), color: color.cgColor, in: cg)
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
func drawLine(_ line: CTLine, at pen: CGPoint, color: CGColor, in cg: CGContext) {
    cg.saveGState()
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
