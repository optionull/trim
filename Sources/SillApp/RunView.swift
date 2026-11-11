import AppKit
import SillCore
import SillEditor

/// The Run pane: what the branch touched first, then what was run (the last first), then everything else the checkout
/// has. A row runs (↵), runs with its command line changed first (e), debugs (d) or profiles (p) where sill can.
@MainActor
final class RunView: NSView, ToolContent {
    private let runner: Runner
    private var selected = 0
    private var scroll: CGFloat = 0
    private var rowFrames: [(Int, NSRect)] = []
    private var buttonFrames: [(Int, String, NSRect)] = []
    private var actionFrames: [(String, NSRect)] = []

    /// A row: a runnable, or a configuration that was run (its command as altered).
    struct Item {
        var section: String
        var runnable: Runnable
    }

    init(runner: Runner) {
        self.runner = runner
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func changed() {
        selected = min(selected, max(items.count - 1, 0))
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

    /// Touched, then run before, then the rest; each once.
    var items: [Item] {
        var seen: Set<String> = []
        func key(_ runnable: Runnable) -> String { runnable.name + "|" + runnable.directory }
        let byKey = Dictionary(runner.runnables.map { (key($0), $0) }) { first, _ in first }
        var list: [Item] = []
        for run in runner.fromAgent {
            let runnable = Runnable(name: run.name, kind: .script, tool: "", command: run.command)
            if seen.insert(key(runnable)).inserted { list.append(Item(
                section: "From the agent's handoff",
                runnable: runnable
            )) }
        }
        for runnable in runner.touched where seen.insert(key(runnable)).inserted {
            list.append(Item(section: "Touched on this branch", runnable: runnable))
        }
        for configuration in runner.configurations.configurations {
            let found = byKey[configuration.name + "|" + configuration.directory]
            var runnable = found ?? Runnable(
                name: configuration.name,
                kind: .script,
                tool: "",
                command: "",
                directory: configuration.directory
            )
            runnable.command = configuration.command
            if seen.insert(key(runnable)).inserted { list.append(Item(section: "Run before", runnable: runnable)) }
        }
        for runnable in runner.runnables where seen.insert(key(runnable)).inserted {
            list.append(Item(
                section: runnable.kind == .test ? "Tests" : runnable.kind == .app ? "Programs" : "Scripts",
                runnable: runnable
            ))
        }
        return list
    }

    override func draw(_: NSRect) {
        Design.editor.setFill()
        bounds.fill()
        let all = items
        let last = runner.configurations.last
        actionFrames = PaneBar.draw(
            title: "Run",
            detail: runner.reading ? "finding what there is…" : "\(runner.runnables.count) found" +
                (last.map { " · last: \($0.name)" } ?? ""),
            actions: [
                .init(id: "pick", title: "Choose… ⇧⌘R"),
                .init(id: "rerun", title: "Run again ⌘R", primary: last != nil),
            ],
            in: bounds
        ).map { ($0.id, $0.rect) }
        rowFrames = []
        buttonFrames = []
        let left: CGFloat = 24, width = bounds.width - 48
        var y = PaneBar.height + 16 - scroll
        var section = ""
        if all.isEmpty {
            text(
                runner.reading ? "Finding what this checkout can run…" :
                    "Nothing to run that sill found: no .NET program or tests, Swift or Cargo package, package.json " +
                    "scripts, mise tasks or justfile.",
                14,
                Design.textMuted
            )
            .drawLine(in: NSRect(x: left, y: y, width: width, height: 20))
        }
        for (index, item) in all.enumerated() {
            if item.section != section {
                section = item.section
                y += 8
                text(section.uppercased(), 10, Design.textFaint, weight: .semibold).draw(at: NSPoint(x: left, y: y))
                y += 20
            }
            let rect = NSRect(x: 0, y: y, width: bounds.width, height: 46)
            defer { y += 46 }
            guard rect.maxY > PaneBar.height, rect.minY < bounds.height - PaneBar.footer else { continue }
            rowFrames.append((index, rect))
            if index == selected {
                Design.selection.setFill()
                rect.fill()
            }
            let runnable = item.runnable
            let name = NSMutableAttributedString(attributedString: text(runnable.name, 14, weight: .semibold))
            if !runnable.tool.isEmpty { name.append(text("  " + runnable.tool, 11, Design.textFaint)) }
            name.drawLine(in: NSRect(x: left, y: y + 5, width: width - 260, height: 20))
            let line = (runnable.directory.isEmpty ? "" : runnable.directory + " $ ") + runnable.command
            text(line, 12, Design.textMuted, mono: true).drawLine(in: NSRect(
                x: left,
                y: y + 25,
                width: width - 260,
                height: 18
            ))
            // Its buttons, right to left.
            var x = left + width
            for (id, title, enabled) in [
                ("run", "Run", true),
                ("profile", "Profile", runnable.profilable),
                ("debug", "Debug", runnable.debuggable),
            ] where enabled {
                let label = text(
                    title,
                    12,
                    id == "run" ? Design.onAccent : Design.text,
                    weight: id == "run" ? .semibold : .regular
                )
                let button = NSRect(
                    x: x - label.size().width - 22,
                    y: y + 10,
                    width: label.size().width + 22,
                    height: 26
                )
                let shape = NSBezierPath(roundedRect: button.insetBy(dx: 0.5, dy: 0.5), xRadius: 13, yRadius: 13)
                if id == "run" {
                    Design.accent.setFill()
                    shape.fill()
                } else {
                    Design.border.setStroke()
                    shape.stroke()
                }
                label.draw(at: NSPoint(x: button.minX + 11, y: button.midY - label.size().height / 2))
                buttonFrames.append((index, id, button))
                x = button.minX - 8
            }
        }
        PaneBar.drawKeys("run", note: "⌘R run again · ⇧⌘R choose", in: bounds)
    }

    // MARK: Input

    private func perform(_ id: String, _ index: Int) {
        let all = items
        guard all.indices.contains(index) else { return }
        let runnable = all[index].runnable
        switch id {
        case "debug": runner.debug(runnable)
        case "profile": runner.profile(runnable)
        case "alter": runner.alter(runnable)
        default: runner.run(runnable)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let (id, _) = actionFrames.first(where: { $0.1.contains(point) }) {
            if id == "pick" { runner.pick() } else { runner.rerun() }
        } else if let (index, id, _) = buttonFrames.first(where: { $0.2.contains(point) }) {
            perform(id, index)
        } else if let (index, _) = rowFrames.first(where: { $0.1.contains(point) }) {
            selected = index
            needsDisplay = true
            if event.clickCount == 2 { perform("run", index) }
        }
    }

    override func scrollWheel(with event: NSEvent) {
        scroll = max(scroll - event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 10), 0)
        needsDisplay = true
    }

    var keyKind: String { "run" }

    var hintTargets: [NSRect] { actionFrames.map(\.1) + buttonFrames.map(\.2) }

    /// Where a runnable's button was drawn (`run`, `profile`, `debug`), for the checks.
    func button(_ id: String, of name: String) -> NSRect? {
        let all = items
        return buttonFrames.first { all[safe: $0.0]?.runnable.name == name && $0.1 == id }?.2
    }

    func perform(_ command: String, key _: String) -> Bool {
        switch command {
        case "run.down": selected = min(selected + 1, max(items.count - 1, 0))
        case "run.up": selected = max(selected - 1, 0)
        case "run.run": perform("run", selected)
        case "run.edit": perform("alter", selected)
        case "run.debug": perform("debug", selected)
        case "run.profile": perform("profile", selected)
        case "run.refresh": runner.refresh()
        default: return false
        }
        needsDisplay = true
        return true
    }
}
