// Ported from morphnext (KickNext, MIT, github.com/KickNext/morphnext),
// lib/src/geometry/morph_plan.dart at 0.7.1. There, correspondence and polar
// interpolation are adapted from Morphicons' MIT-licensed plan.ts and
// interpolate.ts; filled-topology matching is morphnext's own. See
// THIRD_PARTY_NOTICES.md.

import Foundation

private let rotationTieBreak = 0.05
private let globalResidualThreshold = 5e-3
private let exactAssignmentLimit = 100_000
private let energyEpsilon = 1e-12
private let minimumScale = 1e-6
private let minimumFftAlignmentPointCount = 32
private let alignmentScoreTolerance = 1e-7
private let minimumStableSimilarityScale = 0.05
private let maximumDegenerateSimilarityResidual = 0.95

typealias Point2 = (x: Double, y: Double)

/// One aligned contour pair within a `MorphPlan`.
struct MorphPlanItem: Sendable {
    /// Source points after correspondence selection.
    let source: [Double]
    /// Source points centred on `sourceCentroid`.
    let sourceCentered: [Double]
    /// Target points carried back into the source frame.
    var targetInSourceFrame: [Double]
    /// Target points after orientation and circular-offset selection.
    let orientedTarget: [Double]
    let sourceCentroid: Point2
    let targetCentroid: Point2
    /// Source-to-target rotation, in radians.
    var theta: Double
    /// Natural log of the source-to-target scale.
    var logScale: Double
    /// Normalised Procrustes residual.
    var residual: Double
    /// Whether the source is a synthetic point (a contour growing in).
    let sourceCollapsed: Bool
    /// Whether the target is a synthetic point (a contour shrinking away).
    let targetCollapsed: Bool
    /// Offset from the global source centroid, for rigid block transport.
    var blockOffset: Point2?
    /// Linear correction that makes block transport exact at t = 1.
    var blockDrift: Point2?
    /// A collapsed side that shrinks (or grows) steadily across the whole
    /// morph, toward its point, without turning: `MorphCollapse.gradual`.
    var gradual = false
}

/// How a contour with no partner leaves its shape, or arrives in the other.
public enum MorphCollapse: Sendable {
    /// It shrinks steadily into its place across the whole morph (or grows
    /// from it), so a word's spare letters visibly fold into the shape they
    /// join. A letter's counter shrinks with its letter.
    case gradual
    /// As morphnext does it: almost all of the way gone within the first
    /// tenth of the morph (or grown in the last).
    case morphnext
}

/// A reusable interpolation plan between two filled shapes.
struct MorphPlan: Sendable {
    let items: [MorphPlanItem]

    /// Plans the morph from `source` to `target`: contours paired by role
    /// (fill or hole) at least cost, each pair aligned by rotation, scale and
    /// starting point. Contours left over collapse as `collapse` says.
    init(from source: MorphShape, to target: MorphShape, collapse: MorphCollapse = .gradual) throws {
        try validateShapes(source, target)
        let pairs = matchContours(source, target)
        let unmatchedSource = Set(pairs.filter { $0.1 == nil }.compactMap(\.0))
        let unmatchedTarget = Set(pairs.filter { $0.0 == nil }.compactMap(\.1))
        /// Whether an unmatched contour collapses gradually, and to where. A
        /// fill always can. A hole can when its parent collapses too: both
        /// head for the parent's point, scaling about it as one, so the hole
        /// stays inside. Any other hole goes quickly, before its parent's own
        /// motion can carry it out.
        func departure(_ index: Int, _ shape: MorphShape, _ unmatched: Set<Int>, _ other: MorphShape) -> (Bool, Point2) {
            let contour = shape.contours[index]
            guard collapse == .gradual else { return (false, collapsePoint(contour, shape, other)) }
            if !contour.isHole { return (true, collapsePoint(contour, shape, other)) }
            if let parent = contour.parent, unmatched.contains(parent) {
                return (true, collapsePoint(shape.contours[parent], shape, other))
            }
            return (false, collapsePoint(contour, shape, other))
        }
        var items: [MorphPlanItem] = []
        for (sourceIndex, targetIndex) in pairs {
            let pointCount = pairPointCount(source, target, sourceIndex, targetIndex)
            let length = 2 * pointCount
            var gradual = false
            let sourcePoints: [Double]
            if let sourceIndex {
                sourcePoints = try pointsAtCardinality(source, sourceIndex, pointCount)
            } else {
                let (steady, point) = departure(targetIndex!, target, unmatchedTarget, source)
                gradual = steady
                sourcePoints = collapsedPoints(length, point)
            }
            let targetPoints: [Double]
            if let targetIndex {
                targetPoints = try pointsAtCardinality(target, targetIndex, pointCount)
            } else {
                let (steady, point) = departure(sourceIndex!, source, unmatchedSource, target)
                gradual = steady
                targetPoints = collapsedPoints(length, point)
            }
            let alignment = alignPair(
                sourcePoints,
                targetPoints,
                allowTargetReversal: target.fillRule == .evenOdd
            )
            var item = createItem(
                alignment,
                sourceCollapsed: sourceIndex == nil,
                targetCollapsed: targetIndex == nil
            )
            if gradual { makeGradual(&item) }
            items.append(item)
        }
        if items.count > 1, items.allSatisfy({ !$0.sourceCollapsed && !$0.targetCollapsed }) {
            applyGlobalAlignment(&items)
        }
        guard !items.isEmpty else {
            throw MorphGeometryError("A morph plan needs at least one contour")
        }
        self.items = items
    }

