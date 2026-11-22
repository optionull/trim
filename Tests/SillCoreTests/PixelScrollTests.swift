@testable import SillCore
import Testing

@Suite struct PixelScrollTests {
    @Test func `going down, nvim is asked for the next line as soon as the text starts to move`() {
        var scroll = PixelScroll()
        #expect(scroll.move(by: 0.2) == 1, "a fifth of a line: the line it moves towards is there already")
        #expect(scroll.move(by: 0.3) == 0, "inside that line nothing more is asked")
        #expect(scroll.move(by: 0.4) == 0)
        #expect(scroll.visual == 0.9)
        #expect(scroll.move(by: 0.2) == 1, "past the line, the next one")
        #expect(scroll.sent == 2)
    }

    @Test func `going up is the same the other way`() {
        var scroll = PixelScroll()
        #expect(scroll.move(by: -0.2) == -1)
        #expect(scroll.move(by: -0.5) == 0)
        #expect(scroll.move(by: -0.5) == -1)
    }

    @Test func `a move of several lines asks for all of them`() {
        var scroll = PixelScroll()
        #expect(scroll.move(by: 3.4) == 4)
        #expect(scroll.move(by: -1.0) == -2, "turning round: nvim goes to the line below the text (2.4), from 4")
        #expect(scroll.sent == 2)
    }

    @Test func `turning back inside the line nvim has gone to asks for the line back`() {
        var scroll = PixelScroll()
        #expect(scroll.move(by: 0.6) == 1)
        // The text is at 0.6 with nvim a line ahead; moving back to 0.3 keeps it a line ahead but the other way is
        // floor.
        #expect(scroll.move(by: -0.3) == -1, "nvim leads the other way now: it goes back a line")
        #expect(scroll.sent == 0)
    }

    @Test func `how far along a slide is follows what is left to go`() {
        #expect(PixelScroll.progress(lines: 1, lag: 1) == 0)
        #expect(PixelScroll.progress(lines: 1, lag: 0.25) == 0.75)
        #expect(PixelScroll.progress(lines: 1, lag: 0) == 1)
        #expect(PixelScroll.progress(lines: -1, lag: -0.5) == 0.5)
        #expect(PixelScroll.progress(lines: 2, lag: 1) == 0.5)
        #expect(PixelScroll.progress(lines: 1, lag: -0.4) == 1, "never past where nvim is")
        #expect(PixelScroll.progress(lines: 0, lag: 0.3) == 1)
    }

    @Test func `the text cannot run away from an nvim that does not scroll`() {
        var scroll = PixelScroll()
        for _ in 0 ..< 50 {
            _ = scroll.move(by: 0.5, reported: 0)
        }
        #expect(scroll.visual <= 8, "held within a few lines of where nvim is")
        #expect(scroll.sent <= 8)
        #expect(scroll.lag(reported: 0) == -scroll.visual)
    }

    @Test func `a gesture that is over leaves nothing behind`() {
        var scroll = PixelScroll()
        _ = scroll.move(by: 1.7)
        scroll.reset()
        #expect(scroll == PixelScroll())
    }
}
