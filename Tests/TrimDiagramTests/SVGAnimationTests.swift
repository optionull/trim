import CoreGraphics
import Foundation
import Testing
@testable import TrimDiagram

@Suite("CSS keyframe animations, as Mermaider.Animate makes them")
struct SVGAnimationTests {
    private func animations(_ css: String) -> SVGAnimations { SVGAnimations(styles: [css]) }

    private func near(_ a: Double?, _ b: Double, _ tolerance: Double = 0.001) -> Bool {
        guard let a else { return false }
        return abs(a - b) < tolerance
    }

    @Test("easing: linear is linear, ease-in-out is symmetric, a curve that overshoots goes past 1")
    func easing() throws {
        #expect(near(CubicBezier.linear.value(at: 0.3), 0.3))
        let inOut = try #require(CubicBezier.parse("ease-in-out"))
        #expect(near(inOut.value(at: 0.5), 0.5) && inOut.value(at: 0.2) < 0.2 && inOut.value(at: 0.8) > 0.8)
        let decelerate = try #require(CubicBezier.parse("cubic-bezier(.2,0,0,1)"))
        #expect(decelerate.value(at: 0) == 0 && decelerate.value(at: 1) == 1)
        #expect(decelerate.value(at: 0.25) > 0.5, "a deceleration is most of the way early")
        let springy = try #require(CubicBezier.parse("cubic-bezier(.3,1.6,.6,1)"))
        #expect((1 ... 99).contains { springy.value(at: Double($0) / 100) > 1.05 }, "an overshoot")
        #expect(CubicBezier.parse("cubic-bezier(1,2,3)") == nil && CubicBezier.parse("wobble") == nil)
        var last = 0.0
        for step in 0 ... 100 {
            let value = decelerate.value(at: Double(step) / 100)
            #expect(value >= last - 1e-9, "monotonic")
            last = value
        }
    }

    @Test(
        "a rule is read from the shorthand, with its origin; keyframes from their percentages and the easing at a stop"
    )
    func parsing() throws {
        let set = animations("""
        @keyframes k1{0.000%{opacity:0}50.000%{opacity:1;animation-timing-function:cubic-bezier(.4,0,.2,1)}100.000%{opacity:0}}\
        .k1{animation:k1 15s linear infinite both;transform-box:view-box;transform-origin:450px 115px;}
        text{font-family:Inter}
        """)
        #expect(set.isAnimated && set.duration == 15)
        let rule = try #require(set.rules["k1"])
        #expect(rule.duration == 15 && rule.iterations == .infinity && rule.origin == CGPoint(x: 450, y: 115))
        let stops = try #require(set.keyframes["k1"])
        #expect(stops.map(\.offset) == [0, 0.5, 1])
        #expect(stops[1].timing == CubicBezier.parse("cubic-bezier(.4,0,.2,1)") && stops[0].timing == nil)
        #expect(!animations("text{font-family:Inter}").isAnimated)
    }

    @Test("opacity follows the keyframes, loops, and holds the first keyframe before it begins")
    func opacity() {
        let set =
            animations(
                "@keyframes k{0%{opacity:0}50%{opacity:1}100%{opacity:0}}.k{animation:k 10s linear infinite both}"
            )
        func opacity(_ time: Double) -> Double? { set.values(forClass: "k", at: time)?.opacity }
        #expect(near(opacity(0), 0) && near(opacity(2.5), 0.5) && near(opacity(5), 1) && near(opacity(7.5), 0.5))
        #expect(near(opacity(10), 0) && near(opacity(12.5), 0.5), "it loops")
        #expect(near(opacity(-3), 0), "before it begins, the first keyframe")
        #expect(set.values(forClass: "other", at: 1) == nil, "a class that animates nothing")
    }

    @Test(
        "a keyframe's easing is the one of the interval it starts, else the rule's; stops that skip a property are skipped for it"
    )
    func perStopEasing() {
        let set = animations("""
        @keyframes k{0%{opacity:0;animation-timing-function:cubic-bezier(.4,0,1,1)}50%{opacity:1}100%{opacity:1;stroke-dashoffset:1}}\
        .k{animation:k 10s linear infinite both}
        """)
        let early = set.values(forClass: "k", at: 2.5)?.opacity
        #expect(
            (early ?? 1) < 0.5,
            "an ease-in first half is behind linear at its middle: \(String(describing: early))"
        )
        #expect(near(set.values(forClass: "k", at: 7.5)?.opacity, 1), "the second half sets nothing new")
        #expect(
            near(set.values(forClass: "k", at: 5)?.dashOffset, 1),
            "a property only the last stop sets holds its value before it"
        )
    }

    @Test("transforms interpolate function by function around the origin, and a list pads with identities")
    func transforms() {
        let set = animations("""
        @keyframes k{0%{opacity:1;transform:translateY(4px)}100%{opacity:1;transform:translateY(0)}}\
        @keyframes r{0%{transform:rotate(0deg)}100%{transform:rotate(90deg)}}\
        @keyframes s{0%{transform:scale(.5)}100%{transform:scale(1) translateX(10px)}}\
        .k{animation:k 10s linear infinite both;transform-box:view-box;transform-origin:0px 0px}\
        .r{animation:r 10s linear infinite both;transform-box:view-box;transform-origin:100px 100px}\
        .s{animation:s 10s linear infinite both;transform-box:view-box;transform-origin:0px 0px}
        """)
        let moved = set.values(forClass: "k", at: 5)?.transform
        #expect(near(Double(moved?.ty ?? 99), 2), "half way between 4 and 0")
        // A quarter turn around (100, 100): the point to its right goes below it.
        let turned = set.values(forClass: "r", at: 10 - 1e-9)?.transform
        let point = CGPoint(x: 110, y: 100).applying(turned ?? .identity)
        #expect(abs(point.x - 100) < 0.01 && abs(point.y - 110) < 0.01, "\(point)")
        let half = set.values(forClass: "r", at: 5)?.transform
        let diagonal = CGPoint(x: 110, y: 100).applying(half ?? .identity)
        #expect(abs(diagonal.x - (100 + 10 * cos(.pi / 4))) < 0.01, "an eighth of a turn")
        // scale(.5) to scale(1) translateX(10px): the shorter list is padded with translateX(0).
        let padded = set.values(forClass: "s", at: 5)?.transform
        let sample = CGPoint(x: 8, y: 0).applying(padded ?? .identity)
        #expect(
            abs(sample.x - (8 + 5) * 0.75) < 0.01,
            "moved 5 first, then scaled 0.75 (the last function acts on a point first): \(sample)"
        )
    }

    @Test("an animation of a finite count holds its end, and a delay holds its start")
    func finite() {
        let set = animations("@keyframes k{0%{opacity:0}100%{opacity:1}}.k{animation:k 4s linear 2s 1 both}")
        func opacity(_ time: Double) -> Double? { set.values(forClass: "k", at: time)?.opacity }
        #expect(near(opacity(1), 0) && near(opacity(2), 0), "before the delay")
        #expect(near(opacity(4), 0.5) && near(opacity(6), 1) && near(opacity(60), 1), "plays once, then holds the end")
        #expect(set.duration == 6)
    }
}
