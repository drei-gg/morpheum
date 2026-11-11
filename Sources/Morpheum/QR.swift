// QR codes as morph ends, and a morph made for them: a grid of modules
// rearranging itself into another, square by square.

import CoreGraphics
import CoreImage
import Foundation

/// A QR code's modules: a square grid, each dark or light.
public struct QRCode: Hashable, Sendable {
    /// Modules a side.
    public let count: Int
    /// Row by row from the top left: true for dark.
    public let dark: [Bool]

    /// `count` by `count` modules, row by row from the top left.
    public init(count: Int, dark: [Bool]) {
        precondition(count > 0 && dark.count == count * count, "dark needs count × count modules")
        self.count = count
        self.dark = dark
    }

    /// Rows of modules, top first: true for dark.
    public init(rows: [[Bool]]) {
        self.init(count: rows.count, dark: rows.flatMap { $0 })
    }

    /// The QR code CoreImage makes for `message` at error correction
    /// `correction` ("L", "M", "Q" or "H"), its quiet zone included; nil if
    /// it can't.
    public init?(message: String, correction: String = "M") {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(message.utf8), forKey: "inputMessage")
        filter.setValue(correction, forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage,
              let cg = CIContext().createCGImage(image, from: image.extent), cg.width == cg.height else { return nil }
        let n = cg.width
        var pixels = [UInt8](repeating: 255, count: n * n)
        guard let gray = CGContext(data: &pixels, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n,
                                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        gray.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        // A bitmap context's first row in memory is the image's top.
        var dark = [Bool](repeating: false, count: n * n)
        for y in 0..<n { for x in 0..<n { dark[y * n + x] = pixels[y * n + x] < 128 } }
        self.init(count: n, dark: dark)
    }

    /// The top-left modules of its three finder squares (top left, top
    /// right, bottom left), looked for near the corners past any quiet zone;
    /// fewer when it hasn't all three.
    func finders() -> [(Int, Int)] {
        func isFinder(_ x0: Int, _ y0: Int) -> Bool {
            guard x0 >= 0, y0 >= 0, x0 + 7 <= count, y0 + 7 <= count else { return false }
            for dy in 0..<7 {
                for dx in 0..<7 {
                    let ring = max(abs(dx - 3), abs(dy - 3))
                    if dark[(y0 + dy) * count + x0 + dx] != (ring != 2) { return false }
                }
            }
            return true
        }
        var found: [(Int, Int)] = []
        let margin = min(6, count / 4)
        let corners = [(0, 0, 1, 1), (count - 7, 0, -1, 1), (0, count - 7, 1, -1)]
        for (cx, cy, sx, sy) in corners {
            search: for q in 0...margin {
                for r in 0...margin where isFinder(cx + sx * r, cy + sy * q) {
                    found.append((cx + sx * r, cy + sy * q))
                    break search
                }
            }
        }
        return found
    }

    /// The dark modules as one path, `side` points square, y down.
    func path(side: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let m = side / CGFloat(count)
        for y in 0..<count {
            for x in 0..<count where dark[y * count + x] {
                path.addRect(CGRect(x: CGFloat(x) * m, y: CGFloat(y) * m, width: m, height: m))
            }
        }
        return path.normalized(using: .winding)
    }
}

/// One QR code into another, module by module. Modules dark in both, in the
/// same place, stay. Each other module of the start slides to the nearest
/// free module of the end (squares stay squares, growing or shrinking from
/// one grid's size to the other's), in a wave across the code; any left
/// over shrink away in place, or grow in. Every frame is a code's worth of
/// crisp squares: nothing melts.
final class QRMorph: @unchecked Sendable {
    // @unchecked: immutable after init.
    private struct Move {
        let x0, y0, x1, y1: Double
        /// When in the morph it moves (or shrinks, or grows): 0...1 each.
        let start: Double, end: Double
        /// Whether it's there at the start, and at the end.
        let from: Bool, to: Bool
    }
    private let moves: [Move]
    private let sizeA: Double, sizeB: Double

