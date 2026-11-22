import AppKit
import FrameTree
import FrameWorkspaces
import SillEditor

/// One choice in a `ListPickerView`.
struct PickerItem: Equatable {
    var id: String
    var title: String
    /// Quieter, at the right (a kind, a version).
    var detail = ""
    /// A Nerd Font glyph before the title, if any.
    var glyph = ""
    /// A file's name, to take the icon from (the tree's, in colour).
    var file: String?
    /// What is chosen now: marked with a dot.
    var isCurrent = false
}

/// The rows of a `ListPickerView`: the keyboard's row on the colour scheme's selection fill, the rest quiet, in the
/// editor's font as the tree has it.
final class PickerRowsView: NSView {
    var look = TreeLook() {
        didSet { needsDisplay = true }
    }

    var items: [PickerItem] = [] {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }

    var cursor: String? {
        didSet { needsDisplay = true }
    }

    var onChoose: ((String) -> Void)?
    private var offset: CGFloat = 0
    private var hovered: String?

    var rowHeight: CGFloat { max(look.rowHeight + 4, 24) }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    func pointerRects() -> [NSRect] { items.isEmpty ? [] : [bounds] }

    override func resetCursorRects() {
        pointerRects().forEach { addCursorRect($0, cursor: .pointingHand) }
    }

    override func layout() {
        super.layout()
        window?.invalidateCursorRects(for: self)
    }

    /// Scrolls so the row shows.
    func reveal(_ id: String) {
        guard let at = items.firstIndex(where: { $0.id == id }) else { return }
        let top = CGFloat(at) * rowHeight
        if top - offset < 0 { offset = top }
        if top + rowHeight - offset > bounds.height { offset = top + rowHeight - bounds.height }
        offset = max(0, offset)
        needsDisplay = true
    }

    override func draw(_: NSRect) {
        offset = min(max(offset, 0), max(0, CGFloat(items.count) * rowHeight - bounds.height))
        let iconFont = NerdFont.font(size: look.iconSize - 1) ?? look.smallFont
        for (index, item) in items.enumerated() {
            let rect = NSRect(x: 0, y: CGFloat(index) * rowHeight - offset, width: bounds.width, height: rowHeight)
            guard rect.intersects(bounds) else { continue }
            if item.id == cursor {
                look.focusedSelection.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 6, dy: 0), xRadius: 6, yRadius: 6).fill()
            } else if item.id == hovered {
                look.selection.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 6, dy: 0), xRadius: 6, yRadius: 6).fill()
            }
            var x: CGFloat = 18
            let fileIcon = item.file.map { FileIcons.icon(name: $0, isDirectory: false) }
            if !item.glyph.isEmpty || fileIcon != nil {
                let glyph = NSAttributedString(
                    string: fileIcon.map { String($0.glyph) } ?? item.glyph,
                    attributes: [
                        .font: iconFont,
                        .foregroundColor: fileIcon.map { TreeCellView.color($0.tint, look: look) } ?? look.muted,
                    ]
                )
                glyph.draw(at: NSPoint(x: x, y: rect.midY - glyph.size().height / 2))
                x += max(glyph.size().width, look.iconSize) + 8
            }
            var right = bounds.width - 18
            if !item.detail.isEmpty {
                let detail = NSAttributedString(
                    string: item.detail, attributes: [.font: look.smallFont, .foregroundColor: look.faint]
                )
                right -= ceil(detail.size().width)
                detail.draw(at: NSPoint(x: right, y: rect.midY - detail.size().height / 2))
                right -= 12
            }
            if item.isCurrent {
                let dot = NSAttributedString(
                    string: "●", attributes: [.font: look.smallFont, .foregroundColor: Design.accent]
                )
                right -= ceil(dot.size().width)
                dot.draw(at: NSPoint(x: right, y: rect.midY - dot.size().height / 2))
                right -= 10
            }
            let color = item.id == cursor || item.isCurrent ? look.text : look.muted
            let title = NSAttributedString(string: item.title, attributes: [.font: look.font, .foregroundColor: color])
            title.draw(
                with: NSRect(
                    x: x,
                    y: rect.midY - title.size().height / 2,
                    width: max(0, right - x),
                    height: title.size().height
                ),
                options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin]
            )
        }
    }

    private func item(at point: NSPoint) -> PickerItem? {
        let index = Int((point.y + offset) / rowHeight)
        return items.indices.contains(index) ? items[index] : nil
    }

    override func mouseDown(with event: NSEvent) {
        if let item = item(at: convert(event.locationInWindow, from: nil)) { onChoose?(item.id) }
    }

    override func scrollWheel(with event: NSEvent) {
        let before = offset
        offset = min(
            max(offset - event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 8), 0),
            max(0, CGFloat(items.count) * rowHeight - bounds.height)
        )
        if offset != before { needsDisplay = true }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        let found = item(at: convert(event.locationInWindow, from: nil))?.id
        if found != hovered {
            hovered = found
            needsDisplay = true
        }
    }

    override func mouseExited(with _: NSEvent) {
        hovered = nil
        needsDisplay = true
    }
}

