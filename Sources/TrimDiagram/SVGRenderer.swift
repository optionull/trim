import AppKit
import CoreGraphics
import CoreText
import Foundation

/// A diagram drawn: premultiplied BGRA pixels, the size it takes in points, and where each element that has a `data-id`
/// is
/// (points from the top left), so a click on it can be told apart.
public struct DiagramImage: Sendable {
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var bytesPerRow: Int
    public var pixels: Data
    public var size: CGSize
    public var scale: CGFloat
    public var regions: [DiagramRegion]
}

public struct DiagramRegion: Sendable, Equatable {
    public var id: String
    /// What it is in the diagram: the element's class (`node`, `actor`, `edge-label`...).
    public var kind: String
    public var rect: CGRect
}

public enum SVGRender {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// Draws `svg` (what Mermaider's `RenderSvg` makes) at `scale` pixels to the point, shrunk to `maxWidth` points
    /// when wider.
    /// `monoFont` is the family for the diagram's monospace text (the editor's own, say); the rest is the system font.
    public static func image(
        svg: String,
        scale: CGFloat,
        maxWidth: CGFloat? = nil,
        monoFont: String? = nil
    ) throws -> DiagramImage {
        let document: SVGDocument
        do { document = try SVGDocument(svg) } catch { throw Failure(description: "\(error)") }
        let painter = SVGPainter(document: document, monoFont: monoFont)
        return try painter.render(scale: scale, maxWidth: maxWidth)
    }
}

/// The paint of a fill or a stroke.
private enum Paint {
    case color(RGBA)
    case gradient(SVGElement)
}

/// What is inherited down the tree.
private struct Style {
    var fill = "black"
    var stroke = "none"
    var strokeWidth = 1.0
    var fillOpacity = 1.0
    var strokeOpacity = 1.0
    var fontSize = 16.0
    var fontWeight = 400.0
    var anchor = "start"
    var dash: [Double] = []
    var cap = "butt"
    var join = "miter"
    var mono = false
    var strokeFirst = false
    var fillRule = "nonzero"
}

private final class SVGPainter {
    let document: SVGDocument
    let monoFont: String?
    var variables: [String: String]
    var context: CGContext!
    /// The transform from an element's own space to the root's user space, for the regions.
    var matrix = CGAffineTransform.identity
    var regionBounds: [CGRect?] = []
    var regions: [DiagramRegion] = []
    var depth = 0

    init(document: SVGDocument, monoFont: String?) {
        self.document = document
        self.monoFont = monoFont
        variables = document.variables
    }

    // MARK: The root

    func render(scale: CGFloat, maxWidth: CGFloat?) throws -> DiagramImage {
        let root = document.root
        let box = viewBox(root)
        let width = number(root.attributes["width"]) ?? box?.width ?? 300
        let height = number(root.attributes["height"]) ?? box?.height ?? 150
        guard width > 0, height > 0, width < 20000,
              height < 20000 else { throw SVGRender.Failure(description: "the SVG has no size") }
        let fit = maxWidth.map { min(1, Double($0) / width) } ?? 1
        let pointSize = CGSize(width: width * fit, height: height * fit)
        let pixelWidth = max(1, Int((pointSize.width * scale).rounded(.up)))
        let pixelHeight = max(1, Int((pointSize.height * scale).rounded(.up)))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let bitmap = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { throw SVGRender.Failure(description: "no bitmap of \(pixelWidth) x \(pixelHeight)") }
        context = bitmap
        // y down, in points of the SVG's own width and height.
        bitmap.translateBy(x: 0, y: CGFloat(pixelHeight))
        bitmap.scaleBy(x: CGFloat(Double(pixelWidth) / width), y: -CGFloat(Double(pixelHeight) / height))
        if let box {
            bitmap.scaleBy(x: width / box.width, y: height / box.height)
            bitmap.translateBy(x: -box.minX, y: -box.minY)
            matrix = CGAffineTransform(scaleX: width / box.width, y: height / box.height).translatedBy(
                x: -box.minX,
                y: -box.minY
            )
        }
        bitmap.setShouldAntialias(true)
        bitmap.interpolationQuality = .high
        draw(children: root, style: Style(), skipDefsOnly: true)
        guard let data = bitmap.data else { throw SVGRender.Failure(description: "no pixels") }
        let bytesPerRow = bitmap.bytesPerRow
        let scaleToPoints = CGFloat(fit)
        return DiagramImage(
            pixelWidth: pixelWidth, pixelHeight: pixelHeight, bytesPerRow: bytesPerRow,
            pixels: Data(bytes: data, count: bytesPerRow * pixelHeight), size: pointSize, scale: scale,
            regions: regions.map { DiagramRegion(
                id: $0.id,
                kind: $0.kind,
                rect: $0.rect.applying(CGAffineTransform(scaleX: scaleToPoints, y: scaleToPoints))
            ) }
        )
    }

