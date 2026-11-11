import AppKit
import SillCore
import SillEditor

/// The checkout's summary, what a workspace opens on when no walkthrough is new: what the agent does or did, the
/// walkthroughs agents prepared (the new ones first), what was asked, the commits since the branch left its base, and
/// the files touched. Each opens what it names; `w` reads the newest walkthrough, `v` reviews the branch.
@MainActor
final class SummaryView: NSView, ToolContent {
    private let stories: Stories
    private var scroll: CGFloat = 0
    private var links: [(NSRect, () -> Void)] = []
    private var actionFrames: [(String, NSRect)] = []
    var onWalkthrough: ((String) -> Void)?
    var onReview: (() -> Void)?
    var onReviewSince: (() -> Void)?
    var onFile: ((String) -> Void)?
    /// Runs one of the handoff's runs.
    var onRun: ((HandoffFile.Run) -> Void)?
    /// When a run of that name last ran, if it did.
    var lastRun: ((String) -> Date?)?
    private var runFrames: [(NSRect, HandoffFile.Run)] = []

    init(stories: Stories) {
        self.stories = stories
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

    /// The summary answers "what happened here since I looked, and is it any good?" On top a headline (the new
    /// walkthrough's title, else what happened, counted) and the verdicts under it; at the left the walkthrough to
    /// read (↵) and the session as a line through time; at the right what to run and where it changed.
    override func draw(_: NSRect) {
        Design.editor.setFill()
        bounds.fill()
        links = []
        runFrames = []
        let story = stories.story
        let unseen = stories.unseen
        actionFrames = PaneBar.draw(
            title: "Summary",
            detail: stories.reading ? "reading…" : (story?.base.map { "since the branch left \($0)" } ?? ""),
            actions: [
                .init(id: "review", title: "Review  v"),
                .init(
                    id: "walk",
                    title: unseen == nil ? "Walkthroughs  w" : "Read the new walkthrough  ↵",
                    primary: unseen != nil
                ),
            ],
            in: bounds
        ).map { ($0.id, $0.rect) }
        let left: CGFloat = 32
        var y = PaneBar.height + 22 - scroll

        // The headline and its verdicts.
        let kicker = stories.since.map { "Since you last looked · \(HomeView.ago($0.point.at))" }
            ?? (story?.base.map { "On this branch, since \($0)" } ?? "Here")
        text(kicker.uppercased(), 10, Design.textFaint, weight: .semibold).draw(at: NSPoint(x: left, y: y))
        y += 20
        let headline = StoryLine.headline(
            unread: unseen,
            latest: stories.walkthroughs.max { $0.at < $1.at },
            prompts: stories.since?.prompts ?? story?.prompts.count ?? 0,
            commits: stories.since?.commits ?? story?.commits.count ?? 0,
            files: stories.since?.files.count ?? story?.touched.count ?? 0,
            base: stories.since == nil ? story?.base : nil,
            agent: stories.agent
        )
        text(headline, 21, weight: .semibold).drawLine(in: NSRect(
            x: left,
            y: y,
            width: bounds.width - 2 * left,
            height: 28
        ))
        y += 38
        var chips: [(String, NSColor)] = []
        if let agent = stories.agent {
            chips.append(agent.working ? ("● an agent is working", Design.insert) :
                ("○ done \(HomeView.ago(agent.last))", Design.textMuted))
        }
        let unread = stories.walkthroughs.count(where: { !$0.seen })
        if unread > 0 { chips.append(("● \(unread) new walkthrough\(unread == 1 ? "" : "s")", Design.accent)) }
        if let commits = story?.commits.count, commits > 0 {
            chips.append((
                "\(commits) commit\(commits == 1 ? "" : "s") since \(story?.base ?? "the base")",
                Design.text
            ))
        }
        if let files = story?.touched, !files.isEmpty {
            let added = files.reduce(0) { $0 + $1.added }, removed = files.reduce(0) { $0 + $1.removed }
            chips.append(("\(files.count) file\(files.count == 1 ? "" : "s") · +\(added) −\(removed)", Design.text))
        }
        var x = left
        for (label, colour) in chips {
            let line = text(label, 12, colour)
            let rect = NSRect(x: x, y: y, width: line.size().width + 20, height: 26)
            guard rect.maxX < bounds.width - left else { break }
            Design.chrome.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            line.draw(at: NSPoint(x: rect.minX + 10, y: rect.midY - line.size().height / 2))
            x = rect.maxX + 8
        }
        y += 44
        Design.border.setFill()
        NSRect(x: 0, y: y - 14, width: bounds.width, height: 1).fill()

        // Two columns when there is room, else one under the other.
        let wide = bounds.width >= 900
        let sideWidth: CGFloat = wide ? min(380, bounds.width * 0.32) : bounds.width - 2 * left
        let mainWidth = wide ? bounds.width - 2 * left - sideWidth - 32 : bounds.width - 2 * left
        let columnTop = y + 6
        y = drawMain(left: left, top: columnTop, width: mainWidth)
        let sideLeft = wide ? left + mainWidth + 32 : left
        drawSide(left: sideLeft, top: wide ? columnTop : y + 12, width: sideWidth)
        PaneBar.drawKeys("summary", note: "a click opens what it names", in: bounds)
    }

    /// The walkthrough to read, the other ones, and the session's line. Returns where it ends.
    private func drawMain(left: CGFloat, top: CGFloat, width: CGFloat) -> CGFloat {
        var y = top
        let hero = stories.unseen ?? stories.walkthroughs.first
        if let hero {
            let fresh = !hero.seen
            let summary = text(
                hero.summary.isEmpty ? "No summary." : hero.summary,
                13.5,
                fresh ? Design.text :
                    Design.textMuted
            )
            let bodyHeight = min(summary.boundingRect(
                with: NSSize(width: width - 40, height: 400),
                options: [.usesLineFragmentOrigin]
            ).height, 120)
            let card = NSRect(x: left, y: y, width: width, height: 78 + bodyHeight + 46)
            Design.chrome.setFill()
            NSBezierPath(roundedRect: card, xRadius: 10, yRadius: 10).fill()
            (fresh ? Design.accent : Design.border).setFill()
            NSRect(x: card.minX, y: card.minY, width: 3, height: card.height).fill()
            let label = "\(hero.kind) · \(HomeView.ago(hero.at))" + (fresh ? " · not read" : " · read")
            text(label.uppercased(), 10, fresh ? Design.accent : Design.textFaint, weight: .semibold)
                .draw(at: NSPoint(x: card.minX + 20, y: card.minY + 16))
            text(hero.title, 16, weight: .semibold).drawLine(in: NSRect(
                x: card.minX + 20, y: card.minY + 34, width: width - 40, height: 22
            ))
            summary.draw(
                with: NSRect(x: card.minX + 20, y: card.minY + 64, width: width - 40, height: bodyHeight),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
            )
            let read = text(
                fresh ? "Read it  ↵" : "Read it again  w",
                13,
                fresh ? Design.onAccent : Design.text,
                weight: fresh ? .semibold : .regular
            )
            let button = NSRect(x: card.minX + 20, y: card.maxY - 44, width: read.size().width + 28, height: 30)
            let shape = NSBezierPath(roundedRect: button.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
            if fresh {
                Design.accent.setFill()
                shape.fill()
            } else {
                Design.border.setStroke()
                shape.stroke()
            }
            read.draw(at: NSPoint(x: button.minX + 14, y: button.midY - read.size().height / 2))
            links.append((button, { [weak self] in self?.onWalkthrough?(hero.path) }))
            let review = text("Review the branch  v", 13)
            let second = NSRect(x: button.maxX + 10, y: button.minY, width: review.size().width + 28, height: 30)
            Design.border.setStroke()
            NSBezierPath(roundedRect: second.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8).stroke()
            review.draw(at: NSPoint(x: second.minX + 14, y: second.midY - review.size().height / 2))
            links.append((second, { [weak self] in self?.onReview?() }))
            y = card.maxY + 16
        } else {
            text("No walkthrough here yet: when an agent hands off, it shows here.", 13, Design.textMuted)
                .draw(at: NSPoint(x: left, y: y))
            y += 30
        }
        let others = stories.walkthroughs.filter { $0.path != hero?.path }.prefix(4)
        if !others.isEmpty {
            text("OTHER WALKTHROUGHS", 10, Design.textFaint, weight: .semibold).draw(at: NSPoint(x: left, y: y))
            y += 20
            for prepared in others {
                let line = NSMutableAttributedString(attributedString: text(
                    prepared.seen ? "" : "● ", 12, Design.accent
                ))
                line.append(text(prepared.title, 13, prepared.seen ? Design.textMuted : Design.text))
                line.append(text("   \(prepared.kind) · \(HomeView.ago(prepared.at))", 12, Design.textFaint))
                line.drawLine(in: NSRect(x: left, y: y, width: width, height: 18))
                links.append((
                    NSRect(x: left - 6, y: y - 3, width: width, height: 22),
                    { [weak self] in self?.onWalkthrough?(prepared.path) }
                ))
                y += 24
            }
            y += 10
        }
        return drawSession(left: left, top: y, width: width)
    }

    /// The session as a line through time: what was asked (blue), what was committed (mint), when you last looked.
    private func drawSession(left: CGFloat, top: CGFloat, width: CGFloat) -> CGFloat {
        var events: [(at: Date, event: StoryLine.Event)] = []
        for prompt in stories.story?.prompts ?? [] {
            if let at = prompt.at { events.append((at, .prompt(prompt.text))) }
        }
        for commit in stories.story?.commits ?? [] {
            events.append((commit.at, .commit(String(commit.hash.prefix(7)))))
        }
        if let since = stories.since { events.append((since.point.at, .looked)) }
        guard events.count > 1 else { return top }
        var y = top
        text("THE SESSION", 10, Design.textFaint, weight: .semibold).draw(at: NSPoint(x: left, y: y))
        y += 26
        let axis = y + 26
        Design.border.setFill()
        NSRect(x: left, y: axis, width: width, height: 1).fill()
        var lastLabel: [Bool: CGFloat] = [true: -1000, false: -1000]
        for (index, placed) in StoryLine.place(events, width: Double(width - 12)).enumerated() {
            let x = left + 6 + CGFloat(placed.x)
            switch placed.event {
            case .looked:
                Design.modified.setFill()
                NSRect(x: x, y: axis - 20, width: 1, height: 40).fill()
                text("you looked", 11, Design.modified).draw(at: NSPoint(x: x + 4, y: axis - 24))
            case let .prompt(prompt):
                Design.insert.setFill()
                NSBezierPath(ovalIn: NSRect(x: x - 5, y: axis - 5, width: 10, height: 10)).fill()
                // Labels under the line, alternating rows so neighbours do not overlap.
                let below = index % 2 == 0
                let label = text(
                    "“" + String(prompt.prefix(28)) + (prompt.count > 28 ? "…" : "") + "”",
                    11,
                    Design.textMuted
                )
                if x - (lastLabel[below] ?? 0) > label.size().width + 8 {
                    label.draw(at: NSPoint(
                        x: min(x - 6, left + width - label.size().width),
                        y: axis + (below ? 10 : 26)
                    ))
                    lastLabel[below] = x
                }
            case let .commit(hash):
                Design.accent.setFill()
                let diamond = NSBezierPath()
                diamond.move(to: NSPoint(x: x, y: axis - 6))
                diamond.line(to: NSPoint(x: x + 6, y: axis))
                diamond.line(to: NSPoint(x: x, y: axis + 6))
                diamond.line(to: NSPoint(x: x - 6, y: axis))
                diamond.close()
                diamond.fill()
                text(hash, 10.5, Design.accent, mono: true).draw(at: NSPoint(x: x - 18, y: axis - 22))
            }
        }
        y = axis + 48
        text("● asked · ◆ committed · newest at the right, the last day at most", 11, Design.textFaint)
            .draw(at: NSPoint(x: left, y: y))
        return y + 28
    }

    /// What to run (the agent's runs first, each with when it last ran), and where it changed, by folder.
    private func drawSide(left: CGFloat, top: CGFloat, width: CGFloat) {
        var y = top
        let runs = stories.handoffRuns
        if !runs.isEmpty {
            text("RUN IT", 10, Design.textFaint, weight: .semibold).draw(at: NSPoint(x: left, y: y))
            y += 20
            for run in runs.prefix(4) {
                let rect = NSRect(x: left, y: y, width: width, height: 48)
                Design.chrome.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
                text("▷", 14, Design.accent).draw(at: NSPoint(x: rect.minX + 12, y: rect.minY + 14))
                let name = NSMutableAttributedString(attributedString: text(run.name, 13, weight: .semibold))
                if let last = lastRun?(run.name) {
                    name.append(text("   ran \(HomeView.ago(last))", 11, Design.textFaint))
                }
                name.drawLine(in: NSRect(x: rect.minX + 34, y: rect.minY + 7, width: width - 44, height: 18))
                text(run.command, 11.5, Design.textMuted, mono: true)
                    .drawLine(in: NSRect(x: rect.minX + 34, y: rect.minY + 26, width: width - 44, height: 16))
                runFrames.append((rect, run))
                y = rect.maxY + 8
            }
            y += 14
        }
        guard let files = stories.story?.touched, !files.isEmpty else { return }
        text("WHERE IT CHANGED · \(files.count)", 10, Design.textFaint, weight: .semibold)
            .draw(at: NSPoint(x: left, y: y))
        y += 22
        let most = CGFloat(files.map { $0.added + $0.removed }.max() ?? 1)
        let byFolder = Dictionary(grouping: files) { ($0.path as NSString).deletingLastPathComponent }
        let folders = byFolder.keys.sorted { a, b in
            byFolder[a]!.reduce(0) { $0 + $1.added + $1.removed } > byFolder[b]!
                .reduce(0) { $0 + $1.added + $1.removed }
        }
        var shown = 0
        for folder in folders where shown < 14 {
            text(folder.isEmpty ? "(the root)" : folder, 11.5, Design.textFaint)
                .drawLine(in: NSRect(x: left, y: y, width: width, height: 16))
            y += 20
            for file in byFolder[folder]!.sorted(by: { $0.added + $0.removed > $1.added + $1.removed })
                where shown < 14
            {
                let name = (file.path as NSString).lastPathComponent
                text(name, 13).drawLine(in: NSRect(x: left + 10, y: y, width: width - 110, height: 18))
                // Its churn: added then removed, to the scale of the most changed file.
                let barWidth: CGFloat = 80
                let addedWidth = max(CGFloat(file.added) / most * barWidth, file.added > 0 ? 2 : 0)
                let removedWidth = max(CGFloat(file.removed) / most * barWidth, file.removed > 0 ? 2 : 0)
                Design.accent.setFill()
                NSRect(x: left + width - barWidth, y: y + 6, width: addedWidth, height: 6).fill()
                Design.error.setFill()
                NSRect(x: left + width - barWidth + addedWidth + 1, y: y + 6, width: removedWidth, height: 6).fill()
                links.append((
                    NSRect(x: left, y: y - 3, width: width, height: 22),
                    { [weak self] in self?.onFile?(file.path) }
                ))
                y += 24
                shown += 1
            }
        }
        if files.count > shown { text("v reviews all \(files.count)", 12, Design.textFaint).draw(at: NSPoint(
            x: left,
            y: y
        )) }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let (id, _) = actionFrames.first(where: { $0.1.contains(point) }) {
            if id == "review" { onReview?() } else { openWalkthrough() }
        } else if let (_, run) = runFrames.first(where: { $0.0.contains(point) }) {
            onRun?(run)
        } else if let (_, open) = links.first(where: { $0.0.contains(point) }) {
            open()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        scroll = max(scroll - event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 10), 0)
        needsDisplay = true
    }

    /// The newest walkthrough not seen, else the newest.
    private func openWalkthrough() {
        if let prepared = stories.unseen ?? stories.walkthroughs.first { onWalkthrough?(prepared.path) }
    }

    var keyKind: String { "summary" }

    var hintTargets: [NSRect] { actionFrames.map(\.1) + links.map(\.0) + runFrames.map(\.0) }

    func perform(_ command: String, key _: String) -> Bool {
        switch command {
        // What the summary is for: the walkthrough not read, else what changed since you looked, else the branch.
        case "summary.read":
            if stories.unseen != nil {
                openWalkthrough()
            } else if let since = stories.since, !since.files.isEmpty {
                onReviewSince?()
            } else {
                onReview?()
            }
        case "summary.walkthrough": openWalkthrough()
        case "summary.review": onReview?()
        case "summary.reviewSince": onReviewSince?()
        case "summary.examples": if let run = stories.handoffRuns.first { onRun?(run) }
        case "summary.refresh": stories.refresh()
        default: return false
        }
        return true
    }
}
