import AppKit
import FrameRun
import SillEditor

/// The Run pane, a pane and a mode (RUN) of its own: everything the folder can run, each row saying what kind it is and
/// the file it comes from, the highlighted one's command, folder and environment under the list, and the form for the
/// person's own configurations in its place while one is made or changed. It takes the slot the build pane has when it
/// is
/// shown (what is run goes to the build pane, which comes back for it).
final class RunPaneView: NSView {
    var look: TreeLook {
        didSet {
            list.look = look
            form.look = look
            detail.font = look.smallFont
            detail.textColor = look.muted
            needsDisplay = true
        }
    }

    let list: ListPickerView
    let form = RunForm()
    private let detail = NSTextField(wrappingLabelWithString: "")
    private(set) var editing = false

    /// The minimize button: the pane goes away.
    var onMinimize: (() -> Void)?
    /// The new button: a configuration made from nothing.
    var onNew: (() -> Void)?
    var onFocus: (() -> Void)?

    enum Control: Equatable { case new, minimize }
    private(set) var newRect = NSRect.zero
    private(set) var minimizeRect = NSRect.zero
    private var hovered: Control?

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
        detail.maximumNumberOfLines = 3
        detail.lineBreakMode = .byTruncatingTail
        detail.font = look.smallFont
        detail.textColor = look.muted
        addSubview(list)
        addSubview(detail)
        addSubview(form)
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

    /// Where the keyboard goes: the form's first field while one is made, else the list.
    var focusView: NSView { editing ? form.firstField : list }

    /// The form for a configuration (a copy, or a new one) in place of the list.
    func edit(_ config: RunConfig, isNew: Bool) {
        form.show(config, isNew: isNew)
        editing = true
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
        list.isHidden = editing
        detail.isHidden = editing
        form.isHidden = !editing
    }

    override func layout() {
        super.layout()
        let header = BuildPane.headerHeight(for: look)
        let body = NSRect(x: 0, y: header, width: bounds.width, height: max(0, bounds.height - header))
        let detailHeight: CGFloat = 46
        form.frame = body
        list.frame = NSRect(x: 0, y: body.minY, width: body.width, height: max(0, body.height - detailHeight))
        detail.frame = NSRect(
            x: 20,
            y: body.maxY - detailHeight + 4,
            width: max(0, body.width - 40),
            height: detailHeight - 8
        )
        showCurrent()
        removeAllToolTips()
        if !newRect.isEmpty { addToolTip(newRect, owner: self, userData: UnsafeMutableRawPointer(bitPattern: 1)) }
        if !minimizeRect.isEmpty { addToolTip(
            minimizeRect,
            owner: self,
            userData: UnsafeMutableRawPointer(bitPattern: 2)
        ) }
    }

    @objc func view(
        _: NSView,
        stringForToolTip _: NSView.ToolTipTag,
        point _: NSPoint,
        userData: UnsafeMutableRawPointer?
    ) -> String {
        Int(bitPattern: userData) == 1 ? "A new configuration of your own (n)" : "Minimize"
    }

    override func draw(_: NSRect) {
        look.island.setFill()
        bounds.fill()
        let header = BuildPane.headerHeight(for: look)
        let iconFont = NerdFont.font(size: look.iconSize - 1) ?? look.smallFont
        // The pane's name, as a tab is drawn (it is the one thing here).
        let icon = NSAttributedString(string: "\u{f04b}", attributes: [.font: iconFont, .foregroundColor: look.text])
        let text = NSAttributedString(string: "Run", attributes: [.font: look.font, .foregroundColor: look.text])
        let width = 10 + max(icon.size().width, look.iconSize) + 7 + ceil(text.size().width) + 12
        let pill = NSRect(x: 8, y: 4, width: width, height: header - 8)
        look.focusedSelection.setFill()
        NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
        icon.draw(at: NSPoint(x: pill.minX + 10, y: pill.midY - icon.size().height / 2))
        text.draw(at: NSPoint(
            x: pill.minX + 10 + max(icon.size().width, look.iconSize) + 7,
            y: pill.midY - text.size().height / 2
        ))
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
        let newNew = NSRect(x: newMinimize.minX - size - 4, y: 4, width: size, height: size)
        button(newNew, "\u{f067}", .new)
        button(newMinimize, "\u{f068}", .minimize)
        if newNew != newRect || newMinimize != minimizeRect {
            newRect = newNew
            minimizeRect = newMinimize
            window?.invalidateCursorRects(for: self)
            needsLayout = true
        }
    }

    private func control(at point: NSPoint) -> Control? {
        if minimizeRect.contains(point) { return .minimize }
        if newRect.contains(point) { return .new }
        return nil
    }

    func pointerRects() -> [NSRect] { [newRect, minimizeRect] }

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
        case nil: window?.makeFirstResponder(focusView)
        }
    }
}
