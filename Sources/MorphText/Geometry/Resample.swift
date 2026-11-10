// Ported from morphnext (KickNext, MIT, github.com/KickNext/morphnext),
// lib/src/geometry/resample.dart at 0.7.1, whose arc-length sampling is
// adapted from Morphicons' MIT-licensed resample.ts. See
// THIRD_PARTY_NOTICES.md.

import Foundation

private let cornerThreshold = Double.pi / 8
private let lengthEpsilon = 1e-12
private let gaussNodes: [Double] = [
    0.18343464249564978, 0.525532409916329, 0.7966664774136267, 0.9602898564975363,
]
private let gaussWeights: [Double] = [
    0.362683783378362, 0.31370664587788727, 0.22238103445337448, 0.10122853629037626,
]

/// Samples a closed cubic contour at even arc-length intervals, keeping a
/// point on every corner.
func resampleContour(_ contour: CubicContour, pointCount: Int = 64) throws -> [Double] {
    precondition(pointCount >= 2, "pointCount must be at least 2")
    let points = contour.points
    let segmentCount = contour.segmentCount
    var output = [Double](repeating: 0, count: 2 * pointCount)
    var lengths = [Double](repeating: 0, count: segmentCount)
    var totalLength = 0.0
    for segment in 0..<segmentCount {
        let length = segmentLength(points, segment)
        lengths[segment] = length
        totalLength += length
    }
    if totalLength < lengthEpsilon {
        for i in 0..<pointCount {
            output[2 * i] = points[0]
            output[2 * i + 1] = points[1]
        }
        return output
    }

    let corners = detectCorners(points, lengths, segmentCount, cornerThreshold)
    let anchors = corners.isEmpty ? [0] : corners
    guard anchors.count <= pointCount else {
        throw MorphGeometryError("pointCount=\(pointCount) cannot retain \(anchors.count) corners")
    }

    let runs: [(start: Int, end: Int)] = anchors.indices.map { i in
        (anchors[i], i + 1 < anchors.count ? anchors[i + 1] : anchors[0] + segmentCount)
    }
    let runLengths = runs.map { sumWrapped(lengths, $0.start, $0.end, segmentCount) }
    let counts = try apportionIntervals(runLengths, pointCount)

    var write = 0
    for (runIndex, run) in runs.enumerated() {
        let intervalCount = counts[runIndex]
        let runLength = runLengths[runIndex]
        let pointOffset = 6 * (run.start % segmentCount)
        output[2 * write] = points[pointOffset]
        output[2 * write + 1] = points[pointOffset + 1]
        write += 1

        var segment = run.start
        var accumulated = 0.0
        var interval = 1
        while interval < intervalCount {
            let target = runLength * Double(interval) / Double(intervalCount)
            while segment < run.end - 1, accumulated + lengths[segment % segmentCount] < target {
                accumulated += lengths[segment % segmentCount]
                segment += 1
            }
            let wrapped = segment % segmentCount
            let length = lengths[wrapped]
            let t = length > lengthEpsilon
                ? invertArcLength(points, wrapped, target - accumulated, length)
                : 0
            writePoint(points, wrapped, t, &output, 2 * write)
            write += 1
            interval += 1
        }
    }
    guard write == pointCount else {
        throw MorphGeometryError("Sampler wrote \(write) of \(pointCount) points")
    }
    return output
}

/// Samples each cubic contour at its own point count and derives the filled
/// topology.
func sampleContours(
    _ contours: [CubicContour],
    pointCounts: [Int],
    fillRule: FillRule = .evenOdd
) throws -> MorphShape {
    precondition(pointCounts.count == contours.count, "pointCounts must match contours")
    return try sampledShape(
        fromPointBuffers: zip(contours, pointCounts).map { try resampleContour($0, pointCount: $1) },
        fillRule: fillRule,
        exactContours: contours
    )
}

private let minimumOutlinePointCount = 64
private let maximumOutlinePointCount = 2048
private let samplesPerCubicSegment = 16

/// Samples a glyph outline for morphing, as morphnext samples icons and
/// glyphs: 16 points per cubic segment, rounded up to a power of two between
/// 64 and 2048, filled with the non-zero rule.
func sampleOutlineContours(_ contours: [CubicContour]) throws -> MorphShape {
    try sampleContours(
        contours,
        pointCounts: contours.map(outlinePointCount),
        fillRule: .nonZero
    )
}

