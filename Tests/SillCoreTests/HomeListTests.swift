import Foundation
@testable import SillCore
import Testing

@Suite("Home's list")
struct HomeListTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func walkthrough(_ title: String, ago: TimeInterval, seen: Bool = false) -> CheckoutState.Prepared {
        CheckoutState.Prepared(
            path: "/r/.sill/handoffs/\(title).walk.md", title: title, summary: "", at: now.addingTimeInterval(-ago),
            seen: seen, kind: "handoff"
        )
    }

    func row(_ path: String, repository: String, ago: TimeInterval, _ state: CheckoutState)
        -> (checkout: Checkout, state: CheckoutState)
    {
        var state = state
        state.lastEdit = now.addingTimeInterval(-ago)
        return (Checkout(path: path, repository: repository, isWorktree: path != repository), state)
    }

    @Test("a checkout's reason: what is new first, then an agent working, then done, then changed files")
    func reasons() {
        var state = CheckoutState(branch: "main", touched: 3, agent: AgentActivity(
            working: true,
            last: now,
            prompt: "fix it"
        ))
        #expect(HomeList.reason(state) == .working("fix it"))
        #expect(HomeList.reason(state).line == "Working · “fix it”")
        state.walkthroughs = [walkthrough("Older", ago: 600), walkthrough("Newer", ago: 60), walkthrough(
            "Read",
            ago: 1,
            seen: true
        )]
        #expect(HomeList.reason(state) == .new("Newer", count: 2))
        #expect(HomeList.reason(state).line == "New: Newer, and 1 more")
        state.walkthroughs = []
        state.agent?.working = false
        #expect(HomeList.reason(state).line == "Done · asked “fix it”")
        state.agent = nil
        #expect(HomeList.reason(state).line == "3 files changed")
        state.touched = 0
        #expect(HomeList.reason(state) == .nothing)
    }

    @Test("grouped by repository, the one last active first, its checkouts by activity; a quiet week folded away")
    func groups() {
        let day: TimeInterval = 86400
        let rows = [
            row("/p/alpha", repository: "/p/alpha", ago: 3 * day, CheckoutState(branch: "main")),
            row("/p/beta", repository: "/p/beta", ago: 60, CheckoutState(branch: "main")),
            row("/w/alpha-feature", repository: "/p/alpha", ago: 30, CheckoutState(branch: "feature")),
            row("/p/old", repository: "/p/old", ago: 30 * day, CheckoutState(branch: "main")),
            // A month quiet, but a walkthrough not read: not quiet.
            row("/p/gamma", repository: "/p/gamma", ago: 30 * day, CheckoutState(
                branch: "main",
                walkthroughs: [walkthrough("Kept", ago: 30 * day)]
            )),
        ]
        let (groups, quiet) = HomeList.groups(rows, now: now)
        #expect(groups.map(\.repository) == ["/p/alpha", "/p/beta", "/p/gamma"])
        #expect(groups[0].rows == [2, 0], "alpha-feature, active 30 s ago, before alpha")
        #expect(quiet == [3])
    }

    @Test("when: minutes and hours today, then the day, and the year when it is another")
    func when() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        #expect(HomeList.when(now.addingTimeInterval(-20), now: now, calendar: calendar) == "now")
        #expect(HomeList.when(now.addingTimeInterval(-720), now: now, calendar: calendar) == "12 min")
        #expect(HomeList.when(now.addingTimeInterval(-3 * 3600), now: now, calendar: calendar) == "3 h")
        #expect(HomeList.when(now.addingTimeInterval(-9 * 86400), now: now, calendar: calendar).hasPrefix("Jan"))
        #expect(HomeList.when(now.addingTimeInterval(-400 * 86400), now: now, calendar: calendar).contains("2025"))
        #expect(HomeList.when(.distantPast, now: now) == "")
    }
}
