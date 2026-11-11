/// Which letter of one word becomes which letter of another.
///
/// A weighted edit distance: a letter kept as itself costs nothing, a letter
/// morphing into another costs a little less than one growing in or
/// shrinking away, and a letter never morphs into a space. So most letters
/// morph into the letter at the same place (`Amethyst` into `Citrine`), as
/// few as possible appear or vanish (only the length difference, usually),
/// and a word slides only when that keeps many letters as themselves (`Ruby`
/// into `bRuby`).
///
/// Returns one entry per pair, in order: an index into `a`, into `b`, or
/// both.
func alignLetters(_ a: [Character], _ b: [Character]) -> [(Int?, Int?)] {
    let gap = 1.0
    func change(_ x: Character, _ y: Character) -> Double {
        if x == y { return 0 }
        let space = x.isWhitespace, otherSpace = y.isWhitespace
        if space || otherSpace { return space && otherSpace ? 0 : 3 * gap }
        if x.lowercased() == y.lowercased() { return 0.4 }
        return 0.9
    }

    let n = a.count, m = b.count
    // cost[i][j]: aligning a[i...] with b[j...].
    var cost = [[Double]](repeating: [Double](repeating: 0, count: m + 1), count: n + 1)
    for i in stride(from: n, through: 0, by: -1) {
        for j in stride(from: m, through: 0, by: -1) {
            if i == n, j == m { continue }
            var best = Double.infinity
            if i < n, j < m { best = change(a[i], b[j]) + cost[i + 1][j + 1] }
            if i < n { best = min(best, gap + cost[i + 1][j]) }
            if j < m { best = min(best, gap + cost[i][j + 1]) }
            cost[i][j] = best
        }
    }
    var pairs: [(Int?, Int?)] = []
    var i = 0, j = 0
    let eps = 1e-9
    while i < n || j < m {
        // Prefer pairing, then letting a's letter go, then b's growing in.
        if i < n, j < m, abs(cost[i][j] - change(a[i], b[j]) - cost[i + 1][j + 1]) < eps {
            pairs.append((i, j))
            i += 1
            j += 1
        } else if i < n, abs(cost[i][j] - gap - cost[i + 1][j]) < eps {
            pairs.append((i, nil))
            i += 1
        } else {
            pairs.append((nil, j))
            j += 1
        }
    }
    return pairs
}

/// Every letter of a word paired with the single glyph at the other end (a
/// symbol, say), so the whole word flows into it, or out of it. Spaces pair
/// with nothing. When neither end is a single glyph, or both are, it is
/// `alignLetters`.
func convergeLetters(_ a: [Character], _ b: [Character]) -> [(Int?, Int?)] {
    if (a.count == 1) == (b.count == 1) { return alignLetters(a, b) }
    let one = a.count == 1
    let many = one ? b : a
    return many.indices.map { k in
        if many[k].isWhitespace { return one ? (nil, k) : (k, nil) }
        return one ? (0, k) : (k, 0)
    }
}