/// A list of choices as a mode: a card over the window, a heading and the choices under it, in the tree's font and
/// colours.
/// ↑ ↓ (or j k) move the keyboard, Return chooses, Escape goes back; `/` filters by typing (j and k then type; Escape
/// ends the filter, and the next goes back). Moving the keyboard is told (`onMove`), so a choice can be tried as it is
/// passed (a colour scheme).
@MainActor
final class ListPickerView: NSView {
    var look: TreeLook {
        didSet { apply() }
    }

    let rows = PickerRowsView()
    var onMove: ((PickerItem) -> Void)?
    var onChoose: ((PickerItem) -> Void)?
    var onDismiss: (() -> Void)?
    var onFilterChange: ((Bool) -> Void)?
    /// A list that asks as you type (the finder): the text goes to `onQuery`, and what the owner answers with (`set`)
    /// is
    /// what shows, not a filtering of what is there. It is always typing: j and k are letters, Escape goes back at
    /// once.
    var liveQuery = false {
        didSet { if liveQuery, filter == nil { filter = "" } }
    }

    var onQuery: ((String) -> Void)?
    private let card = FlippedView()
    private let header = FlippedView()
    private let divider = FlippedView()
    private let heading = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private let title: String
    private(set) var all: [PickerItem] = []
    private(set) var visible: [PickerItem] = []
    private(set) var cursor: String?
    private(set) var filter: String?
    private static let maxRows = 12

