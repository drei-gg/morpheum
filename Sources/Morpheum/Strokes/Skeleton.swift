// Ported from morphtext for Flutter (lib/src/skeleton.dart, strokes
// branch): a glyph's medial axis as a graph, thinned from its pixels, pruned
// of noise, and read as lines. Strokes.swift turns the lines into strokes.

import Foundation

/// `mask` thinned to one-pixel lines along its medial axis.
///
/// Pixels are peeled from the outside in, in order of their distance from
/// the edge (`d2`), each only if removing it can't change the shape's
/// topology (it is "simple": one neighbouring piece of ink, and it borders
/// the outside) and it isn't the end of a line. Pixels on a ridge of the
/// distance (the centres of the largest discs that fit, the medial axis)
/// are never peeled, so the lines run on into every corner and lobe: thin
/// as a stroke, out to the tip of a heart. Parallel thinning (Zhang and
/// Suen, Guo and Hall) erodes those branches from their ends, and wipes out
/// some diagonals outright.
///
/// The mask needs a border of at least one empty pixel all round.
func thinToSkeleton(_ mask: inout [UInt8], _ d2: [Double], _ nearest: [Int32], _ w: Int, _ h: Int) {
    let ring = [1, 1 - w, -w, -1 - w, -1, -1 + w, w, 1 + w]
    // The medial axis, filtered: a pixel whose nearest point outside lies
    // in another direction from its neighbour's (opposite sides of a stroke,
    // two edges of a corner) is on it. The raw medial axis of a pixel image
    // is mostly hairs, where an edge's pixel steps make neighbours' nearest
    // points jump along the same edge: those lie the same way, and are close.
    // So: at least sixty degrees apart, at least three pixels (or half the
    // depth) apart, and not in the outermost two pixels.
    var anchor = [UInt8](repeating: 0, count: w * h)
    var maxLevel = 0
    for p in 0..<(w * h) {
        if mask[p] == 0 { continue }
        maxLevel = max(maxLevel, Int(d2[p].rounded()))
        if d2[p] < 4 { continue }
        let px = p % w, py = p / w
        let fp = Int(nearest[p])
        let ax = fp % w - px, ay = fp / w - py
        let far = max(9.0, d2[p] / 4)
        for q in [p + 1, p - 1, p + w, p - w, p + w + 1, p - w - 1, p + w - 1, p - w + 1] {
            if mask[q] == 0 { continue }
            let fq = Int(nearest[q])
            let dx = fq % w - fp % w, dy = fq / w - fp / w
            if Double(dx * dx + dy * dy) < far { continue }
            let bx = fq % w - q % w, by = fq / w - q / w
            let dot = Double(ax * bx + ay * by)
            let norms = (Double(ax * ax + ay * ay) * Double(bx * bx + by * by)).squareRoot()
            if norms > 0, dot <= 0.5 * norms {
                anchor[p] = 1
                break
            }
        }
    }
    func neighbours(_ p: Int) -> Int {
        var n = 0
        for o in ring { n += Int(mask[p + o]) }
        return n
    }
    // Whether removing p leaves the ink around it in one piece and makes no
    // hole: its 8-connectivity number (Yokoi's) is one.
    func simple(_ p: Int) -> Bool {
        var c = 0
        for k in stride(from: 0, to: 8, by: 2) {
            let a = 1 - Int(mask[p + ring[k]])
            let b = 1 - Int(mask[p + ring[k + 1]])
            let e = 1 - Int(mask[p + ring[(k + 2) % 8]])
            c += a - a * b * e
        }
        return c == 1
    }

    // By distance from the edge, nearest first.
    var buckets = [[Int]](repeating: [], count: maxLevel + 1)
    for p in 0..<(w * h) where mask[p] == 1 {
        buckets[Int(d2[p].rounded())].append(p)
    }
    for level in 0...maxLevel {
        var i = 0
        while i < buckets[level].count {
            let p = buckets[level][i]
            i += 1
            if mask[p] == 0 || anchor[p] == 1 { continue }
            if neighbours(p) < 2 || !simple(p) { continue }
            mask[p] = 0
            // Its neighbours already passed may be free to go now.
            for o in ring {
                let q = p + o
                if mask[q] == 1, anchor[q] == 0, Int(d2[q].rounded()) <= level {
                    buckets[level].append(q)
                }
            }
        }
    }
    // A ridge can be two pixels wide (an even-width stroke): thin what's left
    // the same way, ridge or not, to a line one pixel wide.
    var changed = true
    while changed {
        changed = false
        for p in 0..<(w * h) {
            if mask[p] == 0 || neighbours(p) < 2 || !simple(p) { continue }
            // Not the pixel just before a line's end, which a corner leaves
            // simple: it would shorten the line.
            var ends = false
            for o in ring where mask[p + o] == 1 && neighbours(p + o) == 1 {
                ends = true
                break
            }
            if ends { continue }
            mask[p] = 0
            changed = true
        }
    }
}