    /// Plans the morph from `a` to `b`, in a unit square.
    init(from a: QRCode, to b: QRCode) {
        sizeA = 1 / Double(a.count)
        sizeB = 1 / Double(b.count)
        var moves: [Move] = []
        // A wave from the top left to the bottom right: each module's window
        // starts a little later the further along it is.
        func wave(_ x: Double, _ y: Double) -> Double { 0.3 * (x + y) / 2 }
        func centre(_ q: QRCode, _ x: Int, _ y: Int) -> (Double, Double) {
            ((Double(x) + 0.5) / Double(q.count), (Double(y) + 0.5) / Double(q.count))
        }
        // The three finder squares, matched corner to corner and moved as
        // units, module for module: each stays a crisp square at any size.
        let fa = a.finders(), fb = b.finders()
        var finderA = Set<Int>(), finderB = Set<Int>()
        if fa.count == 3 && fb.count == 3 {
            for k in 0..<3 {
                for dy in 0..<7 {
                    for dx in 0..<7 {
                        let (ax, ay) = (fa[k].0 + dx, fa[k].1 + dy), (bx, by) = (fb[k].0 + dx, fb[k].1 + dy)
                        finderA.insert(ay * a.count + ax)
                        finderB.insert(by * b.count + bx)
                        guard a.dark[ay * a.count + ax] else { continue }
                        let p = centre(a, ax, ay), q = centre(b, bx, by)
                        moves.append(Move(x0: p.0, y0: p.1, x1: q.0, y1: q.1, start: 0, end: 1, from: true, to: true))
                    }
                }
            }
        }
        func modules(_ q: QRCode, skipping: Set<Int>) -> [(Double, Double)] {
            var out: [(Double, Double)] = []
            for y in 0..<q.count { for x in 0..<q.count where q.dark[y * q.count + x] && !skipping.contains(y * q.count + x) { out.append(centre(q, x, y)) } }
            return out
        }
        let pa = modules(a, skipping: finderA), pb = modules(b, skipping: finderB)
        // Candidate pairs within a few modules, nearest first; taken
        // greedily, so a module that's dark in both (distance 0, same grid)
        // stays put.
        let radius = 4.0 * max(sizeA, sizeB)
        let cell = radius
        let bins = Int((1 / cell).rounded(.up)) + 1
        func binned(_ p: [(Double, Double)]) -> [[Int]] {
            var grid = [[Int]](repeating: [], count: bins * bins)
            for (j, q) in p.enumerated() { grid[min(Int(q.1 / cell), bins - 1) * bins + min(Int(q.0 / cell), bins - 1)].append(j) }
            return grid
        }
        let gridA = binned(pa), gridB = binned(pb)
        func near(_ p: (Double, Double), _ grid: [[Int]], _ points: [(Double, Double)], _ body: (Int, Double) -> Void) {
            let bi = min(Int(p.0 / cell), bins - 1), bj = min(Int(p.1 / cell), bins - 1)
            for v in max(0, bj - 1)...min(bins - 1, bj + 1) {
                for u in max(0, bi - 1)...min(bins - 1, bi + 1) {
                    for j in grid[v * bins + u] { body(j, hypot(points[j].0 - p.0, points[j].1 - p.1)) }
                }
            }
        }
        var pairs: [(Double, Int, Int)] = []
        for (i, p) in pa.enumerated() { near(p, gridB, pb) { j, d in if d <= radius { pairs.append((d, i, j)) } } }
        pairs.sort { $0.0 < $1.0 }
        var takenA = [Bool](repeating: false, count: pa.count), takenB = [Bool](repeating: false, count: pb.count)
        for (d, i, j) in pairs where !takenA[i] && !takenB[j] {
            takenA[i] = true
            takenB[j] = true
            let delay = d < 1e-9 ? 0 : wave((pa[i].0 + pb[j].0) / 2, (pa[i].1 + pb[j].1) / 2)
            moves.append(Move(x0: pa[i].0, y0: pa[i].1, x1: pb[j].0, y1: pb[j].1, start: delay, end: delay + 0.7, from: true, to: true))
        }
        // Left over: nothing pops. A module of the start with no partner
        // merges into the nearest module of the end; one of the end splits
        // off from the nearest of the start. (Shrinking and growing in place,
        // a code into a bigger one turned to dust mid-flight.)
        func nearest(_ p: (Double, Double), _ grid: [[Int]], _ points: [(Double, Double)]) -> (Double, Double)? {
            var best: (Double, Double)?, bestD = Double.infinity
            near(p, grid, points) { j, d in if d < bestD { bestD = d; best = points[j] } }
            if best == nil {
                for q in points { let d = hypot(q.0 - p.0, q.1 - p.1); if d < bestD { bestD = d; best = q } }
            }
            return best
        }
        for i in pa.indices where !takenA[i] {
            let delay = wave(pa[i].0, pa[i].1)
            if let q = nearest(pa[i], gridB, pb) {
                moves.append(Move(x0: pa[i].0, y0: pa[i].1, x1: q.0, y1: q.1, start: delay, end: delay + 0.7, from: true, to: true))
            } else {
                moves.append(Move(x0: pa[i].0, y0: pa[i].1, x1: pa[i].0, y1: pa[i].1, start: delay, end: delay + 0.45, from: true, to: false))
            }
        }
        for j in pb.indices where !takenB[j] {
            let delay = wave(pb[j].0, pb[j].1)
            if let p = nearest(pb[j], gridA, pa) {
                moves.append(Move(x0: p.0, y0: p.1, x1: pb[j].0, y1: pb[j].1, start: delay, end: delay + 0.7, from: true, to: true))
            } else {
                moves.append(Move(x0: pb[j].0, y0: pb[j].1, x1: pb[j].0, y1: pb[j].1, start: 0.25 + delay, end: 0.7 + delay, from: false, to: true))
            }
        }
        self.moves = moves
    }

    /// The modules at `t` (0 is the start, 1 the end) as closed squares in
    /// the unit square, each a hair bigger than its module so neighbours
    /// overlap rather than meet at a seam.
    func polygons(at t: Double) -> [[Double]] {
        let t = min(max(t, 0), 1)
        var out: [[Double]] = []
        out.reserveCapacity(moves.count)
        for m in moves {
            let raw = min(max((t - m.start) / (m.end - m.start), 0), 1)
            let u = raw * raw * (3 - 2 * raw)
            let x = m.x0 + (m.x1 - m.x0) * u, y = m.y0 + (m.y1 - m.y0) * u
            var side = sizeA + (sizeB - sizeA) * u
            if !m.to { side = sizeA * (1 - u) }
            if !m.from { side = sizeB * u }
            if side <= 1e-6 { continue }
            let h = side / 2 + 0.01 * min(sizeA, sizeB)
            out.append([x - h, y - h, x + h, y - h, x + h, y + h, x - h, y + h])
        }
        return out
    }
}
