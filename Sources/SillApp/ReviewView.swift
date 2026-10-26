import AppKit
import SillCore
import SillEditor

/// The review pane: the baselines to compare against, the files that changed since, and the selected file's hunks,
/// each to keep, take back or comment on; the comments go to the agent as one review.
final class ReviewView: NSView, ToolContent {
    let reviewer: Reviewer
    private var baselineFrames: [(Int, NSRect)] = []
    private var fileFrames: [(Int, NSRect)] = []
    /// The first file the list shows, and the selection it last followed.
    private var firstFile = 0
    private var followed = -1
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
    private static let bar = PaneBar.height + 40
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
        PaneBar.drawKeys(
            "j/k files · J/K changes · a keep · x take back · c comment · s send · w walkthrough · ↵ side by side",
            in: bounds
        )
    }

    private func drawBar() {
        let count = reviewer.files.count
        let summary = reviewer.reading ? "reading the worktree…" : count == 0 ? "nothing changed since" :
            "\(count) file\(count == 1 ? "" : "s") changed since"
        actionFrames = PaneBar.draw(
            title: "Review",
            detail: summary,
            actions: [
                .init(
                    id: "send", title: "Send review (\(reviewer.comments.count))", primary: true,
                    enabled: !reviewer.comments.isEmpty
                ),
                .init(id: "walkthrough", title: "Walkthrough", enabled: !reviewer.files.isEmpty),
            ],
            in: bounds
        ).map { ($0.id, 0, $0.rect) }
        Design.chrome.setFill()
        NSRect(x: 0, y: PaneBar.height, width: bounds.width, height: Self.bar - PaneBar.height).fill()
        Design.border.setFill()
        NSRect(x: 0, y: Self.bar - 1, width: bounds.width, height: 1).fill()
        // The baselines as chips, newest last.
        baselineFrames = []
        var x: CGFloat = 20
        for (index, baseline) in reviewer.baselines.enumerated() {
            let label = "\(baseline.name) · \(baseline.at.formatted(date: .omitted, time: .shortened))"
            let selected = index == reviewer.selectedBaseline
            let chip = text(label, 12, selected ? Design.text : Design.textMuted)
            let rect = NSRect(x: x, y: PaneBar.height + 6, width: chip.size().width + 24, height: 28)
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
        // Only the rows that fit, the selected one among them: a large pull request has hundreds of files.
        let reserved = reviewer.comments.isEmpty ? 0 : CGFloat(36 + 36 * min(reviewer.comments.count, 4))
        // Above the keys along the bottom, with room for the count of what is above and below.
        let fit = max(Int((column.height - 16 - reserved - PaneBar.footer - 24) / 30), 1)
        let count = reviewer.files.count
        // The list follows the selection when it moves; the wheel scrolls it freely.
        if reviewer.selectedFile != followed {
            followed = reviewer.selectedFile
            if followed < firstFile { firstFile = followed }
            if followed >= firstFile + fit { firstFile = followed - fit + 1 }
        }
        firstFile = max(min(firstFile, count - fit), 0)
        for (index, file) in reviewer.files.enumerated().dropFirst(firstFile).prefix(fit) {
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
            // The file's name first, its folder after it: in a long list the name is what is looked for.
            let name = NSMutableAttributedString(attributedString: text((file.path as NSString).lastPathComponent, 13))
            let folder = (file.path as NSString).deletingLastPathComponent
            if !folder.isEmpty { name.append(text("  " + folder, 12, Design.textFaint)) }
            name.drawLine(in: NSRect(x: 36, y: y + 6, width: list - 130, height: 18))
            let counts = NSMutableAttributedString(attributedString: text("+\(file.added) ", 12, Design.accent))
            counts.append(text("−\(file.removed)", 12, Design.error))
            counts.draw(at: NSPoint(x: list - counts.size().width - 14, y: y + 7))
            fileFrames.append((index, rect))
            y += 30
        }
        if count > fit {
            let above = firstFile, below = count - firstFile - fit
            text(
                "\(count) files" + (above > 0 ? " · \(above) above" : "") + (below > 0 ? " · \(below) below" : ""),
                11, Design.textFaint
            ).draw(at: NSPoint(x: 16, y: y + 4))
            y += 20
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
        if convert(event.locationInWindow, from: nil).x < list {
            // Over the files: a row at a time.
            wheel += event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 30)
            let rows = Int(wheel / 30)
            if rows != 0 {
                firstFile = max(firstFile - rows, 0)
                wheel -= CGFloat(rows) * 30
            }
        } else {
            scroll = max(0, scroll - event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 10))
        }
        needsDisplay = true
    }

    private var wheel: CGFloat = 0

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