/// A traced line, in pixels, with the inscribed radius at each point.
struct SkeletonLine {
    /// Whether the last point joins the first.
    let closed: Bool
    /// The points across, down, and the radius at each, in pixels.
    var xs: [Double] = [], ys: [Double] = [], rs: [Double] = []

    init(closed: Bool) { self.closed = closed }

    /// Adds a point at (`x`, `y`) with radius `r`.
    mutating func add(_ x: Double, _ y: Double, _ r: Double) {
        xs.append(x)
        ys.append(y)
        rs.append(r)
    }
}

private struct EndKey: Hashable {
    let edge: Int, side: Int
}

/// A thinned glyph as a graph: its ends and branch points, and the lines
/// between them.
final class SkeletonGraph {
    /// The picture's width, in pixels: a pixel index is y * w + x.
    let w: Int
    /// Each node's place (in pixels) and radius.
    var nodeX: [Double] = [], nodeY: [Double] = [], nodeR: [Double] = []
    /// Each line: its two nodes (-1 for a loop with none) and its pixels.
    var edges: [(a: Int, b: Int, path: [Int])] = []
    /// Whether each line is still there (pruning drops them).
    var alive: [Bool] = []
    /// Each pixel's squared distance to the outside.
    let d2: [Double]

    private init(w: Int, d2: [Double]) {
        self.w = w
        self.d2 = d2
    }

    /// The radius of the largest disc inside, centred on `pixel`, read off
    /// the pixels (Strokes.swift measures it exactly).
    func radius(_ pixel: Int) -> Double { max(0.5, d2[pixel].squareRoot() - 0.5) }

