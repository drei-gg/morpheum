import CoreGraphics
import CoreImage
import Testing
@testable import Morpheum

@Suite struct QRCodes {
    @Test func itFindsTheThreeFinders() throws {
        let code = try #require(QRCode(message: "https://example.com/a"))
        let finders = code.finders()
        try #require(finders.count == 3)
        // Top left, top right, bottom left, mirrored past the same quiet zone.
        #expect(finders[0].0 == finders[0].1)
        #expect(finders[1].0 == code.count - 7 - finders[0].0 && finders[1].1 == finders[0].1)
        #expect(finders[2].1 == code.count - 7 - finders[0].1 && finders[2].0 == finders[0].0)
    }

    @Test func theSameGridKeepsWhatBothShare() throws {
        let a = try #require(QRCode(message: "https://example.com/r/A1B2C3")), b = try #require(QRCode(message: "https://example.com/r/Z9Y8X7"))
        #expect(a.count == b.count)
        let morph = QRMorph(from: a, to: b)
        // Halfway, every module dark in both is still a full module in place.
        let half = morph.polygons(at: 0.5)
        let m = 1 / Double(a.count)
        for y in 0..<a.count {
            for x in 0..<a.count where a.dark[y * a.count + x] && b.dark[y * a.count + x] {
                let cx = (Double(x) + 0.5) * m, cy = (Double(y) + 0.5) * m
                #expect(half.contains { abs(($0[0] + $0[4]) / 2 - cx) < 1e-9 && abs(($0[1] + $0[5]) / 2 - cy) < 1e-9 && $0[4] - $0[0] >= m })
            }
        }
    }

    @MainActor
    @Test func aCodeIntoABiggerOneIsAlwaysWholeSquares() throws {
        let a = try #require(QRCode(message: "https://example.com/r/A1B2C3"))
        let b = try #require(QRCode(message: "https://example.com/receipt/2026-11-11/Z9Y8X7W6V5U4T3S2R1Q0?from=split&amount=41.50"))
        #expect(a.count < b.count)
        let morph = TextMorph(from: .qrCode(a, side: 160), to: .qrCode(b, side: 160))
        for t in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let box = morph.path(at: t, in: morph.size(at: t)).boundingBoxOfPath
            // Covering the code's square, give or take its quiet zone.
            #expect(box.width > 130 && box.width <= 161, "at \(t)")
        }
        // Every module is a square: nothing pops in or out, they merge and split.
        let frames = QRMorph(from: a, to: b)
        #expect(frames.polygons(at: 0.5).allSatisfy { abs(($0[4] - $0[0]) - ($0[5] - $0[1])) < 1e-9 })
        #expect(frames.polygons(at: 0).count == frames.polygons(at: 1).count)
    }

    @Test func atRestItScans() throws {
        let message = "https://example.com/r/A1B2C3"
        let code = try #require(QRCode(message: message))
        // Its path drawn black on white, with room around it, read back.
        let side = 400, pad = 40
        let cg = try #require(CGContext(data: nil, width: side + 2 * pad, height: side + 2 * pad, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        cg.setFillColor(gray: 1, alpha: 1)
        cg.fill(CGRect(x: 0, y: 0, width: side + 2 * pad, height: side + 2 * pad))
        // y down, as the path is.
        cg.translateBy(x: CGFloat(pad), y: CGFloat(side + pad))
        cg.scaleBy(x: 1, y: -1)
        cg.addPath(code.path(side: CGFloat(side)))
        cg.setFillColor(gray: 0, alpha: 1)
        cg.fillPath()
        let image = CIImage(cgImage: try #require(cg.makeImage()))
        let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let found = detector.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        #expect(found == [message])
    }
}
