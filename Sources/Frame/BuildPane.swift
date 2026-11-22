import AppKit
import FrameRun
import SillEditor

/// The pane beside or under the code for building and running: one header in the style of the file tabs, with two tabs,
/// Problems (every diagnostic and what the build printed, as a list) and Output (a real terminal that stays after the
/// command ends), a button to run it again, and at the right the toggle for each level of problem and the button that
/// puts the pane away. Its keys and its mode (BUILD) are the window's (`FrameWindowController`).
final class BuildPane: NSView {
    enum Tab { case output, problems }

    /// Something in the header that can be pointed at.
    enum Control: Equatable { case tab(Tab), rebuild, minimize }

    var look: TreeLook {
        didSet {
            problems.look = look
            chipsView.look = look
            hint.textColor = look.faint
            hint.font = look.font
            needsDisplay = true
        }
    }

    /// The problems, as a list that is part of the pane (it filters, goes to a problem on Return, has Alt+Enter).
    let problems: ListPickerView
    private(set) var tab: Tab = .problems
    /// Whether Output is saying how to run something (nothing has run yet).
    var showsHint: Bool { tab == .output && terminal == nil }
    /// What ran last.
    private(set) var entry: RunEntry?
    private(set) var terminal: NSView?
    /// What the terminal shows, scrollback included, for the problems to be read from.
    private(set) var screenText: () -> String? = { nil }
    /// The errors and warnings in the list, shown on the tab.
    var problemCount = 0 {
        didSet { if problemCount != oldValue { needsDisplay = true } }
    }

    var onTabChange: ((Tab) -> Void)?
    /// The minimize button: the pane goes away and what runs in it goes on.
    var onMinimize: (() -> Void)?
    /// The button next to Output: run the last thing again (or build, when nothing has run).
    var onRebuild: (() -> Void)?
    var onFocus: (() -> Void)?
    var onEscape: (() -> Void)?

    /// The toggles for each level, in the header.
    let chipsView = ChipsView()
    private let hint = NSTextField(wrappingLabelWithString: "")
    private var tabFrames: [(Tab, NSRect)] = []
    private(set) var rebuildRect = NSRect.zero
    private(set) var minimizeRect = NSRect.zero
    private var hovered: Control?

    /// As tall as the file tabs' strip.
    static func headerHeight(for look: TreeLook) -> CGFloat { look.rowHeight + 12 }

