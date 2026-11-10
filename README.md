# MorphText for Swift

Text that morphs letter by letter, outline into outline. A light word turns
heavy, a serif word turns rounded, a small title grows and loosens, and one
word becomes another, all as one shape, with plain text at either end.

The Swift sibling of [morphtext](https://github.com/drei-gg/morphtext) for
Flutter. SwiftUI, iOS 17 and macOS 14, Swift Package Manager.

> Early: one end-to-end morph works (text into text, any weight, size,
> spacing or font), with tests. SF Symbols, an implicit `AnimatedMorphText`
> and the outline-to-text handoff are next.

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
grows from, or shrinks into, the place of its neighbour.

The geometry is a port of morphnext's, checked against it: the tests plan
the same letter pairs from the same font files as morphnext 0.7.1 and must
draw the same shapes.

## Demo

On a Mac, `swift run MorphTextDemo`: four morphs, a spring and a scrubber.
`MorphText.swift` has an Xcode preview too.

## License and attribution

MorphText is MIT licensed.

Its outline geometry is ported from [morphnext](https://github.com/KickNext/morphnext)
(MIT, © 2026 KickNext), which in turn adapts MIT-licensed work from
[Morphicons](https://github.com/guillermolg00/morphicons); see
`THIRD_PARTY_NOTICES.md`. MorphText is an independent project, not affiliated
with or endorsed by KickNext or the Morphicons project.
