import AppKit
import SillCore
import SillEditor

/// Home's window: on top what agents prepared that is not seen yet (the summary of summaries), under it every checkout
/// most recently active first: what an agent does there, its branch, its changes, its new walkthroughs.
@MainActor
final class HomeView: NSView {
    let model: HomeModel
    private var selected = 0
    private var scroll: CGFloat = 0
    private var rowFrames: [(Int, NSRect)] = []
    private var newFrames: [(Int, NSRect)] = []
    private var actionFrames: [(String, NSRect)] = []
    var onRoots: (() -> Void)?

    init(model: HomeModel) {
        self.model = model
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func changed() {
        selected = min(selected, max(model.rows.count - 1, 0))
        needsDisplay = true
    }

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

    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) h" }
        if seconds < 86400 * 365 { return "\(Int(seconds / 86400)) d" }
        return "long ago"
    }

    /// A checkout as Home names it: its repository, and its worktree's folder when it is one.
    static func name(_ checkout: Checkout) -> String {
        checkout.isWorktree ? "\(checkout.repositoryName) / \(checkout.name)" : checkout.repositoryName
    }

    override func draw(_: NSRect) {
        Design.editor.setFill()
        bounds.fill()
        let roots = model.roots.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ")
        let working = model.working
        actionFrames = PaneBar.draw(
            title: "sill",
            detail: "\(model.rows.count) checkouts in \(roots)" +
                (working > 0 ? " · \(working) agent\(working == 1 ? "" : "s") working" : "") +
                (model.reading ? " · reading…" : ""),
            actions: [.init(id: "roots", title: "Folders…"), .init(id: "refresh", title: "Read again")],
            in: bounds
        ).map { ($0.id, $0.rect) }
        let left: CGFloat = 24, width = bounds.width - 48
        var y = PaneBar.height + 18 - scroll
        newFrames = []
        rowFrames = []

        // What agents prepared that is not seen yet, newest first.
        let unseen = model.unseen
        if !unseen.isEmpty {
            text("NEW FROM AGENTS · \(unseen.count)", 10, Design.textFaint, weight: .semibold)
                .draw(at: NSPoint(x: left, y: y))
            y += 22
            for (index, item) in unseen.prefix(6).enumerated() {
                let rect = NSRect(x: left - 10, y: y - 6, width: width + 20, height: 54)
                Design.chrome.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
                Design.accent.setFill()
                NSBezierPath(ovalIn: NSRect(x: left, y: y + 6, width: 8, height: 8)).fill()
                let heading = NSMutableAttributedString(attributedString: text(
                    item.prepared.title,
                    14,
                    weight: .semibold
                ))
                heading.append(text(
                    "   " + Self.name(item.checkout) + " · " + item.prepared.kind,
                    12,
                    Design.textMuted
                ))
                heading.drawLine(in: NSRect(x: left + 18, y: y, width: width - 90, height: 20))
                text(item.prepared.summary, 12, Design.textMuted)
                    .drawLine(in: NSRect(x: left + 18, y: y + 21, width: width - 30, height: 18))
                let when = text(Self.ago(item.prepared.at), 12, Design.textFaint)
                when.draw(at: NSPoint(x: left + width - when.size().width, y: y + 1))
                newFrames.append((index, rect))
                y += 62
            }
            if unseen.count > 6 {
                text("and \(unseen.count - 6) more, in their checkouts below", 12, Design.textFaint)
                    .draw(at: NSPoint(x: left, y: y))
                y += 22
            }
            y += 14
        }

        text("CHECKOUTS", 10, Design.textFaint, weight: .semibold).draw(at: NSPoint(x: left, y: y))
        y += 20
        if model.rows.isEmpty {
            text(model.reading ? "Looking for checkouts…" : "No git checkouts in these folders.", 14, Design.textMuted)
                .draw(at: NSPoint(x: left, y: y + 8))
        }
        for (index, row) in model.rows.enumerated() {
            let rect = NSRect(x: 0, y: y, width: bounds.width, height: 52)
            defer { y += 52 }
            guard rect.maxY > PaneBar.height, rect.minY < bounds.height - PaneBar.footer else { continue }
            rowFrames.append((index, rect))
            if index == selected {
                Design.selection.setFill()
                rect.fill()
            }
            let state = row.state
            // Working: a filled dot; an agent that has been here: a ring.
            if let agent = state.agent {
                let dot = NSBezierPath(ovalIn: NSRect(x: left, y: y + 12, width: 9, height: 9))
                if agent.working {
                    Design.accent.setFill()
                    dot.fill()
                } else {
                    Design.textFaint.setStroke()
                    dot.lineWidth = 1.2
                    dot.stroke()
                }
            }
            let name = NSMutableAttributedString(attributedString: text(Self.name(row.checkout), 14, weight: .semibold))
            name.append(text("  " + state.branch, 12, Design.textMuted, mono: true))
            if state.touched > 0 { name.append(text("   \(state.touched) changed", 12, Design.modified)) }
            if !state.unseen.isEmpty {
                name.append(text(
                    "   \(state.unseen.count) new walkthrough\(state.unseen.count == 1 ? "" : "s")",
                    12,
                    Design.accent,
                    weight: .semibold
                ))
            }
            name.drawLine(in: NSRect(x: left + 20, y: y + 7, width: width - 100, height: 20))
            let detail = state.agent
                .map { [$0.working ? "working" : nil, $0.prompt].compactMap { $0 }.joined(separator: ": ") } ??
                (state.walkthroughs.first.map { "last walkthrough: " + $0.title } ?? "")
            text(detail, 12, state.agent?.working == true ? Design.text : Design.textFaint)
                .drawLine(in: NSRect(x: left + 20, y: y + 28, width: width - 100, height: 18))
            let when = text(state.active == .distantPast ? "" : Self.ago(state.active), 12, Design.textFaint)
            when.draw(at: NSPoint(x: left + width - when.size().width, y: y + 9))
        }
        PaneBar.drawKeys(
            "j/k checkouts · ↵ open · n the newest walkthrough · r read again · f folders",
            back: false,
            in: bounds
        )
    }

    // MARK: Input

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let (id, _) = actionFrames.first(where: { $0.1.contains(point) }) {
            if id == "roots" { onRoots?() } else { model.refresh() }
        } else if let (index, _) = newFrames.first(where: { $0.1.contains(point) }) {
            openNew(index)
        } else if let (index, _) = rowFrames.first(where: { $0.1.contains(point) }) {
            selected = index
            needsDisplay = true
            if event.clickCount == 2 { model.open(model.rows[index].checkout) }
        }
    }

    override func scrollWheel(with event: NSEvent) {
        scroll = max(scroll - event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 10), 0)
        needsDisplay = true
    }

    private func openNew(_ index: Int) {
        let unseen = model.unseen
        guard unseen.indices.contains(index) else { return }
        model.open(unseen[index].checkout, walkthrough: unseen[index].prepared.path)
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers ?? "" {
        case "j", String(UnicodeScalar(NSDownArrowFunctionKey)!): selected = min(
                selected + 1,
                max(model.rows.count - 1, 0)
            )
        case "k", String(UnicodeScalar(NSUpArrowFunctionKey)!): selected = max(selected - 1, 0)
        case "\r": if model.rows.indices.contains(selected) { model.open(model.rows[selected].checkout) }
        case "n": openNew(0)
        case "r": model.refresh()
        case "f": onRoots?()
        default: return super.keyDown(with: event)
        }
        keepSelectionInView()
        needsDisplay = true
    }

    /// The selected row scrolled into view.
    private func keepSelectionInView() {
        guard let frame = rowFrames.first(where: { $0.0 == selected })?.1 else {
            // Not drawn: off the top or the bottom; move by a row's height until it is.
            scroll = max(scroll + (selected > (rowFrames.last?.0 ?? 0) ? 52 : -52), 0)
            return
        }
        if frame.maxY > bounds.height - PaneBar.footer { scroll += frame.maxY - (bounds.height - PaneBar.footer) }
        if frame.minY < PaneBar.height { scroll = max(scroll - (PaneBar.height - frame.minY), 0) }
    }
}