    init(title: String, look: TreeLook) {
        self.title = title
        self.look = look
        super.init(frame: .zero)
        wantsLayer = true
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.borderWidth = 1
        card.layer?.shadowOpacity = 0.4
        card.layer?.shadowRadius = 24
        card.layer?.shadowOffset = CGSize(width: 0, height: 8)
        addSubview(card)
        card.addSubview(header)
        for label in [heading, count] {
            label.isBordered = false
            label.drawsBackground = false
            header.addSubview(label)
        }
        heading.lineBreakMode = .byTruncatingHead
        divider.wantsLayer = true
        header.addSubview(divider)
        card.addSubview(rows)
        rows.onChoose = { [weak self] id in
            guard let self, let item = all.first(where: { $0.id == id }) else { return }
            onChoose?(item)
        }
        apply()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private func apply() {
        card.layer?.backgroundColor = look.island.cgColor
        card.layer?.borderColor = look.muted.withAlphaComponent(0.35).cgColor
        divider.layer?.backgroundColor = look.muted.withAlphaComponent(0.25).cgColor
        heading.font = look.font
        count.font = look.smallFont
        count.textColor = look.faint
        rows.look = look
        updateHeading()
        needsLayout = true
    }

    private func updateHeading() {
        if liveQuery {
            heading.stringValue = title + "  " + (filter ?? "") + "▏"
            heading.textColor = look.text
        } else if let filter {
            heading.stringValue = "/" + filter + "▏"
            heading.textColor = look.text
        } else {
            heading.stringValue = title
            heading.textColor = look.muted
        }
        count.stringValue = liveQuery ? "\(visible.count)" : filter == nil ? "\(all.count)" : "\(visible.count) of \(all.count)"
    }

    /// The choices, the keyboard on `current` (or the first).
    func set(_ items: [PickerItem], current: String?) {
        all = items
        cursor = current.flatMap { id in items.contains { $0.id == id } ? id : nil } ?? items.first?.id
        refilter()
    }

    private func refilter() {
        if liveQuery {
            visible = all
        } else if let filter, !filter.isEmpty {
            visible = all.enumerated().compactMap { index, item -> (Int, Int, PickerItem)? in
                Fuzzy.match(filter, in: item.title).map { ($0.score, index, item) }
            }.sorted { ($0.0, $1.1) > ($1.0, $0.1) }.map(\.2)
        } else {
            visible = all
        }
        if !visible.contains(where: { $0.id == cursor }) { cursor = visible.first?.id }
        rows.items = visible
        rows.cursor = cursor
        if let cursor { rows.reveal(cursor) }
        updateHeading()
        needsLayout = true
    }

    private func beginFilter() {
        filter = ""
        refilter()
        onFilterChange?(true)
        if let item = visible.first(where: { $0.id == cursor }) { onMove?(item) }
    }

    /// The filter ends and every choice shows again (the window's modes have already said Escape ended it).
    func endFilter() {
        filter = nil
        refilter()
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let width = min(520, bounds.width - 32)
        let headerHeight = ceil(look.rowHeight) + 16
        let shown = CGFloat(min(max(visible.count, 1), Self.maxRows))
        let height = headerHeight + shown * ceil(rows.rowHeight) + 12
        card.frame = NSRect(
            x: (bounds.width - width) / 2,
            y: min(70, max(16, bounds.height * 0.1)),
            width: width,
            height: height
        )
        header.frame = NSRect(x: 0, y: 0, width: width, height: headerHeight)
        divider.frame = NSRect(x: 0, y: headerHeight - 1, width: width, height: 1)
        let textHeight = ceil(look.font.ascender - look.font.descender + look.font.leading)
        count.sizeToFit()
        count.frame.origin = NSPoint(x: width - 18 - count.frame.width, y: (headerHeight - count.frame.height) / 2)
        heading.frame = NSRect(
            x: 18,
            y: (headerHeight - textHeight) / 2,
            width: max(0, count.frame.minX - 26),
            height: textHeight
        )
        rows.frame = NSRect(x: 0, y: headerHeight + 6, width: width, height: max(0, height - headerHeight - 12))
    }

    override func mouseDown(with event: NSEvent) {
        if !card.frame.contains(convert(event.locationInWindow, from: nil)) { onDismiss?() }
    }

    // MARK: Keys

    private func move(by step: Int) {
        guard !visible.isEmpty else { return }
        let at = visible.firstIndex { $0.id == cursor } ?? 0
        let next = visible[min(max(at + step, 0), visible.count - 1)]
        guard next.id != cursor else { return }
        cursor = next.id
        rows.cursor = cursor
        rows.reveal(next.id)
        onMove?(next)
    }

    private func choose() {
        if let item = visible.first(where: { $0.id == cursor }) { onChoose?(item) }
    }

    override func keyDown(with event: NSEvent) {
        let characters = event.charactersIgnoringModifiers ?? ""
        let control = event.modifierFlags.contains(.control), command = event.modifierFlags.contains(.command)
        if filter != nil {
            switch (event.keyCode, characters) {
            case (125, _): move(by: 1)
            case (126, _): move(by: -1)
            case (_, "n") where control: move(by: 1)
            case (_, "p") where control: move(by: -1)
            case (36, _), (76, _): choose()
            case (53, _): onDismiss?()
            case (51, _): backspace()
            default:
                if !command, !control, let typed = event.characters,
                   typed.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 })
                {
                    filter = (filter ?? "") + typed
                    refilter()
                    if liveQuery { onQuery?(filter ?? "") }
                    else if let item = visible.first(where: { $0.id == cursor }) { onMove?(item) }
                }
            }
            return
        }
        switch (event.keyCode, characters) {
        case (125, _), (_, "j"): move(by: 1)
        case (126, _), (_, "k"): move(by: -1)
        case (36, _), (76, _), (_, " "): choose()
        case (53, _): onDismiss?()
        case (_, "/"): beginFilter()
        default: break
        }
    }

    private func backspace() {
        guard var text = filter, !text.isEmpty else { return }
        text.removeLast()
        filter = text
        refilter()
        if liveQuery { onQuery?(text) }
    }
}