    /// One correctly sized buffer per contour pair, for `interpolate`.
    func allocateOutput() -> [[Double]] {
        items.map { [Double](repeating: 0, count: $0.source.count) }
    }

    /// Writes the shape at `t` into `output` (from `allocateOutput`). `t` is
    /// clamped to -0.25...1.25, as a spring may overshoot either end.
    func interpolate(_ t: Double, into output: inout [[Double]]) {
        precondition(output.count == items.count, "output must come from allocateOutput()")
        let bounded = t.isFinite ? min(max(t, -0.25), 1.25) : 0
        for index in items.indices {
            interpolateItem(items[index], bounded, &output[index])
        }
    }
}

private func validateShapes(_ source: MorphShape, _ target: MorphShape) throws {
    if source.contours.isEmpty || target.contours.isEmpty {
        throw MorphGeometryError("Cannot morph an empty shape")
    }
    for shape in [source, target] {
        if let exact = shape.exactContours, exact.count != shape.contours.count {
            throw MorphGeometryError("Exact and sampled contour counts differ")
        }
        for contour in shape.contours
        where contour.points.count < 4 || contour.points.count % 2 == 1 || !contour.points.allSatisfy(\.isFinite) {
            throw MorphGeometryError("Invalid morph point cardinality")
        }
    }
}

private func pairPointCount(_ source: MorphShape, _ target: MorphShape, _ si: Int?, _ ti: Int?) -> Int {
    max(si.map { source.contours[$0].points.count / 2 } ?? 0, ti.map { target.contours[$0].points.count / 2 } ?? 0)
}

private func pointsAtCardinality(_ shape: MorphShape, _ index: Int, _ pointCount: Int) throws -> [Double] {
    let points = shape.contours[index].points
    let current = points.count / 2
    if current == pointCount { return points }
    if let exact = shape.exactContours {
        return try resampleContour(exact[index], pointCount: pointCount)
    }
    guard pointCount % current == 0 else {
        throw MorphGeometryError("Incompatible morph point cardinality")
    }
    return subdividePolygon(points, pointCount / current)
}

private func subdividePolygon(_ source: [Double], _ factor: Int) -> [Double] {
    let n = source.count / 2
    var output = [Double](repeating: 0, count: source.count * factor)
    var out = 0
    for point in 0..<n {
        let next = point + 1 == n ? 0 : point + 1
        let x = source[2 * point], y = source[2 * point + 1]
        let dx = source[2 * next] - x, dy = source[2 * next + 1] - y
        for step in 0..<factor {
            let t = Double(step) / Double(factor)
            output[2 * out] = x + dx * t
            output[2 * out + 1] = y + dy * t
            out += 1
        }
    }
    return output
}

