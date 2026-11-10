import CoreText
import Foundation

/// One end of a morph laid out by CoreText on one line: its size, its
/// baseline, and each letter's pen position (kerning included) and outline.
/// Or vector art (an SF Symbol, a shape), as one letter in a box of its own.
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
        /// The font and letter, to keep its strokes by; nil for art.
        var strokeKey: String? = nil
        /// The family of the font that drew it; nil for art.
        var family: String? = nil
    }

    /// How far above the baseline, in ems, a letter missing from this layout
    /// grows from or shrinks to: about the middle of a lowercase letter.
    static let gapHeight: CGFloat = 0.3

    /// The text, or a name for the art.
    let text: String
    /// The text's font and spacing; nil for art.
    let style: MorphStyle.Geometry?
    /// The line CoreText draws at rest; nil for art.
    let line: CTLine?
    /// The art at rest, in points from the box's top left; nil for text.
    let vector: CGPath?
    private(set) var letters: [Letter]
    /// The line's typographic size: its advance, by its ascent plus descent
    /// plus leading.
    let size: CGSize
    /// From the top of the line to its baseline.
    let baseline: CGFloat
    /// The font size, in points.
    let em: CGFloat
    /// The QR code it draws, for a QR code.
    var qr: QRCode? = nil

    init(_ text: String, style: MorphStyle.Geometry) {
        self.text = text
        self.style = style
        vector = nil
        em = CTFontGetSize(style.font)
        let line = Self.line(text, style: style)
        self.line = line

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
            return Letter(character: characters[k], pen: first.position.x, em: em, outline: outline,
                          strokeKey: strokeCacheKey(first.font, characters[k]),
                          family: CTFontCopyFamilyName(first.font) as String)
        }
    }

    /// The SF Symbol `name` at `size` points, as one letter: its outline from
    /// its pen (the box's left edge) and baseline. Empty when there's no such
    /// symbol.
    init(symbol outline: SymbolOutline?, name: String, size: CGFloat) {
        guard let outline else {
            self.init(vector: nil, name: name, box: .zero, baseline: 0, em: size)
            return
        }
        self.init(vector: outline.path, name: name, box: outline.size, baseline: outline.baseline, em: size)
    }

    /// Vector art `path` (points, y down, from the top left of a `box`), as
    /// one letter whose pen is the box's left edge, on `baseline`, `em` points
    /// to the em. Empty without a path.
    init(vector path: CGPath?, name: String, box: CGSize, baseline: CGFloat, em: CGFloat) {
        text = name
        style = nil
        line = nil
        self.em = em
        guard let path else {
            vector = nil
            letters = []
            size = .zero
            self.baseline = 0
            return
        }
        vector = path
        size = box
        self.baseline = baseline
        var toEms = CGAffineTransform(a: 1 / em, b: 0, c: 0, d: 1 / em, tx: 0, ty: -baseline / em)
        let shape = path.copy(using: &toEms).flatMap { (try? MorphOutline(path: $0)) ?? nil }
        letters = [Letter(character: "\u{FFFC}", pen: 0, em: em, outline: shape)]
    }

    /// Keeps art's strokes under `key` (a symbol's name, size, weight and
    /// scale), so it is traced once whatever it morphs into.
    mutating func keyStrokes(_ key: String) {
        for i in letters.indices { letters[i].strokeKey = key }
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