private func outlinePointCount(_ contour: CubicContour) -> Int {
    let required = contour.segmentCount * samplesPerCubicSegment
    var count = minimumOutlinePointCount
    while count < required, count < maximumOutlinePointCount { count *= 2 }
    return count
}

/// Derives the topology (nesting, holes, a canonical winding and order) of
/// already sampled point buffers. `exactContours`, when given, are the cubic
/// contours they were sampled from, in the same order.
func sampledShape(
    fromPointBuffers buffers: [[Double]],
    fillRule: FillRule = .evenOdd,
    exactContours: [CubicContour]? = nil
) throws -> MorphShape {
    if buffers.isEmpty { return MorphShape([], fillRule: fillRule) }
    for points in buffers where points.count < 4 || points.count % 2 == 1 || !points.allSatisfy(\.isFinite) {
        throw MorphGeometryError("Invalid sampled point buffer")
    }
    let sampled = buffers
    let count = sampled.count
    let areas = sampled.map(signedPolygonArea)
    var parents = [Int?](repeating: nil, count: count)
    for child in 0..<count {
        var parent: Int?
        for candidate in 0..<count {
            if candidate == child || abs(areas[candidate]) <= abs(areas[child]) { continue }
            if !polygonContains(sampled[candidate], sampled[child][0], sampled[child][1]) { continue }
            if parent == nil || abs(areas[candidate]) < abs(areas[parent!]) { parent = candidate }
        }
        parents[child] = parent
    }

    var depths = [Int](repeating: -1, count: count)
    func depthOf(_ index: Int, _ active: inout Set<Int>) throws -> Int {
        if depths[index] >= 0 { return depths[index] }
        guard active.insert(index).inserted else {
            throw MorphGeometryError("Cyclic contour topology")
        }
        let depth = try parents[index].map { try depthOf($0, &active) + 1 } ?? 0
        active.remove(index)
        depths[index] = depth
        return depth
    }
    for i in 0..<count {
        var active = Set<Int>()
        _ = try depthOf(i, &active)
    }

    var holes = [Bool](repeating: false, count: count)
    switch fillRule {
    case .evenOdd:
        for i in 0..<count { holes[i] = depths[i] % 2 == 1 }
    case .nonZero:
        var insideWindings = [Int?](repeating: nil, count: count)
        func insideWinding(_ index: Int) -> Int {
            if let known = insideWindings[index] { return known }
            let outside = parents[index].map(insideWinding) ?? 0
            let sign = areas[index] > lengthEpsilon ? 1 : areas[index] < -lengthEpsilon ? -1 : 0
            let inside = outside + sign
            holes[index] = outside != 0 && inside == 0
            insideWindings[index] = inside
            return inside
        }
        for i in 0..<count { _ = insideWinding(i) }
    }

    let reversed: [Bool]
    switch fillRule {
    case .nonZero:
        var reference = 0
        for i in 1..<count where parents[i] == nil && abs(areas[i]) > abs(areas[reference]) {
            reference = i
        }
        reversed = [Bool](repeating: areas[reference] < 0, count: count)
    case .evenOdd:
        reversed = (0..<count).map { holes[$0] ? areas[$0] > 0 : areas[$0] < 0 }
    }
    let canonicalSampled = (0..<count).map { reversed[$0] ? reversedPointBuffer(sampled[$0]) : sampled[$0] }
    let canonicalAreas = (0..<count).map { reversed[$0] ? -areas[$0] : areas[$0] }
    if let exactContours, exactContours.count != count {
        throw MorphGeometryError("Exact and sampled contour counts differ")
    }
    let canonicalExact = try exactContours.map { exact in
        try (0..<count).map { reversed[$0] ? try reversedCubicContour(exact[$0]) : exact[$0] }
    }

    let order = (0..<count).sorted { a, b in
        if depths[a] != depths[b] { return depths[a] < depths[b] }
        let areaA = abs(canonicalAreas[a]), areaB = abs(canonicalAreas[b])
        if areaA != areaB { return areaA > areaB }
        return comparePointBuffers(canonicalSampled[a], canonicalSampled[b]) < 0
    }
    var remapped = [Int](repeating: 0, count: count)
    for (newIndex, oldIndex) in order.enumerated() { remapped[oldIndex] = newIndex }

    return MorphShape(
        try order.map { old in
            try SampledContour(
                canonicalSampled[old],
                signedArea: canonicalAreas[old],
                depth: depths[old],
                parent: parents[old].map { remapped[$0] },
                isHole: holes[old]
            )
        },
        exactContours: canonicalExact.map { exact in order.map { exact[$0] } },
        fillRule: fillRule
    )
}

