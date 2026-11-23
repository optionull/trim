import AppKit
import SillEditor
import TrimModes
import TrimTree
import TrimWorkspaces

/// The status bar's list of open files, a card over the window above the file's name: the editor's font, the tree's
/// colours, the file's icon in its colour, the colour scheme's selection on the row the keyboard is on. ↑ ↓ (or j k)
/// move,
/// Return shows the file, x (or ⌫, ⌘W) closes it, `/` filters them by typing (j and k then type; Escape ends the
/// filter, and the next goes back), Escape goes back; a click on a row shows it, on its mark closes it,
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
    /// A filter began (true) or ended: the window's modes say what Escape does meanwhile.
    var onFilterChange: ((Bool) -> Void)?
    /// Where the card sits: its left edge, and the line it stands on (the top of the status bar), in this view's
    /// coordinates.
    var anchor = NSPoint.zero {
        didSet { needsLayout = true }
    }

    private let card = FlippedView()
    private let header = FlippedView()
    private let divider = FlippedView()
    private let filterText = NSTextField(labelWithString: "")
    private let filterCount = NSTextField(labelWithString: "")
    /// Every open file, and those showing (all of them, or what the filter finds).
    private(set) var tabs: [TrimTab] = []
    private(set) var visible: [TrimTab] = []
    /// What is typed while filtering; nil when browsing.
    private(set) var filter: String?
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
        card.addSubview(header)
        for label in [filterText, filterCount] {
            label.isBordered = false
            label.drawsBackground = false
            label.lineBreakMode = .byTruncatingHead
            header.addSubview(label)
        }
        divider.wantsLayer = true
        header.addSubview(divider)
        header.isHidden = true
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
        filterText.font = look.font
        filterText.textColor = look.text
        filterCount.font = look.smallFont
        filterCount.textColor = look.faint
        divider.layer?.backgroundColor = look.muted.withAlphaComponent(0.25).cgColor
        needsLayout = true
    }

    /// The tabs as they are now; the keyboard stays on the tab it was on, else on the shown one.
    func set(_ tabs: [TrimTab]) {
        self.tabs = tabs
        refilter()
    }

    /// What shows: every tab, or those whose names the filter finds, the best first.
    private func refilter() {
        let labels = Tabs.labels(tabs)
        if let filter, !filter.isEmpty {
            visible = tabs.enumerated().compactMap { index, tab -> (Int, Int, TrimTab)? in
                Fuzzy.match(filter, in: labels[tab.id] ?? tab.name).map { ($0.score, index, tab) }
            }.sorted { ($0.0, $1.1) > ($1.0, $0.1) }.map(\.2)
        } else {
            visible = tabs
        }
        if cursor == nil || !visible.contains(where: { $0.id == cursor }) {
            cursor = visible.first(where: \.current)?.id ?? visible.first?.id
        }
        list.tabs = visible
        list.highlightedID = cursor
        if let cursor { list.reveal(cursor) }
        header.isHidden = filter == nil
        filterText.stringValue = "/" + (filter ?? "") + "▏"
        filterCount.stringValue = "\(visible.count) of \(tabs.count)"
        needsLayout = true
    }

    /// The filter on (typing narrows the list), or off (j and k move).
    private func beginFilter() {
        filter = ""
        refilter()
        onFilterChange?(true)
    }

    /// The filter ends and every tab shows again (the window's modes have already said Escape ended it).
    func endFilter() {
        filter = nil
        refilter()
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let labels = Tabs.labels(tabs)
        let widest = labels.values.map { ($0 as NSString).size(withAttributes: [.font: look.font]).width }.max() ?? 120
        let width = min(max(300, ceil(widest) + 110), min(480, bounds.width - 24))
        let rows = CGFloat(min(max(visible.count, 1), Self.maxRows))
        let headerHeight: CGFloat = filter == nil ? 0 : ceil(look.rowHeight) + 16
        let height = headerHeight + rows * ceil(list.rowHeight) + 12
        let x = min(max(12, anchor.x), max(12, bounds.width - width - 12))
        let y = max(12, anchor.y - height - 8)
        card.frame = NSRect(x: x, y: y, width: width, height: height)
        header.frame = NSRect(x: 0, y: 0, width: width, height: headerHeight)
        divider.frame = NSRect(x: 0, y: headerHeight - 1, width: width, height: 1)
        let textHeight = ceil(look.font.ascender - look.font.descender + look.font.leading)
        filterCount.sizeToFit()
        filterCount.frame.origin = NSPoint(
            x: width - 16 - filterCount.frame.width,
            y: (headerHeight - filterCount.frame.height) / 2
        )
        filterText.frame = NSRect(
            x: 16, y: (headerHeight - textHeight) / 2, width: max(0, filterCount.frame.minX - 24), height: textHeight
        )
        list.frame = NSRect(x: 0, y: headerHeight + 6, width: width, height: max(0, height - headerHeight - 12))
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
        let command = event.modifierFlags.contains(.command), control = event.modifierFlags.contains(.control)
        if filter != nil {
            // Typing: letters (j, k and x too) go into the filter; the arrows and Control-n and p move.
            switch (event.keyCode, characters) {
            case (125, _): move(by: 1)
            case (126, _): move(by: -1)
            case (_, "n") where control: move(by: 1)
            case (_, "p") where control: move(by: -1)
            case (36, _), (76, _): if let cursor { onChoose?(cursor) }
            case (53, _): onDismiss?()
            case (51, _): typeBackspace()
            case (_, "w") where command: if let cursor { onClose?(cursor) }
            default:
                if !command, !control, let typed = event.characters,
                   typed.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 })
                {
                    filter = (filter ?? "") + typed
                    refilter()
                }
            }
            return
        }
        switch (event.keyCode, characters) {
        case (125, _), (_, "j"): move(by: 1)
        case (126, _), (_, "k"): move(by: -1)
        case (36, _), (76, _), (_, " "): if let cursor { onChoose?(cursor) }
        case (53, _): onDismiss?()
        case (51, _), (117, _), (_, "x"): if let cursor { onClose?(cursor) }
        case (_, "/"): beginFilter()
        case (_, "w") where command: if let cursor { onClose?(cursor) }
        default: break
        }
    }

    private func typeBackspace() {
        guard var text = filter, !text.isEmpty else { return }
        text.removeLast()
        filter = text
        refilter()
    }
}
