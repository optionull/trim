import AppKit
import FrameRun
import SillEditor

/// The pane beside or under the code for building and running: one header in the style of the file tabs, with two tabs,
/// Problems (every diagnostic and what the build printed, as a list) and Output (a real terminal that stays after the
/// command ends), a button to run it again, and at the right the toggle for each level of problem and the button that
/// puts the pane away. Its keys and its mode (BUILD) are the window's (`FrameWindowController`).
final class BuildPane: NSView {
    enum Tab { case output, problems, run }

    /// Something in the header that can be pointed at.
    enum Control: Equatable { case tab(Tab), rebuild, minimize, scope(ProblemScope) }

    var look: TreeLook {
        didSet {
            problems.look = look
            runList.look = look
            form.look = look
            runDetail.font = look.smallFont
            runDetail.textColor = look.muted
            chipsView.look = look
            hint.textColor = look.faint
            hint.font = look.font
            needsDisplay = true
        }
    }

    /// The problems, as a list that is part of the pane (it filters, goes to a problem on Return, has Alt+Enter).
    let problems: ListPickerView
    /// What can be run, each with where it comes from; and the form for the person's own, which replaces it while one
    /// is made.
    let runList: ListPickerView
    let form = RunForm()
    private let runDetail = NSTextField(wrappingLabelWithString: "")
    /// Whether the form is showing (instead of the list).
    private(set) var editing = false
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

    /// How much the Problems list covers (this file, its folder, all of it), chosen in the header.
    var scope = ProblemScope.project {
        didSet { if scope != oldValue { needsDisplay = true } }
    }

    var onScope: ((ProblemScope) -> Void)?

    /// Language servers are working (loading projects, analysing files): problems are still arriving. A loader turns on
    /// the Problems tab until they are done, so they do not come as a surprise.
    var loading = false {
        didSet {
            guard loading != oldValue else { return }
            loader.isHidden = !loading
            needsDisplay = true
        }
    }