    private func viewBox(_ element: SVGElement) -> CGRect? {
        guard let text = element.attributes["viewBox"] else { return nil }
        let numbers = text.split { $0 == " " || $0 == "," }.compactMap { Double($0) }
        guard numbers.count == 4, numbers[2] > 0, numbers[3] > 0 else { return nil }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    // MARK: Walking

    private func draw(children element: SVGElement, style: Style, skipDefsOnly _: Bool = false) {
        for child in element.children {
            draw(child, style: style)
        }
    }

    private func draw(_ element: SVGElement, style parent: Style) {
        guard depth < 64 else { return }
        depth += 1
        defer { depth -= 1 }
        switch element.name {
        case "defs", "style", "title", "desc", "linearGradient", "radialGradient", "marker", "clipPath", "symbol",
             "metadata": return
        default: break
        }
        var style = parent
        applyStyle(&style, from: element)
        let opacity = number(effective("opacity", element)) ?? 1
        context.saveGState()
        let savedMatrix = matrix
        if let transform = element.attributes["transform"] {
            let t = Self.transform(transform)
            context.concatenate(t)
            matrix = t.concatenating(matrix)
        }
        let layered = opacity < 1
        if layered {
            context.setAlpha(CGFloat(opacity))
            context.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        let collects = element.attributes["data-id"] != nil && (element.name == "g")
        if collects { regionBounds.append(nil) }
        switch element.name {
        case "g", "a", "svg":
            for child in element.children {
                draw(child, style: style)
            }
        case "rect", "circle", "ellipse", "line", "polyline", "polygon", "path":
            if let path = shape(element) { paint(path, element: element, style: style) }
        case "text":
            drawText(element, style: style)
        case "image":
            drawImage(element)
        default:
            break
        }
        if collects, let bounds = regionBounds.popLast() ?? nil, let id = element.attributes["data-id"] {
            regions.append(DiagramRegion(id: id, kind: element.classes.first ?? element.name, rect: bounds))
            union(bounds)
        }
        if layered { context.endTransparencyLayer() }
        matrix = savedMatrix
        context.restoreGState()
    }

    /// Adds `rect` (root user space) to the element that is collecting its bounds.
    private func union(_ rect: CGRect) {
        guard !regionBounds.isEmpty, rect.width.isFinite, rect.height.isFinite else { return }
        let last = regionBounds.count - 1
        regionBounds[last] = regionBounds[last].map { $0.union(rect) } ?? rect
    }

    // MARK: Style

    /// The attribute `name`, or the same property in the element's `style` attribute.
    private func effective(_ name: String, _ element: SVGElement) -> String? {
        if let style = element.attributes["style"] {
            for declaration in CSSValue.splitDeclarations(style) {
                guard let colon = declaration.firstIndex(of: ":") else { continue }
                if declaration[..<colon].trimmingCharacters(in: .whitespacesAndNewlines) == name {
                    return declaration[declaration.index(after: colon)...]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return element.attributes[name]
    }

    private func applyStyle(_ style: inout Style, from element: SVGElement) {
        if let value = effective("fill", element) { style.fill = value }
        if let value = effective("stroke", element) { style.stroke = value }
        if let value = effective("stroke-width", element),
           let n = CSSValue.length(value, variables) { style.strokeWidth = n }
        if let value = effective("fill-opacity", element), let n = Double(value) { style.fillOpacity = n }
        if let value = effective("stroke-opacity", element), let n = Double(value) { style.strokeOpacity = n }
        if let value = effective("font-size", element),
           let n = CSSValue.length(value, variables, font: style.fontSize) { style.fontSize = n }
        if let value = effective("font-weight", element) {
            let resolved = CSSValue.resolve(value, variables)
            style.fontWeight = Double(resolved) ?? (resolved == "bold" ? 700 : 400)
        }
        if let value = effective("text-anchor", element) { style.anchor = value }
        if let value = effective("stroke-linecap", element) { style.cap = value }
        if let value = effective("stroke-linejoin", element) { style.join = value }
        if let value = effective("fill-rule", element) { style.fillRule = value }
        if let value = effective("stroke-dasharray", element) {
            style.dash = value == "none" ? [] : value.split { $0 == "," || $0 == " " }.compactMap { Double($0) }
        }
        if let value = effective("paint-order", element) { style.strokeFirst = value.hasPrefix("stroke") }
        if element.classes.contains("mono") { style.mono = true }
        if let family = effective("font-family", element)?.lowercased(), family.contains("mono") { style.mono = true }
    }

    private func number(_ text: String?) -> Double? {
        guard let text else { return nil }
        return CSSValue.length(text, variables)
    }

    private func paintValue(_ text: String) -> Paint? {
        let value = CSSValue.resolve(text, variables).trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("url(#"), let close = value.firstIndex(of: ")") {
            let id = String(value[value.index(value.startIndex, offsetBy: 5) ..< close])
            if let gradient = document.ids[id], gradient.name == "linearGradient" || gradient.name == "radialGradient" {
                return .gradient(gradient)
            }
            return nil
        }
        if value == "currentColor" || value ==
            "currentcolor" { return CSSValue.color(variables["--fg"] ?? "#000000").map(Paint.color) }
        return CSSValue.color(value, variables).map(Paint.color)
    }

    // MARK: Shapes

    private func shape(_ element: SVGElement) -> CGPath? {
        let a = element.attributes
        func n(_ key: String, _ fallback: Double = 0) -> Double { number(a[key]) ?? fallback }
        switch element.name {
        case "rect":
            let rect = CGRect(x: n("x"), y: n("y"), width: n("width"), height: n("height"))
            guard rect.width > 0, rect.height > 0 else { return nil }
            var rx = number(a["rx"]), ry = number(a["ry"])
            if rx == nil { rx = ry }
            if ry == nil { ry = rx }
            let radiusX = min(rx ?? 0, rect.width / 2), radiusY = min(ry ?? 0, rect.height / 2)
            return radiusX > 0 && radiusY > 0
                ? CGPath(roundedRect: rect, cornerWidth: radiusX, cornerHeight: radiusY, transform: nil)
                : CGPath(rect: rect, transform: nil)
        case "circle":
            let r = n("r")
            guard r > 0 else { return nil }
            return CGPath(
                ellipseIn: CGRect(x: n("cx") - r, y: n("cy") - r, width: 2 * r, height: 2 * r),
                transform: nil
            )
        case "ellipse":
            let rx = n("rx"), ry = n("ry")
            guard rx > 0, ry > 0 else { return nil }
            return CGPath(
                ellipseIn: CGRect(x: n("cx") - rx, y: n("cy") - ry, width: 2 * rx, height: 2 * ry),
                transform: nil
            )
        case "line":
            let path = CGMutablePath()
            path.move(to: CGPoint(x: n("x1"), y: n("y1")))
            path.addLine(to: CGPoint(x: n("x2"), y: n("y2")))
            return path
        case "polyline", "polygon":
            let numbers = (a["points"] ?? "").split { $0 == " " || $0 == "," || $0 == "\n" }.compactMap { Double($0) }
            guard numbers.count >= 4 else { return nil }
            let path = CGMutablePath()
            for index in stride(from: 0, to: numbers.count - 1, by: 2) {
                let point = CGPoint(x: numbers[index], y: numbers[index + 1])
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            if element.name == "polygon" { path.closeSubpath() }
            return path
        case "path":
            return SVGPath.parse(a["d"] ?? "")
        default:
            return nil
        }
    }

    private func paint(_ path: CGPath, element: SVGElement, style: Style) {
        let fill = paintValue(style.fill)
        let stroke = paintValue(style.stroke)
        func fillIt() {
            guard let fill else { return }
            fillPath(path, paint: fill, opacity: style.fillOpacity, evenOdd: style.fillRule == "evenodd")
        }
        func strokeIt() {
            guard let stroke, style.strokeWidth > 0 else { return }
            strokePath(path, paint: stroke, style: style)
        }
        if style.strokeFirst { strokeIt(); fillIt() } else { fillIt(); strokeIt() }
        let strokeWidth = stroke == nil ? 0 : style.strokeWidth
        union(path.boundingBoxOfPath.insetBy(dx: -strokeWidth / 2, dy: -strokeWidth / 2).applying(matrix))
        drawMarkers(on: path, element: element, style: style)
    }

    private func fillPath(_ path: CGPath, paint: Paint, opacity: Double, evenOdd: Bool) {
        switch paint {
        case let .color(color):
            context.setFillColor(CGColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: color.a * opacity))
            context.addPath(path)
            context.fillPath(using: evenOdd ? .evenOdd : .winding)
        case let .gradient(gradient):
            context.saveGState()
            context.addPath(path)
            context.clip(using: evenOdd ? .evenOdd : .winding)
            drawGradient(gradient, in: path.boundingBoxOfPath, opacity: opacity)
            context.restoreGState()
        }
    }

    private func strokePath(_ path: CGPath, paint: Paint, style: Style) {
        context.saveGState()
        context.setLineWidth(CGFloat(style.strokeWidth))
        context.setLineCap(style.cap == "round" ? .round : style.cap == "square" ? .square : .butt)
        context.setLineJoin(style.join == "round" ? .round : style.join == "bevel" ? .bevel : .miter)
        if !style.dash.isEmpty { context.setLineDash(phase: 0, lengths: style.dash.map { CGFloat($0) }) }
        switch paint {
        case let .color(color):
            context.setStrokeColor(CGColor(
                srgbRed: color.r,
                green: color.g,
                blue: color.b,
                alpha: color.a * style.strokeOpacity
            ))
            context.addPath(path)
            context.strokePath()
        case let .gradient(gradient):
            context.addPath(path)
            context.replacePathWithStrokedPath()
            context.clip()
            drawGradient(gradient, in: path.boundingBoxOfPath, opacity: style.strokeOpacity)
        }
        context.restoreGState()
    }

    // MARK: Gradients

    private func stops(_ gradient: SVGElement) -> (colors: [CGColor], locations: [CGFloat]) {
        var colors: [CGColor] = []
        var locations: [CGFloat] = []
        for stop in gradient.children where stop.name == "stop" {
            let offsetText = stop.attributes["offset"] ?? "0"
            var offset = offsetText
                .hasSuffix("%") ? (Double(offsetText.dropLast()) ?? 0) / 100 : (Double(offsetText) ?? 0)
            offset = min(max(offset, locations.last.map(Double.init) ?? 0), 1)
            let colour = CSSValue.color(effective("stop-color", stop) ?? "#000000", variables) ?? .black
            let alpha = colour.a * (Double(effective("stop-opacity", stop) ?? "1") ?? 1)
            colors.append(CGColor(srgbRed: colour.r, green: colour.g, blue: colour.b, alpha: alpha))
            locations.append(CGFloat(offset))
        }
        return (colors, locations)
    }

    private func drawGradient(_ gradient: SVGElement, in box: CGRect, opacity: Double) {
        let (colors, locations) = stops(gradient)
        guard !colors.isEmpty, let cg = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: colors.map { $0.copy(alpha: $0.alpha * CGFloat(opacity)) ?? $0 } as CFArray,
            locations: locations
        ) else { return }
        let userSpace = gradient.attributes["gradientUnits"] == "userSpaceOnUse"
        func point(_ x: Double, _ y: Double) -> CGPoint {
            userSpace ? CGPoint(x: x, y: y) : CGPoint(x: box.minX + x * box.width, y: box.minY + y * box.height)
        }
        func fraction(_ key: String, _ fallback: Double) -> Double {
            guard let text = gradient.attributes[key] else { return fallback }
            return text.hasSuffix("%") ? (Double(text.dropLast()) ?? 0) / 100 : (Double(text) ?? fallback)
        }
        let options: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        if gradient.name == "linearGradient" {
            context.drawLinearGradient(
                cg, start: point(fraction("x1", 0), fraction("y1", 0)), end: point(
                    fraction("x2", 1),
                    fraction("y2", 0)
                ),
                options: options
            )
        } else {
            let centre = point(fraction("cx", 0.5), fraction("cy", 0.5))
            let focus = point(fraction("fx", fraction("cx", 0.5)), fraction("fy", fraction("cy", 0.5)))
            let radius = fraction("r", 0.5) * (userSpace ? 1 : max(box.width, box.height))
            context.drawRadialGradient(
                cg,
                startCenter: focus,
                startRadius: 0,
                endCenter: centre,
                endRadius: radius,
                options: options
            )
        }
    }

    // MARK: Markers

    private func drawMarkers(on path: CGPath, element: SVGElement, style: Style) {
        let start = effective("marker-start", element), end = effective("marker-end", element)
        guard start != nil || end != nil else { return }
        var points: [CGPoint] = []
        var firstDirection: CGPoint?
        var lastDirection: CGPoint?
        var current = CGPoint.zero
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            func add(_ point: CGPoint, from: CGPoint) {
                if points.isEmpty { points.append(from) }
                let direction = CGPoint(x: point.x - from.x, y: point.y - from.y)
                if direction != .zero {
                    if firstDirection == nil { firstDirection = direction }
                    lastDirection = direction
                }
                points.append(point)
                current = point
            }
            switch element.type {
            case .moveToPoint: current = element.points[0]
            case .addLineToPoint: add(element.points[0], from: current)
            case .addQuadCurveToPoint:
                let control = element.points[0], end = element.points[1]
                add(end, from: control == end ? current : control)
                current = end
            case .addCurveToPoint:
                let c1 = element.points[0], c2 = element.points[1], end = element.points[2]
                add(end, from: c2 == end ? (c1 == end ? current : c1) : c2)
                if firstDirection == nil || points.count <= 2 { firstDirection = CGPoint(
                    x: (c1 == current ? c2 : c1).x - current.x,
                    y: (c1 == current ? c2 : c1).y - current.y
                ) }
                current = end
            default: break
            }
        }
        guard let first = points.first, let last = points.last else { return }
        if let start, let direction = firstDirection { drawMarker(
            start,
            at: first,
            direction: direction,
            reversed: true,
            style: style
        ) }
        if let end, let direction = lastDirection { drawMarker(
            end,
            at: last,
            direction: direction,
            reversed: false,
            style: style
        ) }
    }

    private func drawMarker(_ reference: String, at point: CGPoint, direction: CGPoint, reversed: Bool, style: Style) {
        let value = CSSValue.resolve(reference, variables)
        guard value.hasPrefix("url(#"), let close = value.firstIndex(of: ")"),
              let marker = document.ids[String(value[value.index(value.startIndex, offsetBy: 5) ..< close])],
              marker.name == "marker"
        else { return }
        let orient = marker.attributes["orient"] ?? "0"
        var angle = 0.0
        if orient == "auto" || orient == "auto-start-reverse" {
            angle = atan2(direction.y, direction.x)
            if reversed, orient == "auto" { angle += .pi } // a start marker points the way the line leaves
            if reversed, orient == "auto-start-reverse" { angle += 0 }
        } else if let degrees = Double(orient) {
            angle = degrees * .pi / 180
        }
        // A start marker of `orient=auto` points along the line's direction in the line's own sense; SVG turns it with
        // the line.
        if reversed, orient == "auto" { angle -= .pi }
        let scale = marker.attributes["markerUnits"] == "userSpaceOnUse" ? 1 : style.strokeWidth
        let refX = number(marker.attributes["refX"]) ?? 0, refY = number(marker.attributes["refY"]) ?? 0
        context.saveGState()
        let savedMatrix = matrix
        let transform = CGAffineTransform(translationX: point.x, y: point.y).rotated(by: angle).scaledBy(
            x: scale,
            y: scale
        )
        .translatedBy(x: -refX, y: -refY)
        context.concatenate(transform)
        matrix = transform.concatenating(matrix)
        var inner = Style()
        inner.stroke = "none"
        for child in marker.children {
            draw(child, style: inner)
        }
        matrix = savedMatrix
        context.restoreGState()
    }

    // MARK: Text

    private func font(_ style: Style) -> CTFont {
        let weight: NSFont.Weight = style.fontWeight >= 700 ? .bold : style.fontWeight >= 600 ? .semibold
            : style.fontWeight >= 500 ? .medium : style.fontWeight <= 300 ? .light : .regular
        let size = CGFloat(style.fontSize)
        if style.mono {
            if let name = monoFont, let font = NSFont(name: name, size: size) { return font }
            return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        }
        return NSFont.systemFont(ofSize: size, weight: weight)
    }

    private func drawText(_ element: SVGElement, style: Style) {
        var penX = number(element.attributes["x"]) ?? 0
        var penY = number(element.attributes["y"]) ?? 0
        penY += number(element.attributes["dy"]) ?? 0
        penX += number(element.attributes["dx"]) ?? 0
        func chunk(_ string: String, style: Style) {
            let text = string.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            let width = drawChunk(text, x: penX, y: penY, style: style)
            penX += width
        }
        for item in element.content {
            switch item {
            case let .text(string):
                chunk(string, style: style)
            case let .element(span) where span.name == "tspan":
                var inner = style
                applyStyle(&inner, from: span)
                if let x = number(span.attributes["x"]) { penX = x }
                if let y = number(span.attributes["y"]) { penY = y }
                penX += number(span.attributes["dx"]) ?? 0
                penY += number(span.attributes["dy"]) ?? 0
                for part in span.content {
                    if case let .text(string) = part { chunk(string, style: inner) }
                }
            default: break
            }
        }
    }

    /// One run of text at a position, anchored; returns its width.
    @discardableResult
    private func drawChunk(_ text: String, x: Double, y: Double, style: Style) -> Double {
        let font = font(style)
        let fillPaint = paintValue(style.fill)
        var colour = RGBA.black
        switch fillPaint {
        case let .color(c)?: colour = c
        case let .gradient(gradient)?:
            let (colors, _) = stops(gradient)
            if let first = colors.first?.components, first.count >= 3 { colour = RGBA(
                Double(first[0]),
                Double(first[1]),
                Double(first[2]),
                1
            ) }
        case nil: colour = .clear
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(
                srgbRed: colour.r,
                green: colour.g,
                blue: colour.b,
                alpha: colour.a * style.fillOpacity
            ),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        let origin = style.anchor == "middle" ? x - width / 2 : style.anchor == "end" ? x - width : x
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        if let stroke = paintValue(style.stroke), case let .color(c) = stroke, style.strokeWidth > 0 {
            // A halo: the outline first (paint-order), then the letters over it.
            context.setTextDrawingMode(.stroke)
            context.setLineWidth(CGFloat(style.strokeWidth))
            context.setLineJoin(.round)
            context.setStrokeColor(CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a * style.strokeOpacity))
            context.textPosition = CGPoint(x: origin, y: y)
            CTLineDraw(line, context)
        }
        context.setTextDrawingMode(.fill)
        context.textPosition = CGPoint(x: origin, y: y)
        CTLineDraw(line, context)
        context.restoreGState()
        let ascent = Double(CTFontGetAscent(font)), descent = Double(CTFontGetDescent(font))
        union(CGRect(x: origin, y: y - ascent, width: width, height: ascent + descent).applying(matrix))
        return width
    }

    // MARK: Images (the icons of architecture diagrams)

    private func drawImage(_ element: SVGElement) {
        guard let href = element.attributes["href"] ?? element.attributes["xlink:href"], href.hasPrefix("data:"),
              let comma = href.firstIndex(of: ",")
        else { return }
        let header = href[..<comma], body = String(href[href.index(after: comma)...])
        let isBase64 = header.hasSuffix(";base64")
        guard let data = isBase64 ? Data(base64Encoded: body) : body.removingPercentEncoding.map({ Data($0.utf8) })
        else { return }
        let rect = CGRect(
            x: number(element.attributes["x"]) ?? 0, y: number(element.attributes["y"]) ?? 0,
            width: number(element.attributes["width"]) ?? 0, height: number(element.attributes["height"]) ?? 0
        )
        guard rect.width > 0, rect.height > 0 else { return }
        if header.contains("svg"), let inner = try? SVGDocument(String(decoding: data, as: UTF8.self)) {
            let box = viewBox(inner.root) ?? CGRect(x: 0, y: 0, width: rect.width, height: rect.height)
            let child = SVGPainter(document: inner, monoFont: monoFont)
            child.context = context
            context.saveGState()
            context.translateBy(x: rect.minX, y: rect.minY)
            context.scaleBy(x: rect.width / box.width, y: rect.height / box.height)
            context.translateBy(x: -box.minX, y: -box.minY)
            child.draw(children: inner.root, style: Style())
            context.restoreGState()
        } else if let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(
                      source,
                      0,
                      nil
                  )
        {
            context.saveGState()
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
            context.restoreGState()
        }
        union(rect.applying(matrix))
    }

    // MARK: Transforms

    static func transform(_ text: String) -> CGAffineTransform {
        var result = CGAffineTransform.identity
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") {
            let name = rest[..<open]
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
            let numbers = rest[rest.index(after: open) ..< close].split { $0 == " " || $0 == "," }
                .compactMap { Double($0) }
            var step = CGAffineTransform.identity
            switch name {
            case "translate": step = CGAffineTransform(
                    translationX: numbers.first ?? 0,
                    y: numbers.count > 1 ? numbers[1] : 0
                )
            case "scale": step = CGAffineTransform(
                    scaleX: numbers.first ?? 1,
                    y: numbers.count > 1 ? numbers[1] : numbers.first ?? 1
                )
            case "rotate":
                let angle = (numbers.first ?? 0) * .pi / 180
                if numbers.count == 3 {
                    step = CGAffineTransform(translationX: numbers[1], y: numbers[2]).rotated(by: angle).translatedBy(
                        x: -numbers[1],
                        y: -numbers[2]
                    )
                } else {
                    step = CGAffineTransform(rotationAngle: angle)
                }
            case "matrix" where numbers.count == 6:
                step = CGAffineTransform(
                    a: numbers[0],
                    b: numbers[1],
                    c: numbers[2],
                    d: numbers[3],
                    tx: numbers[4],
                    ty: numbers[5]
                )
            case "skewX": step = CGAffineTransform(
                    a: 1,
                    b: 0,
                    c: tan((numbers.first ?? 0) * .pi / 180),
                    d: 1,
                    tx: 0,
                    ty: 0
                )
            case "skewY": step = CGAffineTransform(
                    a: 1,
                    b: tan((numbers.first ?? 0) * .pi / 180),
                    c: 0,
                    d: 1,
                    tx: 0,
                    ty: 0
                )
            default: break
            }
            // SVG applies a list left to right in the element's own space: each one is applied to what is inside it.
            result = step.concatenating(result)
            rest = rest[rest.index(after: close)...]
        }
        return result
    }
}

/// An SVG path's `d` as a `CGPath`: the absolute and relative lines, curves, arcs and closes.
enum SVGPath {
    static func parse(_ d: String) -> CGPath? {
        let path = CGMutablePath()
        var scanner = Scanner(d)
        var current = CGPoint.zero, start = CGPoint.zero
        var lastControl: CGPoint?
        var lastCommand: Character = " "
        var command: Character = " "
        var valid = false
        while let next = scanner.peekCommand() ?? (scanner.hasNumber ? repeatOf(command) : nil) {
            if scanner.peekCommand() != nil { scanner.advance() }
            command = next
            let relative = command.isLowercase
            func point(
                _ x: Double,
                _ y: Double
            ) -> CGPoint { relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(
                x: x,
                y: y
            ) }
            switch Character(command.uppercased()) {
            case "M":
                guard let x = scanner.number(), let y = scanner.number() else { return valid ? path : nil }
                current = point(x, y)
                start = current
                path.move(to: current)
                command = relative ? "l" : "L"
                lastControl = nil
            case "L":
                guard let x = scanner.number(), let y = scanner.number() else { return valid ? path : nil }
                current = point(x, y)
                path.addLine(to: current)
                lastControl = nil
            case "H":
                guard let x = scanner.number() else { return valid ? path : nil }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current)
                lastControl = nil
            case "V":
                guard let y = scanner.number() else { return valid ? path : nil }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current)
                lastControl = nil
            case "C":
                guard let a = scanner.number(), let b = scanner.number(), let c = scanner.number(),
                      let d = scanner.number(),
                      let e = scanner.number(), let f = scanner.number() else { return valid ? path : nil }
                let c1 = point(a, b), c2 = point(c, d), end = point(e, f)
                path.addCurve(to: end, control1: c1, control2: c2)
                lastControl = c2
                current = end
            case "S":
                guard let c = scanner.number(), let d = scanner.number(), let e = scanner.number(),
                      let f = scanner.number() else { return valid ? path : nil }
                let c1 = "CS".contains(lastCommand.uppercased()) && lastControl != nil
                    ? CGPoint(x: 2 * current.x - lastControl!.x, y: 2 * current.y - lastControl!.y) : current
                let c2 = point(c, d), end = point(e, f)
                path.addCurve(to: end, control1: c1, control2: c2)
                lastControl = c2
                current = end
            case "Q":
                guard let a = scanner.number(), let b = scanner.number(), let c = scanner.number(),
                      let d = scanner.number() else { return valid ? path : nil }
                let control = point(a, b), end = point(c, d)
                path.addQuadCurve(to: end, control: control)
                lastControl = control
                current = end
            case "T":
                guard let c = scanner.number(), let d = scanner.number() else { return valid ? path : nil }
                let control = "QT".contains(lastCommand.uppercased()) && lastControl != nil
                    ? CGPoint(x: 2 * current.x - lastControl!.x, y: 2 * current.y - lastControl!.y) : current
                let end = point(c, d)
                path.addQuadCurve(to: end, control: control)
                lastControl = control
                current = end
            case "A":
                guard let rx = scanner.number(), let ry = scanner.number(), let rotation = scanner.number(),
                      let large = scanner.flag(),
                      let sweep = scanner.flag(), let x = scanner.number(),
                      let y = scanner.number() else { return valid ? path : nil }
                let end = point(x, y)
                addArc(path, from: current, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep, to: end)
                current = end
                lastControl = nil
            case "Z":
                path.closeSubpath()
                current = start
                lastControl = nil
            default:
                return valid ? path : nil
            }
            valid = true
            lastCommand = command
        }
        return valid ? path : nil
    }

