import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Morpheum

/// Renders `MorphText` through SwiftUI, the way an app draws it.
@MainActor
@Suite struct Frames {
    private func render(_ view: some View) throws -> CGImage {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .light))
        renderer.scale = 2
        return try #require(renderer.cgImage)
    }

    /// How many pixels hold any ink.
    private func ink(_ image: CGImage) -> Int {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] > 32 }.count
    }

    @Test func everyFrameDrawsAWord() throws {
        let from = MorphStyle.system(size: 48, weight: .ultraLight, color: .black)
        let to = MorphStyle.system(size: 48, weight: .black, color: .black)
        var inks: [Int] = []
        var frames: [CGImage] = []
        for t in stride(from: 0.0, through: 1.0, by: 0.25) {
            let image = try render(MorphText("Light", toText: "Heavy", from: from, to: to, progress: t))
            frames.append(image)
            inks.append(ink(image))
        }
        #expect(inks.allSatisfy { $0 > 500 }, "ink per frame: \(inks)")
        // Black is heavier than ultralight, and the morph gets there steadily.
        #expect(inks.last! > 2 * inks.first!, "ink per frame: \(inks)")
        #expect(inks == inks.sorted(), "ink per frame: \(inks)")
        try saveStrip(frames, name: "light-heavy")
    }

    @Test func aWordChangesWeight() throws {
        let from = MorphStyle.system(size: 48, weight: .ultraLight, color: .black)
        let to = MorphStyle.system(size: 48, weight: .black, color: .black)
        let frames = try stride(from: 0.0, through: 1.0, by: 0.25).map {
            try render(MorphText("Morph", from: from, to: to, progress: $0))
        }
        let inks = frames.map(ink)
        #expect(inks == inks.sorted(), "ink per frame: \(inks)")
        try saveStrip(frames, name: "morph-weight")
    }

    @Test func theOutlineAtTheEndMatchesTheText() throws {
        let style = MorphStyle.system(size: 64, weight: .bold, color: .black)
        let text = try render(MorphText("Morph", from: style, to: style, progress: 1))
        let outline = try render(MorphText("Morph", from: style, to: style, progress: 0.999_999))
        #expect(text.width == outline.width && text.height == outline.height)
        let (a, b) = (ink(text), ink(outline))
        #expect(abs(a - b) < a / 20, "text \(a) px, outline \(b) px")
    }
}

/// With MORPHEUM_FRAMES set to a folder, writes the frames there side by
/// side as a PNG, to look at.
func saveStrip(_ frames: [CGImage], name: String) throws {
    guard let folder = ProcessInfo.processInfo.environment["MORPHEUM_FRAMES"] else { return }
    let width = frames.map(\.width).max()!
    let height = frames.map(\.height).reduce(0, +)
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    var y = height
    for frame in frames {
        y -= frame.height
        context.draw(frame, in: CGRect(x: (width - frame.width) / 2, y: y, width: frame.width, height: frame.height))
    }
    let url = URL(fileURLWithPath: folder).appendingPathComponent("\(name).png")
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    #expect(CGImageDestinationFinalize(destination))
}