// MARK: Contour matching

private func matchContours(_ source: MorphShape, _ target: MorphShape) -> [(Int?, Int?)] {
    var pairs: [(Int?, Int?)] = []
    for isHole in [false, true] {
        let sourceIndices = source.contours.indices.filter { source.contours[$0].isHole == isHole }
        let targetIndices = target.contours.indices.filter { target.contours[$0].isHole == isHole }
        pairs += matchRole(source, target, sourceIndices, targetIndices)
    }
    return pairs
}

private func matchRole(
    _ source: MorphShape,
    _ target: MorphShape,
    _ sourceIndices: [Int],
    _ targetIndices: [Int]
) -> [(Int?, Int?)] {
    if sourceIndices.isEmpty { return targetIndices.map { (nil, $0) } }
    if targetIndices.isEmpty { return sourceIndices.map { ($0, nil) } }
    if sourceIndices.count == 1, targetIndices.count == 1 {
        return [(sourceIndices[0], targetIndices[0])]
    }

    let sourceScale = maximumArea(source, sourceIndices)
    let targetScale = maximumArea(target, targetIndices)
    let sourceMetrics = sourceIndices.map { contourMetrics(source, $0, sourceScale) }
    let targetMetrics = targetIndices.map { contourMetrics(target, $0, targetScale) }
    let costs = sourceMetrics.map { s in targetMetrics.map { contourCost(s, $0) } }

    if sourceIndices.count <= targetIndices.count {
        let assignment = minimumInjection(sourceIndices.count, targetIndices.count) { costs[$0][$1] }
        let used = Set(assignment)
        return sourceIndices.indices.map { (sourceIndices[$0], targetIndices[assignment[$0]]) }
            + targetIndices.indices.filter { !used.contains($0) }.map { (nil, targetIndices[$0]) }
    }

    let assignment = minimumInjection(targetIndices.count, sourceIndices.count) { costs[$1][$0] }
    var targetBySource: [Int: Int] = [:]
    for (targetPosition, sourcePosition) in assignment.enumerated() {
        targetBySource[sourcePosition] = targetPosition
    }
    return sourceIndices.indices.map { position in
        (sourceIndices[position], targetBySource[position].map { targetIndices[$0] })
    }
}

private func maximumArea(_ shape: MorphShape, _ indices: [Int]) -> Double {
    indices.map { abs(shape.contours[$0].signedArea) }.reduce(energyEpsilon, max)
}

private struct ContourMetrics {
    let centroid: Point2
    let length: Double
    let area: Double
    let depth: Int
    let parentCentroid: Point2?
}

private func contourMetrics(_ shape: MorphShape, _ index: Int, _ areaScale: Double) -> ContourMetrics {
    let contour = shape.contours[index]
    return ContourMetrics(
        centroid: centroid(contour.points),
        length: polygonLength(contour.points) / areaScale.squareRoot(),
        area: abs(contour.signedArea) / areaScale,
        depth: contour.depth,
        parentCentroid: contour.parent.map { centroid(shape.contours[$0].points) }
    )
}

private func contourCost(_ source: ContourMetrics, _ target: ContourMetrics) -> Double {
    var parentCost = 0.0
    if (source.parentCentroid == nil) != (target.parentCentroid == nil) {
        parentCost = 2
    } else if let a = source.parentCentroid, let b = target.parentCentroid {
        parentCost = distance(a, b)
    }
    return distance(source.centroid, target.centroid)
        + 0.35 * abs(source.length - target.length)
        + 0.5 * abs(source.area - target.area)
        + 0.75 * Double(abs(source.depth - target.depth))
        + 0.25 * parentCost
}