    init(look: TreeLook) {
        self.look = look
        problems = ListPickerView(title: "Problems", look: look)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        problems.embedded = true
        problems.onChipsChange = { [weak self] chips in
            self?.chipsView.chips = chips
            self?.needsLayout = true
        }
        chipsView.look = look
        chipsView.onToggle = { [weak self] id in self?.problems.onChip?(id) }
        hint.alignment = .center
        hint.isHidden = true
        hint.stringValue = "Nothing has run yet.\n\n⇧⌘B builds  ·  F5 runs  ·  ⇧⌘R chooses what to run"
        hint.textColor = look.faint
        hint.font = look.font
        addSubview(problems)
        addSubview(hint)
        addSubview(chipsView)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onFocus?() }
        return result
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() }
    }

    /// A run begins: its terminal replaces the last one, and the Output tab shows it.
    func setTerminal(_ view: NSView, entry: RunEntry, screenText: @escaping () -> String?) {
        terminal?.removeFromSuperview()
        terminal = view
        self.entry = entry
        self.screenText = screenText
        addSubview(view, positioned: .below, relativeTo: chipsView)
        select(.output)
    }

    private func showSelectedTab() {
        terminal?.isHidden = tab != .output
        problems.isHidden = tab != .problems
        hint.isHidden = !showsHint
    }

    func select(_ tab: Tab) {
        self.tab = tab
        showSelectedTab()
        needsLayout = true
        needsDisplay = true
        onTabChange?(tab)
    }

    /// Where the keyboard goes: the terminal on Output (or the pane itself, with nothing run), the list on Problems.
    var focusView: NSView {
        switch tab {
        case .problems: problems
        case .output: terminal ?? self
        }
    }

    override func layout() {
        super.layout()
        let header = Self.headerHeight(for: look)
        let body = NSRect(x: 0, y: header, width: bounds.width, height: max(0, bounds.height - header))
        terminal?.frame = body
        problems.frame = body
        showSelectedTab()
        hint.frame = NSRect(
            x: 24,
            y: header + max(0, body.height / 2 - 40),
            width: max(0, bounds.width - 48),
            height: 80
        )
        // The toggles fill what the tabs and the rebuild button leave, up to the minimize button.
        let from = (rebuildRect.isEmpty ? 8 : rebuildRect.maxX) + 12
        let to = bounds.width - header - 4
        chipsView.frame = NSRect(x: from, y: 0, width: max(0, to - from), height: header)
        chipsView.isHidden = problems.chips.isEmpty || to - from < 60
    }

    override func draw(_: NSRect) {
        look.island.setFill()
        bounds.fill()
        let header = Self.headerHeight(for: look)
        let iconFont = NerdFont.font(size: look.iconSize - 1) ?? look.smallFont
        var newTabs: [(Tab, NSRect)] = []
        var x: CGFloat = 8
        let tabs: [(Tab, String, String)] = [
            (.problems, problemCount > 0 ? "Problems \(problemCount)" : "Problems", "\u{f071}"),
            (.output, "Output", "\u{f120}"),
        ]
        for (which, name, glyph) in tabs {
            let selected = which == tab
            let color = selected ? look.text : look.muted
            let icon = NSAttributedString(string: glyph, attributes: [.font: iconFont, .foregroundColor: color])
            let text = NSAttributedString(string: name, attributes: [.font: look.font, .foregroundColor: color])
            let width = 10 + max(icon.size().width, look.iconSize) + 7 + ceil(text.size().width) + 12
            let rect = NSRect(x: x, y: 4, width: width, height: header - 8)
            if selected {
                look.focusedSelection.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            } else if hovered == .tab(which) {
                look.selection.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            }
            icon.draw(at: NSPoint(x: rect.minX + 10, y: rect.midY - icon.size().height / 2))
            let textX = rect.minX + 10 + max(icon.size().width, look.iconSize) + 7
            text.draw(at: NSPoint(x: textX, y: rect.midY - text.size().height / 2))
            newTabs.append((which, rect))
            x += width + 4
        }
        // The button that runs it again, next to Output; and at the far right the one that puts the pane away.
        func button(_ rect: NSRect, _ glyph: String, _ control: Control) {
            if hovered == control {
                look.selection.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            }
            let icon = NSAttributedString(string: glyph, attributes: [
                .font: iconFont, .foregroundColor: hovered == control ? look.text : look.muted,
            ])
            icon.draw(at: NSPoint(x: rect.midX - icon.size().width / 2, y: rect.midY - icon.size().height / 2))
        }
        let size = header - 8
        let newRebuild = NSRect(x: x + 4, y: 4, width: size, height: size)
        let newMinimize = NSRect(x: bounds.width - size - 8, y: 4, width: size, height: size)
        button(newRebuild, "\u{f021}", .rebuild)
        button(newMinimize, "\u{f068}", .minimize)
        let moved = newRebuild != rebuildRect || newMinimize != minimizeRect || newTabs.map(\.1) != tabFrames.map(\.1)
        rebuildRect = newRebuild
        minimizeRect = newMinimize
        tabFrames = newTabs
        if moved {
            window?.invalidateCursorRects(for: self)
            needsLayout = true
        }
    }

    // MARK: Pointing

    private func control(at point: NSPoint) -> Control? {
        if minimizeRect.contains(point) { return .minimize }
        if rebuildRect.contains(point) { return .rebuild }
        return tabFrames.first { $0.1.contains(point) }.map { .tab($0.0) }
    }

    /// The header's controls, where the pointer is a hand.
    func pointerRects() -> [NSRect] { tabFrames.map(\.1) + [rebuildRect, minimizeRect] }

    override func resetCursorRects() {
        pointerRects().filter { !$0.isEmpty }.forEach { addCursorRect($0, cursor: .pointingHand) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) { hover(control(at: convert(event.locationInWindow, from: nil))) }
    override func mouseExited(with _: NSEvent) { hover(nil) }

    func hover(_ control: Control?) {
        guard control != hovered else { return }
        hovered = control
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        switch control(at: convert(event.locationInWindow, from: nil)) {
        case .minimize: onMinimize?()
        case .rebuild: onRebuild?()
        case let .tab(which): select(which)
        case nil: window?.makeFirstResponder(focusView)
        }
    }
}
