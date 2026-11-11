import CoreGraphics
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// An SF Symbol's outline, read as SwiftUI draws `Image(systemName:)`.
///
/// No public API gives a symbol's outline, so it is drawn by SwiftUI into a
/// PDF, which keeps it vector, and the PDF's paths are read back
/// (`PDFPaths`). The box and baseline are the platform image's, so the
/// symbol sits on a line of text as it does in SwiftUI. Monochrome only: a
/// symbol's layers all become one shape.
struct SymbolOutline {
    /// The symbol in points, y down, from the top left of its box: exactly
    /// what SwiftUI fills.
    let path: CGPath
    /// The box `Image(systemName:)` takes.
    let size: CGSize
    /// From the box's top to the baseline it shares with text.
    let baseline: CGFloat
    /// Whether the PDF painted something that isn't a fill, so the outline
    /// may be missing a part.
    let incomplete: Bool

    /// `name` at `size` points and `weight`, placed as SwiftUI draws it on a
    /// screen of `scale` pixels per point, or nil when there is no such
    /// symbol.
    @MainActor
    init?(_ name: String, size: CGFloat, weight: Font.Weight, scale: CGFloat) {
        guard let baselineOffset = Self.baselineOffset(name, size: size, weight: weight) else { return nil }
        let renderer = ImageRenderer(content: Image(systemName: name).font(.system(size: size, weight: weight)))
        var data: Data?
        var box = CGSize.zero
        renderer.render { rendered, draw in
            box = rendered
            var mediaBox = CGRect(origin: .zero, size: rendered)
            let buffer = NSMutableData()
            guard let consumer = CGDataConsumer(data: buffer as CFMutableData),
                  let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return }
            context.beginPDFPage(nil)
            draw(context)
            context.endPDFPage()
            context.closePDF()
            data = buffer as Data
        }
        guard let data, let provider = CGDataProvider(data: data as CFData),
              let page = CGPDFDocument(provider)?.page(at: 1) else { return nil }
        let paths = PDFPaths(page: page)
        // PDF is y up from the bottom of the box.
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: box.height)
        guard var path = paths.union.copy(using: &flip), !path.isEmpty else { return nil }
        // SwiftUI snaps a symbol to the pixel grid it draws on, so its PDF
        // (at 1x) can sit up to 3/4 of a point from where a 2x or 3x screen
        // shows it. Move the outline to that screen's pixels, so it takes over
        // from `Image(systemName:)` without a jump.
        if let offset = Self.screenOffset(of: path, renderer: renderer, scale: scale) {
            var move = CGAffineTransform(translationX: offset.width, y: offset.height)
            path = path.copy(using: &move) ?? path
        }
        self.path = path
        self.size = box
        self.baseline = box.height - baselineOffset
        self.incomplete = paths.unsupported
    }

    /// How far to move `path` to cover the pixels SwiftUI draws for the symbol
    /// (`renderer`'s) at `scale`, by the edges of the ink: nil when either
    /// draws nothing.
    @MainActor
    private static func screenOffset(of path: CGPath, renderer: ImageRenderer<some View>, scale: CGFloat) -> CGSize? {
        renderer.scale = scale
        guard let image = renderer.cgImage else { return nil }
        let width = image.width, height = image.height
        func inkBounds(_ draw: (CGContext) -> Void) -> CGRect? {
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return false }
                draw(context)
                return true
            }
            guard drawn else { return nil }
            var minX = width, minY = height, maxX = -1, maxY = -1
            for y in 0..<height {
                for x in 0..<width where rgba[(y * width + x) * 4 + 3] > 127 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            guard maxX >= 0 else { return nil }
            // Rows run top down in memory, as y does in `path`.
            return CGRect(x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(maxX - minX), height: CGFloat(maxY - minY))
        }
        let screen = inkBounds { $0.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)) }
        let ours = inkBounds { context in
            // y down, like `path`, in pixels.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: scale, y: -scale)
            context.addPath(path)
            context.fillPath()
        }
        guard let screen, let ours else { return nil }
        return CGSize(width: (screen.midX - ours.midX) / scale, height: (screen.midY - ours.midY) / scale)
    }

    /// How far the symbol's baseline sits above the bottom of its box, as the
    /// platform image reports it; nil when there's no such symbol.
    private static func baselineOffset(_ name: String, size: CGFloat, weight: Font.Weight) -> CGFloat? {
        #if canImport(UIKit)
        let configuration = UIImage.SymbolConfiguration(pointSize: size, weight: weight.symbolWeight)
        guard let image = UIImage(systemName: name, withConfiguration: configuration) else { return nil }
        return image.baselineOffsetFromBottom ?? image.alignmentRectInsets.bottom
        #else
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: weight.platform)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        // The alignment rect runs from the baseline to the cap height.
        return image.alignmentRect.minY
        #endif
    }
}

#if canImport(UIKit)
extension Font.Weight {
    var symbolWeight: UIImage.SymbolWeight {
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
#endif
