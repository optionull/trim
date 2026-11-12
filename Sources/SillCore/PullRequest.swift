import Foundation

/// A pull request of the worktree's branch, as `gh pr list --head <branch> --json …` gives it, and what it means for
/// whoever works on it next: the checks failing, a review asking for changes, a conflict with its base, commits not
/// pushed. sill reads it (it never writes to the forge); the person sees it, and so does the agent.
public struct PullRequest: Equatable, Sendable {
    public struct Check: Equatable, Sendable {
        public enum State: String, Sendable { case passed, failed, pending, skipped }
        public var name: String
        public var state: State
        public var link: String?
    }

    public struct Remark: Equatable, Sendable {
        /// A review's state (`APPROVED`, `CHANGES_REQUESTED`, `COMMENTED`), or nil for a comment.
        public var review: String?
        public var author: String
        public var body: String
        public var at: Date?
    }

    public var number: Int
    public var title: String
    public var url: String
    /// `OPEN`, `MERGED` or `CLOSED`.
    public var state: String
    public var draft: Bool
    public var base: String
    /// `MERGEABLE`, `CONFLICTING` or `UNKNOWN`.
    public var mergeable: String
    /// `APPROVED`, `CHANGES_REQUESTED`, `REVIEW_REQUIRED`, or empty.
    public var decision: String
    public var checks: [Check]
    /// Reviews and comments, oldest first.
    public var remarks: [Remark]
    public var updated: Date?
    /// The branch it is from (`headRefName`), when gh was asked for it: how Home finds a checkout's.
    public var head = ""

