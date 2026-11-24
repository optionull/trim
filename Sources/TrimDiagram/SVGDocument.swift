import Foundation

/// An element of an SVG: its name, attributes, children and the character data directly in it.
final class SVGElement {
    let name: String
    var attributes: [String: String]
    var children: [SVGElement] = []
    /// What is inside it, in order: character data and child elements (a `<text>` with `<tspan>`s).
    var content: [Content] = []
    weak var parent: SVGElement?

    enum Content {
        case text(String)
        case element(SVGElement)
    }

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    var text: String { content.compactMap { if case let .text(string) = $0 { string } else { nil } }.joined() }
    var classes: [String] { (attributes["class"] ?? "").split(separator: " ").map(String.init) }
}

/// An SVG read into a tree, with what `<defs>` defines by id and the custom properties (`--fg: ...`) that the root and
/// its
/// `<style>` set.
final class SVGDocument {
    let root: SVGElement
    private(set) var ids: [String: SVGElement] = [:]
    private(set) var variables: [String: String] = [:]

    struct ParseFailure: Error, CustomStringConvertible {
        let description: String
    }

    init(_ svg: String) throws {
        let parser = Builder()
        let xml = XMLParser(data: Data(svg.utf8))
        xml.delegate = parser
        xml.shouldProcessNamespaces = false
        guard xml.parse(), let root = parser.root else {
            throw ParseFailure(description: xml.parserError?.localizedDescription ?? "not an SVG")
        }
        guard root.name == "svg" else { throw ParseFailure(description: "the root is <\(root.name)>, not <svg>") }
        self.root = root
        index(root)
        // Custom properties: the root's style attribute, then each `<style>`'s `svg { --x: ... }` rule, later ones over
        // earlier.
        if let style = root.attributes["style"] { Self.declarations(style).forEach { variables[$0.0] = $0.1 } }
        collectStyles(root)
    }

    private func index(_ element: SVGElement) {
        if let id = element.attributes["id"] { ids[id] = element }
        element.children.forEach(index)
    }

    private func collectStyles(_ element: SVGElement) {
        if element.name == "style" {
            for rule in Self.rules(element.text) where rule.selector.split(separator: ",").contains(where: {
                $0.trimmingCharacters(in: .whitespaces) == "svg"
            }) {
                Self.declarations(rule.body).forEach { variables[$0.0] = $0.1 }
            }
        }
        element.children.forEach(collectStyles)
    }

    /// The `--name: value` declarations of a block, in order.
    static func declarations(_ block: String) -> [(String, String)] {
        CSSValue.splitDeclarations(block).compactMap { declaration in
            guard let colon = declaration.firstIndex(of: ":") else { return nil }
            let name = declaration[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.hasPrefix("--") else { return nil }
            return (
                name,
                declaration[declaration.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    /// The `selector { body }` rules of a stylesheet (no nesting: Mermaider's has none).
    static func rules(_ css: String) -> [(selector: String, body: String)] {
        var result: [(String, String)] = []
        var rest = Substring(css)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            result.append((
                rest[..<open].trimmingCharacters(in: .whitespacesAndNewlines),
                String(rest[rest.index(after: open) ..< close])
            ))
            rest = rest[rest.index(after: close)...]
        }
        return result
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: SVGElement?
        private var stack: [SVGElement] = []

        func parser(
            _: XMLParser,
            didStartElement name: String,
            namespaceURI _: String?,
            qualifiedName _: String?,
            attributes: [String: String]
        ) {
            let element = SVGElement(name: name, attributes: attributes)
            if let parent = stack.last {
                element.parent = parent
                parent.children.append(element)
                parent.content.append(.element(element))
            } else {
                root = element
            }
            stack.append(element)
        }

        func parser(_: XMLParser, didEndElement _: String, namespaceURI _: String?, qualifiedName _: String?) {
            _ = stack.popLast()
        }

        func parser(_: XMLParser, foundCharacters string: String) {
            stack.last?.content.append(.text(string))
        }

        func parser(_: XMLParser, foundCDATA data: Data) {
            stack.last?.content.append(.text(String(decoding: data, as: UTF8.self)))
        }
    }
}

extension CSSValue {
    /// A declaration block cut at its semicolons (not those inside parentheses or quotes).
    static func splitDeclarations(_ block: String) -> [String] {
        var parts: [String] = []
        var depth = 0
        var quote: Character?
        var current = ""
        for character in block {
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
            } else if character == ";", depth == 0 {
                parts.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(current) }
        return parts
    }
}
