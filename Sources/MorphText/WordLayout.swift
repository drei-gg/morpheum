import CoreText
import Foundation

/// One end of a morph laid out by CoreText on one line: its size, its
/// baseline, and each letter's pen position (kerning included) and outline.
///
/// A letter is a `Character` (an extended grapheme cluster), so `é` written
/// as `e` and a combining accent is one letter, its glyphs one outline.
/// Ligatures are off, so every letter has a glyph of its own to morph.
struct WordLayout: @unchecked Sendable {
    // @unchecked: CTLine and CTFont are immutable.

    /// One letter where the line draws it.
    struct Letter {
        let character: Character
        /// Its pen position on the baseline, from the line's left edge; nil
        /// when the line drew no glyph for it.
        let pen: CGFloat?
        /// The size of the font that drew it.
        let em: CGFloat
        /// Its outline in ems (x from the pen, y down from the baseline);
        /// nil for a space, or a glyph with no outline (a colour emoji).
        let outline: MorphOutline?
    }

    /// How far above the baseline, in ems, a letter missing from this layout
    /// grows from or shrinks to: about the middle of a lowercase letter.
    static let gapHeight: CGFloat = 0.3

    let text: String
    let style: MorphStyle.Geometry
    let line: CTLine
    let letters: [Letter]
    /// The line's typographic size: its advance, by its ascent plus descent
    /// plus leading.
    let size: CGSize
    /// From the top of the line to its baseline.
    let baseline: CGFloat
    /// The font size, in points.
    let em: CGFloat

    init(_ text: String, style: MorphStyle.Geometry) {
        self.text = text
        self.style = style
        em = CTFontGetSize(style.font)
        line = Self.line(text, style: style)

        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        size = CGSize(width: width, height: ascent + descent + leading)
        baseline = ascent

        // Which letter each UTF-16 offset belongs to.
        let characters = Array(text)
        var starts: [Int] = []
        var offset = 0
        for character in characters {
            starts.append(offset)
            offset += character.utf16.count
        }
        func letterIndex(_ utf16: Int) -> Int {
            var low = 0, high = starts.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if starts[mid] <= utf16 { low = mid } else { high = mid - 1 }
            }
            return low
        }

        // Each letter's glyphs, with the font that draws them (a fallback
        // font, sometimes) and where.
        var glyphs = [[(font: CTFont, glyph: CGGlyph, position: CGPoint)]](repeating: [], count: characters.count)
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let font = attributes[kCTFontAttributeName as String] as! CTFont
            let count = CTRunGetGlyphCount(run)
            guard count > 0, !characters.isEmpty else { continue }
            var ids = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(), &ids)
            CTRunGetPositions(run, CFRange(), &positions)
            CTRunGetStringIndices(run, CFRange(), &indices)
            for k in 0..<count {
                glyphs[letterIndex(indices[k])].append((font, ids[k], positions[k]))
            }
        }

        letters = characters.indices.map { k in
            let parts = glyphs[k]
            guard let first = parts.first else {
                return Letter(character: characters[k], pen: nil, em: CTFontGetSize(style.font), outline: nil)
            }
            let em = CTFontGetSize(first.font)
            let path = CGMutablePath()
            for part in parts {
                // To ems, y down, about the letter's pen.
                var transform = CGAffineTransform(
                    a: 1 / em, b: 0, c: 0, d: -1 / em,
                    tx: (part.position.x - first.position.x) / em,
                    ty: -(part.position.y - first.position.y) / em
                )
                if let glyph = CTFontCreatePathForGlyph(part.font, part.glyph, &transform) {
                    path.addPath(glyph)
                }
            }
            let outline = (try? MorphOutline(path: path)) ?? nil
            return Letter(character: characters[k], pen: first.position.x, em: em, outline: outline)
        }
    }

    /// `text` in `style` as one CoreText line, ligatures off.
    static func line(_ text: String, style: MorphStyle.Geometry) -> CTLine {
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): style.font,
            NSAttributedString.Key(kCTLigatureAttributeName as String): 0,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        if style.kerning != 0 {
            attributes[NSAttributedString.Key(kCTKernAttributeName as String)] = style.kerning
        }
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    /// Where a letter that isn't in this layout comes from or goes to: the
    /// pen of the letter at `index` (the end of the line past the last one),
    /// a little above the baseline. Measured from the line's top left.
    func gap(_ index: Int) -> CGPoint {
        let x = index < letters.count ? (letters[index].pen ?? size.width) : size.width
        return CGPoint(x: x, y: baseline - Self.gapHeight * em)
    }
}
