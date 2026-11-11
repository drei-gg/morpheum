# Morpheum

Shapes that morph, in SwiftUI. A light word turns heavy, one word becomes
another, a word pours into an SF Symbol, an app icon flows into a logo, one
QR code rearranges itself into the next, with plain text (or the art itself)
at either end.

Two engines do the work, and `auto` picks between them:

- **Ink** treats ink as mass and carries it the cheapest way from one shape
  to the other (optimal transport). Nothing is matched, so nothing is left
  to vanish or tear: `Save` bends and pours into its tick, `Send` shears
  into a paper plane.
- **Outlines** morph each letter's outline into its partner's, point for
  point: exact, every counter kept through a weight change, and a lively
  scatter between two icons.

SwiftUI, iOS 17 and macOS 14, Swift Package Manager. The Swift sibling of
[morphtext](https://github.com/drei-gg/morphtext) for Flutter.

> Pre-release: not tagged yet. It lives in the Seven and Done apps first.

```swift
.package(url: "https://github.com/drei-gg/morpheum", branch: "main")
```

```swift
import Morpheum

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
carries the shapes a little past either end and back), or drive it from a
gesture, a scroll position or a transition. At exactly 0 and 1 it is plain
text, drawn exactly where the morph lands, so there is no step as it
settles.

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

## Engines

```swift
MorphBetween(from: send, to: plane, progress: t)
    .morphEngine(.ink)      // for everything inside; .auto by default
```

- **Ink** (`.ink`): each end is sampled as grains of ink, and each grain's
  cheapest way to the other end is planned (entropic optimal transport,
  Sinkhorn's iterations on Accelerate). Each end's own outline travels
  along that flow, the start's out and the end's in, spring overshoot and
  all, so both move as vector outlines do: smooth at any size, landing
  exactly. In mid flight one hands over to the other through their
  distance fields, warped by the same flow. About 20 ms to plan (in the
  background) and 2 to 5 ms a frame, on an Intel Mac VM.
- **Outlines** (`.outline`): each letter's outline morphs into its
  partner's, point for point, contours matched fills to fills and holes to
  holes, and interpolated in polar form. Exact at both ends and best for one
  letter at another weight. Between different letters a stroke's sides can
  drift apart, and pieces with no partner shrink away almost at once.
- **Auto** (`.auto`, the default) picks: outlines for the same letter at
  another weight and for a shape filling in or hollowing out (a bookmark
  into a filled one); ink for everything else.

Two more engines ship as experiments, to show there's room for others:

- **Strokes** (`.strokes`): each letter traced to its centrelines, a width
  at every point, each stroke bending and thinning into its partner, serifs
  riding their stems, drawn as one seamless outline a frame. A calligraphic
  look between letters; a stroke that grows in can part from its letter
  for a frame or two.
- **Fields** (`.fields`): what only the start has drains into the end, what
  only the end has fills in. Every frame is clean, but the two ends read as
  overlaid rather than one becoming the other.

### Engines of your own

An engine plans a morph between two outlines once, then draws any frame of
it. Conform to `Morpher` and hand it over:

```swift
final class Dissolve: Morpher {
    init(_ from: MorphOutline, _ to: MorphOutline) { … }   // plan
    func polygons(at t: Double) -> [[Double]] { … }         // a frame, in ems
}

MorphBetween(from: a, to: b, progress: t)
    .morphEngine(.custom("dissolve") { from, to, context in Dissolve(from, to) })
```

`MorphOutline.polygons` gives each end as closed polygons in ems; return
each frame the same way, each end's own outline at 0 and 1, and the package
carries it into place, draws it and hands over to the text at rest.
`context` says how many points an em is on screen, and whether it's a whole
word gathering into a symbol. The built-in engines are written the same
way.

## SF Symbols

`MorphBetween` takes text, a symbol or art at either end:

```swift
MorphBetween(from: .text("Send", style: .system(size: 28, weight: .semibold)),
             to: .symbol("paperplane.fill", size: 28, weight: .semibold),
             progress: sent ? 1 : 0)
```

A word and a symbol morph as one shape, every letter from its place in the
word. At rest a symbol end is its own outline, filled where the morph lands
it (`Image(systemName:)` would sit up to 3/4 of a point elsewhere, and the
landing would step).

No public API hands over a symbol's outline, so SwiftUI draws the symbol
into a PDF, which keeps it vector, and the PDF's paths are read back, soft
masks (the tick cut out of `checkmark.circle.fill`) included. Each symbol is
read once per size, weight and screen scale. Monochrome only: a multicolour
or hierarchical symbol's layers become one shape in one colour.

## Shapes of your own

Vector art morphs too: an app icon's glyph into a logo, a logo into a word.
Give it a `CGPath` in a box, or SVG:

```swift
let icon = MorphContent.shape(glyphPath, size: CGSize(width: 160, height: 160), color: ink)
let mark = try MorphContent.shape(svg: logoSVG, size: CGSize(width: 160, height: 160), color: red)
MorphBetween(from: icon, to: mark, progress: t)
```

The SVG is read for its solid shape: path data (every command, arcs
included), transforms on paths and groups, the viewBox (fitted into `size`
and centred, as SVG does by default) and fill rules. Anything in `<defs>`,
`<clipPath>` or `<mask>`, and paths filled with `none` or a gradient, are
left out as decoration, so draw shadows and highlights yourself, over the
morph. One shape, one colour: the art's own colours are ignored.

## QR codes

Two QR codes morph module by module, whatever their sizes:

```swift
MorphBetween(from: .qrCode(QRCode(message: oldLink)!, side: 200),
             to: .qrCode(QRCode(message: newLink)!, side: 200),
             progress: t)
```

Modules dark in both stay put. The others slide to the nearest free module
of the other code in a wave across it; one with no partner merges into a
neighbour, or splits off from one, so nothing pops. The three finder
squares move as units, so they stay crisp concentric squares as the grid
grows or shrinks. Every frame is a code's worth of squares, and each end
scans. It plans in a few milliseconds and draws in well under one.
`QRCode(rows:)` and `QRCode(count:dark:)` take modules from any generator.

## Styles

A SwiftUI `Font` can't be read back as an outline, so each text end takes a
`MorphStyle`: a CoreText font (size, and for a variable font, where on its
axes), a colour and letter spacing.

```swift
.system(size: 34, weight: .bold, design: .rounded, color: .orange, kerning: -1)
.custom("Fraunces-SemiBold", size: 40)           // register the font first
MorphStyle(font: someCTFont, color: .primary)    // any CTFont, UIFont or NSFont
```

## Drawing it yourself

The morph is public, for UIKit, AppKit or Core Animation:

```swift
let morph = TextMorph("Light", from: .system(size: 48, weight: .ultraLight),
                      to: "Heavy", in: .system(size: 48, weight: .black))
morph.prepareInBackground()           // plan off the main thread
let size = morph.size(at: t)
shapeLayer.path = morph.path(at: t, in: size)   // fill non-zero
```

`TextMorph(…, engine:)` takes an engine. Underneath, `MorphOutline` reads
any `CGPath` and `MorphOutlinePlan` morphs one outline into another.

## How it works

CoreText lays out both ends (kerning, fallback fonts and baseline) and gives
each letter's glyph outline, the system font included, so nothing is parsed
from font files. A glyph drawn as overlapping pieces (many fonts draw a g's
ear over its bowl) is merged into one outline first. Letters pair up by a
weighted edit distance (`Ruby` slides into `bRuby`; `Amethyst` keeps its
`t`); a letter with no partner grows from, or shrinks into, the place of its
neighbour. A word and a single glyph morph as one shape.

The outline engine is a port of [morphnext](https://github.com/KickNext/morphnext)'s
geometry, checked against it: the tests plan the same letter pairs from the
same font files as morphnext 0.7.1 and must draw the same shapes. The ink
engine is this package's own. The stroke engine is a port of the Flutter
package's experimental one. The tests run on macOS and the iOS simulator.

## Demo

On a Mac, `swift run MorpheumDemo`: seven morphs (weight, words, fonts,
size, two words into symbols, a symbol into a symbol), an engine switch, a
spring and a scrubber, and below them a Save button and a bookmark switch
built on `AnimatedMorph`. `MorphText.swift` has Xcode previews too.

## License and attribution

Morpheum is MIT licensed.

Its outline engine is ported from [morphnext](https://github.com/KickNext/morphnext)
(MIT, © 2026 KickNext), which in turn adapts MIT-licensed work from
[Morphicons](https://github.com/guillermolg00/morphicons); see
`THIRD_PARTY_NOTICES.md`. Morpheum is an independent project, not affiliated
with or endorsed by KickNext or the Morphicons project.
