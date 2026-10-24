import AppKit
import SillCore
import SillEditor

/// The walkthrough pane: its steps on the left, the step on the right: its prose, the code each anchor points at now
/// (or why it was not found), and its questions with their answers.
final class WalkView: NSView, ToolContent {
    let walker: Walker
    private var stepFrames: [(Int, NSRect)] = []
    private var actionFrames: [(String, Int, NSRect)] = []
    private var scroll: CGFloat = 0

    init(walker: Walker) {
        self.walker = walker
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    private var list: CGFloat { min(300, bounds.width * 0.28) }

    func changed() { needsDisplay = true }

    private func text(
        _ string: String,
        _ size: CGFloat = 14,
        _ color: NSColor = Design.text,
        weight: NSFont.Weight = .regular
    ) -> NSAttributedString {
        NSAttributedString(
            string: string,
            attributes: [.font: Design.ui(size, weight: weight), .foregroundColor: color]
        )
    }

    /// Prose with `code` spans in the grid's font.
    private func prose(_ string: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (index, part) in string.components(separatedBy: "`").enumerated() {
            out.append(index % 2 == 1 ? NSAttributedString(string: part, attributes: [
                .font: EditorFont.metrics.regular, .foregroundColor: Design.insert,
            ]) : text(part, 14, Design.text))
        }
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: out.length))
        return out
    }

    override func draw(_: NSRect) {
        Design.editor.setFill()
        bounds.fill()
        stepFrames = []
        actionFrames = []
        guard let walk = walker.walk else {
            text(
                walker.path == nil ? "No walkthrough open: :SillWalk picks one." : "Reading the walkthrough…",
                14,
                Design.textFaint
            ).draw(at: NSPoint(x: 24, y: 24))
            return
        }
        drawSteps(walk)
        drawStep(walk)
    }

    private func drawSteps(_ walk: Walkthrough) {
        let column = NSRect(x: 0, y: 0, width: list, height: bounds.height)
        Design.chrome.setFill()
        column.fill()
        let title = text(walk.title, 15, weight: .semibold)
        let titleHeight = ceil(title.boundingRect(
            with: NSSize(width: list - 40, height: 80),
            options: [.usesLineFragmentOrigin]
        ).height)
        title.draw(
            with: NSRect(x: 20, y: 20, width: list - 40, height: titleHeight),
            options: [.usesLineFragmentOrigin]
        )
        var y = 30 + titleHeight
        if let target = walk.target {
            text(target, 12, Design.textFaint).draw(at: NSPoint(x: 20, y: y))
            y += 22
        }
        y += 8
        for (index, step) in walk.steps.enumerated() {
            let rect = NSRect(x: 0, y: y, width: list, height: 34)
            if index == walker.step {
                Design.selection.setFill()
                rect.fill()
                Design.accent.setFill()
                NSRect(x: 0, y: y, width: 3, height: 34).fill()
            }
            let stale = walker.found[safe: index]?.values.contains { $0.problem != nil } ?? false
            text("\(index + 1)", 12, stale ? Design.error : Design.textFaint).draw(at: NSPoint(x: 20, y: y + 9))
            text(step.title, 13, index == walker.step ? Design.text : Design.textMuted).draw(
                with: NSRect(x: 44, y: y + 8, width: list - 60, height: 18),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
            )
            stepFrames.append((index, rect))
            y += 34
        }
        text("n/p steps · o open the code · a ask · r read again", 11, Design.textFaint)
            .draw(at: NSPoint(x: 20, y: bounds.height - 28))
    }

    private func drawStep(_ walk: Walkthrough) {
        guard let step = walk.steps[safe: walker.step] else { return }
        let left = list + 32, width = min(bounds.width - list - 64, 900)
        var y = 28 - scroll
        func write(_ string: NSAttributedString, gap: CGFloat = 14) {
            let height = ceil(string.boundingRect(
                with: NSSize(width: width, height: 10000),
                options: [.usesLineFragmentOrigin]
            ).height)
            string.draw(with: NSRect(x: left, y: y, width: width, height: height), options: [.usesLineFragmentOrigin])
            y += height + gap
        }
        write(text("STEP \(walker.step + 1) OF \(walk.steps.count)", 11, Design.textMuted, weight: .semibold), gap: 6)
        write(text(step.title, 22, weight: .semibold), gap: 18)
        if walker.step == 0, !walk.intro.isEmpty { write(prose(walk.intro)) }
        let lineHeight = EditorFont.metrics.height
        for (index, block) in step.blocks.enumerated() {
            switch block {
            case let .prose(string):
                write(prose(string))
            case let .code(anchor, _):
                let place = walker.found[safe: walker.step]?[index]
                let name = switch anchor {
                case let .symbol(name, _): name
                case let .file(name, _): name
                }
                if let place, let file = place.path {
                    let lines = place.lines.prefix(40)
                    let box = NSRect(x: left, y: y, width: width, height: 36 + CGFloat(lines.count) * lineHeight + 10)
                    Design.chrome.setFill()
                    NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
                    let heading = "\((file as NSString).lastPathComponent):\(place.from)–\(place.to)" +
                        (place.by == "text" ? " · found by its text" : "")
                    text(heading, 12, Design.textMuted).draw(at: NSPoint(x: box.minX + 14, y: box.minY + 10))
                    let open = text("Open", 12, Design.accent)
                    let openRect = NSRect(
                        x: box.maxX - open.size().width - 24,
                        y: box.minY + 6,
                        width: open.size().width + 14,
                        height: 22
                    )
                    open.draw(at: NSPoint(x: openRect.minX + 7, y: openRect.minY + 3))
                    actionFrames.append(("open", index, openRect))
                    var lineY = box.minY + 36
                    for (offset, line) in lines.enumerated() {
                        let number = NSAttributedString(
                            string: String(format: "%4d  ", place.from + offset),
                            attributes: [
                                .font: EditorFont.metrics.regular, .foregroundColor: Design.textFaint,
                            ]
                        )
                        let row = NSMutableAttributedString(attributedString: number)
                        row.append(NSAttributedString(string: line, attributes: [
                            .font: EditorFont.metrics.regular, .foregroundColor: Design.text,
                        ]))
                        row.draw(
                            with: NSRect(x: box.minX + 8, y: lineY, width: box.width - 16, height: lineHeight),
                            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
                        )
                        lineY += lineHeight
                    }
                    y = box.maxY + 16
                } else {
                    let why = place?.problem ?? (walker.resolving ? "finding \(name)…" : "not found")
                    write(text("⚠︎ \(name): \(why)", 13, walker.resolving ? Design.textFaint : Design.error))
                }
            case let .ask(question, answer, line):
                write(text(question, 14, Design.insert, weight: .semibold), gap: 6)
                if let answer {
                    let quote = NSMutableAttributedString(attributedString: prose(answer))
                    quote.addAttribute(
                        .foregroundColor,
                        value: Design.textMuted,
                        range: NSRange(location: 0, length: quote.length)
                    )
                    Design.border.setFill()
                    let top = y
                    write(quote)
                    NSRect(x: left - 12, y: top, width: 3, height: y - top - 14).fill()
                } else {
                    let ask = text("Ask the agent", 12, Design.onAccent, weight: .semibold)
                    let rect = NSRect(x: left, y: y, width: ask.size().width + 24, height: 26)
                    Design.accent.setFill()
                    NSBezierPath(roundedRect: rect, xRadius: 13, yRadius: 13).fill()
                    ask.draw(at: NSPoint(x: rect.minX + 12, y: rect.midY - ask.size().height / 2))
                    actionFrames.append(("ask", line, rect))
                    y = rect.maxY + 16
                }
            }
        }
    }

    // MARK: Input

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let (index, _) = stepFrames.first(where: { $0.1.contains(point) }) {
            scroll = 0
            return walker.go(to: index)
        }
        if let (action, value, _) = actionFrames.first(where: { $0.2.contains(point) }) {
            switch action {
            case "open": walker.openCode(block: value)
            case "ask": walker.ask(line: value)
            default: break
            }
        }
    }

    override func scrollWheel(with event: NSEvent) {
        scroll = max(0, scroll - event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 10))
        needsDisplay = true
    }

    /// Asks a question of its own about the step.
    private func askAboutStep() {
        let alert = NSAlert()
        alert.messageText = "Ask about this step"
        alert.informativeText = "The agent gets the step and its code; the answer is written into the walkthrough."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Ask")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty {
            walker.ask(line: nil, question: field.stringValue)
        }
    }

    func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { return false }
        switch event.characters ?? "" {
        case "n", "j", String(UnicodeScalar(NSDownArrowFunctionKey)!): scroll = 0; walker.go(to: walker.step + 1)
        case "p", "k", String(UnicodeScalar(NSUpArrowFunctionKey)!): scroll = 0; walker.go(to: walker.step - 1)
        case "o", "\r": walker.openCode()
        case "a": askAboutStep()
        case "r": Task { await walker.read() }
        default: return false
        }
        return true
    }
}
