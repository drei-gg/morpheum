import CoreGraphics
import Foundation

/// Just enough SVG to read vector art as one filled shape: path data, the
/// transforms on paths and groups, the viewBox, and fill rules.
enum SVG {
    /// The path an SVG `d` attribute draws: every command (`M L H V C S Q T
    /// A Z`, absolute and relative), arcs included.
    static func path(_ data: String) throws -> CGPath {
        var scanner = PathScanner(data)
        let path = CGMutablePath()
        var current = CGPoint.zero
        var start = CGPoint.zero
        // The previous segment's second control point, for S and T.
        var lastCubic: CGPoint?
        var lastQuad: CGPoint?
        var command: Character?

        while let next = try scanner.command(after: command) {
            command = next
            let relative = next.isLowercase
            let origin = relative ? current : .zero
            func point() throws -> CGPoint {
                let x = try scanner.number(), y = try scanner.number()
                return CGPoint(x: origin.x + x, y: origin.y + y)
            }
            var cubic: CGPoint?
            var quad: CGPoint?
            switch next.uppercased() {
            case "M":
                current = try point()
                start = current
                path.move(to: current)
                // Further pairs after a move are lines.
                command = relative ? "l" : "L"
            case "L":
                current = try point()
                path.addLine(to: current)
            case "H":
                current = CGPoint(x: (relative ? current.x : 0) + (try scanner.number()), y: current.y)
                path.addLine(to: current)
            case "V":
                current = CGPoint(x: current.x, y: (relative ? current.y : 0) + (try scanner.number()))
                path.addLine(to: current)
            case "C":
                let c1 = try point(), c2 = try point(), end = try point()
                path.addCurve(to: end, control1: c1, control2: c2)
                cubic = c2
                current = end
            case "S":
                let c1 = lastCubic.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let c2 = try point(), end = try point()
                path.addCurve(to: end, control1: c1, control2: c2)
                cubic = c2
                current = end
            case "Q":
                let control = try point(), end = try point()
                path.addQuadCurve(to: end, control: control)
                quad = control
                current = end
            case "T":
                let control = lastQuad.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let end = try point()
                path.addQuadCurve(to: end, control: control)
                quad = control
                current = end
            case "A":
                let rx = abs(try scanner.number()), ry = abs(try scanner.number())
                let rotation = try scanner.number() * .pi / 180
                let large = try scanner.flag(), sweep = try scanner.flag()
                let end = try point()
                addArc(to: path, from: current, to: end, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep)
                current = end
            case "Z":
                path.closeSubpath()
                current = start
            default:
                throw MorphGeometryError("SVG path command \(next) isn't supported")
            }
            lastCubic = cubic
            lastQuad = quad
        }
        return path
    }

