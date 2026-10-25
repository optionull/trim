import AppKit
import SillCore
import SillEditor

/// The trace pane: a symbol's callers (or callees) as a tree, opened a level at a time. A row says what the symbol is
/// and where; the selected one opens in the editor, and the path to it can go to the agent.
final class TraceView: NSView, ToolContent {
    let tracer: Tracer
    /// The row selected, as a node index.
    private(set) var selected = 0
    private var scroll: CGFloat = 0
    private(set) var rows: [(index: Int, rect: NSRect)] = []

    init(tracer: Tracer) {
        self.tracer = tracer
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    private static let bar: CGFloat = 52, row: CGFloat = 28

    func changed() {
        if let tree = tracer.tree, !tree.nodes.indices.contains(selected) { selected = 0 }
        needsDisplay = true
    }

    private func text(
        _ string: String, _ size: CGFloat = 13, _ color: NSColor = Design.text, weight: NSFont.Weight = .regular
    ) -> NSAttributedString {
        NSAttributedString(
            string: string,
            attributes: [.font: Design.ui(size, weight: weight), .foregroundColor: color]
        )
    }

    override func draw(_: NSRect) {
        Design.editor.setFill()
        bounds.fill()
        rows = []
        if let tree = tracer.tree {
            drawTree(tree)
        } else {
            let message = tracer.busy ? "Asking the language server…" :
                tracer.problem ?? ":SillTrace on a symbol shows who calls it; :SillTrace callees what it calls"
            text(message, 13, Design.textMuted).draw(at: NSPoint(x: 20, y: Self.bar + 20))
        }
        drawBar()
    }

    private func drawTree(_ tree: TraceTree) {
        var y = Self.bar + 10 - scroll
        for index in tree.visible {
            let node = tree.nodes[index]
            let rect = NSRect(x: 0, y: y, width: bounds.width, height: Self.row)
            rows.append((index, rect))
            if index == selected {
                Design.selection.setFill()
                rect.fill()
            }
            let x = 20 + CGFloat(node.depth) * 22
            let open = node.children == nil ? "▸" : node.children!.isEmpty ? " " : node.expanded ? "▾" : "▸"
            text(open, 12, Design.textMuted).draw(at: NSPoint(x: x, y: y + 6))
            let name = text(
                node.item.name,
                13,
                index == 0 ? Design.accent : Design.text,
                weight: index == 0 ? .semibold : .regular
            )
            name.draw(at: NSPoint(x: x + 16, y: y + 5))
            let file = (node.item.path as NSString).lastPathComponent
            var place = "\(file):\(node.item.line)"
            if tree.direction == .incoming, let at = node.item.at, index != 0 { place += " · calls at line \(at)" }
            if node.recursive { place += " · recursive" }
            text(place, 12, Design.textMuted).draw(at: NSPoint(x: x + 30 + name.size().width, y: y + 6))
            // Roslyn's detail is the containing type, already in its names; other servers' may say more.
            let detail = node.item.detail
            if !detail.isEmpty, detail != node.item.name, !node.item.name.hasPrefix(detail + ".") {
                text(detail, 11, Design.textFaint).draw(
                    with: NSRect(x: bounds.width * 0.6, y: y + 7, width: bounds.width * 0.4 - 20, height: 16),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
                )
            }
            y += Self.row
        }
        if tree.nodes[0].children?.isEmpty == true {
            text(
                tree.direction == .incoming ? "No callers found." : "It calls nothing the server knows of.",
                12,
                Design.textMuted
            ).draw(at: NSPoint(x: 42, y: y + 6))
        }
        if let problem = tracer.problem {
            text(problem, 12, Design.error).draw(at: NSPoint(x: 20, y: y + 30))
        }
    }

    private func drawBar() {
        Design.chrome.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: Self.bar).fill()
        let title = text("Trace", 16, weight: .semibold)
        title.draw(at: NSPoint(x: 20, y: 16))
        if let tree = tracer.tree {
            let state = "\(tree.direction.label) of \(tree.nodes[0].item.name)" + (tracer.busy ? " · asking…" : "")
            text(state, 13, Design.textMuted).draw(at: NSPoint(x: 36 + title.size().width, y: 19))
        }
        let hint = text(
            "j/k · l open · h close · ↵ go to · d callers/callees · e explain · b to the basket",
            11,
            Design.textFaint
        )
        hint.draw(at: NSPoint(x: bounds.width - hint.size().width - 20, y: 20))
    }

    // MARK: Input

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let row = rows.first(where: { $0.rect.contains(point) }) else { return }
        selected = row.index
        needsDisplay = true
        if event.clickCount == 2 { tracer.reveal(row.index) } else { toggle(row.index) }
    }

    override func scrollWheel(with event: NSEvent) {
        scroll = max(scroll - event.scrollingDeltaY, 0)
        needsDisplay = true
    }

    private func toggle(_ index: Int) {
        guard let node = tracer.tree?.nodes[safe: index] else { return }
        if node.expanded { tracer.close(index) } else { Task { await tracer.open(index) } }
    }

    func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { return false }
        let visible = tracer.tree?.visible ?? []
        let position = visible.firstIndex(of: selected) ?? 0
        switch event.charactersIgnoringModifiers ?? "" {
        case "j", String(UnicodeScalar(NSDownArrowFunctionKey)!):
            selected = visible[safe: position + 1] ?? selected
        case "k", String(UnicodeScalar(NSUpArrowFunctionKey)!):
            selected = visible[safe: position - 1] ?? selected
        case "l", String(UnicodeScalar(NSRightArrowFunctionKey)!):
            Task { await tracer.open(selected) }
        case "h", String(UnicodeScalar(NSLeftArrowFunctionKey)!):
            if tracer.tree?.nodes[safe: selected]?.expanded == true {
                tracer.close(selected)
            } else if let parent = tracer.tree?.nodes[safe: selected]?.parent {
                selected = parent
            }
        case "\r": tracer.reveal(selected)
        case "d":
            selected = 0
            Task { await tracer.turn() }
        case "e": tracer.explain(selected)
        case "b": tracer.addToBasket(selected)
        default: return false
        }
        needsDisplay = true
        return true
    }
}
