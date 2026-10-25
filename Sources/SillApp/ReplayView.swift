import AppKit
import SillCore
import SillEditor

/// A session's replay: its turns down the left (each prompt, and for the selected one what the agent's tools did), the
/// selected turn's changes on the right, file by file.
@MainActor
final class ReplayView: NSView, ToolContent {
    private let replays: Replays
    private var selectedFile = 0
    private var scroll: CGFloat = 0
    private var turnFrames: [(Int, NSRect)] = []
    private var fileFrames: [(Int, NSRect)] = []

    init(replays: Replays) {
        self.replays = replays
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    private var list: CGFloat { min(380, bounds.width * 0.36) }

    func changed() {
        selectedFile = min(selectedFile, max(replays.files.count - 1, 0))
        needsDisplay = true
    }

    private func text(
        _ string: String,
        _ size: CGFloat = 12,
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
        let log = replays.log
        let turns = log?.turns ?? []
        let detail = log.map { "\($0.title) · \($0.turns.count) turn\($0.turns.count == 1 ? "" : "s")" } ?? ""
        PaneBar.draw(title: "Replay", detail: detail, in: bounds)
        drawTurns(turns)
        drawChanges()
        PaneBar.drawKeys("j/k turns · J/K files · ↵ open the file · r read again", in: bounds)
    }

    /// The turns, numbered: the prompt, how many steps, and the selected one's steps under it.
    private func drawTurns(_ turns: [SessionLog.Turn]) {
        Design.chrome.setFill()
        NSRect(x: 0, y: PaneBar.height, width: list, height: bounds.height - PaneBar.height).fill()
        Design.border.setFill()
        NSRect(x: list - 1, y: PaneBar.height, width: 1, height: bounds.height - PaneBar.height).fill()
        turnFrames = []
        var y = PaneBar.height + 10
        let width = list - 44
        for (index, turn) in turns.enumerated() {
            let selected = index == replays.selected
            let prompt = turn.prompt.isEmpty ? "Before the first prompt" : turn.prompt
                .replacingOccurrences(of: "\n", with: " ")
            let heading = text(
                prompt,
                13,
                selected ? Design.text : Design.textMuted,
                weight: selected ? .semibold : .regular
            )
            let height = min(ceil(heading.boundingRect(
                with: NSSize(width: width, height: 1000),
                options: [.usesLineFragmentOrigin]
            ).height), 36)
            let top = y
            text("\(index + 1)", 11, Design.textFaint, mono: true).draw(at: NSPoint(x: 12, y: y + 1))
            heading.draw(
                with: NSRect(x: 32, y: y, width: width, height: height),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
            )
            y += height + 2
            let writes = turn.written.count, commands = turn.steps.count(where: { $0.tool == "Bash" })
            var facts = [
                turn.mode == "plan" ? "planned" : nil,
                writes > 0 ? "\(writes) file\(writes == 1 ? "" : "s") written" : nil,
                commands > 0 ? "\(commands) command\(commands == 1 ? "" : "s")" : nil,
            ].compactMap { $0 }
            if let at = turn.at, let ended = turn.ended {
                facts.append(Duration.seconds(ended.timeIntervalSince(at)).formatted(.units(width: .narrow)))
            } else if turn.ended == nil {
                facts.append("not ended")
            }
            text(facts.joined(separator: " · "), 11, Design.textFaint).draw(at: NSPoint(x: 32, y: y))
            y += 18
            if selected {
                for step in turn.steps.prefix(40) {
                    let line = NSMutableAttributedString(attributedString: text(step.tool + "  ", 11, Design.accent))
                    line.append(text(
                        step.detail.replacingOccurrences(of: "\n", with: " "),
                        11,
                        Design.textMuted,
                        mono: true
                    ))
                    line.draw(
                        with: NSRect(x: 32, y: y, width: width, height: 16),
                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
                    )
                    y += 16
                }
                if turn.steps.count > 40 {
                    text("… \(turn.steps.count - 40) more", 11, Design.textFaint).draw(at: NSPoint(x: 32, y: y))
                    y += 16
                }
            }
            let rect = NSRect(x: 0, y: top - 6, width: list, height: y - top + 8)
            if selected {
                Design.accent.setFill()
                NSRect(x: 0, y: rect.minY, width: 2, height: rect.height).fill()
            }
            turnFrames.append((index, rect))
            y += 10
        }
    }

    /// The selected turn's files, then the diff of the selected one.
    private func drawChanges() {
        let left = list + 20, width = bounds.width - list - 40
        var y = PaneBar.height + 14
        fileFrames = []
        if replays.reading {
            text("Reading the turn's changes…", 13, Design.textMuted).draw(at: NSPoint(x: left, y: y))
            return
        }
        if let missing = replays.missing {
            text(missing, 13, Design.textMuted).draw(at: NSPoint(x: left, y: y))
            return
        }
        if replays.files.isEmpty {
            text(
                replays.log == nil ? "No session open: :SillReplay picks one." : "No changes in this turn.",
                13,
                Design.textMuted
            ).draw(at: NSPoint(x: left, y: y))
            return
        }
        for (index, file) in replays.files.enumerated() {
            let selected = index == selectedFile
            let line = NSMutableAttributedString(attributedString: text(
                file.path, 12, selected ? Design.text : Design.textMuted, weight: selected ? .semibold : .regular,
                mono: true
            ))
            line.append(text("  +\(file.added)", 11, Design.accent, mono: true))
            line.append(text(" −\(file.removed)", 11, Design.error, mono: true))
            let rect = NSRect(x: left - 8, y: y - 3, width: width + 16, height: 22)
            if selected {
                Design.selection.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            }
            line.draw(at: NSPoint(x: left, y: y))
            fileFrames.append((index, rect))
            y += 24
        }
        y += 12
        guard let file = replays.files[safe: selectedFile], let diff = replays.diffs[file.path] else { return }
        let lineHeight = EditorFont.metrics.height
        y -= scroll
        for hunk in diff.hunks {
            if y > bounds.height { break }
            text(hunk.header, 11, Design.textFaint, mono: true).draw(at: NSPoint(x: left, y: y))
            y += lineHeight + 4
            for line in hunk.lines {
                if y > bounds.height { break }
                let color: NSColor = line.hasPrefix("+") ? Design.accent : line.hasPrefix("-") ? Design.error : Design
                    .text
                if line.hasPrefix("+") || line.hasPrefix("-") {
                    color.withAlphaComponent(0.08).setFill()
                    NSRect(x: list, y: y, width: bounds.width - list, height: lineHeight).fill()
                }
                if y > PaneBar.height {
                    NSAttributedString(string: line, attributes: [
                        .font: EditorFont.metrics.regular, .foregroundColor: color,
                    ]).draw(at: NSPoint(x: left, y: y))
                }
                y += lineHeight
            }
            y += 10
        }
    }

    // MARK: Input

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let (index, _) = turnFrames.first(where: { $0.1.contains(point) }) {
            select(turn: index)
        } else if let (index, _) = fileFrames.first(where: { $0.1.contains(point) }) {
            selectedFile = index
            scroll = 0
            if event.clickCount == 2, let file = replays.files[safe: index] { replays.reveal(file.path) }
            needsDisplay = true
        }
    }

    override func scrollWheel(with event: NSEvent) {
        scroll = max(scroll - event.scrollingDeltaY, 0)
        needsDisplay = true
    }

    private func select(turn index: Int) {
        selectedFile = 0
        scroll = 0
        replays.select(index)
    }

    func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { return false }
        switch event.charactersIgnoringModifiers ?? "" {
        case "j": select(turn: min(replays.selected + 1, max((replays.log?.turns.count ?? 1) - 1, 0)))
        case "k": select(turn: max(replays.selected - 1, 0))
        case "J":
            selectedFile = min(selectedFile + 1, max(replays.files.count - 1, 0))
            scroll = 0
        case "K":
            selectedFile = max(selectedFile - 1, 0)
            scroll = 0
        case "\r": if let file = replays.files[safe: selectedFile] { replays.reveal(file.path) }
        case "r":
            if let session = replays.session {
                let turn = replays.selected
                replays.open(session)
                replays.select(turn)
            }
        default: return false
        }
        needsDisplay = true
        return true
    }
}