/// The cheapest one-to-one map from `smallCount` items into `largeCount`:
/// exact by branch and bound while the choices are few, else greedy.
private func minimumInjection(_ smallCount: Int, _ largeCount: Int, _ cost: (Int, Int) -> Double) -> [Int] {
    var possibilities = 1
    for i in 0..<smallCount {
        possibilities *= largeCount - i
        if possibilities > exactAssignmentLimit { break }
    }
    if possibilities > exactAssignmentLimit {
        return greedyInjection(smallCount, largeCount, cost)
    }
    var current = [Int](repeating: -1, count: smallCount)
    var used = [Bool](repeating: false, count: largeCount)
    var best = current
    var bestCost = Double.infinity
    func search(_ small: Int, _ accumulated: Double) {
        if accumulated >= bestCost { return }
        if small == smallCount {
            bestCost = accumulated
            best = current
            return
        }
        for large in 0..<largeCount where !used[large] {
            used[large] = true
            current[small] = large
            search(small + 1, accumulated + cost(small, large))
            used[large] = false
        }
    }
    search(0, 0)
    return best
}

private func greedyInjection(_ smallCount: Int, _ largeCount: Int, _ cost: (Int, Int) -> Double) -> [Int] {
    var candidates: [(Double, Int, Int)] = []
    for small in 0..<smallCount {
        for large in 0..<largeCount { candidates.append((cost(small, large), small, large)) }
    }
    candidates.sort { a, b in
        if a.0 != b.0 { return a.0 < b.0 }
        if a.1 != b.1 { return a.1 < b.1 }
        return a.2 < b.2
    }
    var assignment = [Int](repeating: -1, count: smallCount)
    var usedLarge = [Bool](repeating: false, count: largeCount)
    for (_, small, large) in candidates where assignment[small] < 0 && !usedLarge[large] {
        assignment[small] = large
        usedLarge[large] = true
    }
    for small in 0..<smallCount where assignment[small] < 0 {
        var bestLarge = -1
        var bestCost = Double.infinity
        for large in 0..<largeCount where !usedLarge[large] && cost(small, large) < bestCost {
            bestCost = cost(small, large)
            bestLarge = large
        }
        assignment[small] = bestLarge
        usedLarge[bestLarge] = true
    }
    return assignment
}

/// Where a contour with no partner grows from (or shrinks to): the centre
/// of the nearest contour of the same role in the other shape.
private func collapsePoint(_ actual: SampledContour, _ actualShape: MorphShape, _ otherShape: MorphShape) -> Point2 {
    let reference = actual.parent.map { actualShape.contours[$0] } ?? actual
    let candidates = otherShape.contours.filter { $0.isHole == reference.isHole }
    if candidates.isEmpty { return shapeCentroid(otherShape) }
    let referenceCentroid = centroid(reference.points)
    let nearest = candidates.min { a, b in
        distance(centroid(a.points), referenceCentroid) < distance(centroid(b.points), referenceCentroid)
    }!
    return centroid(nearest.points)
}

private func shapeCentroid(_ shape: MorphShape) -> Point2 {
    var x = 0.0, y = 0.0
    for contour in shape.contours {
        let c = centroid(contour.points)
        x += c.x
        y += c.y
    }
    let n = Double(shape.contours.count)
    return (x / n, y / n)
}

private func collapsedPoints(_ length: Int, _ point: Point2) -> [Double] {
    var output = [Double](repeating: 0, count: length)
    for i in stride(from: 0, to: length, by: 2) {
        output[i] = point.x
        output[i + 1] = point.y
    }
    return output
}

// MARK: Pair alignment

private struct Similarity {
    var theta: Double
    var scale: Double
    var residual: Double
}

private struct Alignment {
    let source: [Double]
    let target: [Double]
    let sourceCentroid: Point2
    let targetCentroid: Point2
    let similarity: Similarity
}

