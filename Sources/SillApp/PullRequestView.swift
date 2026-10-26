import AppKit
import SillCore
import SillEditor

/// The branch's pull request: what needs attention first, then its checks, its reviews and comments, and the branch
/// beside it. Read only; the agent is the one to act (Send to agent).
@MainActor
final class PullRequestView: NSView, ToolContent {
    private let pulls: PullRequests
    private var scroll: CGFloat = 0
    private var actionFrames: [(String, NSRect)] = []
    private var checkFrames: [(String, NSRect)] = []

    init(pulls: PullRequests) {
        self.pulls = pulls
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func changed() { needsDisplay = true }

    private func text(
        _ string: String,
        _ size: CGFloat = 13,
        _ color: NSColor = Design.text,
        weight: NSFont.Weight = .regular,
        mono: Bool = false
    ) -> NSAttributedString {
        let font = mono ? EditorFont.font(size, weight) : Design.ui(size, weight: weight)
        return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
    }

    static func color(_ level: PullRequest.Insight.Level) -> NSColor {
        switch level {
        case .attention: Design.error
        case .waiting: Design.modified
        case .fine: Design.accent
        }
    }

    override func draw(_: NSRect) {
        Design.editor.setFill()
        bounds.fill()
        let pr = pulls.current
        let detail = pr.map { "\($0.title) · \($0.state.lowercased()) · into \($0.base)" } ??
            (pulls.reading ? "reading…" : pulls.branch?.name ?? "")
        let attention = pr?.insights(pulls.branch).contains { $0.level == .attention } ?? false
        actionFrames = PaneBar.draw(
            title: pr.map { "Pull request #\($0.number)" } ?? "Pull request",
            detail: detail + (pulls.reading && pr != nil ? " · reading…" : ""),
            actions: pr == nil ? [] : [
                .init(id: "agent", title: "Send to agent", primary: attention),
                .init(id: "review", title: "Review"),
                .init(id: "walkthrough", title: "Walkthrough"),
                .init(id: "open", title: "Open on GitHub"),
            ],
            in: bounds
        ).map { ($0.id, $0.rect) }
        checkFrames = []
        let left: CGFloat = 24, width = min(bounds.width - 48, 900)
        var y = PaneBar.height + 20 - scroll
        guard let pr else {
            let why = pulls.problem ?? (pulls.reading ? "Reading the branch's pull requests…" :
                "No pull request for \(pulls.branch?.name ?? "this branch") yet: when an agent opens one, it shows here.")
            text(why, 14, Design.textMuted).draw(at: NSPoint(x: left, y: y))
            PaneBar.drawKeys("r read again", in: bounds)
            return
        }
        func heading(_ title: String) {
            y += 8
            text(title.uppercased(), 10, Design.textFaint, weight: .semibold).draw(at: NSPoint(x: left, y: y))
            y += 22
        }
        func row(_ string: NSAttributedString, dot: NSColor? = nil, height: CGFloat = 22) {
            if let dot {
                dot.setFill()
                NSBezierPath(ovalIn: NSRect(x: left, y: y + 6, width: 8, height: 8)).fill()
            }
            string.draw(
                with: NSRect(x: left + (dot == nil ? 0 : 18), y: y, width: width - 18, height: height),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
            )
            y += height
        }
        let insights = pr.insights(pulls.branch)
        heading("Now")
        for insight in insights {
            row(text(insight.text, 14), dot: Self.color(insight.level), height: 24)
        }
        if insights.isEmpty { row(text("Nothing to see to.", 14, Design.textMuted)) }

        // Where it changes things: the files, or for a large one its folders, most changed first.
        if !pulls.changes.isEmpty {
            let added = pulls.changes.reduce(0) { $0 + $1.added }, removed = pulls.changes.reduce(0) { $0 + $1.removed }
            heading("Changes · \(pulls.changes.count) files · +\(added) −\(removed)")
            let lines = Review.outline(pulls.changes, limit: 12).split(separator: "\n").map(String.init)
            let shown = pulls.changes
                .count > 12 ? Array(lines.dropFirst().prefix { $0 != "The largest:" }.prefix(8)) : lines
            for line in shown {
                row(text(line.trimmingCharacters(in: .whitespaces), 13, Design.textMuted, mono: true))
            }
            if pulls.changes.count > 12 {
                row(text("v reviews them all, w asks the agent for a walkthrough", 12, Design.textFaint))
            }
        }

        if !pr.checks.isEmpty {
            heading("Checks")
            // Those that need looking at in full; the passed and skipped counted in a line.
            let open = pr.checks.filter { $0.state == .failed || $0.state == .pending }
                .sorted { $0.state == .failed && $1.state != .failed }
            for check in open {
                let color: NSColor = switch check.state {
                case .failed: Design.error
                case .pending: Design.modified
                case .passed: Design.accent
                case .skipped: Design.textFaint
                }
                let line = NSMutableAttributedString(attributedString: text(check.name, 13, mono: true))
                line.append(text("  " + check.state.rawValue, 12, color))
                if let link = check.link { checkFrames.append((link, NSRect(x: left, y: y, width: width, height: 22))) }
                row(line, dot: color)
            }
            let passed = pr.checks.count(where: { $0.state == .passed })
            let skipped = pr.checks.count(where: { $0.state == .skipped })
            if passed + skipped > 0 {
                row(
                    text(
                        [passed > 0 ? "\(passed) passed" : nil, skipped > 0 ? "\(skipped) skipped" : nil]
                            .compactMap { $0 }.joined(separator: " · "),
                        13,
                        Design.textMuted
                    ),
                    dot: passed > 0 ? Design.accent : Design.textFaint
                )
            }
        }

        let remarks = pr.remarks.filter { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.suffix(10)
        if !remarks.isEmpty {
            heading("Reviews and comments")
            for remark in remarks {
                let what = remark.review.map { $0.lowercased().replacingOccurrences(of: "_", with: " ") } ?? "comment"
                let color = remark.review == "CHANGES_REQUESTED" ? Design.error :
                    remark.review == "APPROVED" ? Design.accent : Design.textMuted
                let line = NSMutableAttributedString(attributedString: text(remark.author, 13, weight: .semibold))
                line.append(text("  " + what, 12, color))
                row(line)
                let body = text(remark.body.trimmingCharacters(in: .whitespacesAndNewlines), 13, Design.textMuted)
                let height = min(ceil(body.boundingRect(
                    with: NSSize(width: width, height: 10000), options: [.usesLineFragmentOrigin]
                ).height), 120)
                body.draw(
                    with: NSRect(x: left, y: y, width: width, height: height),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
                )
                y += height + 12
            }
        }

        if let branch = pulls.branch {
            heading("Here")
            row(text(
                "\(branch.name) · \(branch.unpushed) not pushed · \(branch.behind) behind \(pr.base) · " +
                    "\(branch.uncommitted) changed, not committed",
                13,
                Design.textMuted,
                mono: true
            ))
        }
        if let at = pulls.readAt {
            y += 8
            row(text(
                "Read \(at.formatted(date: .omitted, time: .shortened)) from GitHub with gh",
                11,
                Design.textFaint
            ))
        }
        PaneBar.drawKeys(
            "v review · w walkthrough · a send to agent · o open on GitHub · a click on a check opens it · r read again",
            in: bounds
        )
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let (id, _) = actionFrames.first(where: { $0.1.contains(point) }) {
            switch id {
            case "agent": pulls.sendToAgent()
            case "review": pulls.review()
            case "walkthrough": pulls.walkthrough()
            default: pulls.openInBrowser()
            }
        } else if let (link, _) = checkFrames.first(where: { $0.1.contains(point) }), let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        scroll = max(scroll - event.scrollingDeltaY, 0)
        needsDisplay = true
    }

    func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { return false }
        switch event.charactersIgnoringModifiers ?? "" {
        case "a": pulls.sendToAgent()
        case "o": pulls.openInBrowser()
        case "v": pulls.review()
        case "w": pulls.walkthrough()
        case "r": pulls.refresh()
        default: return false
        }
        return true
    }
}
