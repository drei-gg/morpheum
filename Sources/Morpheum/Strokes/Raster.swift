// Ported from morphtext for Flutter (lib/src/raster.dart, strokes branch):
// glyph outlines as pixels, filled, and how far each pixel lies from the
// edge. The stroke tracer and the measuring tools share it.

import Foundation

/// Polygons (interleaved x, y) filled non-zero into a `w` by `h` mask whose
/// pixel (0, 0) has its corner at (`ox`, `oy`), each pixel `px` across:
/// 1 inside, 0 out, by each pixel's centre.
func fillPolygons(_ polygons: [[Double]], _ w: Int, _ h: Int, _ ox: Double, _ oy: Double, _ px: Double) -> [UInt8] {
    var mask = [UInt8](repeating: 0, count: w * h)
    var crossings: [(x: Double, winding: Int)] = []
    for j in 0..<h {
        let y = oy + (Double(j) + 0.5) * px
        crossings.removeAll(keepingCapacity: true)
        for p in polygons {
            let n = p.count / 2
            for k in 0..<n {
                let x1 = p[2 * k], y1 = p[2 * k + 1]
                let l = (k + 1) % n
                let x2 = p[2 * l], y2 = p[2 * l + 1]
                if y1 == y2 { continue }
                let lo = min(y1, y2), hi = max(y1, y2)
                if y < lo || y >= hi { continue }
                crossings.append((x1 + (y - y1) * (x2 - x1) / (y2 - y1), y2 > y1 ? 1 : -1))
            }
        }
        crossings.sort { $0.x < $1.x }
        // Spans where the winding isn't zero.
        var winding = 0
        var c = 0
        while c + 1 < crossings.count {
            defer { c += 1 }
            winding += crossings[c].winding
            if winding == 0 { continue }
            let start = max(0, Int(((crossings[c].x - ox) / px - 0.5).rounded(.up)))
            let end = min(w - 1, Int(((crossings[c + 1].x - ox) / px - 0.5).rounded(.up)) - 1)
            if start > end { continue }
            for i in start...end { mask[j * w + i] = 1 }
        }
    }
    return mask
}

/// The squared distance, in pixels, from each pixel inside `mask` to the
/// nearest outside (Felzenszwalb and Huttenlocher's exact transform).
func distanceField(_ mask: [UInt8], _ w: Int, _ h: Int) -> [Double] {
    featureField(mask, w, h).distances
}

/// As `distanceField`, and for each pixel the nearest pixel outside (its
/// index): the feature transform, from the same two passes.
func featureField(_ mask: [UInt8], _ w: Int, _ h: Int) -> (distances: [Double], nearest: [Int32]) {
    let far = 1e20
    var rows = [Int32](repeating: 0, count: w * h), nearest = [Int32](repeating: 0, count: w * h)
    var d = mask.map { $0 == 1 ? far : 0 }
    let size = max(w, h)
    var f = [Double](repeating: 0, count: size), out = [Double](repeating: 0, count: size)
    var v = [Int](repeating: 0, count: size), z = [Double](repeating: 0, count: size + 1)
    var arg = [Int](repeating: 0, count: size)
    func pass(_ n: Int) {
        var k = 0
        v[0] = 0
        z[0] = -far
        z[1] = far
        if n > 1 {
            for q in 1..<n {
                let qd = Double(q)
                var vk = Double(v[k])
                var s = ((f[q] + qd * qd) - (f[v[k]] + vk * vk)) / (2 * qd - 2 * vk)
                while s <= z[k] {
                    k -= 1
                    vk = Double(v[k])
                    s = ((f[q] + qd * qd) - (f[v[k]] + vk * vk)) / (2 * qd - 2 * vk)
                }
                k += 1
                v[k] = q
                z[k] = s
                z[k + 1] = far
            }
        }
        k = 0
        for q in 0..<n {
            while z[k + 1] < Double(q) { k += 1 }
            let dq = Double(q - v[k])
            out[q] = dq * dq + f[v[k]]
            arg[q] = v[k]
        }
    }
    for x in 0..<w {
        for y in 0..<h { f[y] = d[y * w + x] }
        pass(h)
        for y in 0..<h {
            d[y * w + x] = out[y]
            rows[y * w + x] = Int32(arg[y])
        }
    }
    for y in 0..<h {
        for x in 0..<w { f[x] = d[y * w + x] }
        pass(w)
        for x in 0..<w {
            d[y * w + x] = out[x]
            nearest[y * w + x] = rows[y * w + arg[x]] * Int32(w) + Int32(arg[x])
        }
    }
    return (d, nearest)
}