    private static func repeatOf(_ command: Character) -> Character? { command == " " || "Zz"
        .contains(command) ? nil : command
    }

    /// An elliptical arc as cubic curves (the endpoint-to-centre conversion of the SVG specification).
    private static func addArc(
        _ path: CGMutablePath,
        from p0: CGPoint,
        rx rxIn: Double,
        ry ryIn: Double,
        rotation: Double,
        large: Bool,
        sweep: Bool,
        to p1: CGPoint
    ) {
        var rx = abs(rxIn), ry = abs(ryIn)
        guard p0 != p1 else { return }
        guard rx > 0, ry > 0 else { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy, y1 = -sinPhi * dx + cosPhi * dy
        let lambda = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
        if lambda > 1 { rx *= lambda.squareRoot(); ry *= lambda.squareRoot() }
        let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var factor = denominator == 0 ? 0 : max(numerator / denominator, 0).squareRoot()
        if large == sweep { factor = -factor }
        let cxp = factor * rx * y1 / ry, cyp = -factor * ry * x1 / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2
        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let sign: Double = ux * vy - uy * vx < 0 ? -1 : 1
            let dot = (ux * vx + uy * vy) / ((ux * ux + uy * uy).squareRoot() * (vx * vx + vy * vy).squareRoot())
            return sign * acos(min(max(dot, -1), 1))
        }
        let theta1 = angle(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry)
        var delta = angle((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry)
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }
        let segments = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
        let step = delta / Double(segments)
        let t = 4.0 / 3.0 * tan(step / 4)
        var theta = theta1
        for _ in 0 ..< segments {
            let cos1 = cos(theta), sin1 = sin(theta), cos2 = cos(theta + step), sin2 = sin(theta + step)
            func map(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: cosPhi * rx * x - sinPhi * ry * y + cx, y: sinPhi * rx * x + cosPhi * ry * y + cy)
            }
            path.addCurve(
                to: map(cos2, sin2),
                control1: map(cos1 - t * sin1, sin1 + t * cos1),
                control2: map(cos2 + t * sin2, sin2 - t * cos2)
            )
            theta += step
        }
    }

    /// Reads a path's commands and numbers (`1.5.5` is two numbers, `-1-2` is two, flags of an arc may touch).
    struct Scanner {
        private let characters: [Character]
        private var index = 0

        init(_ text: String) { characters = Array(text) }

        private mutating func skipSeparators() {
            while index < characters.count,
                  characters[index] == " " || characters[index] == "," || characters[index] == "\n" ||
                  characters[index] == "\t" || characters[index] == "\r"
            {
                index += 1
            }
        }

        mutating func peekCommand() -> Character? {
            skipSeparators()
            guard index < characters.count, characters[index].isLetter, characters[index] != "e",
                  characters[index] != "E" else { return nil }
            return characters[index]
        }

        mutating func advance() { index += 1 }

        var hasNumber: Bool {
            var probe = self
            probe.skipSeparators()
            guard probe.index < probe.characters.count else { return false }
            let c = probe.characters[probe.index]
            return c.isNumber || c == "-" || c == "+" || c == "."
        }

        mutating func number() -> Double? {
            skipSeparators()
            var text = ""
            var seenDot = false, seenExponent = false
            while index < characters.count {
                let c = characters[index]
                if c.isNumber { text.append(c) } else if c == "." {
                    if seenDot || seenExponent { break }
                    seenDot = true
                    text.append(c)
                } else if c == "-" || c == "+",
                          text.isEmpty || (text.last == "e" || text.last == "E") { text.append(c) }
                else if c == "e" || c == "E", !text.isEmpty, !seenExponent {
                    seenExponent = true
                    text.append(c)
                } else { break }
                index += 1
            }
            return Double(text)
        }

        /// An arc's flag: one `0` or `1`.
        mutating func flag() -> Bool? {
            skipSeparators()
            guard index < characters.count, characters[index] == "0" || characters[index] == "1" else { return nil }
            defer { index += 1 }
            return characters[index] == "1"
        }
    }
}