private func alignPair(_ source: [Double], _ target: [Double], allowTargetReversal: Bool) -> Alignment {
    let sourceCentroid = centroid(source)
    let targetCentroid = centroid(target)
    let pointCount = source.count / 2
    let sourceEnergy = pointEnergy(source, sourceCentroid)
    let targetEnergy = pointEnergy(target, targetCentroid)
    if sourceEnergy <= energyEpsilon || targetEnergy <= energyEpsilon {
        return Alignment(
            source: source,
            target: target,
            sourceCentroid: sourceCentroid,
            targetCentroid: targetCentroid,
            similarity: procrustesShifted(source, target, sourceCentroid, targetCentroid, reversed: false, offset: 0)
        )
    }
    let reversed = allowTargetReversal && signedPolygonArea(source) * signedPolygonArea(target) < 0
    let shortlist: [Bool]? = pointCount >= minimumFftAlignmentPointCount && isPowerOfTwo(pointCount)
        ? alignmentShortlist(fftAlignmentScores(
            source, target, sourceCentroid, targetCentroid, sourceEnergy, targetEnergy, reversed: reversed
        ))
        : nil
    var bestScore = Double.infinity
    var bestOffset = 0
    var bestSimilarity = Similarity(theta: 0, scale: 1, residual: 0)
    for offset in 0..<pointCount {
        if let shortlist, !shortlist[offset] { continue }
        let similarity = procrustesShifted(
            source, target, sourceCentroid, targetCentroid, reversed: reversed, offset: offset
        )
        let score = alignmentScore(similarity)
        if score < bestScore {
            bestScore = score
            bestOffset = offset
            bestSimilarity = similarity
        }
    }
    return Alignment(
        source: source,
        target: orientedPoints(target, reversed: reversed, offset: bestOffset),
        sourceCentroid: sourceCentroid,
        targetCentroid: targetCentroid,
        similarity: bestSimilarity
    )
}

/// Every ring offset's alignment score at once, by circular
/// cross-correlation in O(n log n). The shortlist it gives is still checked
/// by the exact Procrustes pass.
private func fftAlignmentScores(
    _ source: [Double],
    _ target: [Double],
    _ sourceCentroid: Point2,
    _ targetCentroid: Point2,
    _ sourceEnergy: Double,
    _ targetEnergy: Double,
    reversed: Bool
) -> [Double] {
    let n = source.count / 2
    let sourceSpectrum = pointSpectrum(source, sourceCentroid, reversed: false)
    let targetSpectrum = pointSpectrum(target, targetCentroid, reversed: reversed)
    var correlation = [Double](repeating: 0, count: 2 * n)
    for f in 0..<n {
        let i = 2 * f
        let sr = sourceSpectrum[i], si = sourceSpectrum[i + 1]
        let tr = targetSpectrum[i], ti = targetSpectrum[i + 1]
        correlation[i] = sr * tr + si * ti
        correlation[i + 1] = sr * ti - si * tr
    }
    fft(&correlation, inverse: true)
    return (0..<n).map { offset in
        alignmentScore(similarityFromCorrelation(
            correlation[2 * offset], correlation[2 * offset + 1], sourceEnergy, targetEnergy
        ))
    }
}

private func pointSpectrum(_ points: [Double], _ centroid: Point2, reversed: Bool) -> [Double] {
    let n = points.count / 2
    var spectrum = [Double](repeating: 0, count: points.count)
    for point in 0..<n {
        let from = reversed ? n - 1 - point : point
        spectrum[2 * point] = points[2 * from] - centroid.x
        spectrum[2 * point + 1] = points[2 * from + 1] - centroid.y
    }
    fft(&spectrum, inverse: false)
    return spectrum
}

private func alignmentShortlist(_ scores: [Double]) -> [Bool] {
    let best = scores.min() ?? .infinity
    return scores.map { $0 <= best + alignmentScoreTolerance }
}

private func isPowerOfTwo(_ value: Int) -> Bool { value > 0 && value & (value - 1) == 0 }

/// In-place iterative radix-2 Cooley-Tukey transform over interleaved
/// complex values; the count must be a power of two.
private func fft(_ values: inout [Double], inverse: Bool) {
    let n = values.count / 2
    var reversed = 0
    for point in 1..<max(n, 1) {
        var bit = n >> 1
        while reversed & bit != 0 {
            reversed ^= bit
            bit >>= 1
        }
        reversed ^= bit
        if point >= reversed { continue }
        values.swapAt(2 * point, 2 * reversed)
        values.swapAt(2 * point + 1, 2 * reversed + 1)
    }
    var length = 2
    while length <= n {
        let angle = (inverse ? 2.0 : -2.0) * .pi / Double(length)
        let stepReal = cos(angle), stepImaginary = sin(angle)
        let half = length >> 1
        for start in stride(from: 0, to: n, by: length) {
            var twiddleReal = 1.0, twiddleImaginary = 0.0
            for offset in 0..<half {
                let even = 2 * (start + offset)
                let odd = 2 * (start + offset + half)
                let oddReal = values[odd] * twiddleReal - values[odd + 1] * twiddleImaginary
                let oddImaginary = values[odd] * twiddleImaginary + values[odd + 1] * twiddleReal
                let evenReal = values[even], evenImaginary = values[even + 1]
                values[even] = evenReal + oddReal
                values[even + 1] = evenImaginary + oddImaginary
                values[odd] = evenReal - oddReal
                values[odd + 1] = evenImaginary - oddImaginary
                let nextReal = twiddleReal * stepReal - twiddleImaginary * stepImaginary
                twiddleImaginary = twiddleReal * stepImaginary + twiddleImaginary * stepReal
                twiddleReal = nextReal
            }
        }
        length <<= 1
    }
    if !inverse { return }
    for i in values.indices { values[i] /= Double(n) }
}

