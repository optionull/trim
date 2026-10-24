import SillCore
import Testing

@Suite("a profile over time")
struct ProfileStretchTests {
    /// Ten samples a millisecond apart: the first five in main → load, the last five in main → render, render's last
    /// two in render → paint.
    func document() -> ProfileDocument {
        var builder = CallTreeBuilder(program: "app")
        let main = SampledFrame(name: "main", module: "app")
        for time in 0 ..< 10 {
            let frames = time < 5 ? [main, SampledFrame(name: "load", module: "app")] :
                time < 8 ? [main, SampledFrame(name: "render", module: "app")] :
                [main, SampledFrame(name: "render", module: "app"), SampledFrame(name: "paint", module: "app")]
            builder.add(thread: "main thread", frames: frames, at: Double(100 + time))
        }
        return builder.document(name: "app", sampleMs: 1, exited: true)
    }

    func samples(_ document: ProfileDocument, _ name: String) -> Int {
        document.preorder.filter { document.names[$0.name] == name }.map(\.samples).reduce(0, +)
    }

    @Test("the strip counts the samples in each stretch, from the first")
    func timeline() {
        let profile = document()
        #expect(profile.timeline?.reduce(0, +) == 10 && profile.timeline?.count == 120)
        #expect(profile.sampleTimes?.first == 0 && profile.sampleTimes?.last == 9)
    }

    @Test("a stretch keeps only its samples: the tree, the totals and the hot spots")
    func stretch() throws {
        let profile = document()
        let early = try #require(profile.within(from: 0, to: 0.45))
        #expect(early.samples == 5 && samples(early, "load") == 5 && samples(early, "render") == 0)
        #expect(early.hotSpots.map(\.name) == ["load"])
        let late = try #require(profile.within(from: 0.5, to: 1))
        #expect(late.samples == 5 && samples(late, "render") == 5 && samples(late, "paint") == 2)
        #expect(late.hotSpots.first.map { ($0.name, $0.selfSamples, $0.total) } ?? ("", 0, 0) == ("render", 3, 5))
        #expect(late.preorder.first?.samples == 5, "the root counts the stretch")
        let whole = try #require(profile.within(from: 0, to: 1))
        #expect(whole.frames == profile.frames, "the whole run is the run")
    }
}
