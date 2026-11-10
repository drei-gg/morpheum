import CoreGraphics

/// The filled shapes a PDF page draws, collected by scanning its content
/// stream: how a vector image (an SF Symbol) gives up its outline, since no
/// public API hands one over.
///
/// It follows what SwiftUI writes when it renders a symbol into a PDF: fills
/// (`f`, `B` and the rest, even-odd included), transformations (`q`, `Q`,
/// `cm`), form XObjects however deeply nested, and luminosity soft masks,
/// which is how a symbol cuts one shape out of another (the tick out of
/// `checkmark.circle.fill`). A mask is applied exactly, with path boolean
/// operations, wherever it reads as fully on or off.
///
/// Strokes, text, images and shadings draw nothing here; `unsupported` says
/// whether any of them painted, which means the outline is incomplete.
final class PDFPaths {
    /// What was painted, in page space (y up, as PDF has it), masks applied,
    /// each with its fill colour's luminance (0 black, 1 white).
    private(set) var painted: [(path: CGPath, luminance: CGFloat)] = []
    /// Whether anything painted that isn't a fill (text, an image, a stroke).
    fileprivate(set) var unsupported = false

    /// A luminosity soft mask that is either on or off at every point: on
    /// where its backdrop is light, then each shape it paints turning its
    /// area on (light) or off (dark), in order.
    struct Mask {
        var onByDefault: Bool
        var layers: [(path: CGPath, on: Bool)]

        /// `path` where the mask lets it through.
        func apply(to path: CGPath) -> CGPath {
            var visible = onByDefault ? path : CGMutablePath()
            for layer in layers {
                visible = layer.on
                    ? visible.union(path.intersection(layer.path))
                    : visible.subtracting(layer.path)
            }
            return visible
        }
    }

    private struct State {
        var transform = CGAffineTransform.identity
        var mask: Mask?
        var luminance: CGFloat = 0
    }

    private var state = State()
    private var stack: [State] = []
    private var path = CGMutablePath()
    private let depth: Int

    /// The shapes `page` paints.
    convenience init(page: CGPDFPage) {
        let contents = CGPDFContentStreamCreateWithPage(page)
        self.init(contents, transform: .identity, depth: 0)
        CGPDFContentStreamRelease(contents)
    }

    private init(_ contents: CGPDFContentStreamRef, transform: CGAffineTransform, depth: Int, luminance: CGFloat = 0) {
        self.depth = depth
        state.transform = transform
        state.luminance = luminance
        scan(contents)
    }

    /// Everything painted, as one path with every contour winding the same
    /// way (overlaps merged).
    var union: CGPath {
        painted.dropFirst().reduce(painted.first?.path ?? CGMutablePath()) { $0.union($1.path) }
    }