private func createItem(_ alignment: Alignment, sourceCollapsed: Bool, targetCollapsed: Bool) -> MorphPlanItem {
    let n = alignment.source.count / 2
    var sourceCentered = [Double](repeating: 0, count: alignment.source.count)
    var targetInSourceFrame = [Double](repeating: 0, count: alignment.target.count)
    let similarity = alignment.similarity
    // A near-zero scale is meaningful for a good fit (a contour collapsing to
    // a point). With an almost total residual it would instead divide
    // unrelated target points by a tiny number and explode the frames between.
    let useSimilarity = similarity.scale >= minimumStableSimilarityScale
        || similarity.residual <= maximumDegenerateSimilarityResidual
    let theta = useSimilarity ? similarity.theta : 0
    let scale = useSimilarity ? similarity.scale : 1
    let inverseCosine = cos(-theta), inverseSine = sin(-theta)
    for i in 0..<n {
        sourceCentered[2 * i] = alignment.source[2 * i] - alignment.sourceCentroid.x
        sourceCentered[2 * i + 1] = alignment.source[2 * i + 1] - alignment.sourceCentroid.y
        let tx = alignment.target[2 * i] - alignment.targetCentroid.x
        let ty = alignment.target[2 * i + 1] - alignment.targetCentroid.y
        targetInSourceFrame[2 * i] = (tx * inverseCosine - ty * inverseSine) / scale
        targetInSourceFrame[2 * i + 1] = (tx * inverseSine + ty * inverseCosine) / scale
    }
    return MorphPlanItem(
        source: alignment.source,
        sourceCentered: sourceCentered,
        targetInSourceFrame: targetInSourceFrame,
        orientedTarget: alignment.target,
        sourceCentroid: alignment.sourceCentroid,
        targetCentroid: alignment.targetCentroid,
        theta: theta,
        logScale: log(scale),
        residual: similarity.residual,
        sourceCollapsed: sourceCollapsed,
        targetCollapsed: targetCollapsed
    )
}

