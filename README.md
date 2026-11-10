# MorphText for Swift

Text that morphs letter by letter, outline into outline. A light word turns
heavy, a serif word turns rounded, a small title grows and loosens, one word
becomes another, and a word flows into an SF Symbol, all as one shape, with
plain text (or the symbol itself) at either end.

The Swift sibling of [morphtext](https://github.com/drei-gg/morphtext) for
Flutter. SwiftUI, iOS 17 and macOS 14, Swift Package Manager.

> Early: text into text (any weight, size, spacing or font), text into and
> out of SF Symbols and your own vector shapes, and an implicit
> `AnimatedMorph` work, with tests on macOS and iOS. Not published: it lives
> in the Seven and Done apps first.

```swift
import MorphText

struct Title: View {
    @State private var on = false

    var body: some View {
        MorphText("Light", toText: "Heavy",
                  from: .system(size: 48, weight: .ultraLight),
                  to: .system(size: 48, weight: .black),
                  progress: on ? 1 : 0)
            .onTapGesture { withAnimation(.spring) { on.toggle() } }
    }
}
```

`progress` animates: change it inside `withAnimation` (a spring's overshoot
carries the outlines a little past either end), or drive it from a gesture,
a scroll position or a transition. At exactly 0 and 1 it is plain text.

## Implicit morphs

`AnimatedMorph` morphs to each new content you give it, as SwiftUI's
`.animation` does. It fits inside stock controls, so a button stays a
system button and only its label moves:

```swift
Button(action: save) {
    AnimatedMorph(saved ? .symbol("checkmark", size: 17, weight: .semibold)
                        : .text("Save", style: .system(size: 17, weight: .semibold)))
}
.buttonStyle(.borderedProminent)

Button { bookmarked.toggle() } label: {
    AnimatedMorph(.symbol(bookmarked ? "bookmark.fill" : "bookmark", size: 22))
}
```

Turning back before it lands reverses from where it is, keeping the
spring's speed. A third content arriving mid-flight replaces whichever end
is further from what's shown. Text into text settles without a bounce (a
bounce reads as a wobble on letters); anything with a symbol gets a little
snap. Pass `animation:` for your own, and `onEnd:` to hear when it lands.
With Reduce Motion on, changes apply at once.

## SF Symbols

`MorphBetween` takes text or a symbol at either end:

```swift
MorphBetween(from: .text("Send", style: .system(size: 28, weight: .semibold)),
             to: .symbol("paperplane.fill", size: 28, weight: .semibold),
             progress: sent ? 1 : 0)
```

A word and a symbol morph as one shape, every letter from its place in the
word; one symbol morphs into another as a glyph does. At rest a symbol end is
`Image(systemName:)` itself.

No public API hands over a symbol's outline, so SwiftUI draws the symbol
into a PDF, which keeps it vector, and the PDF's paths are read back, soft
masks (the tick cut out of `checkmark.circle.fill`) included. Each symbol is
read once per size, weight and screen scale. Monochrome only: a multicolour
or hierarchical symbol's layers become one shape in one colour. SwiftUI
places a symbol's pixels by up to 3/4 of a point differently depending on
where it sits, so the first frame of a morph can land that far from the
resting `Image`.

## Shapes of your own

Vector art morphs too: an app icon's glyph into a logo, a logo into a word.
Give it a `CGPath` in a box, or SVG:

```swift
let icon = MorphContent.shape(glyphPath, size: CGSize(width: 160, height: 160), color: ink)
let mark = try MorphContent.shape(svg: squaremarkSVG, size: CGSize(width: 160, height: 160), color: red)
MorphBetween(from: icon, to: mark, progress: t)
```

The SVG is read for its solid shape: path data (every command, arcs
included), transforms on paths and groups, the viewBox (fitted into `size`
and centred, as SVG does by default) and fill rules. Anything in `<defs>`,
`<clipPath>` or `<mask>`, and paths filled with `none` or a gradient, are
left out as decoration, so draw shadows and highlights yourself, over the
morph. One shape, one colour: the art's own colours are ignored.

## Styles

A SwiftUI `Font` can't be read back as an outline, so each end takes a
`MorphStyle`: a CoreText font (size, and for a variable font, where on its
axes), a colour and letter spacing.

```swift
.system(size: 34, weight: .bold, design: .rounded, color: .orange, kerning: -1)
.custom("Fraunces-SemiBold", size: 40)           // register the font first
MorphStyle(font: someCTFont, color: .primary)    // any CTFont, UIFont or NSFont
```

## Drawing it yourself

The engine is public, for UIKit, AppKit or Core Animation:

```swift
let morph = TextMorph("Light", from: .system(size: 48, weight: .ultraLight),
                      to: "Heavy", in: .system(size: 48, weight: .black))
morph.prepare()                       // plan now, not on the first frame
let size = morph.size(at: t)
shapeLayer.path = morph.path(at: t, in: size)   // fill non-zero
```

Underneath, `MorphOutline` reads any `CGPath` and `MorphOutlinePlan` morphs
one outline into another.

## How it works

CoreText lays out both ends (kerning, fallback fonts and baseline) and gives
each letter's glyph outline, the system font included, so nothing is parsed
from font files. Letters pair up by a weighted edit distance (`Ruby` slides
into `bRuby`; `Amethyst` keeps its `t`), and each pair's contours are sampled,
matched (fills with fills, holes with holes) and aligned by rotation, scale
and starting point, then interpolated in polar form. A letter with no partner
grows from, or shrinks into, the place of its neighbour, steadily across the
whole morph, so `Send`'s spare letters visibly fold into the paper plane.
(morphnext collapses them within the first tenth; `MorphOutlinePlan`'s
`collapse: .morphnext` does the same.)

The geometry is a port of morphnext's, checked against it: the tests plan
the same letter pairs from the same font files as morphnext 0.7.1 and, with
its collapse, must draw the same shapes. The tests run on macOS and the iOS simulator.

## Demo

On a Mac, `swift run MorphTextDemo`: six morphs (weight, words, fonts, size,
a word into a symbol, a symbol into a symbol), a spring and a scrubber, and
below them a Save button and a bookmark switch built on `AnimatedMorph`.
`MorphText.swift` has Xcode previews too.

## License and attribution

MorphText is MIT licensed.

Its outline geometry is ported from [morphnext](https://github.com/KickNext/morphnext)
(MIT, © 2026 KickNext), which in turn adapts MIT-licensed work from
[Morphicons](https://github.com/guillermolg00/morphicons); see
`THIRD_PARTY_NOTICES.md`. MorphText is an independent project, not affiliated
with or endorsed by KickNext or the Morphicons project.
