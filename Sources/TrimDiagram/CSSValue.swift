import Foundation

/// A colour, straight (not premultiplied) components 0...1.
public struct RGBA: Equatable, Sendable {
    public var r: Double, g: Double, b: Double, a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public static let clear = RGBA(0, 0, 0, 0)
    public static let black = RGBA(0, 0, 0, 1)
}

/// The slice of CSS that Mermaider's SVG uses: custom properties (`--fg`), `var(--x, fallback)`, `color-mix(in srgb,
/// ...)`,
/// hex and `rgb()` colours, and lengths in `px`, `rem` and `em`.
public enum CSSValue {
    /// `value` with every `var(--name, fallback)` replaced from `variables` (a name not defined takes its fallback; a
    /// variable that holds another `var()` is resolved too, to a bounded depth).
    public static func resolve(_ value: String, _ variables: [String: String], depth: Int = 0) -> String {
        guard depth < 12, value.contains("var(") else { return value }
        var result = ""
        var index = value.startIndex
        while index < value.endIndex {
            if value[index...].hasPrefix("var("), let close = matchingParenthesis(
                in: value,
                open: value.index(index, offsetBy: 3)
            ) {
                let inner = String(value[value.index(index, offsetBy: 4) ..< close])
                let (name, fallback) = splitFirstComma(inner)
                let key = name.trimmingCharacters(in: .whitespaces)
                if let held = variables[key] {
                    result += resolve(held, variables, depth: depth + 1)
                } else if let fallback {
                    result += resolve(fallback.trimmingCharacters(in: .whitespaces), variables, depth: depth + 1)
                }
                index = value.index(after: close)
            } else {
                result.append(value[index])
                index = value.index(after: index)
            }
        }
        return result
    }

    /// The colour `value` names, nil for `none` or what is not a colour. `variables` resolve first.
    public static func color(_ value: String, _ variables: [String: String] = [:]) -> RGBA? {
        let text = resolve(value, variables).trimmingCharacters(in: .whitespaces).lowercased()
        if text.isEmpty || text == "none" { return nil }
        if text == "transparent" { return .clear }
        if text.hasPrefix("#") { return hex(String(text.dropFirst())) }
        if text.hasPrefix("rgb") { return rgb(text) }
        if text.hasPrefix("color-mix(") { return mix(text) }
        return named[text]
    }

    /// A length in user units: `12`, `12px`, `0.75rem`, `1.5em` (both taken as 16 points to the unit).
    public static func length(_ value: String, _ variables: [String: String] = [:], font: Double = 16) -> Double? {
        let text = resolve(value, variables).trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("rem") { return Double(text.dropLast(3)).map { $0 * 16 } }
        if text.hasSuffix("em") { return Double(text.dropLast(2)).map { $0 * font } }
        if text.hasSuffix("px") { return Double(text.dropLast(2)) }
        if text.hasSuffix("%") { return Double(text.dropLast(1)).map { $0 / 100 * font } }
        return Double(text)
    }

    // MARK: Parsing

    private static func hex(_ digits: String) -> RGBA? {
        var d = digits
        if d.count == 3 || d.count == 4 { d = d.map { "\($0)\($0)" }.joined() }
        guard d.count == 6 || d.count == 8, let number = UInt64(d, radix: 16) else { return nil }
        if d.count == 6 {
            return RGBA(
                Double((number >> 16) & 255) / 255,
                Double((number >> 8) & 255) / 255,
                Double(number & 255) / 255
            )
        }
        return RGBA(
            Double((number >> 24) & 255) / 255, Double((number >> 16) & 255) / 255,
            Double((number >> 8) & 255) / 255, Double(number & 255) / 255
        )
    }

