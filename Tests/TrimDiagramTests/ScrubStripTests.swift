import Foundation
import Testing
@testable import TrimDiagram

private let theme = ["fg": "#ffffff", "accent": "#ff0000", "muted": "#808080", "bg": "#000000"]

private func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

/// Whether the pixel at the point (from the top left, in points) is the accent red.
private func isRed(_ image: DiagramImage, x: Double, y: Double) -> Bool {
    let px = min(max(Int(x * Double(image.scale)), 0), image.pixelWidth - 1)
    let py = min(max(Int(y * Double(image.scale)), 0), image.pixelHeight - 1)
    let offset = py * image.bytesPerRow + px * 4
    let (b, r, a): (UInt8, UInt8, UInt8) = image.pixels.withUnsafeBytes { ($0[offset], $0[offset + 2], $0[offset + 3]) }
    return a > 150 && Int(r) > 180 && Int(b) < 90
}

@Suite("The bar for scrubbing a diagram that moves")
struct ScrubStripTests {
    @Test("a press on the mark toggles, on the track seeks to where it is, on the time does nothing")
    func hits() {
        let width = 600.0
        let track = ScrubStrip.track(width: width)
        #expect(ScrubStrip.hit(x: 10, width: width) == .toggle)
        #expect(ScrubStrip.hit(x: ScrubStrip.iconWidth - 1, width: width) == .toggle, "the whole mark")
        if case .toggle? = ScrubStrip
            .hit(x: ScrubStrip.iconWidth + 1, width: width) { Issue.record("past the mark is the track") }
        #expect(ScrubStrip.hit(x: track.from, width: width) == .seek(0))
        #expect(ScrubStrip.hit(x: track.to, width: width) == .seek(1))
        guard case let .seek(middle)? = ScrubStrip.hit(x: (track.from + track.to) / 2, width: width) else {
            Issue.record("the middle of the track is not a seek")
            return
        }
        #expect(abs(middle - 0.5) < 0.001)
        #expect(ScrubStrip.hit(x: width - 20, width: width) == nil, "the time")
        #expect(
            ScrubStrip.fraction(x: -50, width: width) == 0 && ScrubStrip.fraction(x: 5000, width: width) == 1,
            "a drag past the ends"
        )
    }

    @Test(
        "a picture with the bar is taller by its height, and the bar says where it is: the filled part grows with the time"
    )
    func drawn() throws {
        let diagram = try AnimatedDiagram(svg: fixture("animated-request-path"))
        let plain = try diagram.frame(at: 1, scale: 2)
        func strip(_ seconds: Double, paused: Bool = false) -> ScrubStrip {
            ScrubStrip(seconds: seconds, duration: diagram.duration, paused: paused, theme: theme)
        }
        let early = try diagram.frame(at: 1.5, scale: 2, strip: strip(1.5))
        let late = try diagram.frame(at: 12, scale: 2, strip: strip(12))
        #expect(early.size.height == plain.size.height + ScrubStrip.height && early.scrubHeight == ScrubStrip.height)
        #expect(plain.scrubHeight == 0)
        let width = Double(early.size.width)
        let track = ScrubStrip.track(width: width)
        let y = Double(early.size.height) - Double(ScrubStrip.height) / 2
        let quarter = track.from + (track.to - track.from) * 0.4
        #expect(!isRed(early, x: quarter, y: y), "1.5 of 15 s: the track is not filled at 40%")
        #expect(isRed(late, x: quarter, y: y), "12 of 15 s: it is")
        #expect(isRed(early, x: track.from + 2, y: y), "filled from the start")
    }

    @Test("the mark is a triangle while paused and two bars while it plays")
    func mark() throws {
        let diagram = try AnimatedDiagram(svg: fixture("animated-request-path"))
        func frame(paused: Bool) throws -> DiagramImage {
            try diagram.frame(
                at: 3, scale: 2, strip: ScrubStrip(seconds: 3, duration: diagram.duration, paused: paused, theme: theme)
            )
        }
        let playing = try frame(paused: false), paused = try frame(paused: true)
        let y = Double(playing.size.height) - Double(ScrubStrip.height) / 2
        let centre = ScrubStrip.iconWidth / 2
        // Between the two bars there is nothing; in a triangle there is.
        #expect(!isRed(playing, x: centre, y: y) && isRed(paused, x: centre, y: y))
        #expect(isRed(playing, x: centre - 3, y: y) && isRed(playing, x: centre + 3, y: y))
        #expect(playing.pixels != paused.pixels)
    }

    @Test("the time wraps with the loop")
    func wraps() {
        let strip = ScrubStrip(seconds: 17, duration: 15, paused: false, theme: theme)
        #expect(abs(strip.seconds - 2) < 1e-9)
    }
}