private func reversedPointBuffer(_ points: [Double]) -> [Double] {
    let n = points.count / 2
    var reversed = points
    for point in 1..<n {
        let source = n - point
        reversed[2 * point] = points[2 * source]
        reversed[2 * point + 1] = points[2 * source + 1]
    }
    return reversed
}

private func reversedCubicContour(_ contour: CubicContour) throws -> CubicContour {
    let source = contour.points
    var reversed = [source[0], source[1]]
    reversed.reserveCapacity(source.count)
    for segment in stride(from: contour.segmentCount - 1, through: 0, by: -1) {
        let o = 6 * segment
        reversed += [source[o + 4], source[o + 5], source[o + 2], source[o + 3], source[o], source[o + 1]]
    }
    return try CubicContour(reversed)
}

private func speed(_ p: [Double], _ segment: Int, _ t: Double) -> Double {
    let o = 6 * segment
    let u = 1 - t
    let c0 = 3 * u * u, c1 = 6 * u * t, c2 = 3 * t * t
    let dx = c0 * (p[o + 2] - p[o]) + c1 * (p[o + 4] - p[o + 2]) + c2 * (p[o + 6] - p[o + 4])
    let dy = c0 * (p[o + 3] - p[o + 1]) + c1 * (p[o + 5] - p[o + 3]) + c2 * (p[o + 7] - p[o + 5])
    return (dx * dx + dy * dy).squareRoot()
}

private func segmentLength(_ points: [Double], _ segment: Int, _ end: Double = 1) -> Double {
    let half = end / 2
    var sum = 0.0
    for i in 0..<gaussNodes.count {
        sum += gaussWeights[i] * (
            speed(points, segment, half + half * gaussNodes[i])
                + speed(points, segment, half - half * gaussNodes[i])
        )
    }
    return sum * half
}

private func writePoint(_ p: [Double], _ segment: Int, _ t: Double, _ output: inout [Double], _ at: Int) {
    let o = 6 * segment
    let u = 1 - t
    let b0 = u * u * u, b1 = 3 * u * u * t, b2 = 3 * u * t * t, b3 = t * t * t
    output[at] = b0 * p[o] + b1 * p[o + 2] + b2 * p[o + 4] + b3 * p[o + 6]
    output[at + 1] = b0 * p[o + 1] + b1 * p[o + 3] + b2 * p[o + 5] + b3 * p[o + 7]
}

private func tangent(_ p: [Double], _ segment: Int, atEnd: Bool) -> (Double, Double)? {
    let o = 6 * segment
    let base = atEnd ? o + 6 : o
    for candidate in atEnd ? [4, 2, 0] : [2, 4, 6] {
        let dx = atEnd ? p[base] - p[o + candidate] : p[o + candidate] - p[base]
        let dy = atEnd ? p[base + 1] - p[o + candidate + 1] : p[o + candidate + 1] - p[base + 1]
        if dx * dx + dy * dy > 1e-18 { return (dx, dy) }
    }
    return nil
}

private func detectCorners(_ p: [Double], _ lengths: [Double], _ segmentCount: Int, _ threshold: Double) -> [Int] {
    let active = (0..<segmentCount).filter { lengths[$0] > 1e-9 }
    if active.count < 2 { return [] }
    var corners = Set<Int>()
    func testJoint(_ previous: Int, _ next: Int) {
        guard let incoming = tangent(p, previous, atEnd: true),
              let outgoing = tangent(p, next, atEnd: false) else { return }
        let angle = abs(atan2(
            incoming.0 * outgoing.1 - incoming.1 * outgoing.0,
            incoming.0 * outgoing.0 + incoming.1 * outgoing.1
        ))
        if angle > threshold { corners.insert(next) }
    }
    for i in 0..<(active.count - 1) { testJoint(active[i], active[i + 1]) }
    testJoint(active[active.count - 1], active[0])
    return corners.sorted()
}

