import SwiftUI

/// Content that morphs, outline into outline, to each new content it's given:
/// a word into another word or a symbol, a symbol into a word or another
/// symbol, any style into any other.
///
/// The implicit counterpart of `MorphBetween`, as `.animation` is to
/// `withAnimation`: change `content` and it morphs there, from whatever is on
/// screen.
///
/// - Turning back before it lands (the old content again) reverses from where
///   it is, keeping the spring's speed.
/// - A third content arriving mid-flight takes the place of whichever end is
///   further from what's shown, and the morph heads there.
/// - With Reduce Motion on, or a nil `animation`, changes apply at once.
///
/// At rest it is the content itself: text as CoreText draws it, a symbol as
/// `Image(systemName:)`. It sits happily inside a stock control:
///
/// ```swift
/// Button { save() } label: {
///     AnimatedMorph(saved ? .symbol("checkmark", size: 17, weight: .semibold)
///                         : .text("Save", style: .system(size: 17, weight: .semibold)))
/// }
/// .buttonStyle(.borderedProminent)
/// ```
public struct AnimatedMorph: View {
    /// What to show, and to morph into when it changes.
    public var content: MorphContent
    /// How each morph runs; nil for `AnimatedMorph.defaultAnimation(from:to:)`.
    public var animation: Animation?
    /// Called when a morph lands; not for one that was superseded.
    public var onEnd: (() -> Void)?

    @State private var timeline: MorphTimeline
    @State private var shown = ShownProgress()
    @State private var run = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `content`, morphing to each new content with `animation` (nil picks
    /// one that suits the two ends).
    public init(_ content: MorphContent, animation: Animation? = nil, onEnd: (() -> Void)? = nil) {
        self.content = content
        self.animation = animation
        self.onEnd = onEnd
        _timeline = State(initialValue: MorphTimeline(content))
    }

    /// A morph between text alone settles without overshoot, since a bounce
    /// reads as a wobble on letters; one with a symbol or shape at either end
    /// gets a little snap.
    public static func defaultAnimation(from: MorphContent, to: MorphContent) -> Animation {
        from.kind.isGlyph || to.kind.isGlyph ? .snappy(duration: 0.45, extraBounce: 0.05) : .smooth(duration: 0.45)
    }

    public var body: some View {
        MorphBetween(from: timeline.from, to: timeline.to, progress: timeline.target, shown: shown)
            .onChange(of: content) { old, new in morph(from: old, to: new) }
    }

    private func morph(from old: MorphContent, to new: MorphContent) {
        run += 1
        let thisRun = run
        guard !reduceMotion else {
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { timeline.jump(to: new) }
            return
        }
        guard let change = timeline.change(to: new, shown: shown.value) else { return }
        let animation = animation ?? Self.defaultAnimation(from: old, to: new)
        // The ends change at once (they aren't animatable); only the progress
        // moves, so a spring already running is retargeted, speed and all.
        withAnimation(animation, completionCriteria: .logicallyComplete) {
            timeline = change
        } completion: {
            if thisRun == run { onEnd?() }
        }
    }
}

/// What an `AnimatedMorph` shows: two ends and which one it's heading for.
///
/// A morph never resets its progress: turning back heads for the other end,
/// and a new content replaces an end, so a running spring is only ever
/// retargeted.
struct MorphTimeline: Equatable {
    /// The content at progress 0.
    var from: MorphContent
    /// The content at progress 1.
    var to: MorphContent
    /// The end it's heading for: 0 or 1.
    var target: Double

    /// At rest on `content`.
    init(_ content: MorphContent) {
        from = content
        to = content
        target = 1
    }

    init(from: MorphContent, to: MorphContent, target: Double) {
        self.from = from
        self.to = to
        self.target = target
    }

    /// The content it's heading for.
    var destination: MorphContent { target == 1 ? to : from }

    /// The timeline that morphs to `content` from what's on screen at
    /// `shown`, or nil when it's already heading there.
    func change(to content: MorphContent, shown: Double) -> MorphTimeline? {
        if content == destination { return nil }
        // Turning back: head for the end it came from.
        if content == (target == 1 ? from : to) {
            return MorphTimeline(from: from, to: to, target: 1 - target)
        }
        // A new content takes the end further from what's shown.
        if shown >= 0.5 {
            return MorphTimeline(from: content, to: to, target: 0)
        }
        return MorphTimeline(from: from, to: content, target: 1)
    }

    /// At rest on `content`, with no morph.
    mutating func jump(to content: MorphContent) {
        self = MorphTimeline(content)
    }
}

/// The progress a `MorphBetween` last drew, mid-animation included: SwiftUI
/// only tells the view itself. A plain reference, written as it draws and
/// read when the content changes, so it never invalidates a view.
final class ShownProgress {
    var value: Double = 1
}
