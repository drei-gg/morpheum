import CoreText
import SwiftUI

#if canImport(UIKit)
import UIKit
typealias PlatformFont = UIFont
typealias PlatformFontDescriptor = UIFontDescriptor
#elseif canImport(AppKit)
import AppKit
typealias PlatformFont = NSFont
typealias PlatformFontDescriptor = NSFontDescriptor
#endif

/// How one end of a morph is drawn: its font (which carries its size and,
/// for a variable font, where on its axes), colour and letter spacing.
///
/// A SwiftUI `Font` can't be read back as an outline, so a morph takes a
/// CoreText font instead. `system(size:weight:design:)` is the system font
/// (SF Pro, SF Pro Rounded, New York, SF Mono) as `Font.system` draws it.
public struct MorphStyle: Hashable, @unchecked Sendable {
    // @unchecked: CTFont is immutable and documented safe to share between
    // threads.

    /// The font, at its size.
    public var font: CTFont
    /// The colour of the letters.
    public var color: Color
    /// Extra space after each letter, in points, as `Text.kerning` adds.
    public var kerning: CGFloat

    /// A style in `font`.
    public init(font: CTFont, color: Color = .primary, kerning: CGFloat = 0) {
        self.font = font
        self.color = color
        self.kerning = kerning
    }

    /// The font's size in points.
    public var size: CGFloat { CTFontGetSize(font) }

    /// The system font at `size`, `weight` and `design`, as
    /// `Font.system(size:weight:design:)` draws it.
    public static func system(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        color: Color = .primary,
        kerning: CGFloat = 0
    ) -> MorphStyle {
        var font = PlatformFont.systemFont(ofSize: size, weight: weight.platform)
        if let systemDesign = design.platform,
           let descriptor = font.fontDescriptor.withDesign(systemDesign) {
            #if canImport(UIKit)
            font = PlatformFont(descriptor: descriptor, size: size)
            #else
            font = PlatformFont(descriptor: descriptor, size: size) ?? font
            #endif
        }
        return MorphStyle(font: font as CTFont, color: color, kerning: kerning)
    }

    /// The font named `name` (a PostScript or full name) at `size`, as
    /// `Font.custom(_:size:)` draws it. Register a bundled font first (its
    /// `UIAppFonts` entry, or `CTFontManagerRegisterFontsForURL`).
    public static func custom(
        _ name: String,
        size: CGFloat,
        color: Color = .primary,
        kerning: CGFloat = 0
    ) -> MorphStyle {
        MorphStyle(font: CTFontCreateWithName(name as CFString, size, nil), color: color, kerning: kerning)
    }

    /// The same style in another colour.
    public func color(_ color: Color) -> MorphStyle {
        var style = self
        style.color = color
        return style
    }

    /// The same style with extra letter spacing.
    public func kerning(_ kerning: CGFloat) -> MorphStyle {
        var style = self
        style.kerning = kerning
        return style
    }

    /// What lays the text out: everything but the colour.
    var geometry: Geometry { Geometry(font: font, kerning: kerning) }

    struct Geometry: Hashable, @unchecked Sendable {
        let font: CTFont
        let kerning: CGFloat
    }
}

extension Font.Weight {
    var platform: PlatformFont.Weight {
        switch self {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
    }
}

extension Font.Design {
    var platform: PlatformFontDescriptor.SystemDesign? {
        switch self {
        case .serif: .serif
        case .rounded: .rounded
        case .monospaced: .monospaced
        default: nil
        }
    }
}
