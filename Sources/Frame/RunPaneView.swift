import AppKit
import FrameRun
import SillEditor

/// One thing that was run from the Run pane: its own terminal, what it ran, and how it is going.
final class RunSession {
    enum Status: Equatable { case running, exited(Int) }

    let id = UUID()
    var entry: RunEntry
    var terminal: NSView
    var screenText: () -> String?
    /// The file the command writes its exit code to when it ends.
    var marker: String
    var status = Status.running
    var started = Date()
    var duration: TimeInterval?

    init(entry: RunEntry, terminal: NSView, marker: String, screenText: @escaping () -> String?) {
        self.entry = entry
        self.terminal = terminal
        self.marker = marker
        self.screenText = screenText
    }

    /// "running", "exited 0 in 1.2 s".
    var summary: String {
        switch status {
        case .running: "running"
        case let .exited(code): "exited \(code)" + (duration.map { String(format: " in %.1f s", $0) } ?? "")
        }
    }
}

/// The Run pane, a pane and a mode (RUN) of its own, with tabs as the build pane has: Run, the list of everything the
/// folder can run (each row saying what kind it is and the file it comes from, with a pill for each origin to filter
/// by,
/// and the form for the person's own configurations in its place while one is made), and one Output tab for each thing
/// run,
/// several at once if you like. A tab says how its run is going, and when it has ended how it ended; the header has the
/// button to run it again. Once something is run, only its output shows. It takes the slot the build pane has when
/// shown.
final class RunPaneView: NSView {
    enum Selection: Equatable { case list, session(UUID) }

    enum Control: Equatable { case tab(Selection), close(UUID), new, rerun, minimize }

    var look: TreeLook {
        didSet {
            list.look = look
            form.look = look
            chipsView.look = look
            detail.font = look.smallFont
            detail.textColor = look.muted
            needsDisplay = true
        }
    }

    let list: ListPickerView
    let form = RunForm()
    /// A pill for each origin (make, npm, dotnet, VS Code, yours...) with how many it has: a click filters the list by
    /// it.
    let chipsView = ChipsView()
    private let detail = NSTextField(wrappingLabelWithString: "")
    private(set) var editing = false
    private(set) var selection = Selection.list
    private(set) var sessions: [RunSession] = []
    static let maxSessions = 8

    var onMinimize: (() -> Void)?
    var onNew: (() -> Void)?
    var onFocus: (() -> Void)?
    /// The header's run-again button, for the session whose output shows.
    var onRerun: ((RunSession) -> Void)?
    /// A session's tab closed: its run ends.
    var onClose: ((RunSession) -> Void)?

    private var tabFrames: [(Selection, NSRect)] = []
    private var closeFrames: [(UUID, NSRect)] = []
    private(set) var newRect = NSRect.zero
    private(set) var rerunRect = NSRect.zero
    private(set) var minimizeRect = NSRect.zero
    private var hovered: Control?
    private var loaders: [UUID: LoaderView] = [:]

