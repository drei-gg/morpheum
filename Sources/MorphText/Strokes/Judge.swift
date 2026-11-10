// Ported from morphtext for Flutter (lib/src/judge.dart, strokes branch):
// which shapes outlines morph better than anything else (a shape filling in
// or hollowing out, a solid one), by measuring their ink.

import Foundation

/// The resolution shapes are measured at: coarse, since it only compares
/// two shapes' ink.
private let judgePixelsPerEm = 64.0

/// Whether outlines should morph `from` into `to` rather than another
/// engine: a shape filling in or hollowing out (outlines fill the hole in
/// place), or either end solid (outlines keep its edge).
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
