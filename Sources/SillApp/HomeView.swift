import AppKit
import SillCore
import SillEditor

/// Home's window, for one question: does anything need me, and where? On top the answer in a line (how many
/// checkouts have something new, how many agents work); under it the checkouts by repository, each with the one
/// reason it is worth a look in its colour (new from an agent, working, done, changed), what has been quiet for a week
/// folded away (`z`); at the right, the selected checkout before you go in: its new walkthroughs in their agents'
/// words, what it holds, and what ↵ does.
@MainActor
final class HomeView: NSView, ToolContent {
    let model: HomeModel
    /// The selected checkout, by path: it stays selected as the list reorders.
    private var selectedPath: String?
    private var showQuiet = false
    private var scroll: CGFloat = 0
    private var rowFrames: [(Int, NSRect)] = []
    private var newFrames: [(String, NSRect)] = []
    private var actionFrames: [(String, NSRect)] = []
    private var detailFrames: [(String, NSRect)] = []
    var onRoots: (() -> Void)?

    static let rowHeight: CGFloat = 52
    static let headline: CGFloat = 76

    init(model: HomeModel) {
        self.model = model
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

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

    static func ago(_ date: Date, now: Date = Date()) -> String { HomeList.when(date, now: now) }

    /// A checkout as Home names it: its repository, and its worktree's folder when it is one.
    static func name(_ checkout: Checkout) -> String {
        checkout.isWorktree ? "\(checkout.repositoryName) / \(checkout.name)" : checkout.repositoryName
    }

    /// What is listed, in the order drawn: each repository's checkouts, then the quiet ones when shown. An entry is
    /// a row's index, or nil for a heading (its title).
    private var layout: [(row: Int?, heading: String?)] {
        let (groups, quiet) = HomeList.groups(model.rows)
        var lines: [(row: Int?, heading: String?)] = []
        for group in groups {
            let count = group.rows.count
            let name = (group.repository as NSString).lastPathComponent
            lines.append((nil, count > 1 ? "\(name) · \(count) checkouts" : name))
            lines += group.rows.map { ($0, nil) }
        }
        if !quiet.isEmpty {
            lines.append((nil, "Quiet for a week · \(quiet.count)" + (showQuiet ? "" : "  —  z shows them")))
            if showQuiet { lines += quiet.map { ($0, nil) } }
        }
        return lines
    }

    /// The rows that can be selected, in order.
    private var order: [Int] { layout.compactMap(\.row) }

    private var selected: Int? {
        let order = order
        if let selectedPath, let row = order.first(where: { model.rows[$0].checkout.path == selectedPath }) {
            return row
        }
        return order.first
    }

    private func select(_ row: Int?) {
        selectedPath = row.map { model.rows[$0].checkout.path }
    }

    override func draw(_: NSRect) {
        Design.editor.setFill()
        bounds.fill()
        let roots = model.roots.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ")
        actionFrames = PaneBar.draw(
            title: "sill",
            detail: "\(model.rows.count) checkouts in \(roots)" + (model.reading ? " · reading…" : ""),
            actions: [.init(id: "roots", title: "Folders…"), .init(id: "refresh", title: "Read again")],
            in: bounds
        ).map { ($0.id, $0.rect) }
        drawHeadline()
        let split = bounds.width >= 880
        let listWidth = split ? min(max(bounds.width * 0.44, 400), 640) : bounds.width
        drawList(width: listWidth)
        if split { drawDetail(in: NSRect(
            x: listWidth,
            y: PaneBar.height,
            width: bounds.width - listWidth,
            height: bounds.height - PaneBar.height - PaneBar.footer
        )) }
        PaneBar.drawKeys("home", back: false, in: bounds)
    }

    /// The answer in a line: how many checkouts have something new from an agent, how many agents work.
    private func drawHeadline() {
        let top = PaneBar.height
        let waiting = model.rows.count(where: { !$0.state.unseen.isEmpty })
        let working = model.working
        let line = NSMutableAttributedString()
        if waiting > 0 {
            line.append(text("\(waiting) to look at", 20, Design.accent, weight: .semibold))
        } else {
            line.append(text("Nothing new", 20, Design.text, weight: .semibold))
        }
        if working > 0 {
            line.append(text(
                " · \(working) agent\(working == 1 ? "" : "s") working",
                20,
                Design.text,
                weight: .semibold
            ))
        }
        line.drawLine(in: NSRect(x: 24, y: top + 14, width: bounds.width - 48, height: 28))
        let newest = model.unseen.first
        let sub = newest
            .map { "Newest: \($0.prepared.title), in \(Self.name($0.checkout)), \(Self.ago($0.prepared.at))" }
            ?? (working > 0 ? "Agents are at work; what they hand off shows here." :
                "When an agent hands off a walkthrough, it shows here.")
        text(sub, 12, Design.textMuted).drawLine(in: NSRect(x: 24, y: top + 46, width: bounds.width - 48, height: 18))
        Design.border.setFill()
        NSRect(x: 0, y: top + Self.headline - 1, width: bounds.width, height: 1).fill()
    }

    private func drawList(width: CGFloat) {
        let top = PaneBar.height + Self.headline
        let bottom = bounds.height - PaneBar.footer
        let left: CGFloat = 24
        var y = top + 10 - scroll
        rowFrames = []
        let selected = selected
        if model.rows.isEmpty {
            text(model.reading ? "Looking for checkouts…" : "No git checkouts in these folders.", 14, Design.textMuted)
                .draw(at: NSPoint(x: left, y: y + 8))
        }
        NSGraphicsContext.saveGraphicsState()
        NSRect(x: 0, y: top, width: width, height: bottom - top).clip()
        for line in layout {
            if let heading = line.heading {
                y += 8
                text(heading.uppercased(), 10, Design.textFaint, weight: .semibold)
                    .drawLine(in: NSRect(x: left, y: y, width: width - 2 * left, height: 14))
                y += 22
                continue
            }
            guard let index = line.row else { continue }
            let rect = NSRect(x: 0, y: y, width: width, height: Self.rowHeight)
            defer { y += Self.rowHeight }
            guard rect.maxY > top, rect.minY < bottom else { continue }
            rowFrames.append((index, rect))
            let (checkout, state) = model.rows[index]
            if index == selected {
                Design.selection.setFill()
                rect.fill()
                Design.accent.setFill()
                NSRect(x: 0, y: rect.minY, width: 3, height: rect.height).fill()
            }
            let reason = HomeList.reason(state)
            let working = state.agent?.working == true
            // An agent at work shows, whatever else the row says.
            drawDot(working ? .working(nil) : reason, at: NSPoint(x: left, y: y + 12))
            let name = NSMutableAttributedString(attributedString: text(
                checkout.isWorktree ? checkout.name : checkout.repositoryName,
                14,
                weight: .semibold
            ))
            name.append(text("  " + state.branch, 12, Design.textMuted, mono: true))
            name.drawLine(in: NSRect(x: left + 22, y: y + 7, width: width - left - 110, height: 20))
            let line = NSMutableAttributedString(attributedString: text(reason.line, 12, Self.colour(reason)))
            if working, case .new = reason { line.append(text(" · an agent works here", 12, Design.insert)) }
            line.drawLine(in: NSRect(x: left + 22, y: y + 28, width: width - left - 60, height: 18))
            let when = text(Self.ago(state.active), 12, Design.textFaint)
            when.draw(at: NSPoint(x: width - 20 - when.size().width, y: y + 9))
        }
        NSGraphicsContext.restoreGraphicsState()
        if bounds.width >= 880 {
            Design.border.setFill()
            NSRect(x: width - 1, y: top, width: 1, height: bottom - top).fill()
        }
    }

    /// One mark per reason: new is the accent, filled; working is blue with a halo; done is a ring.
    private func drawDot(_ reason: HomeList.Reason, at origin: NSPoint) {
        let dot = NSRect(x: origin.x, y: origin.y, width: 10, height: 10)
        switch reason {
        case .new:
            Design.accent.setFill()
            NSBezierPath(ovalIn: dot).fill()
        case .working:
            Design.insert.withAlphaComponent(0.25).setFill()
            NSBezierPath(ovalIn: dot.insetBy(dx: -4, dy: -4)).fill()
            Design.insert.setFill()
            NSBezierPath(ovalIn: dot).fill()
        case .idle:
            let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 1.5
            Design.textFaint.setStroke()
            ring.stroke()
        case .changed, .nothing:
            break
        }
    }

    static func colour(_ reason: HomeList.Reason) -> NSColor {
        switch reason {
        case .new: Design.accent
        case .working: Design.text
        case .changed: Design.modified
        case .idle, .nothing: Design.textFaint
        }
    }

    /// The selected checkout before you go in: what is new in its agents' words, what it holds, what ↵ does.
    private func drawDetail(in area: NSRect) {
        newFrames = []
        detailFrames = []
        guard let index = selected else { return }
        let (checkout, state) = model.rows[index]
        let left = area.minX + 28, width = area.width - 56
        var y = area.minY + Self.headline + 18
        let title = NSMutableAttributedString(attributedString: text(Self.name(checkout), 17, weight: .semibold))
        title.append(text("   " + state.branch, 13, Design.textMuted, mono: true))
        title.drawLine(in: NSRect(x: left, y: y, width: width, height: 24))
        y += 28
        let agentLine = state.agent.map { agent in
            agent.working ? "An agent is working" + (agent.prompt.map { " on “\($0)”" } ?? "") :
                "The agent finished \(Self.ago(agent.last))" + (agent.prompt.map { " after “\($0)”" } ?? "")
        } ?? "No agent session here"
        text(agentLine, 12.5, Design.textMuted).drawLine(in: NSRect(x: left, y: y, width: width, height: 18))
        y += 34

        // The walkthroughs not read, newest first, each in its agent's words; else the last one, read.
        let unseen = state.unseen.sorted { $0.at > $1.at }
        let shown = unseen
            .isEmpty ? Array(state.walkthroughs.sorted { $0.at > $1.at }.prefix(1)) : Array(unseen.prefix(3))
        for prepared in shown {
            let fresh = !prepared.seen
            let summary = text(prepared.summary, 13, fresh ? Design.text : Design.textMuted)
            let bodyHeight = min(summary.boundingRect(
                with: NSSize(width: width - 36, height: 200),
                options: [.usesLineFragmentOrigin]
            ).height, 54)
            let card = NSRect(x: left, y: y, width: width, height: 58 + bodyHeight)
            guard card.maxY < area.maxY - 120 else { break }
            Design.chrome.setFill()
            NSBezierPath(roundedRect: card, xRadius: 8, yRadius: 8).fill()
            (fresh ? Design.accent : Design.border).setFill()
            NSRect(x: card.minX, y: card.minY, width: 3, height: card.height).fill()
            let label = (fresh ? "New · " : "Read · ") + prepared.kind + " · " + Self.ago(prepared.at)
            text(label.uppercased(), 10, fresh ? Design.accent : Design.textFaint, weight: .semibold)
                .draw(at: NSPoint(x: card.minX + 18, y: card.minY + 12))
            text(prepared.title, 15, weight: .semibold)
                .drawLine(in: NSRect(x: card.minX + 18, y: card.minY + 28, width: width - 36, height: 20))
            summary.draw(
                with: NSRect(x: card.minX + 18, y: card.minY + 50, width: width - 36, height: bodyHeight),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
            )
            newFrames.append((prepared.path, card))
            y = card.maxY + 12
        }
        if unseen.count > shown.count {
            text("and \(unseen.count - shown.count) more", 12, Design.textFaint).draw(at: NSPoint(x: left, y: y))
            y += 22
        }
        y += 6

        // What it holds.
        var chips: [String] = []
        if state.touched > 0 { chips.append("\(state.touched) file\(state.touched == 1 ? "" : "s") changed") }
        if let commit = state.lastCommit { chips.append("last commit \(Self.ago(commit))") }
        if !state.walkthroughs.isEmpty {
            chips.append("\(state.walkthroughs.count) walkthrough\(state.walkthroughs.count == 1 ? "" : "s")")
        }
        var x = left
        for chip in chips {
            let label = text(chip, 12, Design.textMuted)
            let rect = NSRect(x: x, y: y, width: label.size().width + 20, height: 26)
            guard rect.maxX < area.maxX - 20 else { break }
            Design.chrome.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            label.draw(at: NSPoint(x: rect.minX + 10, y: rect.midY - label.size().height / 2))
            x = rect.maxX + 8
        }

        // What ↵ does, and the rest.
        let buttons: [(id: String, title: String, primary: Bool)] = unseen.isEmpty
            ? [("read", "Open the checkout  ↵", true)]
            : [
                ("read", "Read the walkthrough  ↵", true),
                ("open", "Open the checkout  o", false),
                ("seen", "Mark read  m", false),
            ]
        x = left
        let buttonY = area.maxY - 52
        for button in buttons {
            let label = text(
                button.title,
                13,
                button.primary ? Design.onAccent : Design.text,
                weight: button.primary ? .semibold : .regular
            )
            let rect = NSRect(x: x, y: buttonY, width: label.size().width + 28, height: 32)
            let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
            if button.primary {
                Design.accent.setFill()
                shape.fill()
            } else {
                Design.border.setStroke()
                shape.stroke()
            }
            label.draw(at: NSPoint(x: rect.minX + 14, y: rect.midY - label.size().height / 2))
            detailFrames.append((button.id, rect))
            x = rect.maxX + 10
        }
    }

    // MARK: Input

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let (id, _) = actionFrames.first(where: { $0.1.contains(point) }) {
            if id == "roots" { onRoots?() } else { model.refresh() }
        } else if let (id, _) = detailFrames.first(where: { $0.1.contains(point) }) {
            _ = perform(id == "read" ? "home.read" : id == "seen" ? "home.seen" : "home.open", key: "")
        } else if let (path, _) = newFrames.first(where: { $0.1.contains(point) }), let index = selected {
            model.open(model.rows[index].checkout, walkthrough: path)
        } else if let (index, _) = rowFrames.first(where: { $0.1.contains(point) }) {
            select(index)
            needsDisplay = true
            if event.clickCount == 2 { _ = perform("home.read", key: "") }
        }
    }

