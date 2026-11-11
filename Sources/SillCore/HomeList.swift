import Foundation

/// How Home lays its checkouts out, so that what needs you reads in a second: by repository (its worktrees together,
/// the repository last active first), each checkout with the one reason it is worth a look, and what has been quiet
/// for a week folded away.
public enum HomeList {
    /// Why a checkout is on Home, in the order a person would want to know it.
    public enum Reason: Equatable, Sendable {
        /// Walkthroughs an agent prepared that you have not read: the newest's title.
        case new(String, count: Int)
        /// An agent works there now: what it was asked.
        case working(String?)
        /// An agent finished there: what it was asked last.
        case idle(String?)
        /// Files changed, no agent known.
        case changed(Int)
        case nothing

        /// The line under the checkout's name.
        public var line: String {
            switch self {
            case let .new(title, count): count > 1 ? "New: \(title), and \(count - 1) more" : "New: \(title)"
            case let .working(prompt): prompt.map { "Working · “\($0)”" } ?? "Working"
            case let .idle(prompt): prompt.map { "Done · asked “\($0)”" } ?? "Done"
            case let .changed(count): "\(count) file\(count == 1 ? "" : "s") changed"
            case .nothing: ""
            }
        }
    }

    public static func reason(_ state: CheckoutState) -> Reason {
        if let newest = state.unseen.max(by: { $0.at < $1.at }) { return .new(newest.title, count: state.unseen.count) }
        if let agent = state.agent { return agent.working ? .working(agent.prompt) : .idle(agent.prompt) }
        return state.touched > 0 ? .changed(state.touched) : .nothing
    }

    /// A repository's checkouts, as indices into the rows, the most recently active first.
    public struct Group: Equatable, Sendable {
        public var repository: String
        public var rows: [Int]
    }

    /// Nothing new, no agent working, and last active a week ago or more: folded under "Quiet".
    public static func quiet(_ state: CheckoutState, now: Date = Date()) -> Bool {
        state.unseen.isEmpty && state.agent?.working != true && now.timeIntervalSince(state.active) >= 7 * 86400
    }

    /// The groups (repositories with something not quiet, the one last active first) and the quiet rows (the most
    /// recently active first).
    public static func groups(_ rows: [(checkout: Checkout, state: CheckoutState)], now: Date = Date())
        -> (groups: [Group], quiet: [Int])
    {
        var byRepository: [String: [Int]] = [:]
        var order: [String] = []
        var quiet: [Int] = []
        let byActivity = rows.indices.sorted { rows[$0].state.active > rows[$1].state.active }
        for index in byActivity {
            if Self.quiet(rows[index].state, now: now) {
                quiet.append(index)
                continue
            }
            let repository = rows[index].checkout.repository
            if byRepository[repository] == nil { order.append(repository) }
            byRepository[repository, default: []].append(index)
        }
        return (order.map { Group(repository: $0, rows: byRepository[$0] ?? []) }, quiet)
    }

    /// When, as Home says it: "now", "12 min", "3 h" today, then the day ("Nov 3"), and the year when it is not this
    /// one.
    public static func when(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard date != .distantPast else { return "" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) h" }
        let format = Date.FormatStyle(date: .abbreviated, time: .omitted).locale(Locale(identifier: "en_US"))
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return sameYear ? date.formatted(.dateTime.month(.abbreviated).day().locale(Locale(identifier: "en_US"))) :
            date.formatted(format)
    }
}