    /// The graph of `skel`, a thinned picture `w` by `h`, with `d2` its
    /// distances to the outside.
    static func build(_ skel: [UInt8], _ d2: [Double], _ w: Int, _ h: Int) -> SkeletonGraph {
        let g = SkeletonGraph(w: w, d2: d2)
        let ring = [1, 1 - w, -w, -1 - w, -1, -1 + w, w, 1 + w]
        func degree(_ p: Int) -> Int {
            var n = 0
            for o in ring { n += Int(skel[p + o]) }
            return n
        }

        var nodeOf = [Int](repeating: -1, count: w * h)
        var members: [[Int]] = []
        for p in 0..<(w * h) {
            if skel[p] == 0 || nodeOf[p] != -1 { continue }
            let deg = degree(p)
            if deg == 2 { continue }
            let id = members.count
            var cluster = [p]
            nodeOf[p] = id
            if deg >= 3 {
                var c = 0
                while c < cluster.count {
                    for o in ring {
                        let q = cluster[c] + o
                        if skel[q] == 1, nodeOf[q] == -1, degree(q) >= 3 {
                            nodeOf[q] = id
                            cluster.append(q)
                        }
                    }
                    c += 1
                }
            }
            members.append(cluster)
        }
        var visited = [UInt8](repeating: 0, count: w * h)
        var direct = Set<[Int]>()
        for id in members.indices {
            for p in members[id] {
                for o in ring {
                    let q = p + o
                    if skel[q] == 0 || nodeOf[q] == id { continue }
                    if nodeOf[q] != -1 {
                        let key = p < q ? [p, q] : [q, p]
                        if direct.insert(key).inserted { g.edges.append((id, nodeOf[q], [p, q])) }
                        continue
                    }
                    if visited[q] == 1 { continue }
                    var path = [p, q]
                    visited[q] = 1
                    var prev = p, cur = q, end = -1
                    while true {
                        var next = -1
                        for o2 in ring {
                            let r = cur + o2
                            if skel[r] == 1, r != prev, !(nodeOf[r] == id && path.count == 2 && r == p) {
                                if nodeOf[r] != -1 && r != prev {
                                    next = r
                                    break
                                }
                                if visited[r] == 0 { next = r }
                            }
                        }
                        if next == -1 { break }
                        path.append(next)
                        if nodeOf[next] != -1 {
                            end = nodeOf[next]
                            break
                        }
                        visited[next] = 1
                        prev = cur
                        cur = next
                    }
                    if end == -1 { end = id }
                    g.edges.append((id, end, path))
                }
            }
        }
        // Loops with no node on them: an o.
        for p in 0..<(w * h) {
            if skel[p] == 0 || nodeOf[p] != -1 || visited[p] == 1 { continue }
            var path = [p]
            visited[p] = 1
            var cur = p
            while true {
                var next = -1
                for o in ring {
                    let r = cur + o
                    if skel[r] == 1, visited[r] == 0 {
                        next = r
                        break
                    }
                }
                if next == -1 { break }
                visited[next] = 1
                path.append(next)
                cur = next
            }
            g.edges.append((-1, -1, path))
        }
        // Branch points a pixel or two apart are one.
        var parent = Array(members.indices)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        func isJunction(_ id: Int) -> Bool { degree(members[id][0]) >= 3 }
        var kept: [(a: Int, b: Int, path: [Int])] = []
        for e in g.edges {
            if e.a >= 0, e.b >= 0, e.a != e.b, e.path.count <= 3, isJunction(e.a), isJunction(e.b) {
                parent[find(e.a)] = find(e.b)
            } else {
                kept.append(e)
            }
        }
        var index: [Int: Int] = [:]
        var pixels: [[Int]] = []
        for i in members.indices {
            let root = find(i)
            let k: Int
            if let existing = index[root] {
                k = existing
            } else {
                pixels.append([])
                k = pixels.count - 1
                index[root] = k
            }
            pixels[k] += members[i]
        }
        for ps in pixels {
            var sx = 0.0, sy = 0.0, r = 0.0
            for p in ps {
                sx += Double(p % w)
                sy += Double(p / w)
                r = max(r, g.radius(p))
            }
            g.nodeX.append(sx / Double(ps.count))
            g.nodeY.append(sy / Double(ps.count))
            g.nodeR.append(r)
        }
        g.edges = kept.map { e in
            (e.a < 0 ? -1 : index[find(e.a)]!, e.b < 0 ? -1 : index[find(e.b)]!, e.path)
        }
        g.alive = Array(repeating: true, count: g.edges.count)
        return g
    }

    private func degrees() -> [Int] {
        var deg = [Int](repeating: 0, count: nodeX.count)
        for e in edges.indices where alive[e] {
            let (a, b, _) = edges[e]
            if a >= 0 { deg[a] += 1 }
            if b >= 0 { deg[b] += 1 }
        }
        return deg
    }

