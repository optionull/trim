import CoreGraphics
import Foundation

/// A cubic Bézier easing (`cubic-bezier(x1, y1, x2, y2)`): the fraction of the way a value has gone for a fraction of
/// the time.
struct CubicBezier: Equatable {
    var x1: Double, y1: Double, x2: Double, y2: Double

    static let linear = CubicBezier(x1: 0, y1: 0, x2: 1, y2: 1)
    static let ease = CubicBezier(x1: 0.25, y1: 0.1, x2: 0.25, y2: 1)

    /// The easing a CSS timing function names: `linear`, `ease`, `ease-in`, `ease-out`, `ease-in-out` or
    /// `cubic-bezier(...)`.
    static func parse(_ text: String) -> CubicBezier? {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        switch value {
        case "linear": return .linear
        case "ease": return .ease
        case "ease-in": return CubicBezier(x1: 0.42, y1: 0, x2: 1, y2: 1)
        case "ease-out": return CubicBezier(x1: 0, y1: 0, x2: 0.58, y2: 1)
        case "ease-in-out": return CubicBezier(x1: 0.42, y1: 0, x2: 0.58, y2: 1)
        default: break
        }
        guard value.hasPrefix("cubic-bezier("), let close = value.lastIndex(of: ")") else { return nil }
        let numbers = value[value.index(value.startIndex, offsetBy: 13) ..< close].split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count == 4 else { return nil }
        return CubicBezier(x1: numbers[0], y1: numbers[1], x2: numbers[2], y2: numbers[3])
    }

    /// The eased fraction for `progress` (0 to 1 of the time).
    func value(at progress: Double) -> Double {
        if progress <= 0 { return 0 }
        if progress >= 1 { return 1 }
        if self == .linear { return progress }
        // Find the curve parameter whose x is `progress` (x is monotonic for the values CSS allows), then take its y.
        var low = 0.0, high = 1.0, t = progress
        for _ in 0 ..< 32 {
            let x = Self.sample(t, x1, x2)
            if abs(x - progress) < 1e-7 { break }
            if x < progress { low = t } else { high = t }
            t = (low + high) / 2
        }
        return Self.sample(t, y1, y2)
    }

    private static func sample(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t
    }
}

/// One transform function with its arguments, in the units SVG draws with (points, radians, factors).
struct TransformFunction: Equatable {
    var name: String
    var arguments: [Double]

    var identity: TransformFunction {
        switch name {
        case "scale", "scalex", "scaley": TransformFunction(name: name, arguments: arguments.map { _ in 1 })
        default: TransformFunction(name: name, arguments: arguments.map { _ in 0 })
        }
    }

    var matrix: CGAffineTransform {
        let a = arguments
        switch name {
        case "translate": return CGAffineTransform(translationX: a.first ?? 0, y: a.count > 1 ? a[1] : 0)
        case "translatex": return CGAffineTransform(translationX: a.first ?? 0, y: 0)
        case "translatey": return CGAffineTransform(translationX: 0, y: a.first ?? 0)
        case "scale": return CGAffineTransform(scaleX: a.first ?? 1, y: a.count > 1 ? a[1] : a.first ?? 1)
        case "scalex": return CGAffineTransform(scaleX: a.first ?? 1, y: 1)
        case "scaley": return CGAffineTransform(scaleX: 1, y: a.first ?? 1)
        case "rotate": return CGAffineTransform(rotationAngle: a.first ?? 0)
        default: return .identity
        }
    }

    /// A CSS transform list (`translateY(4px) scale(.96) rotate(30deg)`): lengths in px, angles in degrees (radians
    /// here).
    static func parseList(_ text: String) -> [TransformFunction] {
        var result: [TransformFunction] = []
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        if rest.lowercased() == "none" { return [] }
        while let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") {
            let name = rest[..<open].trimmingCharacters(in: .whitespaces).lowercased()
            let arguments = rest[rest.index(after: open) ..< close].split { $0 == "," || $0 == " " }
                .compactMap { piece -> Double? in
                    let text = piece.trimmingCharacters(in: .whitespaces)
                    if text.hasSuffix("deg") { return Double(text.dropLast(3)).map { $0 * .pi / 180 } }
                    if text.hasSuffix("rad") { return Double(text.dropLast(3)) }
                    if text.hasSuffix("px") { return Double(text.dropLast(2)) }
                    return Double(text)
                }
            result.append(TransformFunction(name: name, arguments: arguments))
            rest = rest[rest.index(after: close)...]
        }
        return result
    }

    /// The two lists a fraction `t` of the way from `from` to `to`: function by function when they match (the shorter
    /// padded with
    /// identities), else the one jumps to the other half way.
    static func interpolate(
        _ from: [TransformFunction],
        _ to: [TransformFunction],
        _ t: Double
    ) -> [TransformFunction] {
        let count = max(from.count, to.count)
        var result: [TransformFunction] = []
        for index in 0 ..< count {
            let a = index < from.count ? from[index] : to[index].identity
            let b = index < to.count ? to[index] : from[index].identity
            guard a.name == b.name, a.arguments.count == b.arguments.count else { return t < 0.5 ? from : to }
            result.append(TransformFunction(
                name: a.name,
                arguments: zip(a.arguments, b.arguments).map { $0 + ($1 - $0) * t }
            ))
        }
        return result
    }

    /// The matrix of a list: `f1 f2` is `f1 * f2`, so the last function is applied to a point first.
    static func matrix(_ list: [TransformFunction]) -> CGAffineTransform {
        var result = CGAffineTransform.identity
        for function in list {
            result = function.matrix.concatenating(result)
        }
        return result
    }
}

