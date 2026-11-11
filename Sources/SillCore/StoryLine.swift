import Foundation

/// What a checkout's summary says first, so the story reads in a second: a headline, and the session as events on a
/// line through time.
public enum StoryLine {
    /// The headline: the newest walkthrough not read, in its agent's words, when there is one; else what happened,
    /// counted ("2 prompts, 2 commits and 4 files since main"), and where the agent is; with nothing to count, the
    /// latest walkthrough's title.
    public static func headline(
        unread: CheckoutState.Prepared?,
        latest: CheckoutState.Prepared? = nil,
        prompts: Int,
        commits: Int,
        files: Int,
        base: String?,
        agent: AgentActivity?
    ) -> String {
        if let unread { return unread.title }
        func count(_ number: Int, _ noun: String) -> String? {
            number > 0 ? "\(number) \(noun)\(number == 1 ? "" : "s")" : nil
        }
        let parts = [count(prompts, "prompt"), count(commits, "commit"), count(files, "file").map { $0 + " changed" }]
            .compactMap { $0 }
        // Nothing to count, but an agent wrote something: that, read or not, says more than "nothing".
        if parts.isEmpty, let latest { return latest.title }
        let what: String = switch parts.count {
        case 0: "Nothing yet"
        case 1: parts[0]
        default: parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        }
        let since = base.map { parts.isEmpty ? " on this branch" : " since \($0)" } ?? ""
        let state = agent.map { $0.working ? "; an agent is working" : "; the agent is done" } ?? ""
        return what + since + state
    }

    /// Something that happened, on the session's line.
    public enum Event: Equatable, Sendable {
        case prompt(String)
        case commit(String)
        case looked
    }

    /// Each event at its place on a line `width` wide, from the first event to `now` (a day at most, so a branch
    /// months old does not squash today's work into a dot); events before the line's start are left out.
    public static func place(
        _ events: [(at: Date, event: Event)],
        now: Date = Date(),
        width: Double
    ) -> [(x: Double, event: Event)] {
        guard let first = events.map(\.at).min() else { return [] }
        let start = max(first, now.addingTimeInterval(-86400))
        let span = max(now.timeIntervalSince(start), 60)
        return events.filter { $0.at >= start }.sorted { $0.at < $1.at }.map {
            (min(max($0.at.timeIntervalSince(start) / span, 0), 1) * width, $0.event)
        }
    }
}
