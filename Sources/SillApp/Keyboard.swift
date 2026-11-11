import AppKit
import SillEditor
import SillInput

/// A native pane's keys go through one place: the pane's keymap (`Keymaps`) says which command a key, or a sequence
/// such as `gv`, is; the pane does the command by its name. What the keymap does not take goes on to nvim (`q`, `:`,
/// `<C-w>`), and a sequence nobody here finishes goes there whole, so nvim's `gt` still changes tab.
@MainActor
final class Keyboard {
    /// What `g…` goes to (`go.review`, …): the workspace's, which opens it as the rail would.
    var go: ((String) -> Void)?
    /// Keys for nvim, typed as they were.
    var forward: ((String) -> Void)?
    private var typed: [String] = []
    private weak var overlay: KeyOverlay?

    /// A key in `view`: true when sill took it.
    func handle(_ event: NSEvent, in view: NSView & ToolContent) -> Bool {
        if let overlay, overlay.superview != nil, overlay.mode != .waiting {
            return overlay.key(event)
        }
        if typed.isEmpty, view.captureKey(event) { return true }
        guard let key = KeyNotation.keys(for: event), let keymap = Keymaps.current(view.keyKind) else { return false }
        if !typed.isEmpty, key == "<Esc>" {
            end()
            return true
        }
        let keys = typed + [key]
        switch keymap.match(keys) {
        case let .command(name):
            end()
            run(name, key: key, in: view)
            return true
        case let .prefix(commands):
            typed = keys
            show(.waiting, KeyOverlay(waiting: keys, commands: commands), in: view)
            return true
        case .none:
            guard !typed.isEmpty else { return false }
            end()
            forward?(keys.joined())
            return true
        }
    }

    /// A command by its name, from `:SillKey` or a key: `go.*` and `keys.*` here, the rest the pane's.
    @discardableResult
    func run(_ name: String, key: String? = nil, in view: (NSView & ToolContent)?) -> Bool {
        if name.hasPrefix("go.") {
            go?(name)
            return true
        }
        guard let view else { return false }
        switch name {
        case "keys.help":
            guard let keymap = Keymaps.current(view.keyKind) else { return false }
            show(.help, KeyOverlay(help: keymap), in: view)
            return true
        case "keys.hints":
            let targets = view.hintTargets.filter { view.bounds.intersects($0) }
            guard !targets.isEmpty else { return false }
            let overlay = KeyOverlay(hints: targets)
            overlay
                .onHint = { [weak view] rect in view.map { Self.click($0, at: NSPoint(x: rect.midX, y: rect.midY)) } }
            show(.hints, overlay, in: view)
            return true
        default:
            let keys = Keymaps.current(view.keyKind)?.all.first { $0.name == name }?.keys ?? []
            return view.perform(name, key: key ?? keys.first.map { KeySequence.split($0).last ?? $0 } ?? "")
        }
    }

    private func show(_: KeyOverlay.Mode, _ made: KeyOverlay, in view: NSView) {
        overlay?.removeFromSuperview()
        made.frame = view.bounds
        made.autoresizingMask = [.width, .height]
        made.onClose = { [weak self] in self?.end() }
        view.addSubview(made)
        overlay = made
    }

    /// Nothing waiting and nothing over the pane.
    func end() {
        typed = []
        overlay?.removeFromSuperview()
        overlay = nil
    }

    /// A click where a hint was, as the mouse would have made it.
    static func click(_ view: NSView, at point: NSPoint) {
        guard let window = view.window else { return }
        // A real button there (the panel's Send all, the profiler's): pressed as a button is.
        let hit = view.superview.flatMap { view.hitTest(view.convert(point, to: $0)) }
        if let control = hit as? NSControl, control !== view {
            control.performClick(nil)
            return
        }
        let target = hit.flatMap { $0 === view || !$0.isDescendant(of: view) ? nil : $0 } ?? view
        let location = view.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ) else { continue }
            if type == .leftMouseDown { target.mouseDown(with: event) } else { target.mouseUp(with: event) }
        }
    }
}