    private static func rgb(_ text: String) -> RGBA? {
        guard let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")") else { return nil }
        let parts = text[text.index(after: open) ..< close].split { $0 == "," || $0 == " " || $0 == "/" }
            .map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard parts.count >= 3 else { return nil }
        func channel(_ part: String) -> Double? {
            part.hasSuffix("%") ? Double(part.dropLast()).map { $0 / 100 } : Double(part).map { $0 / 255 }
        }
        guard let r = channel(parts[0]), let g = channel(parts[1]), let b = channel(parts[2]) else { return nil }
        var alpha = 1.0
        if parts
            .count >
            3 { alpha = parts[3].hasSuffix("%") ? (Double(parts[3].dropLast()) ?? 100) / 100 : (Double(parts[3]) ?? 1) }
        return RGBA(r, g, b, alpha)
    }

    /// `color-mix(in srgb, A p%, B q%)`: the two colours weighted (a missing percentage is the rest; weights that do
    /// not add to 100 are
    /// scaled to), mixed with their alphas taken into account.
    private static func mix(_ text: String) -> RGBA? {
        guard let open = text.firstIndex(of: "("),
              let close = matchingParenthesis(in: text, open: open) else { return nil }
        let arguments = splitTopLevel(String(text[text.index(after: open) ..< close]))
        guard arguments.count == 3, arguments[0].hasPrefix("in ") else { return nil }
        func term(_ part: String) -> (RGBA, Double?)? {
            var colourText = part.trimmingCharacters(in: .whitespaces)
            var weight: Double?
            if let space = colourText.lastIndex(of: " "), colourText.hasSuffix("%") {
                weight = Double(colourText[colourText.index(after: space)...].dropLast())
                if weight != nil { colourText = String(colourText[..<space]) }
            }
            guard let colour = color(colourText) else { return nil }
            return (colour, weight)
        }
        guard let first = term(arguments[1]), let second = term(arguments[2]) else { return nil }
        var p1 = first.1, p2 = second.1
        if p1 == nil,
           p2 == nil { p1 = 50; p2 = 50 } else if p1 == nil { p1 = 100 - p2! } else if p2 == nil { p2 = 100 - p1! }
        let total = p1! + p2!
        guard total > 0 else { return nil }
        let w1 = p1! / total, w2 = p2! / total
        let a1 = first.0.a * w1, a2 = second.0.a * w2
        let alpha = a1 + a2
        guard alpha > 0 else { return .clear }
        func channel(_ x: Double, _ y: Double) -> Double { (x * a1 + y * a2) / alpha }
        return RGBA(
            channel(first.0.r, second.0.r), channel(first.0.g, second.0.g), channel(first.0.b, second.0.b), alpha
        )
    }

    private static let named: [String: RGBA] = [
        "white": RGBA(1, 1, 1), "black": .black, "red": RGBA(1, 0, 0), "green": RGBA(0, 0.5, 0), "blue": RGBA(0, 0, 1),
        "gray": RGBA(0.5, 0.5, 0.5), "grey": RGBA(0.5, 0.5, 0.5), "yellow": RGBA(1, 1, 0), "orange": RGBA(1, 0.647, 0),
    ]

    // MARK: Parentheses and commas

    private static func matchingParenthesis(in text: String, open: String.Index) -> String.Index? {
        var depth = 0
        var index = open
        while index < text.endIndex {
            if text[index] == "(" { depth += 1 } else if text[index] == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func splitFirstComma(_ text: String) -> (String, String?) {
        var depth = 0
        for index in text.indices {
            let character = text[index]
            if character == "(" { depth += 1 } else if character == ")" { depth -= 1 } else if character == ",",
                                                                                               depth == 0
            {
                return (String(text[..<index]), String(text[text.index(after: index)...]))
            }
        }
        return (text, nil)
    }

    /// `text` cut at the commas outside parentheses, each part trimmed.
    static func splitTopLevel(_ text: String) -> [String] {
        var parts: [String] = []
        var depth = 0
        var current = ""
        for character in text {
            if character == "(" { depth += 1 } else if character == ")" { depth -= 1 }
            if character == ",", depth == 0 {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current.trimmingCharacters(in: .whitespaces))
        return parts
    }
}
