import Foundation
@testable import SillCore
import Testing

@Suite("the summary's story line")
struct StoryLineTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("the headline: the walkthrough not read, else what happened, counted, and where the agent is")
    func headline() {
        let unread = CheckoutState.Prepared(
            path: "/r/x.walk.md", title: "The tax is rounded once", summary: "", at: now, seen: false, kind: "handoff"
        )
        let idle = AgentActivity(working: false, last: now, prompt: nil)
        #expect(StoryLine.headline(unread: unread, prompts: 2, commits: 1, files: 3, base: "main", agent: idle) ==
            "The tax is rounded once")
        #expect(StoryLine.headline(unread: nil, prompts: 2, commits: 2, files: 4, base: "main", agent: idle) ==
            "2 prompts, 2 commits and 4 files changed since main; the agent is done")
        #expect(StoryLine.headline(unread: nil, prompts: 0, commits: 1, files: 0, base: nil, agent: nil) == "1 commit")
        #expect(StoryLine.headline(unread: nil, prompts: 0, commits: 0, files: 0, base: "main", agent: nil) ==
            "Nothing yet on this branch")
        let read = CheckoutState.Prepared(
            path: "/r/y.walk.md", title: "Hello takes a greeting", summary: "", at: now, seen: true, kind: "handoff"
        )
        #expect(StoryLine.headline(
            unread: nil,
            latest: read,
            prompts: 0,
            commits: 0,
            files: 0,
            base: "main",
            agent: nil
        ) == "Hello takes a greeting")
        #expect(StoryLine.headline(
            unread: nil,
            latest: read,
            prompts: 1,
            commits: 0,
            files: 0,
            base: "main",
            agent: nil
        ) == "1 prompt since main", "counts first when there are some")
    }

    @Test("the line: events by time from the first to now, a day at most")
    func place() {
        let hour: TimeInterval = 3600
        let placed = StoryLine.place([
            (now.addingTimeInterval(-hour), .commit("abc")),
            (now.addingTimeInterval(-2 * hour), .prompt("Round once")),
            (now.addingTimeInterval(-3 * 86400), .looked),
        ], now: now, width: 240)
        #expect(placed.map(\.event) == [.prompt("Round once"), .commit("abc")], "three days ago is off the line")
        #expect(placed.first?.x == 0 + 240 * (22 * hour / 86400))
        #expect(placed.last?.x == 240 * (23 * hour / 86400))
        let recent = StoryLine.place(
            [(now.addingTimeInterval(-600), .prompt("a")), (now, .commit("b"))],
            now: now,
            width: 100
        )
        #expect(recent.map(\.x) == [0, 100])
        #expect(StoryLine.place([], now: now, width: 10).isEmpty)
    }
}