/// What the animations of an SVG say an element looks like at a moment.
struct AnimatedValues {
    var opacity: Double?
    /// The transform around the element's origin, in the user space of its parent.
    var transform: CGAffineTransform?
    var dashOffset: Double?
}

/// The CSS animations of an SVG as Mermaider.Animate makes them: `@keyframes` of percentages that set `opacity`,
/// `transform`
/// and `stroke-dashoffset` (with an easing per stop), and rules that give an element's class `animation: name 15s
/// linear
/// infinite both` and a `transform-origin` in the view box. Evaluated for any time, so the picture is a function of it.
final class SVGAnimations {
    struct Stop {
        var offset: Double
        var values: [String: String]
        var timing: CubicBezier?
    }

    struct Rule {
        var keyframes: String
        var duration: Double
        var delay: Double
        var timing: CubicBezier
        /// How many times it plays (`.infinity` for `infinite`).
        var iterations: Double
        var origin: CGPoint
    }

    private(set) var keyframes: [String: [Stop]] = [:]
    private(set) var rules: [String: Rule] = [:]

    /// The longest of the animations, in seconds: the length of a loop (0 when nothing animates).
    var duration: Double {
        rules.values.map { $0.delay + $0.duration * ($0.iterations.isFinite ? $0.iterations : 1) }.max() ?? 0
    }

    var isAnimated: Bool { !rules.isEmpty }

    init(styles: [String]) {
        for css in styles {
            parse(css)
        }
    }

    // MARK: Parsing