    /// The pull requests in `gh pr list`'s JSON, newest first; nothing for anything else.
    public static func parse(_ json: Data) -> [PullRequest] {
        guard let list = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]] else { return [] }
        let dates = ISO8601DateFormatter()
        func login(_ value: Any?) -> String { ((value as? [String: Any])?["login"] as? String) ?? "someone" }
        return list.compactMap { pr -> PullRequest? in
            guard let number = pr["number"] as? Int else { return nil }
            let checks = (pr["statusCheckRollup"] as? [[String: Any]] ?? []).map { check -> Check in
                // A workflow's check run, or a commit status.
                if let name = check["name"] as? String {
                    let state: Check.State = switch (check["status"] as? String, check["conclusion"] as? String) {
                    case (_, "SUCCESS"?), (_, "NEUTRAL"?): .passed
                    case (_, "SKIPPED"?): .skipped
                    case ("COMPLETED"?, _): .failed
                    default: .pending
                    }
                    return Check(name: name, state: state, link: check["detailsUrl"] as? String)
                }
                let state: Check.State = switch check["state"] as? String {
                case "SUCCESS": .passed
                case "PENDING", "EXPECTED": .pending
                default: .failed
                }
                return Check(
                    name: check["context"] as? String ?? "status",
                    state: state,
                    link: check["targetUrl"] as? String
                )
            }
            let reviews = (pr["latestReviews"] as? [[String: Any]] ?? []).map {
                Remark(
                    review: $0["state"] as? String, author: login($0["author"]),
                    body: Self.visible($0["body"] as? String),
                    at: ($0["submittedAt"] as? String).flatMap(dates.date(from:))
                )
            }
            let comments = (pr["comments"] as? [[String: Any]] ?? []).map {
                Remark(
                    review: nil, author: login($0["author"]), body: Self.visible($0["body"] as? String),
                    at: ($0["createdAt"] as? String).flatMap(dates.date(from:))
                )
            }
            var parsed = PullRequest(
                number: number, title: pr["title"] as? String ?? "", url: pr["url"] as? String ?? "",
                state: pr["state"] as? String ?? "OPEN", draft: pr["isDraft"] as? Bool ?? false,
                base: pr["baseRefName"] as? String ?? "", mergeable: pr["mergeable"] as? String ?? "UNKNOWN",
                decision: pr["reviewDecision"] as? String ?? "", checks: checks,
                remarks: (reviews + comments).sorted { ($0.at ?? .distantPast) < ($1.at ?? .distantPast) },
                updated: (pr["updatedAt"] as? String).flatMap(dates.date(from:))
            )
            parsed.head = pr["headRefName"] as? String ?? ""
            return parsed
        }.sorted { ($0.updated ?? .distantPast) > ($1.updated ?? .distantPast) }
    }

    /// The worktree beside it: commits not pushed, commits on the base it lacks (as of the last fetch), changes not
    /// committed.
    public struct Branch: Equatable, Sendable {
        public var name: String
        public var unpushed: Int
        public var behind: Int
        public var uncommitted: Int

        public init(name: String, unpushed: Int = 0, behind: Int = 0, uncommitted: Int = 0) {
            self.name = name
            self.unpushed = unpushed
            self.behind = behind
            self.uncommitted = uncommitted
        }
    }

    /// Something worth knowing, most pressing first: `attention` asks for work, the rest informs.
    public struct Insight: Equatable, Sendable {
        public enum Level: Int, Sendable, Comparable {
            case attention, waiting, fine
            public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
        }

        public var level: Level
        public var text: String
    }

    public func insights(_ branch: Branch?) -> [Insight] {
        var insights: [Insight] = []
        if state == "MERGED" { return [Insight(level: .fine, text: "Merged into \(base)")] }
        if state == "CLOSED" { return [Insight(level: .fine, text: "Closed without merging")] }
        let failed = checks.filter { $0.state == .failed }, pending = checks.filter { $0.state == .pending }
        if !failed.isEmpty {
            insights.append(Insight(
                level: .attention,
                text: "\(Self.count(failed.count, "check")) failing: " + failed.map(\.name).joined(separator: ", ")
            ))
        }
        if decision == "CHANGES_REQUESTED" {
            let by = remarks.filter { $0.review == "CHANGES_REQUESTED" }.map(\.author)
            insights.append(Insight(
                level: .attention,
                text: "Changes requested" + (by.isEmpty ? "" : " by " + Array(Set(by)).sorted().joined(separator: ", "))
            ))
        }
        if mergeable == "CONFLICTING" {
            insights.append(Insight(level: .attention, text: "Conflicts with \(base): it cannot merge as it is"))
        }
        if let branch, branch.unpushed > 0 {
            insights.append(Insight(
                level: .attention,
                text: "\(Self.count(branch.unpushed, "commit")) here not pushed: the pull request does not have " +
                    (branch.unpushed == 1 ? "it" : "them")
            ))
        }
        if !pending.isEmpty {
            insights.append(Insight(level: .waiting, text: "\(Self.count(pending.count, "check")) running"))
        }
        if decision == "REVIEW_REQUIRED" { insights.append(Insight(level: .waiting, text: "Waiting for a review")) }
        if draft { insights.append(Insight(level: .waiting, text: "A draft")) }
        if let branch, branch.behind > 0 {
            insights.append(Insight(
                level: .waiting, text: "\(Self.count(branch.behind, "commit")) behind \(base) (as of the last fetch)"
            ))
        }
        if let branch, branch.uncommitted > 0 {
            insights.append(Insight(
                level: .waiting,
                text: "\(Self.count(branch.uncommitted, "file")) changed, not committed"
            ))
        }
        if decision == "APPROVED" { insights.append(Insight(level: .fine, text: "Approved")) }
        if failed.isEmpty, pending.isEmpty, !checks.isEmpty {
            insights.append(Insight(level: .fine, text: "\(Self.count(checks.count, "check")) passed"))
        }
        return insights.sorted { $0.level < $1.level }
    }

    /// For the status bar: the number and the most pressing thing.
    public func label(_ branch: Branch?) -> String {
        "#\(number)" + (insights(branch).first.map { " · " + Self.short($0.text) } ?? "")
    }

    /// The pull request as an agent reads it: what needs doing, the failing checks with their links, the reviews and
    /// comments (the latest ten).
    public func text(_ branch: Branch?) -> String {
        var lines = ["Pull request #\(number) (\(state.lowercased())\(draft ? ", draft" : "")): \(title)", url]
        let insights = insights(branch)
        if !insights.isEmpty { lines += insights.map { "- " + $0.text } }
        for check in checks where check.state == .failed {
            lines.append("Failing: \(check.name)" + (check.link.map { " \($0)" } ?? ""))
        }
        let recent = remarks.filter { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.suffix(10)
        if !recent.isEmpty {
            lines.append("Reviews and comments, oldest first:")
            for remark in recent {
                let what = remark.review.map { $0.lowercased().replacingOccurrences(of: "_", with: " ") } ?? "comment"
                lines.append("- \(remark.author) (\(what)): " + String(remark.body.prefix(600)))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// A body as it shows on GitHub: without its HTML comments (bots leave their bookkeeping in them).
    static func visible(_ body: String?) -> String {
        (body ?? "").replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    /// The insight cut for the status bar: before its colon.
    static func short(_ text: String) -> String {
        String(text.split(separator: ":", maxSplits: 1).first ?? Substring(text))
    }
}