    /// Drops branches that stand out from the stroke they leave by less than
    /// `spur` of its radius, and never by more than `limit` pixels (a solid
    /// icon's stroke is a third of an em across: its lobes and corners stay),
    /// plus a pixel and a half.
    func prune(_ spur: Double, limit: Double) {
        var changed = true
        while changed {
            changed = false
            var deg = degrees()
            var endsAt: [Int: [(Int, Int)]] = [:]
            for e in edges.indices where alive[e] {
                let (a, b, _) = edges[e]
                if a >= 0 { endsAt[a, default: []].append((e, 0)) }
                if b >= 0 { endsAt[b, default: []].append((e, 1)) }
            }
            var candidates: [(out: Double, edge: Int, junction: Int)] = []
            for e in edges.indices where alive[e] {
                let (a, b, path) = edges[e]
                if a < 0 || a == b { continue }
                let junction: Int
                if deg[a] == 1, deg[b] >= 3 {
                    junction = b
                } else if deg[b] == 1, deg[a] >= 3 {
                    junction = a
                } else {
                    continue
                }
                let jx = nodeX[junction], jy = nodeY[junction], jr = nodeR[junction]
                // How far the branch's discs reach past the discs that cover the
                // most of them: the junction's, and those of the lines it leaves
                // from, a few widths along. A branch running alongside a thick
                // stroke reaches nowhere, however long.
                var cover: [(Double, Double, Double)] = [(jx, jy, jr)]
                for (other, side) in endsAt[junction] ?? [] {
                    if other == e || !alive[other] { continue }
                    let otherPath = edges[other].path
                    let along = min(otherPath.count, Int((3 * jr).rounded(.up)) + 4)
                    for i in 0..<along {
                        let q = side == 0 ? otherPath[i] : otherPath[otherPath.count - 1 - i]
                        cover.append((Double(q % w), Double(q / w), radius(q)))
                    }
                }
                var out = -Double.infinity
                for p in path {
                    let px = Double(p % w), py = Double(p / w)
                    let rp = radius(p)
                    var beyond = Double.infinity
                    for (qx, qy, qr) in cover {
                        beyond = min(beyond, hypot(px - qx, py - qy) + rp - qr)
                    }
                    out = max(out, beyond)
                }
                if out < min(spur * jr, limit) + 1.5 {
                    candidates.append((out, e, junction))
                }
            }
            candidates.sort { $0.out < $1.out }
            for (_, e, junction) in candidates {
                if deg[junction] < 3 { continue }
                alive[e] = false
                deg[junction] -= 1
                changed = true
            }
        }
    }