private func sumWrapped(_ values: [Double], _ start: Int, _ end: Int, _ modulus: Int) -> Double {
    var sum = 0.0
    for i in start..<end { sum += values[i % modulus] }
    return sum
}

private func apportionIntervals(_ lengths: [Double], _ intervalCount: Int) throws -> [Int] {
    guard lengths.count <= intervalCount else {
        throw MorphGeometryError("\(intervalCount) intervals cannot retain \(lengths.count) runs")
    }
    let total = lengths.reduce(0, +)
    let ideals = lengths.map { Double(intervalCount) * $0 / total }
    var counts = ideals.map { max(1, Int($0.rounded(.down))) }
    var remaining = intervalCount - counts.reduce(0, +)
    if remaining > 0 {
        let order = lengths.indices.sorted { a, b in
            let fa = ((ideals[a] - ideals[a].rounded(.down)) * 1e9).rounded()
            let fb = ((ideals[b] - ideals[b].rounded(.down)) * 1e9).rounded()
            return fa != fb ? fa > fb : a < b
        }
        for i in 0..<remaining { counts[order[i % order.count]] += 1 }
    }
    while remaining < 0 {
        var largest = 0
        for i in 1..<counts.count where counts[i] > counts[largest] { largest = i }
        guard counts[largest] > 1 else {
            throw MorphGeometryError("Unable to apportion \(intervalCount) intervals")
        }
        counts[largest] -= 1
        remaining += 1
    }
    return counts
}

private func invertArcLength(_ p: [Double], _ segment: Int, _ target: Double, _ length: Double) -> Double {
    if target <= 0 { return 0 }
    if target >= length { return 1 }
    var lower = 0.0, upper = 1.0
    var t = target / length
    for _ in 0..<12 {
        let difference = segmentLength(p, segment, t) - target
        if abs(difference) < 1e-10 * length + 1e-14 { break }
        if difference > 0 { upper = t } else { lower = t }
        let s = speed(p, segment, t)
        var next = s > 1e-12 ? t - difference / s : (lower + upper) / 2
        if !(next > lower && next < upper) { next = (lower + upper) / 2 }
        t = next
    }
    return t
}

/// The signed area of a closed polygon given as interleaved x, y.
func signedPolygonArea(_ points: [Double]) -> Double {
    var twice = 0.0
    let n = points.count / 2
    for i in 0..<n {
        let next = i + 1 == n ? 0 : i + 1
        twice += points[2 * i] * points[2 * next + 1] - points[2 * next] * points[2 * i + 1]
    }
    return twice / 2
}

private func polygonContains(_ polygon: [Double], _ x: Double, _ y: Double) -> Bool {
    var inside = false
    let n = polygon.count / 2
    var previous = n - 1
    for i in 0..<n {
        let x0 = polygon[2 * previous], y0 = polygon[2 * previous + 1]
        let x1 = polygon[2 * i], y1 = polygon[2 * i + 1]
        if pointOnSegment(x, y, x0, y0, x1, y1) { return true }
        if (y1 > y) != (y0 > y), x < (x0 - x1) * (y - y1) / (y0 - y1) + x1 {
            inside.toggle()
        }
        previous = i
    }
    return inside
}

private func pointOnSegment(_ x: Double, _ y: Double, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> Bool {
    let cross = (x - x0) * (y1 - y0) - (y - y0) * (x1 - x0)
    if abs(cross) > 1e-12 { return false }
    return (x - x0) * (x - x1) + (y - y0) * (y - y1) <= 1e-12
}

private func comparePointBuffers(_ a: [Double], _ b: [Double]) -> Int {
    for i in 0..<min(a.count, b.count) where a[i] != b[i] {
        return a[i] < b[i] ? -1 : 1
    }
    return a.count == b.count ? 0 : a.count < b.count ? -1 : 1
}
