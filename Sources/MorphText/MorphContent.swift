import SwiftUI

/// What a morph shows at one end: a line of text in a style, or an SF
/// Symbol.
///
/// Text and symbols morph into each other freely: a word flows into a
/// symbol, a symbol into a word or another symbol, a word into another word.
public struct MorphContent: Hashable, @unchecked Sendable {
    // @unchecked: a text's style holds a CTFont, which is immutable.

    enum Kind: Hashable {
        case text(String, MorphStyle.Geometry)
        case symbol(String, size: CGFloat, weight: Font.Weight)
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

    var isSymbol: Bool {
        if case .symbol = kind { true } else { false }
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
