import AppKit
import SillInput
import Testing

@Suite("mouse")
struct MouseTests {
    @Test("modifiers in nvim's order")
    func modifiers() {
        #expect(Mouse.modifiers([]) == "")
        #expect(Mouse.modifiers([.command, .shift, .control]) == "CSD")
        #expect(Mouse.modifiers(.option) == "A")
    }

    @Test("a mouse wheel scrolls a line per notch")
    func wheel() {
        var scroll = ScrollAccumulator(lineHeight: 20, columnWidth: 9)
        #expect(scroll.steps(deltaX: 0, deltaY: 3, precise: false) == ["up", "up", "up"])
        #expect(scroll.steps(deltaX: 0, deltaY: -1, precise: false) == ["down"])
    }

    @Test("trackpad pixels add up into lines, the rest carried over")
    func trackpad() {
        var scroll = ScrollAccumulator(lineHeight: 20, columnWidth: 9)
        #expect(scroll.steps(deltaX: 0, deltaY: 12, precise: true).isEmpty)
        #expect(scroll.steps(deltaX: 0, deltaY: 12, precise: true) == ["up"])
        #expect(scroll.steps(deltaX: 0, deltaY: 36, precise: true) == ["up", "up"])
        #expect(scroll.steps(deltaX: 0, deltaY: -20, precise: true) == ["down"])
        #expect(scroll.steps(deltaX: -19, deltaY: 0, precise: true) == ["right", "right"])
    }

    @Test("reset forgets a partial line")
    func reset() {
        var scroll = ScrollAccumulator(lineHeight: 20, columnWidth: 9)
        _ = scroll.steps(deltaX: 0, deltaY: 15, precise: true)
        scroll.reset()
        #expect(scroll.steps(deltaX: 0, deltaY: 10, precise: true).isEmpty)
    }
}
