import Foundation
@testable import SillCore
import Testing

/// What Home reads of an agent's transcript beyond its state: when the person prompted, and what it waits on them for.
@Suite("an agent waiting, and the day's prompts")
struct AgentWaitingTests {
    func line(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
    }

    func user(_ text: String, at stamp: String) -> String {
        line(["type": "user", "timestamp": stamp, "message": ["role": "user", "content": text]])
    }

    func ask(_ name: String, _ input: [String: Any]) -> String {
        line(["type": "assistant", "timestamp": "2026-11-12T10:00:05.000Z", "message": [
            "role": "assistant", "stop_reason": "tool_use",
            "content": [["type": "text", "text": "One question."], ["type": "tool_use", "name": name, "input": input]],
        ]])
    }

    @Test("a question asked and not answered: waiting for it; answered: not")
    func asking() {
        let question = ask("AskUserQuestion", ["questions": [["question": "Keep the v1 route?", "options": []]]])
        #expect(AgentActivity.asking(in: [user("Do it", at: "2026-11-12T10:00:00.000Z"), question]) ==
            "Keep the v1 route?")
        let answered = line(["type": "user", "message": ["role": "user", "content": [
            ["type": "tool_result", "content": "Yes"],
        ]]])
        #expect(AgentActivity.asking(in: [question, answered]) == nil)
        #expect(AgentActivity.asking(in: [ask("ExitPlanMode", ["plan": "# Plan"])]) == "Approve the plan")
        #expect(AgentActivity.asking(in: [ask("Bash", ["command": "swift build"])]) == nil, "a tool running is not")
    }

    @Test("the day's prompts: the person's, not tools' results, after the day began")
    func prompts() throws {
        let since = try #require(ISO8601DateFormatter().date(from: "2026-11-12T00:00:00Z"))
        let lines = [
            user("Yesterday's", at: "2026-11-11T23:00:00.000Z"),
            user("Round once", at: "2026-11-12T09:00:00.000Z"),
            line(["type": "user", "timestamp": "2026-11-12T09:01:00.000Z", "message": ["role": "user", "content": [
                ["type": "tool_result", "content": "ok"],
            ]]]),
            user("Add a test", at: "2026-11-12T10:30:00.500Z"),
        ]
        #expect(AgentActivity.promptTimes(in: lines, since: since).count == 2)
    }

    @Test("waiting is Home's loudest reason, and the day's line counts each hour")
    func home() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var state = CheckoutState(branch: "main", agent: AgentActivity(
            working: true, last: now, prompt: "x", prompts: [now.addingTimeInterval(-60), now.addingTimeInterval(-90)],
            waiting: "Keep the v1 route?"
        ))
        state.walkthroughs = [CheckoutState.Prepared(
            path: "/a",
            title: "New",
            summary: "",
            at: now,
            seen: false,
            kind: "handoff"
        )]
        state.commits = [now.addingTimeInterval(-3 * 3600 - 1), now.addingTimeInterval(-2 * 86400)]
        #expect(HomeList.reason(state) == .waiting("Keep the v1 route?"))
        let line = HomeList.activity(state, now: now)
        #expect(line.count == 24 && line[23].prompts == 2 && line[20].commits == 1)
        #expect(line.reduce(0) { $0 + $1.prompts + $1.commits } == 3, "two days ago is off the line")
    }
}
