import AppKit
import FrameModes
import FrameTree
import SillEditor

/// The status bar's list of open files, a card over the window above the file's name: the editor's font, the tree's
/// colours, the file's icon in its colour, the colour scheme's selection on the row the keyboard is on. ↑ ↓ (or j k)
/// move,
/// Return shows the file, x (or ⌫, ⌘W) closes it, Escape goes back; a click on a row shows it, on its mark closes it,
/// outside the card puts it away.
@MainActor
final class TabPickerView: NSView {
    var look: TreeLook {
        didSet { apply() }
    }

    let list = TabsView(axis: .vertical)
    var onChoose: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onDismiss: (() -> Void)?
    /// Where the card sits: its left edge, and the line it stands on (the top of the status bar), in this view's
    /// coordinates.
    var anchor = NSPoint.zero {
        didSet { needsLayout = true }
    }

    private let card = FlippedView()
    private(set) var tabs: [FrameTab] = []
    /// The tab the keyboard is on.
    private(set) var cursor: Int?
    private static let maxRows = 10

    init(look: TreeLook) {
        self.look = look
        super.init(frame: .zero)
        wantsLayer = true
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.borderWidth = 1
        card.layer?.shadowOpacity = 0.4
        card.layer?.shadowRadius = 22
        card.layer?.shadowOffset = CGSize(width: 0, height: 8)
        addSubview(card)
        list.largeText = true
        list.drawsHairline = false
        card.addSubview(list)
        list.onSelect = { [weak self] id in self?.onChoose?(id) }
        list.onClose = { [weak self] id in self?.onClose?(id) }
        apply()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private func apply() {
        card.layer?.backgroundColor = look.island.cgColor
        card.layer?.borderColor = look.muted.withAlphaComponent(0.35).cgColor
        list.look = look
        needsLayout = true
    }

    /// The tabs as they are now; the keyboard stays on the tab it was on, else on the shown one.
    func set(_ tabs: [FrameTab]) {
        self.tabs = tabs
        if cursor == nil || !tabs
            .contains(where: { $0.id == cursor }) { cursor = tabs.first(where: \.current)?.id ?? tabs.first?.id }
        list.tabs = tabs
        list.highlightedID = cursor
        if let cursor { list.reveal(cursor) }
        needsLayout = true
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let labels = Tabs.labels(tabs)
        let widest = labels.values.map { ($0 as NSString).size(withAttributes: [.font: look.font]).width }.max() ?? 120
        let width = min(max(300, ceil(widest) + 110), min(480, bounds.width - 24))
        let rows = CGFloat(min(max(tabs.count, 1), Self.maxRows))
        let height = rows * ceil(list.rowHeight) + 12
        let x = min(max(12, anchor.x), max(12, bounds.width - width - 12))
        let y = max(12, anchor.y - height - 8)
        card.frame = NSRect(x: x, y: y, width: width, height: height)
        list.frame = NSRect(x: 0, y: 6, width: width, height: height - 12)
    }

    override func mouseDown(with event: NSEvent) {
        if !card.frame.contains(convert(event.locationInWindow, from: nil)) { onDismiss?() }
    }

    // MARK: Keys

    private func move(by step: Int) {
        guard !tabs.isEmpty else { return }
        let at = tabs.firstIndex { $0.id == cursor } ?? 0
        cursor = tabs[min(max(at + step, 0), tabs.count - 1)].id
        list.highlightedID = cursor
        if let cursor { list.reveal(cursor) }
    }

    override func keyDown(with event: NSEvent) {
        let characters = event.charactersIgnoringModifiers ?? ""
        switch (event.keyCode, characters) {
        case (125, _), (_, "j"): move(by: 1)
        case (126, _), (_, "k"): move(by: -1)
        case (36, _), (76, _), (_, " "): if let cursor { onChoose?(cursor) }
        case (53, _): onDismiss?()
        case (51, _), (117, _), (_, "x"): if let cursor { onClose?(cursor) }
        case (_, "w") where event.modifierFlags.contains(.command): if let cursor { onClose?(cursor) }
        default: break
        }
    }
}
