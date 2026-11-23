@testable import SillCore
import Testing

@Suite struct ScrollSlideTests {
    @Test func `a slide starts at nothing, eases out and is done after its duration`() {
        let slide = ScrollSlide(lines: 3, start: 10)
        #expect(slide.progress(at: 10) == 0)
        #expect(slide.progress(at: 10 + ScrollSlide.duration) == 1)
        #expect(slide.progress(at: 10 + ScrollSlide.duration / 2) > 0.5)
        #expect(slide.isDone(at: 10 + ScrollSlide.duration) && !slide.isDone(at: 10.01))
        #expect(slide.progress(at: 5) == 0 && slide.progress(at: 99) == 1)
    }

    @Test func `the lines still to show shrink as it goes`() {
        let slide = ScrollSlide(lines: 4, start: 0)
        #expect(slide.remaining(at: 0) == 4)
        #expect(slide.remaining(at: ScrollSlide.duration) == 0)
        #expect(slide.remaining(at: 0.05) < 4 && slide.remaining(at: 0.05) > 0)
    }

    @Test func `a scroll while sliding goes on from where it is, not from where the first began`() throws {
        let first = ScrollSlide(lines: 1, start: 0)
        let now = 0.04
        let before = first.remaining(at: now)
        let chained = try #require(ScrollSlide.chained(first, then: 1, at: now, height: 40))
        #expect(chained.lines == 2 && chained.start == now)
        // What is still to show right after it is what was left plus the new line: no jump.
        #expect(abs(chained.remaining(at: now) - (before + 1)) < 1e-9)
        // And it still ends at nothing.
        #expect(chained.remaining(at: now + ScrollSlide.duration) == 0)
    }

    @Test func `many in a row never jump back`() throws {
        var slide = ScrollSlide(lines: 1, start: 0)
        var now = 0.0
        var lastVisual = slide.remaining(at: now)
        for _ in 0 ..< 20 {
            now += 0.016
            let visual = slide.remaining(at: now)
            // The window is never further from where nvim has it than it was a frame ago plus the line that came.
            #expect(visual <= lastVisual + 1e-9)
            slide = try #require(ScrollSlide.chained(slide, then: 1, at: now, height: 60))
            let after = slide.remaining(at: now)
            #expect(abs(after - (visual + 1)) < 1e-9)
            lastVisual = after
        }
    }

    @Test func `scrolls that cancel, or reach a screenful, do not slide`() {
        let slide = ScrollSlide(lines: 3, start: 0)
        #expect(ScrollSlide.chained(slide, then: -3, at: 0.02, height: 40) == nil)
        #expect(ScrollSlide.chained(slide, then: 40, at: 0.02, height: 40) == nil)
        #expect(ScrollSlide.chained(slide, then: -4, at: 0.02, height: 40)?.lines == -1)
    }
}