/// When the pairs together are one rigid motion (a whole glyph turning or
/// growing), move them as one block, so its parts don't drift apart.
private func applyGlobalAlignment(_ items: inout [MorphPlanItem]) {
    var sx = 0.0, sy = 0.0, tx = 0.0, ty = 0.0
    for item in items {
        sx += item.sourceCentroid.x
        sy += item.sourceCentroid.y
        tx += item.targetCentroid.x
        ty += item.targetCentroid.y
    }
    let count = Double(items.count)
    let sourceCentroid: Point2 = (sx / count, sy / count)
    let targetCentroid: Point2 = (tx / count, ty / count)
    var dot = 0.0, cross = 0.0, sourceEnergy = 0.0, targetEnergy = 0.0
    for item in items {
        let weight = 1 / Double(item.source.count / 2)
        for i in stride(from: 0, to: item.source.count, by: 2) {
            let sx = item.source[i] - sourceCentroid.x
            let sy = item.source[i + 1] - sourceCentroid.y
            let tx = item.orientedTarget[i] - targetCentroid.x
            let ty = item.orientedTarget[i + 1] - targetCentroid.y
            dot += weight * (sx * tx + sy * ty)
            cross += weight * (sx * ty - sy * tx)
            sourceEnergy += weight * (sx * sx + sy * sy)
            targetEnergy += weight * (tx * tx + ty * ty)
        }
    }
    let global = similarityFromCorrelation(dot, cross, sourceEnergy, targetEnergy)
    if global.residual >= globalResidualThreshold { return }

    let inverseCosine = cos(-global.theta), inverseSine = sin(-global.theta)
    let cosine = cos(global.theta), sine = sin(global.theta)
    for index in items.indices {
        var item = items[index]
        var squaredError = 0.0
        var energy = 0.0
        for i in stride(from: 0, to: item.source.count, by: 2) {
            let tx = item.orientedTarget[i] - item.targetCentroid.x
            let ty = item.orientedTarget[i + 1] - item.targetCentroid.y
            item.targetInSourceFrame[i] = (tx * inverseCosine - ty * inverseSine) / global.scale
            item.targetInSourceFrame[i + 1] = (tx * inverseSine + ty * inverseCosine) / global.scale
            let ex = global.scale * (cosine * item.sourceCentered[i] - sine * item.sourceCentered[i + 1]) - tx
            let ey = global.scale * (sine * item.sourceCentered[i] + cosine * item.sourceCentered[i + 1]) - ty
            squaredError += ex * ex + ey * ey
            energy += tx * tx + ty * ty
        }
        item.theta = global.theta
        item.logScale = log(global.scale)
        item.residual = energy > energyEpsilon ? (squaredError / energy).squareRoot() : 0
        let ox = item.sourceCentroid.x - sourceCentroid.x
        let oy = item.sourceCentroid.y - sourceCentroid.y
        let scaledCosine = cos(item.theta) * exp(item.logScale)
        let scaledSine = sin(item.theta) * exp(item.logScale)
        let rx = ox * scaledCosine - oy * scaledSine - ox
        let ry = ox * scaledSine + oy * scaledCosine - oy
        item.blockOffset = (ox, oy)
        item.blockDrift = (
            item.targetCentroid.x - item.sourceCentroid.x - rx,
            item.targetCentroid.y - item.sourceCentroid.y - ry
        )
        items[index] = item
    }
}

/// A collapsed side as a plain homothety toward its point: no turn, no
/// exponential scale, so at t its size is 1 - t (leaving) or t (arriving),
/// and its centre travels in step.
private func makeGradual(_ item: inout MorphPlanItem) {
    item.theta = 0
    item.logScale = 0
    item.gradual = true
    for i in stride(from: 0, to: item.orientedTarget.count, by: 2) {
        item.targetInSourceFrame[i] = item.orientedTarget[i] - item.targetCentroid.x
        item.targetInSourceFrame[i + 1] = item.orientedTarget[i + 1] - item.targetCentroid.y
    }
}

private func interpolateItem(_ item: MorphPlanItem, _ t: Double, _ output: inout [Double]) {
    // Past either end a gradual collapse stays put: a point stays a point
    // rather than turning inside out.
    let t = item.gradual ? min(max(t, 0), 1) : t
    let scale = exp(item.logScale * t)
    let angle = item.theta * t
    let cosine = cos(angle) * scale
    let sine = sin(angle) * scale
    let cx: Double, cy: Double
    if let offset = item.blockOffset, let drift = item.blockDrift {
        cx = item.sourceCentroid.x + drift.x * t + (offset.x * cosine - offset.y * sine - offset.x)
        cy = item.sourceCentroid.y + drift.y * t + (offset.x * sine + offset.y * cosine - offset.y)
    } else {
        cx = item.sourceCentroid.x + (item.targetCentroid.x - item.sourceCentroid.x) * t
        cy = item.sourceCentroid.y + (item.targetCentroid.y - item.sourceCentroid.y) * t
    }
    item.sourceCentered.withUnsafeBufferPointer { s in
        item.targetInSourceFrame.withUnsafeBufferPointer { g in
            output.withUnsafeMutableBufferPointer { out in
                for i in stride(from: 0, to: out.count, by: 2) {
                    let x = s[i] + (g[i] - s[i]) * t
                    let y = s[i + 1] + (g[i + 1] - s[i + 1]) * t
                    out[i] = cx + x * cosine - y * sine
                    out[i + 1] = cy + x * sine + y * cosine
                }
            }
        }
    }
}