    override func scrollWheel(with event: NSEvent) {
        scroll = max(scroll - event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 10), 0)
        needsDisplay = true
    }

    private let keyboard = Keyboard()

    override func keyDown(with event: NSEvent) {
        if !keyboard.handle(event, in: self) { super.keyDown(with: event) }
    }

    var keyKind: String { "home" }

    /// A row's label on its name; the walkthroughs and the buttons as they are.
    var hintTargets: [NSRect] {
        actionFrames.map(\.1) + rowFrames.map { NSRect(
            x: $0.1.minX + 46, y: $0.1.minY, width: $0.1.width - 46, height: min($0.1.height, 32)
        ) } + newFrames.map(\.1) + detailFrames.map(\.1)
    }

    func perform(_ command: String, key _: String) -> Bool {
        let order = order
        let position = selected.flatMap { order.firstIndex(of: $0) }
        switch command {
        case "home.down": select(order[safe: (position ?? -1) + 1] ?? order.last)
        case "home.up": select(order[safe: (position ?? 1) - 1] ?? order.first)
        case "home.read":
            // On its newest walkthrough not read, when it has one: that is why it is here.
            guard let index = selected else { return true }
            let row = model.rows[index]
            model.open(row.checkout, walkthrough: row.state.unseen.max { $0.at < $1.at }?.path)
        case "home.open": if let index = selected { model.open(model.rows[index].checkout) }
        case "home.new": if let newest = model.unseen.first { model.open(
                newest.checkout,
                walkthrough: newest.prepared.path
            ) }
        case "home.seen": if let index = selected { model.markSeen(model.rows[index].checkout) }
        case "home.quiet": showQuiet.toggle()
        case "home.refresh": model.refresh()
        case "home.folders": onRoots?()
        default: return false
        }
        keepSelectionInView()
        needsDisplay = true
        return true
    }

    /// The selected row scrolled into view.
    private func keepSelectionInView() {
        guard let selected else { return }
        var y = Self.headline + PaneBar.height + 10
        for line in layout {
            if line.heading != nil { y += 30 } else if line.row == selected { break } else { y += Self.rowHeight }
        }
        let top = PaneBar.height + Self.headline, bottom = bounds.height - PaneBar.footer
        if y - scroll + Self.rowHeight > bottom { scroll = y + Self.rowHeight - bottom }
        if y - scroll < top + 10 { scroll = max(y - top - 40, 0) }
    }
}
