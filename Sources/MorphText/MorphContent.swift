import SwiftUI

/// What a morph shows at one end: a line of text in a style, an SF Symbol,
/// or a shape of your own (vector art: a path, or an SVG).
///
/// They morph into each other freely: a word flows into a symbol, a symbol
/// into a word or another symbol, an app icon's glyph into a logo, a word
/// into another word.
public struct MorphContent: Hashable, @unchecked Sendable {
    // @unchecked: a text's style holds a CTFont, which is immutable.

    enum Kind: Hashable {
        case text(String, MorphStyle.Geometry)
        case symbol(String, size: CGFloat, weight: Font.Weight)
        case shape(Shape)

        /// Whether it's one glyph (a symbol or shape) rather than a word.
        var isGlyph: Bool {
            if case .text = self { false } else { true }
        }
    }

    /// A filled path in a box: points, y down, from the box's top left.
    struct Shape: Hashable, @unchecked Sendable {
        let path: CGPath
        let width: CGFloat
        let height: CGFloat
    }

    let kind: Kind
    /// Its colour.
    public var color: Color
    /// What VoiceOver reads at this end: the text itself when nil, and
    /// nothing for a symbol, as for `Image(systemName:)`.
    public var accessibilityLabel: String?

    /// `text` on one line, in `style`.
    public static func text(_ text: String, style: MorphStyle, accessibilityLabel: String? = nil) -> MorphContent {
        MorphContent(kind: .text(text, style.geometry), color: style.color, accessibilityLabel: accessibilityLabel)
    }

    /// The SF Symbol `name`, as `Image(systemName:)` draws it in
    /// `.font(.system(size: size, weight: weight))`, in `color`. Monochrome:
    /// all its layers in the one colour.
    public static func symbol(
        _ name: String,
        size: CGFloat,
        weight: Font.Weight = .regular,
        color: Color = .primary,
        accessibilityLabel: String? = nil
    ) -> MorphContent {
        MorphContent(kind: .symbol(name, size: size, weight: weight), color: color, accessibilityLabel: accessibilityLabel)
    }

    /// `path` filled in `color`, in a box of `size`: points, y down, from the
    /// box's top left. It sits on the box's bottom edge as if that were a
    /// baseline, and morphs with a word as one shape, as a symbol does.
    public static func shape(
        _ path: CGPath,
        size: CGSize,
        color: Color = .primary,
        accessibilityLabel: String? = nil
    ) -> MorphContent {
        MorphContent(
            kind: .shape(Shape(path: path, width: size.width, height: size.height)),
            color: color,
            accessibilityLabel: accessibilityLabel
        )
    }

    /// The solid shape an SVG document fills, scaled to fit `size` and
    /// centred in it, as SVG fits its viewBox by default, filled in `color`.
    ///
    /// Read: path data (every command, arcs included), transforms on paths
    /// and groups, the viewBox, fill rules. Left out as decoration: anything
    /// in `<defs>`, `<clipPath>` or `<mask>`, and paths filled with `none` or
    /// a gradient. Its own colours are ignored; it's one shape in `color`.
    /// Throws when it can't read the SVG or it fills nothing.
    public static func shape(
        svg: String,
        size: CGSize,
        color: Color = .primary,
        accessibilityLabel: String? = nil
    ) throws -> MorphContent {
        let (path, viewBox) = try SVG.document(svg)
        return .shape(fitted(path, from: viewBox, into: size), size: size, color: color, accessibilityLabel: accessibilityLabel)
    }

    /// The shape SVG path data (a `d` attribute) draws in `viewBox`, scaled to
    /// fit `size` and centred in it, filled in `color` with the non-zero rule
    /// (or even-odd).
    public static func shape(
        svgPath data: String,
        viewBox: CGRect,
        size: CGSize,
        evenOdd: Bool = false,
        color: Color = .primary,
        accessibilityLabel: String? = nil
    ) throws -> MorphContent {
        let path = try SVG.path(data).normalized(using: evenOdd ? .evenOdd : .winding)
        return .shape(fitted(path, from: viewBox, into: size), size: size, color: color, accessibilityLabel: accessibilityLabel)
    }

    /// `path`, drawn in `box`, scaled to fit `size` and centred in it.
    private static func fitted(_ path: CGPath, from box: CGRect, into size: CGSize) -> CGPath {
        guard box.width > 0, box.height > 0 else { return path }
        let scale = min(size.width / box.width, size.height / box.height)
        var transform = CGAffineTransform(
            translationX: (size.width - box.width * scale) / 2 - box.minX * scale,
            y: (size.height - box.height * scale) / 2 - box.minY * scale
        ).scaledBy(x: scale, y: scale)
        return path.copy(using: &transform) ?? path
    }


    /// What VoiceOver reads.
    var label: String {
        if let accessibilityLabel { return accessibilityLabel }
        if case .text(let text, _) = kind { return text }
        return ""
    }
}

extension MorphContent.Kind {
    /// This end laid out, for a screen of `scale` pixels per point. A symbol
    /// is read once per name, size, weight and scale.
    @MainActor
    func layout(scale: CGFloat = 2) -> WordLayout {
        switch self {
        case .text(let text, let geometry):
            return WordLayout(text, style: geometry)
        case .symbol(let name, let size, let weight):
            let key = SymbolKey(name: name, size: size, weight: weight, scale: scale)
            if let known = symbolLayouts[key] { return known }
            let outline = SymbolOutline(name, size: size, weight: weight, scale: scale)
            let layout = WordLayout(symbol: outline, name: name, size: size)
            symbolLayouts[key] = layout
            return layout
        case .shape(let shape):
            // Its box's bottom edge stands in for a baseline, and its height
            // for an em.
            let box = CGSize(width: shape.width, height: shape.height)
            let path = shape.path.isEmpty ? nil : shape.path
            return WordLayout(vector: path, name: "shape", box: box, baseline: box.height, em: max(box.height, 1))
        }
    }
}

private struct SymbolKey: Hashable {
    let name: String
    let size: CGFloat
    let weight: Font.Weight
    let scale: CGFloat
}

/// Every symbol read so far: a few kilobytes each.
@MainActor private var symbolLayouts: [SymbolKey: WordLayout] = [:]
