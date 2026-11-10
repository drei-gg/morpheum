// Ported from morphtext for Flutter (lib/src/judge.dart, strokes branch):
// which engine morphs a letter pair better, by looking. A few frames of
// each, measured for the faults an eye catches: ink far thicker than either
// end, holes that close up, a letter breaking into bits.

import Foundation

/// The resolution frames are judged at: coarse, since it compares two
/// morphs of one letter, not either against the font.
private let judgePixelsPerEm = 64.0

private let judgeSamples = [0.25, 0.5, 0.75]

/// What a morph's `frames` get wrong, against its ends (`from` and `to`):
/// 0 for none. Thickness past the thicker end counts by how far past; a
/// frame whose holes close up below both ends', or whose ink breaks into
/// more pieces than either end's, counts a third each.
func fault(_ frames: [Ink], _ from: Ink, _ to: Ink) -> Double {
    let ends = max(from.thickest, to.thickest)
    let fewest = min(from.holes(), to.holes())
    let most = max(from.pieces(), to.pieces())
    var score = 0.0, peak = 0.0
    for ink in frames {
        peak = max(peak, ink.thickest)
        if ink.holes() < fewest { score += 1.0 / 3 }
        if ink.pieces() > most { score += 1.0 / 3 }
    }
    if ends > 0 { score += 4 * max(0, peak / ends - 1.05) }
    return score
}

/// Whether outlines should morph `from` into `to`, whatever strokes do: a
/// shape filling in or hollowing out, or either end solid. Strokes make a
/// solid shape out of a few huge discs, and blend a thin letter into them
/// as blobs; outlines keep its edge.
func keepsOutlines(_ from: [[Double]], _ to: [[Double]]) -> Bool {
    isSolid(from) || isSolid(to) || fillsIn(from, to)
}

/// Whether `shape` is solid rather than drawn: its thickest point a quarter
/// of its extent or more (a heart, a play triangle; not a letter, even a
/// black one, nor a tick).
func isSolid(_ shape: [[Double]]) -> Bool {
    let ink = Ink(polygons: shape, pixelsPerEm: judgePixelsPerEm)
    let (w, h) = ink.extent
    let extent = max(w, h)
    return extent > 0 && ink.thickest / extent >= 0.25
}

/// Whether `from` and `to` are one shape, hollow at one end and solid at
/// the other (or holed differently): their silhouettes, holes filled,
/// mostly overlap (by four fifths), and their holes don't.
func fillsIn(_ from: [[Double]], _ to: [[Double]]) -> Bool {
    let (overlap, holesA, holesB) = silhouettes(from, to)
    return overlap > 0.8 && abs(holesA - holesB) > 0.1
}

/// Whether `strokes` should morph `from` into `to` rather than `outlines`,
/// by `fault`. Between different letters, strokes unless outlines are
/// clearly better (a hollow icon filling in, where the outline fills the
/// hole in place). For the `same` letter, another weight or font, outlines
/// (exact, and every counter kept) unless strokes are clearly better.
func strokesWin(_ outlines: MorphOutlinePlan, _ strokes: StrokeMorph, _ from: [[Double]], _ to: [[Double]],
                same: Bool = false) -> Bool {
    if keepsOutlines(from, to) { return false }
    let a = Ink(polygons: from, pixelsPerEm: judgePixelsPerEm), b = Ink(polygons: to, pixelsPerEm: judgePixelsPerEm)
    let s = fault(judgeSamples.map { Ink(strokes: strokes.at($0), pixelsPerEm: judgePixelsPerEm) }, a, b)
    if s == 0 && !same { return true }
    var output = outlines.allocateOutput()
    let o = fault(judgeSamples.map { t in
        outlines.interpolate(t, into: &output)
        return Ink(polygons: output, pixelsPerEm: judgePixelsPerEm)
    }, a, b)
    return same ? s < o - 0.1 : o >= s - 0.1
}

/// Whether `strokes`, with the corners they miss, are each end's own shape
/// at rest (`from` and `to`), so the text or symbol takes over from them
/// with nothing to settle: no more than `tolerance` of the ink differs.
///
/// Letters trace to within about a percent; a symbol with fine detail (a
/// gear's teeth, 2.6% off) may not, and lands with a jump. Not in the
/// Flutter package.
func landsTrue(_ strokes: StrokeMorph, _ corners: (Corners, Corners), _ from: [[Double]], _ to: [[Double]],
               tolerance: Double = 0.015) -> Bool {
    for (t, shape, corner) in [(0.0, from, corners.0), (1.0, to, corners.1)] {
        var drawn = strokes.at(t).flatMap(strokePolygons)
        drawn += corner.pieces.map { $0.points.map { $0 / Corners.scale } }
        let (onlyShape, onlyDrawn, area) = inkDifference(shape, drawn, pixelsPerEm: 192)
        if area == 0 || Double(onlyShape + onlyDrawn) > tolerance * Double(area) { return false }
    }
    return true
}