    /// Folds branch points joined by a line shorter than the stroke is wide
    /// into one (the apex of an A is two, a stub apart).
    func contract() {
        let deg = degrees()
        var parent = Array(nodeX.indices)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        for e in edges.indices where alive[e] {
            let (a, b, path) = edges[e]
            if a < 0 || a == b || deg[a] < 3 || deg[b] < 3 { continue }
            if Double(path.count) > 1.5 * max(nodeR[a], nodeR[b]) + 3 { continue }
            let ra = find(a), rb = find(b)
            if ra == rb { continue }
            alive[e] = false
            parent[rb] = ra
        }
        // Each merged node at the middle of what it merged, its widest radius.
        let n = nodeX.count
        var sx = [Double](repeating: 0, count: n), sy = [Double](repeating: 0, count: n)
        var count = [Int](repeating: 0, count: n), r = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let root = find(i)
            sx[root] += nodeX[i]
            sy[root] += nodeY[i]
            count[root] += 1
            r[root] = max(r[root], nodeR[i])
        }
        for i in 0..<n where count[i] > 0 {
            nodeX[i] = sx[i] / Double(count[i])
            nodeY[i] = sy[i] / Double(count[i])
            nodeR[i] = r[i]
        }
        for e in edges.indices {
            let (a, b, path) = edges[e]
            edges[e] = (a < 0 ? a : find(a), b < 0 ? b : find(b), path)
        }
    }

    /// The lines joined into strokes: through each branch point, the two
    /// lines that run most nearly straight on are one stroke (an 8 crosses
    /// itself; a T's bar runs through its stem).
    ///
    /// With `loops`, each loop round a hole (a gear's ring, an o, the bowls
    /// of a B) is kept whole first: at a branch point, the two lines on the
    /// loop are one stroke, whatever leaves it.
    func chains(join: Bool, loops: Bool = false) -> [SkeletonLine] {
        let deg = degrees()
        let onLoop = loops ? onLoops() : []
        // Each end of each line, by node, in node order.
        var ends: [Int: [EndKey]] = [:]
        var nodeOrder: [Int] = []
        for e in edges.indices where alive[e] {
            let (a, b, _) = edges[e]
            for (node, side) in [(a, 0), (b, 1)] where node >= 0 {
                if ends[node] == nil { nodeOrder.append(node) }
                ends[node, default: []].append(EndKey(edge: e, side: side))
            }
        }
        var link: [EndKey: EndKey] = [:]
        for node in nodeOrder {
            let list = ends[node]!
            if list.count < 2 { continue }
            let dirs = list.map { heading($0, node) }
            if list.count == 2 {
                link[list[0]] = list[1]
                link[list[1]] = list[0]
                continue
            }
            if !join { continue }
            var taken = Set<Int>()
            func pair(_ i: Int, _ j: Int) {
                taken.insert(i)
                taken.insert(j)
                link[list[i]] = list[j]
                link[list[j]] = list[i]
            }
            if loops {
                let cycle = list.indices.filter { onLoop.contains(list[$0].edge) }
                if cycle.count == 2 { pair(cycle[0], cycle[1]) }
            }
            // Long lines first: the two that run most nearly straight on are one
            // stroke, and then the two longest left turn the corner into each
            // other, as a pen draws an M or the point of an A. Short ones (serifs,
            // corners) join each other only when straight, else end here.
            var longest = 0
            for end in list { longest = max(longest, edges[end.edge].path.count) }
            let long = max(3 * nodeR[node] + 4, 0.4 * Double(longest))
            func isLong(_ i: Int) -> Bool { Double(edges[list[i].edge].path.count) >= long }

            for longs in [true, false] {
                var options: [(dot: Double, i: Int, j: Int)] = []
                for i in list.indices {
                    for j in (i + 1)..<list.count {
                        if isLong(i) != longs || isLong(j) != longs { continue }
                        let dot = dirs[i].0 * dirs[j].0 + dirs[i].1 * dirs[j].1
                        if dot < -0.5 { options.append((dot, i, j)) }
                    }
                }
                options.sort { $0.dot < $1.dot }
                for (_, i, j) in options where !taken.contains(i) && !taken.contains(j) {
                    pair(i, j)
                }
                if !longs { break }
                let left = list.indices.filter { !taken.contains($0) && isLong($0) }
                    .sorted { edges[list[$0].edge].path.count > edges[list[$1].edge].path.count }
                if left.count >= 2 { pair(left[0], left[1]) }
            }
        }
        var used = [Bool](repeating: false, count: edges.count)
        var chains: [SkeletonLine] = []

        // Walks from line `e` entering at `side`, appending to `chain`, until
        // an unlinked end or back at `stop`.
        func walk(_ chain: inout SkeletonLine, _ e: Int, _ side: Int, _ stop: Int) {
            var cur = e, from = side
            while true {
                used[cur] = true
                let (a, b, path) = edges[cur]
                let nodes = from == 0 ? (a, b) : (b, a)
                let pixels = from == 0 ? path : path.reversed()
                for k in pixels.indices {
                    let atNode = k == 0 ? nodes.0 : (k == pixels.count - 1 ? nodes.1 : -1)
                    // Skip the node shared with the line before.
                    if k == 0, !chain.xs.isEmpty { continue }
                    if atNode >= 0, deg[atNode] != 1 {
                        chain.add(nodeX[atNode], nodeY[atNode], nodeR[atNode])
                    } else {
                        let p = pixels[k]
                        chain.add(Double(p % w), Double(p / w), radius(p))
                    }
                }
                guard let next = link[EndKey(edge: cur, side: 1 - from)], next.edge != stop, !used[next.edge] else { return }
                cur = next.edge
                from = next.side
            }
        }

        for e in edges.indices {
            if !alive[e] || used[e] || edges[e].a < 0 { continue }
            for side in [0, 1] where !used[e] && link[EndKey(edge: e, side: side)] == nil {
                var chain = SkeletonLine(closed: false)
                walk(&chain, e, side, -1)
                chains.append(chain)
            }
        }
        for e in edges.indices {
            if !alive[e] || used[e] { continue }
            var chain = SkeletonLine(closed: true)
            walk(&chain, e, 0, e)
            // The loop comes back to where it started: don't repeat the point.
            if chain.xs.count > 2, chain.xs.first == chain.xs.last, chain.ys.first == chain.ys.last {
                chain.xs.removeLast()
                chain.ys.removeLast()
                chain.rs.removeLast()
            }
            chains.append(chain)
        }
        // A lone dot: a node that never had a line (not the far end of a
        // pruned branch).
        var hadLines = Set<Int>()
        for (a, b, _) in edges {
            hadLines.insert(a)
            hadLines.insert(b)
        }
        for node in nodeX.indices where !hadLines.contains(node) && ends[node] == nil {
            var chain = SkeletonLine(closed: false)
            chain.add(nodeX[node], nodeY[node], nodeR[node])
            chains.append(chain)
        }
        return chains
    }

    /// The lines that lie on a loop (not bridges: taking one away leaves the
    /// graph as connected as it was), found by Tarjan's lowpoints.
    private func onLoops() -> Set<Int> {
        var adjacent: [Int: [(Int, Int)]] = [:]
        var order: [Int] = []
        for e in edges.indices where alive[e] {
            let (a, b, _) = edges[e]
            if a < 0 { continue }
            if adjacent[a] == nil { order.append(a) }
            adjacent[a, default: []].append((b, e))
            if adjacent[b] == nil { order.append(b) }
            adjacent[b, default: []].append((a, e))
        }
        var visitOrder: [Int: Int] = [:], low: [Int: Int] = [:]
        var bridges = Set<Int>()
        var clock = 0
        func visit(_ v: Int, _ via: Int) {
            visitOrder[v] = clock
            low[v] = clock
            clock += 1
            for (u, e) in adjacent[v] ?? [] {
                if e == via { continue }
                if let seen = visitOrder[u] {
                    low[v] = min(low[v]!, seen)
                } else {
                    visit(u, e)
                    low[v] = min(low[v]!, low[u]!)
                    if low[u]! > visitOrder[v]! { bridges.insert(e) }
                }
            }
        }
        for v in order where visitOrder[v] == nil { visit(v, -1) }
        return Set(edges.indices.filter { alive[$0] && edges[$0].a >= 0 && !bridges.contains($0) })
    }

    /// The way line end `end` leaves `node`: toward its point a stroke's
    /// width along, as a unit vector.
    private func heading(_ end: EndKey, _ node: Int) -> (Double, Double) {
        let path = edges[end.edge].path
        let pixels = end.side == 0 ? path : path.reversed()
        let reach = max(4.0, 1.5 * nodeR[node])
        let x0 = nodeX[node], y0 = nodeY[node]
        var px = x0, py = y0
        for p in pixels {
            px = Double(p % w)
            py = Double(p / w)
            if hypot(px - x0, py - y0) >= reach { break }
        }
        let d = hypot(px - x0, py - y0)
        return d == 0 ? (0, 0) : ((px - x0) / d, (py - y0) / d)
    }
}