    private func parse(_ css: String) {
        var rest = Substring(css)
        var plain = ""
        while let at = rest.range(of: "@keyframes") {
            plain += rest[..<at.lowerBound]
            rest = rest[at.upperBound...]
            guard let open = rest.firstIndex(of: "{") else { break }
            let name = rest[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let close = Self.matching(in: rest, open: open) else { break }
            keyframes[name] = Self.stops(String(rest[rest.index(after: open) ..< close]))
            rest = rest[rest.index(after: close)...]
        }
        plain += rest
        for (selector, body) in SVGDocument.rules(plain) {
            let declarations = Dictionary(
                CSSValue.splitDeclarations(body).compactMap { declaration -> (String, String)? in
                    guard let colon = declaration.firstIndex(of: ":") else { return nil }
                    return (
                        declaration[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                        declaration[declaration.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }, uniquingKeysWith: { $1 }
            )
            guard let shorthand = declarations["animation"],
                  let rule = Self.rule(shorthand, declarations) else { continue }
            for part in selector.split(separator: ",") {
                let name = part.trimmingCharacters(in: .whitespaces)
                if name.hasPrefix(".") { rules[String(name.dropFirst())] = rule }
            }
        }
    }

    /// `name 15s linear infinite both`: the name, the durations (the first is how long, the second a delay), a timing
    /// function, a
    /// count, a fill.
    private static func rule(_ shorthand: String, _ declarations: [String: String]) -> Rule? {
        var name: String?
        var times: [Double] = []
        var timing = CubicBezier.linear
        var iterations = 1.0
        for token in tokens(shorthand) {
            if let seconds = Self.seconds(token) {
                times.append(seconds)
            } else if token == "infinite" {
                iterations = .infinity
            } else if let count = Double(token) {
                iterations = count
            } else if let bezier = CubicBezier.parse(token) {
                timing = bezier
            } else if Self.keywords.contains(token) {
                continue
            } else if name == nil {
                name = token
            }
        }
        guard let name, let duration = times.first, duration > 0 else { return nil }
        var origin = CGPoint.zero
        if let text = declarations["transform-origin"] {
            let numbers = text.split(separator: " ").compactMap { piece -> Double? in
                let value = piece.trimmingCharacters(in: .whitespaces)
                return Double(value.hasSuffix("px") ? String(value.dropLast(2)) : value)
            }
            if numbers.count >= 2 { origin = CGPoint(x: numbers[0], y: numbers[1]) }
        }
        return Rule(
            keyframes: name,
            duration: duration,
            delay: times.count > 1 ? times[1] : 0,
            timing: timing,
            iterations: iterations,
            origin: origin
        )
    }

    private static let keywords: Set = ["none", "forwards", "backwards", "both", "normal", "reverse", "alternate"]

    private static func seconds(_ token: String) -> Double? {
        if token.hasSuffix("ms") { return Double(token.dropLast(2)).map { $0 / 1000 } }
        if token.hasSuffix("s") { return Double(token.dropLast(1)) }
        return nil
    }

    /// A value cut at the spaces that are not inside parentheses.
    private static func tokens(_ text: String) -> [String] {
        var parts: [String] = []
        var depth = 0
        var current = ""
        for character in text {
            if character == "(" { depth += 1 } else if character == ")" { depth -= 1 }
            if character == " ", depth == 0 {
                if !current.isEmpty { parts.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    private static func stops(_ block: String) -> [Stop] {
        var stops: [Stop] = []
        var rest = Substring(block)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            let selector = rest[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
            var values: [String: String] = [:]
            var timing: CubicBezier?
            for declaration in CSSValue.splitDeclarations(String(rest[rest.index(after: open) ..< close])) {
                guard let colon = declaration.firstIndex(of: ":") else { continue }
                let property = declaration[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let value = declaration[declaration.index(after: colon)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if property == "animation-timing-function" {
                    timing = CubicBezier.parse(value)
                } else {
                    values[property] = value
                }
            }
            for part in selector.split(separator: ",") {
                let text = part.trimmingCharacters(in: .whitespaces)
                let offset: Double? = text == "from" ? 0 : text == "to" ? 1 : text
                    .hasSuffix("%") ? Double(text.dropLast()).map { $0 / 100 } : nil
                if let offset { stops.append(Stop(offset: offset, values: values, timing: timing)) }
            }
            rest = rest[rest.index(after: close)...]
        }
        return stops.sorted { $0.offset < $1.offset }
    }

    private static func matching(in text: Substring, open: Substring.Index) -> Substring.Index? {
        var depth = 0
        var index = open
        while index < text.endIndex {
            if text[index] == "{" { depth += 1 } else if text[index] == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }

    // MARK: Evaluating

    /// How far along its keyframes an animation is `time` seconds in, 0 to 1: looping, or held at the end once it has
    /// played its
    /// count (fill `both`: before it starts it holds the first keyframe).
    func progress(of rule: Rule, at time: Double) -> Double {
        let elapsed = time - rule.delay
        if elapsed <= 0 { return 0 }
        let total = rule.duration * rule.iterations
        if elapsed >= total, total.isFinite { return 1 }
        let within = elapsed.truncatingRemainder(dividingBy: rule.duration)
        return within / rule.duration
    }

    /// What the animation of an element of class `className` says at `time`; nil when its classes animate nothing.
    func values(forClass className: String, at time: Double) -> AnimatedValues? {
        for name in className.split(separator: " ") {
            guard let rule = rules[String(name)], let stops = keyframes[rule.keyframes] else { continue }
            let progress = progress(of: rule, at: time)
            var result = AnimatedValues()
            if let opacity = value(of: "opacity", stops, progress, rule, { Double($0) }, { $0 + ($1 - $0) * $2 }) {
                result.opacity = opacity
            }
            if let offset = value(
                of: "stroke-dashoffset",
                stops,
                progress,
                rule,
                { Double($0) },
                { $0 + ($1 - $0) * $2 }
            ) { result.dashOffset = offset }
            if let list = value(
                of: "transform", stops, progress, rule, { TransformFunction.parseList($0) },
                TransformFunction.interpolate
            ) {
                let around = CGAffineTransform(translationX: -rule.origin.x, y: -rule.origin.y)
                    .concatenating(TransformFunction.matrix(list))
                    .concatenating(CGAffineTransform(translationX: rule.origin.x, y: rule.origin.y))
                result.transform = around
            }
            return result
        }
        return nil
    }

    /// One property at `progress`: among the keyframes that set it, between the one before and the one after, eased by
    /// the
    /// timing function of the earlier (else the rule's), held before the first and after the last.
    private func value<T>(
        of property: String, _ stops: [Stop], _ progress: Double, _ rule: Rule, _ parse: (String) -> T?,
        _ mix: (T, T, Double) -> T
    ) -> T? {
        let have = stops.compactMap { stop -> (Stop, T)? in
            guard let text = stop.values[property], let value = parse(text) else { return nil }
            return (stop, value)
        }
        guard let first = have.first, let last = have.last else { return nil }
        if progress <= first.0.offset { return first.1 }
        if progress >= last.0.offset { return last.1 }
        for index in 0 ..< have.count - 1
            where progress >= have[index].0.offset && progress < have[index + 1].0.offset
        {
            let a = have[index], b = have[index + 1]
            let span = b.0.offset - a.0.offset
            let fraction = span > 0 ? (progress - a.0.offset) / span : 1
            return mix(a.1, b.1, (a.0.timing ?? rule.timing).value(at: fraction))
        }
        return last.1
    }
}