    /// Adds an SVG elliptical arc (endpoint form) as an arc of a transformed
    /// unit circle (SVG 1.1, appendix F.6).
    private static func addArc(
        to path: CGMutablePath, from p1: CGPoint, to p2: CGPoint,
        rx: CGFloat, ry: CGFloat, rotation phi: CGFloat, large: Bool, sweep: Bool
    ) {
        guard p1 != p2 else { return }
        guard rx > 0, ry > 0 else { return path.addLine(to: p2) }
        var rx = rx, ry = ry
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p1.x - p2.x) / 2, dy = (p1.y - p2.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy
        let y1 = -sinPhi * dx + cosPhi * dy
        // Radii too small to reach are scaled up just enough.
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 {
            rx *= lambda.squareRoot()
            ry *= lambda.squareRoot()
        }
        let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var factor = (max(0, numerator) / denominator).squareRoot()
        if large == sweep { factor = -factor }
        let cx1 = factor * rx * y1 / ry
        let cy1 = -factor * ry * x1 / rx
        let center = CGPoint(
            x: cosPhi * cx1 - sinPhi * cy1 + (p1.x + p2.x) / 2,
            y: sinPhi * cx1 + cosPhi * cy1 + (p1.y + p2.y) / 2
        )
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let start = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }
        let transform = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: phi)
            .scaledBy(x: rx, y: ry)
        path.addRelativeArc(center: .zero, radius: 1, startAngle: start, delta: delta, transform: transform)
    }

    /// An SVG `transform` attribute: `matrix`, `translate`, `scale`,
    /// `rotate`, `skewX` and `skewY`, applied in order.
    static func transform(_ text: String) throws -> CGAffineTransform {
        var result = CGAffineTransform.identity
        let pattern = /([a-zA-Z]+)\s*\(([^)]*)\)/
        for match in text.matches(of: pattern) {
            var scanner = PathScanner(String(match.output.2))
            var values: [CGFloat] = []
            while let value = try scanner.optionalNumber() { values.append(value) }
            let v = values
            let step: CGAffineTransform
            switch (String(match.output.1), v.count) {
            case ("matrix", 6): step = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
            case ("translate", 1): step = CGAffineTransform(translationX: v[0], y: 0)
            case ("translate", 2): step = CGAffineTransform(translationX: v[0], y: v[1])
            case ("scale", 1): step = CGAffineTransform(scaleX: v[0], y: v[0])
            case ("scale", 2): step = CGAffineTransform(scaleX: v[0], y: v[1])
            case ("rotate", 1): step = CGAffineTransform(rotationAngle: v[0] * .pi / 180)
            case ("rotate", 3):
                step = CGAffineTransform(translationX: v[1], y: v[2])
                    .rotated(by: v[0] * .pi / 180)
                    .translatedBy(x: -v[1], y: -v[2])
            case ("skewX", 1): step = CGAffineTransform(a: 1, b: 0, c: tan(v[0] * .pi / 180), d: 1, tx: 0, ty: 0)
            case ("skewY", 1): step = CGAffineTransform(a: 1, b: tan(v[0] * .pi / 180), c: 0, d: 1, tx: 0, ty: 0)
            default: throw MorphGeometryError("SVG transform \(match.output.0) isn't supported")
            }
            // Each named transform applies to what comes after it.
            result = step.concatenating(result)
        }
        return result
    }

    /// The solid shape an SVG document fills, in its viewBox, with one
    /// winding throughout (even-odd fills made non-zero). Paths in `<defs>`,
    /// `<clipPath>`, `<mask>` and the like, and paths filled with `none` or a
    /// gradient or pattern (`url(…)`), are left out: they are decoration, not
    /// the shape.
    static func document(_ text: String) throws -> (path: CGPath, viewBox: CGRect) {
        let tags = /<(\/?)([a-zA-Z][\w:-]*)((?:[^>"']|"[^"]*"|'[^']*')*?)(\/?)>/
        struct Group { var transform: CGAffineTransform; var fill: String?; var fillRule: String? }
        var stack = [Group(transform: .identity, fill: nil, fillRule: nil)]
        var hidden = 0
        var viewBox: CGRect?
        var shapes: [CGPath] = []
        let hiddenTags: Set<String> = ["defs", "clipPath", "mask", "pattern", "symbol", "marker", "linearGradient", "radialGradient"]

        for match in text.matches(of: tags) {
            let closing = !match.output.1.isEmpty
            let name = String(match.output.2)
            let attributes = Self.attributes(String(match.output.3))
            let selfClosing = !match.output.4.isEmpty
            if closing {
                if hiddenTags.contains(name) { hidden = max(0, hidden - 1) }
                if name == "g" || name == "svg", stack.count > 1 { stack.removeLast() }
                continue
            }
            if hiddenTags.contains(name) {
                if !selfClosing { hidden += 1 }
                continue
            }
            let parent = stack.last!
            var own = try attributes["transform"].map(Self.transform) ?? .identity
            if name == "svg", let box = attributes["viewBox"] {
                var scanner = PathScanner(box)
                var v: [CGFloat] = []
                while let value = try scanner.optionalNumber() { v.append(value) }
                if v.count == 4, viewBox == nil { viewBox = CGRect(x: v[0], y: v[1], width: v[2], height: v[3]) }
                own = .identity
            }
            let group = Group(
                transform: own.concatenating(parent.transform),
                fill: attributes["fill"] ?? Self.style(attributes["style"], "fill") ?? parent.fill,
                fillRule: attributes["fill-rule"] ?? Self.style(attributes["style"], "fill-rule") ?? parent.fillRule
            )
            if (name == "g" || name == "svg") && !selfClosing {
                stack.append(group)
                continue
            }
            guard hidden == 0, name == "path", let data = attributes["d"] else { continue }
            let fill = group.fill?.trimmingCharacters(in: .whitespaces) ?? "black"
            if fill == "none" || fill.hasPrefix("url(") { continue }
            var placed = group.transform
            guard let path = try Self.path(data).copy(using: &placed) else { continue }
            shapes.append(path.normalized(using: group.fillRule == "evenodd" ? .evenOdd : .winding))
        }
        guard let first = shapes.first else { throw MorphGeometryError("The SVG fills no solid shape") }
        let shape = shapes.dropFirst().reduce(first) { $0.union($1) }
        return (shape, viewBox ?? shape.boundingBoxOfPath)
    }

    private static func attributes(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for match in text.matches(of: /([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/) {
            result[String(match.output.1)] = String(match.output.2 ?? match.output.3 ?? "")
        }
        return result
    }

    /// A property from an inline `style` attribute.
    private static func style(_ style: String?, _ property: String) -> String? {
        guard let style else { return nil }
        for declaration in style.split(separator: ";") {
            let parts = declaration.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == property { return parts[1] }
        }
        return nil
    }
}

/// Reads SVG path data and number lists: numbers written any way SVG allows
/// (`-1-2`, `.5.5`, `1e-3`), arc flags written together (`01`), commas or
/// spaces between.
struct PathScanner {
    private let characters: [Character]
    private var index = 0

    init(_ text: String) { characters = Array(text) }

    private mutating func skipSeparators() {
        while index < characters.count, characters[index].isWhitespace || characters[index] == "," { index += 1 }
    }

    /// The next command letter; or, when a number comes next, `previous`
    /// repeated (SVG lets a command's arguments repeat without the letter).
    /// Nil at the end.
    mutating func command(after previous: Character?) throws -> Character? {
        skipSeparators()
        guard index < characters.count else { return nil }
        let c = characters[index]
        if c.isLetter, c != "e", c != "E" {
            index += 1
            return c
        }
        guard let previous, previous.uppercased() != "Z" else {
            throw MorphGeometryError("SVG path data must start with a command, not \(c)")
        }
        return previous
    }

    mutating func number() throws -> CGFloat {
        guard let value = try optionalNumber() else { throw MorphGeometryError("SVG path data ends mid-command") }
        return value
    }

    mutating func optionalNumber() throws -> CGFloat? {
        skipSeparators()
        guard index < characters.count else { return nil }
        let begin = index
        if characters[index] == "+" || characters[index] == "-" { index += 1 }
        var digits = false, dot = false
        while index < characters.count {
            let c = characters[index]
            if c.isASCII, c.isNumber {
                digits = true
            } else if c == ".", !dot {
                dot = true
            } else {
                break
            }
            index += 1
        }
        if digits, index < characters.count, characters[index] == "e" || characters[index] == "E" {
            var lookahead = index + 1
            if lookahead < characters.count, characters[lookahead] == "+" || characters[lookahead] == "-" { lookahead += 1 }
            if lookahead < characters.count, characters[lookahead].isASCII, characters[lookahead].isNumber {
                index = lookahead
                while index < characters.count, characters[index].isASCII, characters[index].isNumber { index += 1 }
            }
        }
        guard digits, let value = Double(String(characters[begin..<index])) else {
            index = begin
            return nil
        }
        return CGFloat(value)
    }

    /// An arc flag: a lone 0 or 1, which may run straight into what follows.
    mutating func flag() throws -> Bool {
        skipSeparators()
        guard index < characters.count, characters[index] == "0" || characters[index] == "1" else {
            throw MorphGeometryError("SVG arc flags must be 0 or 1")
        }
        defer { index += 1 }
        return characters[index] == "1"
    }
}
