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
    var onFile: ((String) -> Void)?

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

    override func draw(_: NSRect) {
        Design.editor.setFill()
        bounds.fill()
        links = []
        let story = stories.story
        let touched = story?.touched.count ?? 0
        let detail = [
            story?.base.map { "\(touched) file\(touched == 1 ? "" : "s") touched since \($0)" },
            stories.reading ? "reading…" : nil,
        ].compactMap { $0 }.joined(separator: " · ")
        let unseen = stories.unseen
        actionFrames = PaneBar.draw(
            title: "Summary", detail: detail,
            actions: [
                .init(id: "review", title: "Review"),
                .init(
                    id: "walk",
                    title: unseen == nil ? "Walkthroughs" : "Read the new walkthrough",
                    primary: unseen != nil
                ),
            ],
            in: bounds
        ).map { ($0.id, $0.rect) }
        let left: CGFloat = 28, width = min(bounds.width - 56, 980)
        var y = PaneBar.height + 22 - scroll
        func heading(_ title: String) {
            y += 6
            text(title.uppercased(), 10, Design.textFaint, weight: .semibold).draw(at: NSPoint(x: left, y: y))
            y += 22
        }
        func row(_ line: NSAttributedString, height: CGFloat = 24, open: (() -> Void)? = nil) {
            let rect = NSRect(x: left - 8, y: y - 3, width: width + 16, height: height)
            line.drawLine(in: NSRect(x: left, y: y, width: width, height: height - 4))
            if let open { links.append((rect, open)) }
            y += height
        }

        // What the agent does, or did.
        heading("Now")
        if let agent = stories.agent {
            let state = NSMutableAttributedString(attributedString: text(
                agent.working ? "An agent is working" : "The agent is idle since " + HomeView.ago(agent.last),
                14, agent.working ? Design.accent : Design.text, weight: .semibold
            ))
            if let prompt = agent.prompt { state.append(text("   " + prompt, 13, Design.textMuted)) }
            row(state, height: 28)
        } else {
            row(text("No agent session here that sill knows of.", 13, Design.textMuted))
        }

        if !stories.walkthroughs.isEmpty {
            heading("Walkthroughs from agents")
            for prepared in stories.walkthroughs.prefix(8) {
                // Not seen yet: a dot in the accent, as Home marks it.
                let line = NSMutableAttributedString(attributedString: text(
                    prepared.seen ? "    " : "●  ",
                    12,
                    Design.accent
                ))
                line.append(text(
                    prepared.title, 14, prepared.seen ? Design.textMuted : Design.text,
                    weight: prepared.seen ? .regular : .semibold
                ))
                line.append(text("   \(prepared.kind) · \(HomeView.ago(prepared.at))", 12, Design.textFaint))
                if !prepared.seen, !prepared.summary.isEmpty { line.append(text(
                    "   " + prepared.summary,
                    12,
                    Design.textMuted
                )) }
                row(line, height: 28) { [weak self] in self?.onWalkthrough?(prepared.path) }
            }
        }

        if let prompts = story?.prompts, !prompts.isEmpty {
            heading("Asked")
            for prompt in prompts {
                let line = NSMutableAttributedString(attributedString: text(prompt.text, 13))
                if let at = prompt.at { line.append(text("   " + HomeView.ago(at), 12, Design.textFaint)) }
                row(line)
            }
        }

        if let commits = story?.commits, !commits.isEmpty {
            heading("Commits since \(story?.base ?? "the base")")
            for commit in commits.prefix(10) {
                let line = NSMutableAttributedString(attributedString: text(
                    commit.hash.prefix(7) + "  ",
                    12,
                    Design.textFaint,
                    mono: true
                ))
                line.append(text(commit.subject, 13))
                line.append(text("   " + HomeView.ago(commit.at), 12, Design.textFaint))
                row(line)
            }
            if commits.count > 10 { row(text("and \(commits.count - 10) more", 12, Design.textFaint)) }
        }

        if let files = story?.touched, !files.isEmpty {
            heading("Touched · \(files.count) file\(files.count == 1 ? "" : "s")")
            for file in files.prefix(12) {
                let line = NSMutableAttributedString(attributedString: text(
                    (file.path as NSString).lastPathComponent,
                    13
                ))
                let folder = (file.path as NSString).deletingLastPathComponent
                if !folder.isEmpty { line.append(text("  " + folder, 12, Design.textFaint)) }
                line.append(text("   +\(file.added)", 12, Design.accent, mono: true))
                line.append(text(" −\(file.removed)", 12, Design.error, mono: true))
                row(line) { [weak self] in self?.onFile?(file.path) }
            }
            if files.count > 12 { row(text("v reviews all \(files.count)", 12, Design.textFaint)) }
        }
        PaneBar.drawKeys(
            "w the newest walkthrough · v review the branch · a click opens what it names · r read again",
            in: bounds
        )
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let (id, _) = actionFrames.first(where: { $0.1.contains(point) }) {
            if id == "review" { onReview?() } else { openWalkthrough() }
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

    func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { return false }
        switch event.charactersIgnoringModifiers ?? "" {
        case "w": openWalkthrough()
        case "v": onReview?()
        case "r": stories.refresh()
        default: return false
        }
        return true
    }
}