    private let loader = LoaderView(.spinner)
    /// Whether the loader on the Problems tab is turning (for the self-check).
    var showsLoader: Bool { !loader.isHidden && loader.isGoing }
    private var loaderAt = NSRect.zero
    private(set) var scopeRects: [(ProblemScope, NSRect)] = []

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
        runList = ListPickerView(title: "Run", look: look)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        problems.embedded = true
        runList.embedded = true
        form.look = look
        form.isHidden = true
        runDetail.maximumNumberOfLines = 3
        runDetail.lineBreakMode = .byTruncatingTail
        runDetail.font = look.smallFont
        runDetail.textColor = look.muted
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
        addSubview(runList)
        addSubview(runDetail)
        addSubview(form)
        addSubview(hint)
        addSubview(chipsView)
        loader.isHidden = true
        addSubview(loader)
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
        runList.isHidden = tab != .run || editing
        runDetail.isHidden = tab != .run || editing
        form.isHidden = tab != .run || !editing
        hint.isHidden = !showsHint
    }

    /// Shows the form for a configuration (a copy, or a new one) in the Run tab.
    func edit(_ config: RunConfig, isNew: Bool) {
        form.show(config, isNew: isNew)
        editing = true
        select(.run)
    }

    /// The form is put away: the list again.
    func endEditing() {
        editing = false
        showSelectedTab()
        needsLayout = true
    }

    /// What the highlighted entry runs, where and with what, in a line or two under the list.
    func setDetail(_ text: String) { runDetail.stringValue = text }

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
        case .run: editing ? form.firstField : runList
        }
    }

    override func layout() {
        super.layout()
        let header = Self.headerHeight(for: look)
        let body = NSRect(x: 0, y: header, width: bounds.width, height: max(0, bounds.height - header))
        terminal?.frame = body
        problems.frame = body
        form.frame = body
        let detailHeight: CGFloat = 46
        runList.frame = NSRect(x: 0, y: body.minY, width: body.width, height: max(0, body.height - detailHeight))
        runDetail.frame = NSRect(
            x: 20,
            y: body.maxY - detailHeight + 4,
            width: max(0, body.width - 40),
            height: detailHeight - 8
        )
        showSelectedTab()
        hint.frame = NSRect(
            x: 24,
            y: header + max(0, body.height / 2 - 40),
            width: max(0, bounds.width - 48),
            height: 80
        )
        // The toggles fill what the tabs and the rebuild button leave, up to the minimize button.
        let from = (rebuildRect.isEmpty ? 8 : rebuildRect.maxX) + 12
        let to = Self.scopeGroup(in: bounds, header: header).minX - 10
        chipsView.frame = NSRect(x: from, y: 0, width: max(0, to - from), height: header)
        chipsView.isHidden = problems.chips.isEmpty || to - from < 60
        updateToolTips()
    }

    /// The three scope buttons as a group, from the right: left of the minimize button.
    static func scopeGroup(in bounds: NSRect, header: CGFloat) -> NSRect {
        let size = header - 8
        let width = CGFloat(ProblemScope.allCases.count) * size + CGFloat(ProblemScope.allCases.count - 1) * 2
        return NSRect(x: bounds.width - size - 8 - 12 - width, y: 4, width: width, height: size)
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
            (.run, "Run", "\u{f04b}"),
        ]
        for (which, name, glyph) in tabs {
            let selected = which == tab
            let color = selected ? look.text : look.muted
            let icon = NSAttributedString(string: glyph, attributes: [.font: iconFont, .foregroundColor: color])
            let text = NSAttributedString(string: name, attributes: [.font: look.font, .foregroundColor: color])
            let extra: CGFloat = which == .problems && loading ? 20 : 0
            let width = 10 + max(icon.size().width, look.iconSize) + 7 + ceil(text.size().width) + 12 + extra
            let rect = NSRect(x: x, y: 4, width: width, height: header - 8)
            if which == .problems { loaderAt = NSRect(x: rect.maxX - 12 - 14, y: rect.midY - 6, width: 12, height: 12) }
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
        // How much the list covers: three buttons, the one in use filled like a selected tab.
        let group = Self.scopeGroup(in: bounds, header: header)
        var newScopes: [(ProblemScope, NSRect)] = []
        var gx = group.minX
        for which in ProblemScope.allCases {
            let rect = NSRect(x: gx, y: group.minY, width: size, height: size)
            if which == scope {
                look.focusedSelection.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            } else if hovered == .scope(which) {
                look.selection.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            }
            let icon = NSAttributedString(string: which.glyph, attributes: [
                .font: iconFont, .foregroundColor: which == scope ? look.text : look.muted,
            ])
            icon.draw(at: NSPoint(x: rect.midX - icon.size().width / 2, y: rect.midY - icon.size().height / 2))
            newScopes.append((which, rect))
            gx += size + 2
        }
        scopeRects = newScopes
        if loading, loader.frame != loaderAt { loader.frame = loaderAt }
        let moved = newRebuild != rebuildRect || newMinimize != minimizeRect || newTabs.map(\.1) != tabFrames.map(\.1)
            || newScopes.map(\.1) != scopeRects.map(\.1)
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
        if let hit = scopeRects.first(where: { $0.1.contains(point) }) { return .scope(hit.0) }
        return tabFrames.first { $0.1.contains(point) }.map { .tab($0.0) }
    }

    /// The header's controls, where the pointer is a hand.
    func pointerRects() -> [NSRect] { tabFrames.map(\.1) + scopeRects.map(\.1) + [rebuildRect, minimizeRect] }

    override func resetCursorRects() {
        pointerRects().filter { !$0.isEmpty }.forEach { addCursorRect($0, cursor: .pointingHand) }
    }

    /// What each control is called, as its tooltip.
    private func updateToolTips() {
        removeAllToolTips()
        for (which, rect) in scopeRects {
            addToolTip(
                rect,
                owner: self,
                userData: UnsafeMutableRawPointer(bitPattern: 1 + (ProblemScope.allCases.firstIndex(of: which) ?? 0))
            )
        }
        if !rebuildRect
            .isEmpty { addToolTip(rebuildRect, owner: self, userData: UnsafeMutableRawPointer(bitPattern: 10)) }
        if !minimizeRect.isEmpty { addToolTip(
            minimizeRect,
            owner: self,
            userData: UnsafeMutableRawPointer(bitPattern: 11)
        ) }
    }

    @objc func view(
        _: NSView,
        stringForToolTip _: NSView.ToolTipTag,
        point _: NSPoint,
        userData: UnsafeMutableRawPointer?
    ) -> String {
        switch Int(bitPattern: userData) {
        case 1 ... 3: "Problems: " + ProblemScope.allCases[Int(bitPattern: userData) - 1].title.lowercased()
        case 10: "Run it again"
        case 11: "Minimize"
        default: ""
        }
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
        case let .scope(which): onScope?(which)
        case nil: window?.makeFirstResponder(focusView)
        }
    }
}
