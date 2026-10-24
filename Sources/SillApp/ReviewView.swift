import AppKit
import SillCore
import SillEditor

/// The review pane: the baselines to compare against, the files that changed since, and the selected file's hunks,
/// each to keep, take back or comment on; the comments go to the agent as one review.
final class ReviewView: NSView, ToolContent {
    let reviewer: Reviewer
    private var baselineFrames: [(Int, NSRect)] = []
    private var fileFrames: [(Int, NSRect)] = []
    private var actionFrames: [(String, Int, NSRect)] = []
    /// The hunk the keys act on.
    private(set) var selectedHunk = 0
    private var scroll: CGFloat = 0

    init(reviewer: Reviewer) {
        self.reviewer = reviewer
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    private static let bar: CGFloat = 96
    private var list: CGFloat { min(320, bounds.width * 0.3) }

    private func text(
        _ string: String,
        _ size: CGFloat = 13,
        _ color: NSColor = Design.text,
        weight: NSFont.Weight = .regular,
        mono: Bool = false
    ) -> NSAttributedString {
        let font = mono ? EditorFont.metrics.regular : Design.ui(size, weight: weight)
        return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
    }

    func changed() {
        selectedHunk = min(selectedHunk, max((reviewer.diff?.hunks.count ?? 1) - 1, 0))
        needsDisplay = true
    }

    override func draw(_: NSRect) {
        Design.editor.setFill()
        bounds.fill()
        drawBar()
        drawFiles()
        drawHunks()
    }

    private func drawBar() {
        Design.chrome.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: Self.bar).fill()
        Design.border.setFill()
        NSRect(x: 0, y: Self.bar - 1, width: bounds.width, height: 1).fill()
        let title = text("Review", 16, weight: .semibold)
        title.draw(at: NSPoint(x: 20, y: 14))
        let count = reviewer.files.count
        let summary = reviewer.reading ? "reading the worktree…" : count == 0 ? "nothing changed since" :
            "\(count) file\(count == 1 ? "" : "s") changed since"
        text(summary, 13, Design.textMuted).draw(at: NSPoint(x: 36 + title.size().width, y: 17))
        // The action on the right: send the comments.
        actionFrames = []
        let send = text(
            "Send review (\(reviewer.comments.count))",
            13,
            reviewer.comments.isEmpty ? Design.textFaint : Design.onAccent,
            weight: .semibold
        )
        let sendRect = NSRect(
            x: bounds.width - send.size().width - 44,
            y: 10,
            width: send.size().width + 28,
            height: 30
        )
        (reviewer.comments.isEmpty ? Design.border : Design.accent).setFill()
        NSBezierPath(roundedRect: sendRect, xRadius: 15, yRadius: 15).fill()
        send.draw(at: NSPoint(x: sendRect.minX + 14, y: sendRect.midY - send.size().height / 2))
        actionFrames.append(("send", 0, sendRect))
        // A walkthrough of these changes, from the agent.
        let walk = text("Walkthrough", 13, reviewer.files.isEmpty ? Design.textFaint : Design.text)
        let walkRect = NSRect(
            x: sendRect.minX - walk.size().width - 40,
            y: 10,
            width: walk.size().width + 28,
            height: 30
        )
        Design.border.setStroke()
        NSBezierPath(roundedRect: walkRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 15, yRadius: 15).stroke()
        walk.draw(at: NSPoint(x: walkRect.minX + 14, y: walkRect.midY - walk.size().height / 2))
        actionFrames.append(("walkthrough", 0, walkRect))
        // The baselines as chips, newest last.
        baselineFrames = []
        var x: CGFloat = 20
        for (index, baseline) in reviewer.baselines.enumerated() {
            let label = "\(baseline.name) · \(baseline.at.formatted(date: .omitted, time: .shortened))"
            let selected = index == reviewer.selectedBaseline
            let chip = text(label, 12, selected ? Design.text : Design.textMuted)
            let rect = NSRect(x: x, y: 54, width: chip.size().width + 24, height: 28)
            guard rect.maxX < bounds.width - 16 else { break }
            (selected ? Design.selection : Design.editor).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14).fill()
            (selected ? Design.accent : Design.border).setStroke()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14).stroke()
            chip.draw(at: NSPoint(x: rect.minX + 12, y: rect.midY - chip.size().height / 2))
            baselineFrames.append((index, rect))
            x = rect.maxX + 8
        }
    }

    private func drawFiles() {
        fileFrames = []
        let column = NSRect(x: 0, y: Self.bar, width: list, height: bounds.height - Self.bar)
        Design.chrome.setFill()
        column.fill()
        var y = column.minY + 8
        for (index, file) in reviewer.files.enumerated() {
            let rect = NSRect(x: 0, y: y, width: list, height: 30)
            if index == reviewer.selectedFile {
                Design.selection.setFill()
                rect.fill()
            }
            let status: (String, NSColor) = switch file.status {
            case .added: ("A", Design.accent)
            case .deleted: ("D", Design.error)
            case .modified: ("M", Design.modified)
            }
            text(status.0, 12, status.1, weight: .semibold).draw(at: NSPoint(x: 16, y: y + 7))
            text(file.path, 13).draw(
                with: NSRect(x: 36, y: y + 6, width: list - 130, height: 18),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
            )
            let counts = NSMutableAttributedString(attributedString: text("+\(file.added) ", 12, Design.accent))
            counts.append(text("−\(file.removed)", 12, Design.error))
            counts.draw(at: NSPoint(x: list - counts.size().width - 14, y: y + 7))
            fileFrames.append((index, rect))
            y += 30
        }
        if !reviewer.comments.isEmpty {
            y += 16
            text("COMMENTS", 11, Design.textMuted, weight: .semibold).draw(at: NSPoint(x: 16, y: y))
            y += 20
            for comment in reviewer.comments {
                let line = text("\(comment.path):\(comment.line)  \(comment.text)", 12, Design.text)
                line.draw(
                    with: NSRect(x: 16, y: y, width: list - 32, height: 34),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
                )
                y += 36
            }
        }
    }

    private func drawHunks() {
        let left = list + 20, width = bounds.width - list - 40
        var y = Self.bar + 12 - scroll
        guard let file = reviewer.file, let diff = reviewer.diff else {
            text(
                reviewer.baselines.isEmpty ? "No baseline yet: :SillReview mark takes one." :
                    "Nothing changed since \(reviewer.baseline?.name ?? "the baseline").",
                13,
                Design.textFaint
            )
            .draw(at: NSPoint(x: left, y: y + 8))
            return
        }
        let heading = text(file.path, 14, weight: .semibold)
        heading.draw(at: NSPoint(x: left, y: y))
        let hint = text(
            "j/k files · J/K changes · x take back · c comment · w walkthrough · Return side by side",
            11,
            Design.textFaint
        )
        hint.draw(at: NSPoint(x: left + width - hint.size().width, y: y + 2))
        y += 30
        let lineHeight = EditorFont.metrics.height
        for (index, hunk) in diff.hunks.enumerated() {
            let isKept = reviewer.kept.contains(reviewer.key(hunk))
            let height = 34 + CGFloat(hunk.lines.count) * lineHeight + 8
            let box = NSRect(x: left, y: y, width: width, height: height)
            if box.maxY > Self.bar, box.minY < bounds.height {
                Design.chrome.setFill()
                NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
                (index == selectedHunk ? Design.accent : Design.border).setStroke()
                NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8).stroke()
                text(
                    "line \(hunk.firstChange)" + (isKept ? " · kept" : ""),
                    12,
                    isKept ? Design.accent : Design.textMuted
                )
                .draw(at: NSPoint(x: box.minX + 14, y: box.minY + 9))
                var x = box.maxX - 12
                for (title, action) in [("Comment", "comment"), ("Take back", "reject"), ("Keep", "keep")] {
                    let label = text(title, 12, action == "reject" ? Design.error : Design.text)
                    let rect = NSRect(
                        x: x - label.size().width - 20,
                        y: box.minY + 5,
                        width: label.size().width + 20,
                        height: 24
                    )
                    Design.border.setStroke()
                    NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6).stroke()
                    label.draw(at: NSPoint(x: rect.minX + 10, y: rect.midY - label.size().height / 2))
                    actionFrames.append((action, index, rect))
                    x = rect.minX - 8
                }
                var lineY = box.minY + 34
                for line in hunk.lines {
                    let (background, color): (NSColor?, NSColor) = switch line.first {
                    case "+": (Design.accent.withAlphaComponent(0.12), Design.text)
                    case "-": (Design.error.withAlphaComponent(0.12), Design.textMuted)
                    default: (nil, isKept ? Design.textFaint : Design.textMuted)
                    }
                    if let background {
                        background.setFill()
                        NSRect(x: box.minX + 1, y: lineY, width: box.width - 2, height: lineHeight).fill()
                    }
                    text(line, 12, color, mono: true).draw(
                        with: NSRect(
                            x: box.minX + 14,
                            y: lineY + EditorFont.metrics.textOffset,
                            width: box.width - 28,
                            height: lineHeight
                        ),
                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
                    )
                    lineY += lineHeight
                }
            }
            y = box.maxY + 12
        }
    }

    // MARK: Input

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let (index, _) = baselineFrames.first(where: { $0.1.contains(point) }) {
            return reviewer.select(baseline: index)
        }
        if let (index, _) = fileFrames.first(where: { $0.1.contains(point) }) {
            selectedHunk = 0
            scroll = 0
            if event.clickCount >= 2 { reviewer.openSideBySide() }
            return reviewer.select(file: index)
        }
        if let (action, index, _) = actionFrames.first(where: { $0.2.contains(point) }) {
            perform(action, index)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        scroll = max(0, scroll - event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 10))
        needsDisplay = true
    }

    func perform(_ action: String, _ index: Int) {
        if action == "send" { return reviewer.sendReview() }
        if action == "walkthrough" { return reviewer.askForWalkthrough() }
        guard let hunk = reviewer.diff?.hunks[safe: index] else { return }
        selectedHunk = index
        switch action {
        case "keep": reviewer.keep(hunk)
        case "reject": reviewer.reject(hunk)
        case "comment": reviewer.askComment(hunk)
        default: break
        }
        needsDisplay = true
    }

    /// j/k files, J/K changes, x takes the change back, c comments, a keeps, s sends the review, r reads again,
    /// Return opens the file side by side, 1 to 9 pick a baseline.
    func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { return false }
        let key = event.characters ?? ""
        if let number = Int(key), number >= 1, number <= 9 {
            reviewer.select(baseline: number - 1)
            return true
        }
        let hunks = reviewer.diff?.hunks.count ?? 0
        switch key {
        case "j": selectedHunk = 0; reviewer.select(file: reviewer.selectedFile + 1)
        case "k": selectedHunk = 0; reviewer.select(file: reviewer.selectedFile - 1)
        case "J": selectedHunk = min(selectedHunk + 1, max(hunks - 1, 0))
        case "K": selectedHunk = max(selectedHunk - 1, 0)
        case "x": perform("reject", selectedHunk)
        case "c": perform("comment", selectedHunk)
        case "a": perform("keep", selectedHunk)
        case "s": reviewer.sendReview()
        case "w": reviewer.askForWalkthrough()
        case "r": reviewer.refresh()
        case "\r": reviewer.openSideBySide()
        default: return false
        }
        needsDisplay = true
        return true
    }
}