    init(look: TreeLook) {
        self.look = look
        list = ListPickerView(title: "Run", look: look)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        list.embedded = true
        form.look = look
        form.isHidden = true
        chipsView.look = look
        detail.maximumNumberOfLines = 3
        detail.lineBreakMode = .byTruncatingTail
        detail.font = look.smallFont
        detail.textColor = look.muted
        addSubview(list)
        addSubview(detail)
        addSubview(form)
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

    /// The session whose output shows, if one does.
    var current: RunSession? {
        if case let .session(id) = selection { return sessions.first { $0.id == id } }
        return nil
    }

    /// Where the keyboard goes: the form's first field while one is made, else the output shown, else the list.
    var focusView: NSView { editing ? form.firstField : (current?.terminal ?? list) }

    // MARK: Sessions

    /// A run begins: its output has a tab, and shows. Past the most there can be, the oldest that has ended makes room.
    func add(_ session: RunSession) {
        if sessions.count >= Self.maxSessions, let old = sessions.first(where: { $0.status != .running }) { close(old) }
        sessions.append(session)
        addSubview(session.terminal)
        select(.session(session.id))
    }

    /// It runs again, in the same tab: the new terminal replaces the old.
    func restart(_ session: RunSession, terminal: NSView, marker: String, screenText: @escaping () -> String?) {
        session.terminal.removeFromSuperview()
        session.terminal = terminal
        session.marker = marker
        session.screenText = screenText
        session.status = .running
        session.started = Date()
        session.duration = nil
        addSubview(terminal)
        select(.session(session.id))
    }

    /// The command ended with `code`.
    func finish(_ session: RunSession, code: Int) {
        session.status = .exited(code)
        session.duration = Date().timeIntervalSince(session.started)
        needsDisplay = true
    }

    func close(_ session: RunSession) {
        session.terminal.removeFromSuperview()
        loaders[session.id]?.removeFromSuperview()
        loaders[session.id] = nil
        sessions.removeAll { $0 === session }
        if case .session(session.id) = selection { selection = .list }
        showCurrent()
        needsLayout = true
        needsDisplay = true
    }

    func select(_ selection: Selection) {
        self.selection = selection
        showCurrent()
        needsLayout = true
        needsDisplay = true
    }

    /// The form for a configuration (a copy, or a new one) in place of the list.
    func edit(_ config: RunConfig, isNew: Bool) {
        form.show(config, isNew: isNew)
        editing = true
        selection = .list
        showCurrent()
        needsLayout = true
    }

    func endEditing() {
        editing = false
        showCurrent()
        needsLayout = true
    }

    /// What the highlighted entry will do, in a line or two under the list.
    func setDetail(_ text: String) { detail.stringValue = text }

    private func showCurrent() {
        let onList = selection == .list
        list.isHidden = !onList || editing
        detail.isHidden = !onList || editing
        form.isHidden = !onList || !editing
        chipsView.isHidden = !onList || editing || chipsView.chips.isEmpty
        for session in sessions {
            session.terminal.isHidden = session.id != current?.id
        }
    }

    // MARK: Layout

    private var header: CGFloat { BuildPane.headerHeight(for: look) }

    override func layout() {
        super.layout()
        let body = NSRect(x: 0, y: header, width: bounds.width, height: max(0, bounds.height - header))
        let detailHeight: CGFloat = 46
        form.frame = body
        list.frame = NSRect(x: 0, y: body.minY, width: body.width, height: max(0, body.height - detailHeight))
        detail.frame = NSRect(
            x: 20, y: body.maxY - detailHeight + 4, width: max(0, body.width - 40), height: detailHeight - 8
        )
        for session in sessions {
            session.terminal.frame = body
        }
        // The origin pills fill what the tabs leave, up to the buttons.
        let from = (tabFrames.last?.1.maxX ?? 8) + 12
        let to = (newRect.isEmpty ? bounds.width - header : newRect.minX) - 6
        chipsView.frame = NSRect(x: from, y: 0, width: max(0, to - from), height: header)
        showCurrent()
        for (id, loader) in loaders {
            if let frame = tabFrames.first(where: { $0.0 == .session(id) })?.1 {
                loader.frame = NSRect(x: frame.minX + 10, y: frame.midY - 7, width: 14, height: 14)
            }
        }
        removeAllToolTips()
        for (index, rect) in [newRect, rerunRect, minimizeRect].enumerated() where !rect.isEmpty {
            addToolTip(rect, owner: self, userData: UnsafeMutableRawPointer(bitPattern: index + 1))
        }
    }

    @objc func view(
        _: NSView,
        stringForToolTip _: NSView.ToolTipTag,
        point _: NSPoint,
        userData: UnsafeMutableRawPointer?
    ) -> String {
        switch Int(bitPattern: userData) {
        case 1: "A new configuration of your own (n)"
        case 2: "Run it again"
        default: "Minimize"
        }
    }

    // MARK: Drawing

    override func draw(_: NSRect) {
        look.island.setFill()
        bounds.fill()
        let iconFont = NerdFont.font(size: look.iconSize - 1) ?? look.smallFont
        var newTabs: [(Selection, NSRect)] = []
        var newCloses: [(UUID, NSRect)] = []
        var x: CGFloat = 8
        func pill(_ rect: NSRect, selected: Bool, hovering: Bool) {
            if selected {
                look.focusedSelection.setFill()
            } else if hovering {
                look.selection.setFill()
            } else { return }
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        }
        // The list's tab.
        do {
            let selected = selection == .list
            let color = selected ? look.text : look.muted
            let icon = NSAttributedString(string: "\u{f04b}", attributes: [.font: iconFont, .foregroundColor: color])
            let text = NSAttributedString(string: "Run", attributes: [.font: look.font, .foregroundColor: color])
            let width = 10 + max(icon.size().width, look.iconSize) + 7 + ceil(text.size().width) + 12
            let rect = NSRect(x: x, y: 4, width: width, height: header - 8)
            pill(rect, selected: selected, hovering: hovered == .tab(.list))
            icon.draw(at: NSPoint(x: rect.minX + 10, y: rect.midY - icon.size().height / 2))
            text.draw(at: NSPoint(
                x: rect.minX + 10 + max(icon.size().width, look.iconSize) + 7, y: rect.midY - text.size().height / 2
            ))
            newTabs.append((.list, rect))
            x += width + 4
        }
        // One tab for each run: how it is going, what it ran, a cross to close it.
        for session in sessions {
            let selection = Selection.session(session.id)
            let selected = self.selection == selection
            let color = selected ? look.text : look.muted
            var label = session.entry.title
            if label.count > 22 { label = String(label.prefix(21)) + "…" }
            let text = NSAttributedString(string: label, attributes: [.font: look.font, .foregroundColor: color])
            let width = 10 + 14 + 7 + ceil(text.size().width) + 8 + 14 + 8
            let rect = NSRect(x: x, y: 4, width: width, height: header - 8)
            pill(rect, selected: selected, hovering: hovered == .tab(selection) || hovered == .close(session.id))
            switch session.status {
            case .running:
                if loaders[session.id] == nil {
                    let loader = LoaderView(.spinner)
                    loaders[session.id] = loader
                    addSubview(loader)
                }
                loaders[session.id]?.isHidden = false
            case let .exited(code):
                loaders[session.id]?.isHidden = true
                let ok = code == 0
                let mark = NSAttributedString(string: ok ? "\u{f00c}" : "\u{f00d}", attributes: [
                    .font: iconFont, .foregroundColor: ok ? NSColor.systemGreen : NSColor.systemRed,
                ])
                mark.draw(at: NSPoint(x: rect.minX + 10, y: rect.midY - mark.size().height / 2))
            }
            text.draw(at: NSPoint(x: rect.minX + 10 + 14 + 7, y: rect.midY - text.size().height / 2))
            let cross = NSRect(x: rect.maxX - 8 - 14, y: rect.midY - 7, width: 14, height: 14)
            let mark = NSAttributedString(string: "\u{f00d}", attributes: [
                .font: iconFont, .foregroundColor: hovered == .close(session.id) ? look.text : look.faint,
            ])
            mark.draw(at: NSPoint(x: cross.midX - mark.size().width / 2, y: cross.midY - mark.size().height / 2))
            newTabs.append((selection, rect))
            newCloses.append((session.id, cross))
            x += width + 4
        }
        // Buttons at the right: the pane's own, and what belongs to the tab that shows.
        func button(_ rect: NSRect, _ glyph: String, _ control: Control) {
            if hovered == control {
                look.selection.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            }
            let mark = NSAttributedString(string: glyph, attributes: [
                .font: iconFont, .foregroundColor: hovered == control ? look.text : look.muted,
            ])
            mark.draw(at: NSPoint(x: rect.midX - mark.size().width / 2, y: rect.midY - mark.size().height / 2))
        }
        let size = header - 8
        let newMinimize = NSRect(x: bounds.width - size - 8, y: 4, width: size, height: size)
        button(newMinimize, "\u{f068}", .minimize)
        var newNew = NSRect.zero, newRerun = NSRect.zero
        if let session = current {
            newRerun = NSRect(x: newMinimize.minX - size - 4, y: 4, width: size, height: size)
            button(newRerun, "\u{f021}", .rerun)
            // How it is going: running, or the exit code and how long it took.
            let ok = session.status == .exited(0)
            let color: NSColor = session.status == .running ? look.muted : (ok ? .systemGreen : .systemRed)
            let text = NSAttributedString(
                string: session.summary,
                attributes: [.font: look.smallFont, .foregroundColor: color]
            )
            text.draw(at: NSPoint(x: newRerun.minX - 10 - text.size().width, y: (header - text.size().height) / 2))
        } else {
            newNew = NSRect(x: newMinimize.minX - size - 4, y: 4, width: size, height: size)
            button(newNew, "\u{f067}", .new)
        }
        let moved = newTabs.map(\.1) != tabFrames.map(\.1) || newNew != newRect || newRerun != rerunRect
            || newMinimize != minimizeRect
        tabFrames = newTabs
        closeFrames = newCloses
        newRect = newNew
        rerunRect = newRerun
        minimizeRect = newMinimize
        if moved {
            window?.invalidateCursorRects(for: self)
            needsLayout = true
        }
    }

    // MARK: Pointing

    private func control(at point: NSPoint) -> Control? {
        if minimizeRect.contains(point) { return .minimize }
        if rerunRect.contains(point) { return .rerun }
        if newRect.contains(point) { return .new }
        if let hit = closeFrames.first(where: { $0.1.insetBy(dx: -3, dy: -3).contains(point) }) { return .close(hit.0) }
        return tabFrames.first { $0.1.contains(point) }.map { .tab($0.0) }
    }

    func pointerRects() -> [NSRect] { tabFrames.map(\.1) + closeFrames.map(\.1) + [newRect, rerunRect, minimizeRect] }

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
        case .new: onNew?()
        case .rerun: if let session = current { onRerun?(session) }
        case let .close(id): if let session = sessions.first(where: { $0.id == id }) { onClose?(session) }
        case let .tab(selection): select(selection)
        case nil: window?.makeFirstResponder(focusView)
        }
    }
}
