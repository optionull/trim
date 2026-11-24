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
        #expect(scroll.move(by: 3.4) == 3, "held to a few lines (slack) ahead of an nvim that has not scrolled yet")
        #expect(
            scroll.move(by: -1.0, reported: 3) == -1,
            "turning round: nvim goes to the line below the text (2.0), from 3"
        )
        #expect(scroll.sent == 2)
    }

    @Test func `turning back inside the line nvim has gone to asks for the line back`() {
        var scroll = PixelScroll()
        #expect(scroll.move(by: 0.6) == 1)
        // The text is at 0.6 with nvim a line ahead; moving back to 0.3 keeps it a line ahead but the other way is
        // floor.
        #expect(scroll.move(by: -0.3, reported: 1) == -1, "nvim leads the other way now: it goes back a line")
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

    @Test func `a nvim whose steps scroll several rows keeps the text with the finger, and goes only a step ahead of it`(
    ) {
        // Each step nvim is asked for scrolls `rows` rows (a line with a card drawn under it), reported as it happens.
        for rows in [1, 7, 12] {
            var scroll = PixelScroll()
            var reported = 0
            var steps = 0
            var last = 1
            for _ in 0 ..< 200 {
                let asked = scroll.move(by: 0.25, reported: reported, lastStep: last)
                steps += asked
                if asked != 0 {
                    reported += asked * rows
                    last = rows
                    scroll.acknowledge()
                }
            }
            // The finger moved 50 lines.
            #expect(
                abs(scroll.visual - 50) < 0.5,
                "the text is where the finger took it, not carried by nvim's jumps: \(scroll.visual) for \(rows) rows a step"
            )
            #expect(steps <= 50, "no more steps than lines the finger moved: \(steps)")
            #expect(reported <= 50 + rows + 3, "nvim ends within a step of the finger: \(reported) rows for 50")
        }
    }

    @Test func `and going back, or over lines of one row and of several, it still follows the finger`() {
        var scroll = PixelScroll()
        var reported = 0
        var last = 1
        let rows = [1, 1, 9, 1, 1, 1, 12, 1, 1, 6]
        var count = 0
        for _ in 0 ..< 400 {
            let asked = scroll.move(by: 0.25, reported: reported, lastStep: last)
            if asked != 0 {
                let moved = rows[count % rows.count]
                count += abs(asked)
                reported += (asked > 0 ? 1 : -1) * moved * abs(asked)
                last = moved
                scroll.acknowledge()
            }
        }
        #expect(abs(scroll.visual - 100) < 0.5, "down: the text follows 100 lines of finger: \(scroll.visual)")
        for _ in 0 ..< 400 {
            let asked = scroll.move(by: -0.25, reported: reported, lastStep: last)
            if asked != 0 {
                let moved = rows[count % rows.count]
                count += abs(asked)
                reported += (asked > 0 ? 1 : -1) * moved * abs(asked)
                last = moved
                scroll.acknowledge()
            }
        }
        #expect(abs(scroll.visual) < 0.5, "and back to where it began: \(scroll.visual)")
    }
}
