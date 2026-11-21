import AppKit
import FrameTree
import FrameWorkspaces
import SillEditor

/// A view laid out from the top.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A table that never takes the keyboard from the search field above it.
final class SwitcherTable: NSTableView {
    override var acceptsFirstResponder: Bool { false }

    /// A row is a click, so over the rows the pointer is a hand.
    func pointerRects() -> [NSRect] { [visibleRect] }

    override func resetCursorRects() {
        pointerRects().forEach { addCursorRect($0, cursor: .pointingHand) }
    }
}

/// A row: the selected one a rounded fill in the editor's colour.
final class SwitcherRowView: NSTableRowView {
    var fill = NSColor.clear

    override func drawSelection(in _: NSRect) {
        fill.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 6, yRadius: 6).fill()
    }

    override var isEmphasized: Bool {
        get { true }
        set {}
    }
}

/// A workspace as a row: what it is, where it is, and how it stands, drawn in the editor's font.
final class SwitcherCell: NSView {
    var match: WorkspaceMatch? {
        didSet { needsDisplay = true }
    }

    var look = TreeLook()
    override var isFlipped: Bool { true }

    /// "now", "5m", "3h", "2d", "6w": when something last happened, in a word.
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86400: return "\(Int(seconds / 3600))h"
        case ..<(86400 * 14): return "\(Int(seconds / 86400))d"
        default: return "\(Int(seconds / (86400 * 7)))w"
        }
    }

    private func attributed(_ text: String, hits: [Int], font: NSFont, color: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let characters = Array(text)
        for hit in hits where hit < characters.count {
            // By characters, as the matcher counts them: an index into the string's UTF-16 would drift on emoji.
            let range = NSRange(
                text.index(text.startIndex, offsetBy: hit) ... text.index(text.startIndex, offsetBy: hit),
                in: text
            )
            result.addAttributes([.foregroundColor: look.text, .font: look.boldFont, .underlineStyle: 0], range: range)
        }
        return result
    }

    override func draw(_: NSRect) {
        guard let match else { return }
        let workspace = match.workspace
        let left: CGFloat = 16
        // The icon: a worktree branches, a repository is a book.
        let glyph = workspace.isWorktree ? "\u{E0A0}" : "\u{F401}"
        let iconFont = NerdFont.font(size: look.iconSize) ?? look.font
        let iconSize = (glyph as NSString).size(withAttributes: [.font: iconFont])
        let iconColor = workspace.isCurrent ? look.text : look.muted
        (glyph as NSString).draw(
            at: NSPoint(x: left, y: (bounds.height - iconSize.height) / 2),
            withAttributes: [.font: iconFont, .foregroundColor: iconColor]
        )
        let textX = left + max(iconSize.width, look.iconSize) + 10
        // The right side: what needs the person, what works, or when it was last touched; a dot for an open window.
        var trailing = ""
        var trailingColor = look.muted
        if workspace.needsYou {
            trailing = "needs you"
            trailingColor = .controlAccentColor
        } else if workspace.heedState == "working" {
            trailing = "working"
        } else if workspace.isCurrent {
            trailing = "here"
        } else if let since = workspace.openedAt ?? (workspace.activeAt > .distantPast ? workspace.activeAt : nil) {
            // When it was last opened here, else when anything last happened in it.
            trailing = Self.ago(since)
        }
        var rightEdge = bounds.width - 16
        if !trailing.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [.font: look.smallFont, .foregroundColor: trailingColor]
            let size = (trailing as NSString).size(withAttributes: attributes)
            (trailing as NSString).draw(
                at: NSPoint(x: rightEdge - size.width, y: (bounds.height - size.height) / 2), withAttributes: attributes
            )
            rightEdge -= size.width + 8
        }
        if workspace.isOpen {
            let dot = NSRect(x: rightEdge - 6, y: bounds.midY - 3, width: 6, height: 6)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(ovalIn: dot).fill()
            rightEdge -= 14
        }
        let width = max(0, rightEdge - textX)
        let primary = attributed(workspace.primary, hits: match.primaryHits, font: look.font, color: look.text)
        let secondary = attributed(
            workspace.secondary,
            hits: match.secondaryHits,
            font: look.smallFont,
            color: look.muted
        )
        let primaryHeight = primary.size().height
        // A row with nothing under its name is centred on the name.
        let secondaryHeight = workspace.secondary.isEmpty ? 0 : secondary.size().height
        let top = (bounds.height - primaryHeight - secondaryHeight - (secondaryHeight > 0 ? 1 : 0)) / 2
        let options: NSString.DrawingOptions = [.truncatesLastVisibleLine, .usesLineFragmentOrigin]
        primary.draw(with: NSRect(x: textX, y: top, width: width, height: primaryHeight), options: options)
        secondary.draw(
            with: NSRect(x: textX, y: top + primaryHeight + 1, width: width, height: secondaryHeight), options: options
        )
    }
}