private func procrustesShifted(
    _ source: [Double],
    _ target: [Double],
    _ sourceCentroid: Point2,
    _ targetCentroid: Point2,
    reversed: Bool,
    offset: Int
) -> Similarity {
    var xx = 0.0, xy = 0.0, yx = 0.0, yy = 0.0
    var sourceEnergy = 0.0, targetEnergy = 0.0
    let n = source.count / 2
    var targetPoint = reversed ? n - 1 - offset : offset
    source.withUnsafeBufferPointer { s in
        target.withUnsafeBufferPointer { g in
            for sourcePoint in 0..<n {
                let sx = s[2 * sourcePoint] - sourceCentroid.x
                let sy = s[2 * sourcePoint + 1] - sourceCentroid.y
                let tx = g[2 * targetPoint] - targetCentroid.x
                let ty = g[2 * targetPoint + 1] - targetCentroid.y
                xx += sx * tx
                xy += sx * ty
                yx += sy * tx
                yy += sy * ty
                sourceEnergy += sx * sx + sy * sy
                targetEnergy += tx * tx + ty * ty
                if reversed {
                    targetPoint = targetPoint == 0 ? n - 1 : targetPoint - 1
                } else {
                    targetPoint = targetPoint + 1 == n ? 0 : targetPoint + 1
                }
            }
        }
    }
    return similarityFromCorrelation(xx + yy, xy - yx, sourceEnergy, targetEnergy)
}

private func similarityFromCorrelation(
    _ dot: Double,
    _ cross: Double,
    _ sourceEnergy: Double,
    _ targetEnergy: Double
) -> Similarity {
    let theta = atan2(cross, dot)
    let numerator = cos(theta) * dot + sin(theta) * cross
    var scale = sourceEnergy > energyEpsilon ? numerator / sourceEnergy : 1
    if !(scale > minimumScale) { scale = minimumScale }
    let squaredResidual = max(0, scale * scale * sourceEnergy - 2 * scale * numerator + targetEnergy)
    let residual = targetEnergy > energyEpsilon ? (squaredResidual / targetEnergy).squareRoot() : 0
    return Similarity(theta: theta, scale: scale, residual: residual)
}

private func alignmentScore(_ similarity: Similarity) -> Double {
    similarity.residual + rotationTieBreak * abs(similarity.theta) / .pi
}

private func pointEnergy(_ points: [Double], _ centroid: Point2) -> Double {
    var energy = 0.0
    for i in stride(from: 0, to: points.count, by: 2) {
        let x = points[i] - centroid.x, y = points[i + 1] - centroid.y
        energy += x * x + y * y
    }
    return energy
}

func centroid(_ points: [Double]) -> Point2 {
    var x = 0.0, y = 0.0
    for i in stride(from: 0, to: points.count, by: 2) {
        x += points[i]
        y += points[i + 1]
    }
    let n = Double(points.count / 2)
    return (x / n, y / n)
}

private func polygonLength(_ points: [Double]) -> Double {
    var length = 0.0
    let n = points.count / 2
    for i in 0..<n {
        let next = (i + 1) % n
        let dx = points[2 * next] - points[2 * i], dy = points[2 * next + 1] - points[2 * i + 1]
        length += (dx * dx + dy * dy).squareRoot()
    }
    return length
}

private func distance(_ a: Point2, _ b: Point2) -> Double {
    let dx = a.x - b.x, dy = a.y - b.y
    return (dx * dx + dy * dy).squareRoot()
}

private func orientedPoints(_ points: [Double], reversed: Bool, offset: Int) -> [Double] {
    let n = points.count / 2
    var output = [Double](repeating: 0, count: points.count)
    var from = reversed ? n - 1 - offset : offset
    for to in 0..<n {
        output[2 * to] = points[2 * from]
        output[2 * to + 1] = points[2 * from + 1]
        if reversed {
            from = from == 0 ? n - 1 : from - 1
        } else {
            from = from + 1 == n ? 0 : from + 1
        }
    }
    return output
}