/// What is laid over a pane while keys are being typed: the keys that can follow a prefix (along the bottom), every
/// key the pane takes (`?`), or a label on everything that can be clicked (`f`).
@MainActor
final class KeyOverlay: NSView {
    enum Mode { case waiting, help, hints }
    let mode: Mode
    var onClose: (() -> Void)?
    var onHint: ((NSRect) -> Void)?
    private var commands: [PaneKey] = []
    private var typed: [String] = []
    private var keymap: Keymap?
    private var hints: [(label: String, rect: NSRect)] = []
    private var label = ""

    init(waiting typed: [String], commands: [PaneKey]) {
        mode = .waiting
        self.typed = typed
        self.commands = commands
        super.init(frame: .zero)
    }

    init(help keymap: Keymap) {
        mode = .help
        self.keymap = keymap
        super.init(frame: .zero)
    }

    init(hints targets: [NSRect]) {
        mode = .hints
        super.init(frame: .zero)
        let labels = Self.labels(targets.count)
        hints = zip(labels, targets).map { ($0, $1) }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// Home row first, then the rest; two letters when there are more targets than letters.
    static func labels(_ count: Int) -> [String] {
        let letters = Array("asdfjklghqwertyuiopzxcvbnm").map(String.init)
        if count <= letters.count { return Array(letters.prefix(count)) }
        return Array(letters.flatMap { first in letters.map { first + $0 } }.prefix(count))
    }

    /// The bottom panel waiting for a key lets the mouse through; the others take it (a click closes them).
    override func hitTest(_ point: NSPoint) -> NSView? { mode == .waiting ? nil : super.hitTest(point) }

    override func mouseDown(with _: NSEvent) { onClose?() }

    func key(_ event: NSEvent) -> Bool {
        let key = KeyNotation.keys(for: event) ?? ""
        switch mode {
        case .waiting: return false
        case .help:
            if ["<Esc>", "?", "q", "<CR>"].contains(key) { onClose?() }
            return true
        case .hints:
            if key == "<Esc>" {
                onClose?()
                return true
            }
            if key == "<BS>" {
                label = String(label.dropLast())
            } else if key.count == 1 {
                label += key
            }
            let matching = hints.filter { $0.label.hasPrefix(label) }
            if let only = matching.first, matching.count == 1, only.label == label {
                onClose?()
                onHint?(only.rect)
            } else if matching.isEmpty {
                onClose?()
            } else {
                needsDisplay = true
            }
            return true
        }
    }

    override func draw(_: NSRect) {
        switch mode {
        case .waiting: drawWaiting()
        case .help: drawHelp()
        case .hints: drawHints()
        }
    }

    private func drawWaiting() {
        let rows = commands.count
        let columns = max(min(3, Int(bounds.width / 260)), 1)
        let lines = (rows + columns - 1) / columns
        let height = CGFloat(lines) * 24 + 44
        let panel = NSRect(x: 0, y: bounds.height - height, width: bounds.width, height: height)
        Design.popup.setFill()
        panel.fill()
        Design.border.setFill()
        NSRect(x: 0, y: panel.minY, width: bounds.width, height: 1).fill()
        Self.text(typed.map(KeySequence.cap).joined() + " …", 11, Design.textMuted, weight: .semibold)
            .draw(at: NSPoint(x: 16, y: panel.minY + 10))
        let width = (bounds.width - 32) / CGFloat(columns)
        for (index, command) in commands.enumerated() {
            let column = index / lines, line = index % lines
            let origin = NSPoint(x: 16 + CGFloat(column) * width, y: panel.minY + 34 + CGFloat(line) * 24)
            let next = command.keys.map(KeySequence.split).first { Array($0.prefix(typed.count)) == typed }
            let rest = Array((next ?? []).dropFirst(typed.count))
            var x = KeyCaps.draw(rest, at: origin)
            x += 8
            Self.text(command.title, 12, Design.text).draw(at: NSPoint(x: x, y: origin.y + 1))
        }
    }

    private func drawHelp() {
        Design.canvas.withAlphaComponent(0.82).setFill()
        bounds.fill()
        guard let keymap else { return }
        let sections: [(String, [PaneKey])] = [
            ("This pane", keymap.own),
            ("Go to", keymap.shared.filter { $0.pane == "go" }),
            ("Everywhere", keymap.shared.filter { $0.pane == "keys" } + [
                PaneKey("q", ["q"], "back to the code"), PaneKey(":", [":"], "nvim's command line"),
            ]),
        ].filter { !$0.1.isEmpty }
        let lineHeight: CGFloat = 23
        let column: CGFloat = min(380, (bounds.width - 80) / CGFloat(max(sections.count, 1)))
        let tallest = sections.map(\.1.count).max() ?? 0
        let card = NSRect(
            x: max((bounds.width - column * CGFloat(sections.count) - 48) / 2, 16),
            y: max((bounds.height - CGFloat(tallest) * lineHeight - 110) / 2, 16),
            width: min(column * CGFloat(sections.count) + 48, bounds.width - 32),
            height: min(CGFloat(tallest) * lineHeight + 110, bounds.height - 32)
        )
        Design.popup.setFill()
        NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12).fill()
        Design.border.setStroke()
        NSBezierPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12).stroke()
        Self.text("Keys", 15, Design.text, weight: .semibold).draw(at: NSPoint(x: card.minX + 24, y: card.minY + 18))
        Self.text("? or ⎋ closes · :SillKey <name> runs one · [keys] in the settings rebinds", 11, Design.textFaint)
            .draw(at: NSPoint(x: card.minX + 72, y: card.minY + 22))
        for (index, (title, commands)) in sections.enumerated() {
            let x = card.minX + 24 + CGFloat(index) * column
            var y = card.minY + 56
            Self.text(title.uppercased(), 10, Design.textFaint, weight: .semibold).draw(at: NSPoint(x: x, y: y))
            y += 22
            for command in commands where y < card.maxY - 20 {
                var right = x
                for (offset, notation) in command.keys.prefix(2).enumerated() {
                    if offset > 0 { right += 4 }
                    right = KeyCaps.draw(KeySequence.split(notation), at: NSPoint(x: right, y: y))
                }
                let title = Self.text(command.title, 12, Design.text)
                title.drawLine(in: NSRect(x: x + 64, y: y + 1, width: column - 70, height: 18))
                y += lineHeight
            }
        }
    }

    private func drawHints() {
        for hint in hints {
            let typedPart = hint.label.hasPrefix(label) ? label.count : 0
            guard label.isEmpty || typedPart > 0 else { continue }
            let string = NSMutableAttributedString(attributedString: Self.text(
                String(hint.label.dropFirst(typedPart)),
                11,
                Design.onAccent,
                weight: .bold,
                mono: true
            ))
            let size = string.size()
            // Just left of what it labels, so the label hides none of it; inside when there is no room.
            let rect = NSRect(
                x: hint.rect.minX - size.width - 11 >= 0 ? hint.rect.minX - size.width - 11 : hint.rect.minX + 2,
                y: hint.rect.midY - size.height / 2 - 1,
                width: size.width + 8,
                height: size.height + 2
            )
            Design.modified.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
            string.draw(at: NSPoint(x: rect.minX + 4, y: rect.minY + 1))
        }
    }

    fileprivate static func text(
        _ string: String,
        _ size: CGFloat,
        _ color: NSColor,
        weight: NSFont.Weight = .regular,
        mono: Bool = false
    ) -> NSAttributedString {
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : Design.ui(size, weight: weight)
        return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
    }
}

/// Keys drawn as keys: a small raised cap each.
@MainActor
enum KeyCaps {
    /// Draws `keys` from `origin` (the cap's top left) and returns where they end.
    @discardableResult
    static func draw(_ keys: [String], at origin: NSPoint, size: CGFloat = 11) -> CGFloat {
        var x = origin.x
        for key in keys {
            let label = KeyOverlay.text(KeySequence.cap(key), size, Design.text, mono: true)
            let width = max(label.size().width + 8, 18)
            let rect = NSRect(x: x, y: origin.y, width: width, height: size + 8)
            Design.chrome.setFill()
            let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            shape.fill()
            Design.border.setStroke()
            shape.stroke()
            Design.border.setFill()
            NSRect(x: rect.minX + 3, y: rect.maxY - 1.5, width: rect.width - 6, height: 1).fill()
            label.draw(at: NSPoint(x: rect.minX + (width - label.size().width) / 2, y: rect.minY + 3))
            x = rect.maxX + 2
        }
        return x
    }
}