/// The workspace switcher: a card over the window with a search line and the workspaces under it. The keyboard is the
/// search line's: type to narrow, ↑ ↓ to move, Return to go, Escape to close.
@MainActor
final class SwitcherView: NSView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var look: TreeLook {
        didSet { apply() }
    }

    /// A workspace chosen, and whether it is to open in a new window (Shift-Return) and not in this one.
    var onChoose: ((Workspace, _ newWindow: Bool) -> Void)?
    /// Whether Shift is down: what tells Return from Shift-Return (the self-check stands in for the keyboard).
    var shiftHeld: () -> Bool = { NSApp.currentEvent?.modifierFlags.contains(.shift) == true }
    var onDismiss: (() -> Void)?
    let field = NSTextField()
    private let card = FlippedView()
    private let divider = NSView()
    private let scroll = NSScrollView()
    private let table = SwitcherTable()
    private let footer = NSTextField(labelWithString: "")
    private var all: [Workspace] = []
    private(set) var matches: [WorkspaceMatch] = []
    private var loading = true
    private static let maxRows = 8

    init(look: TreeLook) {
        self.look = look
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.borderWidth = 1
        card.layer?.shadowOpacity = 0.4
        card.layer?.shadowRadius = 24
        card.layer?.shadowOffset = CGSize(width: 0, height: -8)
        addSubview(card)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.delegate = self
        card.addSubview(field)
        divider.wantsLayer = true
        card.addSubview(divider)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("workspace"))
        column.resizingMask = .autoresizingMask
        column.minWidth = 100
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.headerView = nil
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.intercellSpacing = .zero
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked(_:))
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        card.addSubview(scroll)
        footer.isBordered = false
        footer.drawsBackground = false
        card.addSubview(footer)
        apply()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    private var rowHeight: CGFloat { ceil(look.font.lineHeight + look.smallFont.lineHeight) + 18 }

    func apply() {
        card.layer?.backgroundColor = look.island.cgColor
        card.layer?.borderColor = look.muted.withAlphaComponent(0.35).cgColor
        divider.layer?.backgroundColor = look.muted.withAlphaComponent(0.25).cgColor
        field.font = look.font
        field.textColor = look.text
        field.placeholderAttributedString = NSAttributedString(string: "Switch workspace", attributes: [
            .font: look.font, .foregroundColor: look.faint,
        ])
        footer.font = look.smallFont
        footer.textColor = look.faint
        table.rowHeight = rowHeight
        table.reloadData()
        updateFooter()
        needsLayout = true
    }

    // MARK: What it shows

    /// The workspaces, again (they arrive in two goes): the query still applies and the selection stays on the same
    /// workspace, if it is still there.
    func set(_ workspaces: [Workspace], loading: Bool) {
        let chosen = selectedWorkspace?.path
        all = workspaces
        self.loading = loading
        search(keeping: chosen)
    }

    var selectedWorkspace: Workspace? {
        table.selectedRow >= 0 && table.selectedRow < matches.count ? matches[table.selectedRow].workspace : nil
    }

    private func search(keeping path: String? = nil) {
        matches = WorkspaceIndex.search(field.stringValue, in: all)
        table.reloadData()
        var row: Int?
        if let path { row = matches.firstIndex { $0.workspace.path == path } }
        // Return with nothing typed goes to the one before this: not the workspace that is already shown.
        if row == nil { row = matches.firstIndex { !$0.workspace.isCurrent } ?? (matches.isEmpty ? nil : 0) }
        if let row {
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        updateFooter()
        needsLayout = true
    }

    private func updateFooter() {
        let status = loading && all.isEmpty ? "looking…" : matches
            .isEmpty ? (all.isEmpty ? "nothing found" : "no match") : ""
        let keys = "↩ here   ⇧↩ new window   ⎋ close   ↑↓ move"
        footer.stringValue = status.isEmpty ? keys : status + "   " + keys
    }

    func choose(newWindow: Bool = false) {
        guard let workspace = selectedWorkspace else { return }
        onChoose?(workspace, newWindow)
    }

    func move(by step: Int) {
        guard !matches.isEmpty else { return }
        let row = min(max(table.selectedRow + step, 0), matches.count - 1)
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func clicked(_: Any?) {
        if table.clickedRow >= 0, table.clickedRow < matches.count {
            table.selectRowIndexes([table.clickedRow], byExtendingSelection: false)
            choose()
        }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let width = min(620, bounds.width - 32)
        let header: CGFloat = 46, foot: CGFloat = 28
        let rows = CGFloat(min(max(matches.count, 1), Self.maxRows))
        let height = header + 1 + (matches.isEmpty ? 0 : rows * rowHeight + 12) + foot
        card.frame = NSRect(
            x: (bounds.width - width) / 2,
            y: min(70, max(16, bounds.height * 0.1)),
            width: width,
            height: height
        )
        let fieldHeight = ceil(look.font.lineHeight + 8)
        field.frame = NSRect(x: 16, y: (header - fieldHeight) / 2, width: width - 32, height: fieldHeight)
        divider.frame = NSRect(x: 0, y: header, width: width, height: 1)
        scroll.frame = NSRect(x: 0, y: header + 4, width: width, height: matches.isEmpty ? 0 : rows * rowHeight + 2)
        scroll.isHidden = matches.isEmpty
        table.tableColumns.first?.width = width
        table.frame.size.width = width
        table.sizeLastColumnToFit()
        footer.sizeToFit()
        footer.frame = NSRect(
            x: 16,
            y: height - foot + (foot - footer.frame.height) / 2,
            width: width - 32,
            height: footer.frame.height
        )
    }

    /// A click outside the card closes it.
    override func mouseDown(with event: NSEvent) {
        if !card.frame.contains(convert(event.locationInWindow, from: nil)) { onDismiss?() }
    }

    // MARK: The table

    func numberOfRows(in _: NSTableView) -> Int { matches.count }

    func tableView(_: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        let cell = SwitcherCell()
        cell.look = look
        cell.match = matches[row]
        return cell
    }

    func tableView(_: NSTableView, rowViewForRow _: Int) -> NSTableRowView? {
        let view = SwitcherRowView()
        view.fill = look.focusedSelection
        return view
    }

    // MARK: The search line

    func controlTextDidChange(_: Notification) { search() }

    func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)): onDismiss?()
        case #selector(NSResponder.insertNewline(_:)): choose(newWindow: shiftHeld())
        case #selector(NSResponder.moveDown(_:)): move(by: 1)
        case #selector(NSResponder.moveUp(_:)): move(by: -1)
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)): move(by: Self.maxRows)
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)): move(by: -Self.maxRows)
        default: return false
        }
        return true
    }
}

private extension NSFont {
    /// A line's height: ascent and descent, which is what the rows are made of.
    var lineHeight: CGFloat { ascender - descender + leading }
}