    private func scan(_ contents: CGPDFContentStreamRef) {
        let table = makeOperatorTable()
        let scanner = CGPDFScannerCreate(contents, table, Unmanaged.passUnretained(self).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFOperatorTableRelease(table)
    }

    // MARK: Operators

    fileprivate func save() { stack.append(state) }
    fileprivate func restore() { if let last = stack.popLast() { state = last } }
    fileprivate func concat(_ m: CGAffineTransform) { state.transform = m.concatenating(state.transform) }
    fileprivate func setLuminance(_ components: [CGFloat]) {
        if let value = luminance(of: components) { state.luminance = value }
    }

    fileprivate func move(_ p: CGPoint) { path.move(to: p, transform: state.transform) }
    fileprivate func line(_ p: CGPoint) {
        if path.isEmpty { move(p) } else { path.addLine(to: p, transform: state.transform) }
    }
    fileprivate func curve(_ c1: CGPoint?, _ c2: CGPoint?, _ p: CGPoint) {
        guard !path.isEmpty else { return move(p) }
        // `v` takes the current point as its first control, `y` the end.
        let current = path.currentPoint.applying(state.transform.inverted())
        path.addCurve(to: p, control1: c1 ?? current, control2: c2 ?? p, transform: state.transform)
    }
    fileprivate func close() { if !path.isEmpty { path.closeSubpath() } }
    fileprivate func rectangle(_ r: CGRect) { path.addRect(r, transform: state.transform) }

    fileprivate func fill(evenOdd: Bool) {
        defer { path = CGMutablePath() }
        guard !path.isEmpty else { return }
        // Normalised: one winding, overlaps merged, whatever the fill rule.
        var shape: CGPath = path.normalized(using: evenOdd ? .evenOdd : .winding)
        if let mask = state.mask { shape = mask.apply(to: shape) }
        if !shape.isEmpty { painted.append((shape, state.luminance)) }
    }

    fileprivate func stroke() {
        if !path.isEmpty { unsupported = true }
        path = CGMutablePath()
    }

    fileprivate func discard() { path = CGMutablePath() }

    /// `Do`: draws a form XObject's own content, in its own matrix.
    fileprivate func drawObject(_ scanner: CGPDFScannerRef, _ name: String) {
        let contents = CGPDFScannerGetContentStream(scanner)
        guard let object = CGPDFContentStreamGetResource(contents, "XObject", name),
              let (stream, dictionary) = Self.stream(object) else { return }
        var subtype: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype,
              String(cString: subtype) == "Form" else {
            unsupported = true // an image
            return
        }
        let inner = paintForm(stream, dictionary, parent: contents, transform: state.transform)
        for (shape, luminance) in inner.painted {
            let visible = state.mask?.apply(to: shape) ?? shape
            if !visible.isEmpty { painted.append((visible, luminance)) }
        }
        unsupported = unsupported || inner.unsupported
    }

    /// `gs`: of a graphics state, only its soft mask changes the shape.
    fileprivate func setGraphicsState(_ scanner: CGPDFScannerRef, _ name: String) {
        let contents = CGPDFScannerGetContentStream(scanner)
        guard let object = CGPDFContentStreamGetResource(contents, "ExtGState", name) else { return }
        var dictionary: CGPDFDictionaryRef?
        var found: CGPDFObjectRef?
        guard CGPDFObjectGetValue(object, .dictionary, &dictionary), let dictionary,
              CGPDFDictionaryGetObject(dictionary, "SMask", &found), let mask = found else { return }
        var none: UnsafePointer<CChar>?
        if CGPDFObjectGetValue(mask, .name, &none) {
            state.mask = nil // /None
            return
        }
        var soft: CGPDFDictionaryRef?
        var group: CGPDFStreamRef?
        guard CGPDFObjectGetValue(mask, .dictionary, &soft), let soft,
              CGPDFDictionaryGetStream(soft, "G", &group), let group,
              let groupDictionary = CGPDFStreamGetDictionary(group) else { return }
        var kind: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(soft, "S", &kind), let kind, String(cString: kind) == "Luminosity" else {
            unsupported = true // an alpha mask
            return
        }
        var backdrop: CGFloat = 0
        var array: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(soft, "BC", &array), let array {
            var components: [CGFloat] = []
            for i in 0..<CGPDFArrayGetCount(array) {
                var value: CGPDFReal = 0
                if CGPDFArrayGetNumber(array, i, &value) { components.append(value) }
            }
            backdrop = luminance(of: components) ?? 0
        }
        // The mask's group is painted in the space in force where it is set.
        let inner = paintForm(group, groupDictionary, parent: contents, transform: state.transform)
        state.mask = Mask(
            onByDefault: backdrop > 0.5,
            layers: inner.painted.map { ($0.path, $0.luminance > 0.5) }
        )
        unsupported = unsupported || inner.unsupported
    }

    /// Paints a form's content on its own, in its matrix after `transform`.
    private func paintForm(
        _ stream: CGPDFStreamRef,
        _ dictionary: CGPDFDictionaryRef,
        parent: CGPDFContentStreamRef,
        transform: CGAffineTransform
    ) -> PDFPaths {
        var transform = transform
        var matrix: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dictionary, "Matrix", &matrix), let matrix, let m = Self.matrix(matrix) {
            transform = m.concatenating(transform)
        }
        // A form without resources of its own looks names up in its parent's.
        var resources: CGPDFDictionaryRef?
        _ = CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
        let inner = CGPDFContentStreamCreateWithStream(stream, resources ?? dictionary, parent)
        defer { CGPDFContentStreamRelease(inner) }
        guard depth < 16 else { return PDFPaths(empty: depth) }
        // A form starts from the graphics state it's drawn in (its colour);
        // the mask in force is applied to what it paints, afterwards.
        return PDFPaths(inner, transform: transform, depth: depth + 1, luminance: state.luminance)
    }

    private init(empty depth: Int) { self.depth = depth }

    private static func stream(_ object: CGPDFObjectRef) -> (CGPDFStreamRef, CGPDFDictionaryRef)? {
        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
              let dictionary = CGPDFStreamGetDictionary(stream) else { return nil }
        return (stream, dictionary)
    }

    private static func matrix(_ array: CGPDFArrayRef) -> CGAffineTransform? {
        guard CGPDFArrayGetCount(array) == 6 else { return nil }
        var v = [CGPDFReal](repeating: 0, count: 6)
        for i in 0..<6 where !CGPDFArrayGetNumber(array, i, &v[i]) { return nil }
        return CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
    }
}

