import Foundation
import Testing
@testable import TrimDiagram

@Suite("CSS values in Mermaider's SVG")
struct CSSValueTests {
    private func close(_ a: RGBA?, _ b: RGBA, tolerance: Double = 0.004) -> Bool {
        guard let a else { return false }
        return abs(a.r - b.r) < tolerance && abs(a.g - b.g) < tolerance && abs(a.b - b.b) < tolerance && abs(
            a.a - b.a
        ) <
            tolerance
    }

    @Test("hex, rgb(), transparent and none")
    func colours() {
        #expect(close(CSSValue.color("#FF8800"), RGBA(1, 0x88 / 255.0, 0)))
        #expect(close(CSSValue.color("#f80"), RGBA(1, 0x88 / 255.0, 0)))
        #expect(close(CSSValue.color("#ff880080"), RGBA(1, 0x88 / 255.0, 0, 0x80 / 255.0)))
        #expect(close(CSSValue.color("rgb(255, 0, 0)"), RGBA(1, 0, 0)))
        #expect(close(CSSValue.color("rgba(0, 0, 255, 0.5)"), RGBA(0, 0, 1, 0.5)))
        #expect(CSSValue.color("transparent") == .clear)
        #expect(CSSValue.color("none") == nil)
        #expect(CSSValue.color("url(#g)") == nil)
    }

    @Test("var() takes a defined variable, else its fallback, through other variables")
    func variables() {
        let vars = ["--fg": "#102030", "--text": "var(--fg)", "--surface": "var(--missing, #405060)"]
        #expect(CSSValue.resolve("var(--fg)", vars) == "#102030")
        #expect(CSSValue.resolve("var(--text)", vars) == "#102030", "a variable that holds a variable")
        #expect(CSSValue.resolve("var(--nope, red)", vars) == "red")
        #expect(CSSValue.resolve("var(--surface)", vars) == "#405060")
        #expect(CSSValue.resolve("a var(--fg) b var(--fg)", vars) == "a #102030 b #102030")
        #expect(CSSValue.resolve("var(--loop)", ["--loop": "var(--loop)"]).count < 400, "a cycle ends")
    }

    @Test("color-mix in srgb: weights, a missing weight, nested mixes and variables")
    func mixing() {
        let vars = ["--fg": "#ffffff", "--bg": "#000000"]
        #expect(close(CSSValue.color("color-mix(in srgb, var(--fg) 25%, var(--bg))", vars), RGBA(0.25, 0.25, 0.25)))
        #expect(
            close(CSSValue.color("color-mix(in srgb, #ff0000, #0000ff)"), RGBA(0.5, 0, 0.5)),
            "no weights is half and half"
        )
        #expect(close(CSSValue.color("color-mix(in srgb, #ff0000 100%, #0000ff)"), RGBA(1, 0, 0)))
        let nested = "color-mix(in srgb, var(--accent, var(--fg)) 50%, color-mix(in srgb, #000000 50%, #ffffff))"
        #expect(
            close(CSSValue.color(nested, vars), RGBA(0.75, 0.75, 0.75)),
            "the accent falls back to fg; the inner mix is grey"
        )
        #expect(
            close(CSSValue.color("color-mix(in srgb, #ff0000 50%, transparent)"), RGBA(1, 0, 0, 0.5)),
            "transparency halves the alpha, not the colour"
        )
    }

    @Test("lengths: px, rem, em, a bare number, and a variable")
    func lengths() {
        #expect(CSSValue.length("12") == 12)
        #expect(CSSValue.length("12px") == 12)
        #expect(CSSValue.length("0.75rem") == 12)
        #expect(CSSValue.length("2em", font: 10) == 20)
        #expect(CSSValue.length("var(--fs-s)", ["--fs-s": "0.875rem"]) == 14)
        #expect(CSSValue.length("wide") == nil)
    }
}