/// The luminance of a colour given as 1 (grey), 3 (RGB) or 4 (CMYK)
/// components.
private func luminance(of c: [CGFloat]) -> CGFloat? {
    switch c.count {
    case 1: c[0]
    case 3: 0.3 * c[0] + 0.59 * c[1] + 0.11 * c[2]
    case 4: (1 - c[3]) * (1 - min(1, 0.3 * c[0] + 0.59 * c[1] + 0.11 * c[2]))
    default: nil
    }
}

// MARK: The operator table
//
// C callbacks can capture nothing, so the table and its helpers live here.

private func collector(_ info: UnsafeMutableRawPointer?) -> PDFPaths {
    Unmanaged<PDFPaths>.fromOpaque(info!).takeUnretainedValue()
}

/// Pops `count` numbers, in the order they were written.
private func numbers(_ scanner: CGPDFScannerRef, _ count: Int) -> [CGFloat]? {
    var values = [CGFloat](repeating: 0, count: count)
    for i in stride(from: count - 1, through: 0, by: -1) {
        var value: CGPDFReal = 0
        guard CGPDFScannerPopNumber(scanner, &value) else { return nil }
        values[i] = value
    }
    return values
}

/// Pops every number on the stack (a colour's components), in order.
private func allNumbers(_ scanner: CGPDFScannerRef) -> [CGFloat] {
    var values: [CGFloat] = []
    var value: CGPDFReal = 0
    while CGPDFScannerPopNumber(scanner, &value) { values.insert(value, at: 0) }
    return values
}

private func popName(_ scanner: CGPDFScannerRef) -> String? {
    var name: UnsafePointer<CChar>?
    guard CGPDFScannerPopName(scanner, &name), let name else { return nil }
    return String(cString: name)
}

private func makeOperatorTable() -> CGPDFOperatorTableRef {
    let table = CGPDFOperatorTableCreate()!
    func on(_ name: String, _ callback: CGPDFOperatorCallback) {
        CGPDFOperatorTableSetCallback(table, name, callback)
    }
    on("q") { _, info in collector(info).save() }
    on("Q") { _, info in collector(info).restore() }
    on("cm") { scanner, info in
        guard let v = numbers(scanner, 6) else { return }
        collector(info).concat(CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]))
    }
    on("m") { scanner, info in
        guard let v = numbers(scanner, 2) else { return }
        collector(info).move(CGPoint(x: v[0], y: v[1]))
    }
    on("l") { scanner, info in
        guard let v = numbers(scanner, 2) else { return }
        collector(info).line(CGPoint(x: v[0], y: v[1]))
    }
    on("c") { scanner, info in
        guard let v = numbers(scanner, 6) else { return }
        collector(info).curve(CGPoint(x: v[0], y: v[1]), CGPoint(x: v[2], y: v[3]), CGPoint(x: v[4], y: v[5]))
    }
    on("v") { scanner, info in
        guard let v = numbers(scanner, 4) else { return }
        collector(info).curve(nil, CGPoint(x: v[0], y: v[1]), CGPoint(x: v[2], y: v[3]))
    }
    on("y") { scanner, info in
        guard let v = numbers(scanner, 4) else { return }
        collector(info).curve(CGPoint(x: v[0], y: v[1]), nil, CGPoint(x: v[2], y: v[3]))
    }
    on("h") { _, info in collector(info).close() }
    on("re") { scanner, info in
        guard let v = numbers(scanner, 4) else { return }
        collector(info).rectangle(CGRect(x: v[0], y: v[1], width: v[2], height: v[3]))
    }
    for name in ["f", "F", "B", "b"] {
        on(name) { _, info in collector(info).fill(evenOdd: false) }
    }
    for name in ["f*", "B*", "b*"] {
        on(name) { _, info in collector(info).fill(evenOdd: true) }
    }
    for name in ["S", "s"] {
        on(name) { _, info in collector(info).stroke() }
    }
    on("n") { _, info in collector(info).discard() }
    for name in ["g", "rg", "k", "sc", "scn"] {
        on(name) { scanner, info in collector(info).setLuminance(allNumbers(scanner)) }
    }
    on("Do") { scanner, info in
        guard let name = popName(scanner) else { return }
        collector(info).drawObject(scanner, name)
    }
    on("gs") { scanner, info in
        guard let name = popName(scanner) else { return }
        collector(info).setGraphicsState(scanner, name)
    }
    for name in ["Tj", "TJ", "'", "\"", "sh", "BI"] {
        on(name) { _, info in collector(info).unsupported = true }
    }
    return table
}
