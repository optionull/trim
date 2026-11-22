import AppKit
import FrameTree
import SillCore
import SillEditor

extension NSColor {
    convenience init(frameRGB rgb: Int, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha
        )
    }
}

/// The sidebar's look: the editor's colours (`TreePalette`) and the editor's font, at the sizes the grid has now.
@MainActor
struct TreeLook {
    var palette = TreePalette(background: 0x0C0D0F, foreground: 0xCFD3D8)

    var island: NSColor { NSColor(frameRGB: palette.sidebar) }
    var text: NSColor { NSColor(frameRGB: palette.foreground) }
    var muted: NSColor { NSColor(frameRGB: palette.muted) }
    var faint: NSColor { NSColor(frameRGB: palette.faint) }
    /// The selected row: the colour scheme's selection colour, quieter while the pane does not have the keyboard.
    var selection: NSColor { NSColor(frameRGB: palette.selectionDim) }
    var focusedSelection: NSColor { NSColor(frameRGB: palette.selection) }

    /// The editor's font (the face, size and line height of the grid), for names; a little smaller for what is beside
    /// them.
    var font: NSFont { EditorFont.font(CGFloat(EditorFont.size)) }
    var boldFont: NSFont { EditorFont.font(CGFloat(EditorFont.size), .semibold) }
    var smallFont: NSFont { EditorFont.font(max(CGFloat(EditorFont.size) - 2, 8)) }
    var iconSize: CGFloat { CGFloat(EditorFont.size) + 1 }
    /// A row is a line of the grid.
    var rowHeight: CGFloat { max(ceil(EditorFont.metrics.height), 20) }
    var indent: CGFloat { ceil(EditorFont.metrics.width * 2) }
}

/// The filter's input: a rounded field under the header, in the editor's font.
final class FilterBox: NSView {
    let field = NSTextField()
    var look = TreeLook() {
        didSet { apply() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        addSubview(field)
        apply()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    func apply() {
        field.font = look.font
        field.textColor = look.text
        field.placeholderAttributedString = NSAttributedString(string: "Filter files", attributes: [
            .font: look.font, .foregroundColor: look.faint,
        ])
        needsDisplay = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        field.sizeToFit()
        let height = field.frame.height
        field.frame = NSRect(x: 9, y: (bounds.height - height) / 2, width: max(0, bounds.width - 18), height: height)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_: NSRect) {
        look.text.withAlphaComponent(0.09).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
}

/// Under the sidebar, level with the status bar: the git root the folder belongs to and its branch, and a click goes to
/// the workspace switcher. The keyboard stays where it was.
final class WorkspaceChip: NSView {
    var look = TreeLook() {
        didSet { needsDisplay = true }
    }

    var onClick: (() -> Void)?
    /// The repository's name, the branch, and whether this folder is a worktree of it.
    private(set) var name = ""
    private(set) var branch = ""
    private(set) var isWorktree = false
    private var hovering = false

    func show(name: String, branch: String, isWorktree: Bool) {
        guard (name, branch, isWorktree) != (self.name, self.branch, self.isWorktree) else { return }
        self.name = name
        self.branch = branch
        self.isWorktree = isWorktree
        needsDisplay = true
    }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func mouseDown(with _: NSEvent) { onClick?() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    /// The whole button is a click, so the pointer says so.
    func pointerRects() -> [NSRect] { [bounds] }

    override func resetCursorRects() {
        pointerRects().forEach { addCursorRect($0, cursor: .pointingHand) }
    }

    override func layout() {
        super.layout()
        window?.invalidateCursorRects(for: self)
    }

    override func mouseEntered(with _: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with _: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    override func draw(_: NSRect) {
        // An island like the sidebar's and the status bar's, a shade lighter under the pointer.
        look.island.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Design.islandRadius, yRadius: Design.islandRadius).fill()
        if hovering {
            look.text.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: Design.islandRadius, yRadius: Design.islandRadius).fill()
        }
        let iconFont = NerdFont.font(size: look.iconSize) ?? look.font
        let glyph = isWorktree ? "\u{E0A0}" : "\u{F401}"
        let iconSize = (glyph as NSString).size(withAttributes: [.font: iconFont])
        (glyph as NSString).draw(
            at: NSPoint(x: 10, y: (bounds.height - iconSize.height) / 2),
            withAttributes: [.font: iconFont, .foregroundColor: look.muted]
        )
        let x = 10 + max(iconSize.width, look.iconSize) + 8
        let available = max(0, bounds.width - x - 10)
        // The branch keeps its room and the name gives way: the name is what the icon already says, the branch is not.
        let branchText = NSAttributedString(
            string: branch, attributes: [.font: look.smallFont, .foregroundColor: look.muted]
        )
        let branchWidth = branch.isEmpty ? 0 : min(ceil(branchText.size().width), available * 0.55)
        let gap: CGFloat = branch.isEmpty ? 0 : 8
        let nameText = NSAttributedString(
            string: name, attributes: [.font: look.boldFont, .foregroundColor: look.text]
        )
        let nameWidth = min(ceil(nameText.size().width), max(0, available - branchWidth - gap))
        let options: NSString.DrawingOptions = [.truncatesLastVisibleLine, .usesLineFragmentOrigin]
        let nameHeight = nameText.size().height
        nameText.draw(
            with: NSRect(x: x, y: (bounds.height - nameHeight) / 2, width: nameWidth, height: nameHeight),
            options: options
        )
        if !branch.isEmpty {
            let height = branchText.size().height
            branchText.draw(
                with: NSRect(
                    x: x + nameWidth + gap,
                    y: (bounds.height - height) / 2,
                    width: branchWidth,
                    height: height
                ),
                options: options
            )
        }
    }
}

/// The column left of the grid: a rounded island with the folder's name and branch over the tree.
final class SidebarView: NSView {
    var look = TreeLook() {
        didSet { applyLook() }
    }

    let scroll = NSScrollView()
    private let title = NSTextField(labelWithString: "")
    private let branch = NSTextField(labelWithString: "")
    /// At the top right: the filter, and what is shown (ignored files, dotfiles).
    let filterButton = HeaderButton()
    let visibilityButton = HeaderButton()
    /// Under the header while the filter is open, and what it says when nothing matches.
    let filterBox = FilterBox()
    let emptyNote = NSTextField(labelWithString: "No files match")
    var filterVisible = false {
        didSet {
            filterBox.isHidden = !filterVisible
            needsLayout = true
        }
    }

    /// The header: the name, and under it the branch, in the editor's font.
    var headerHeight: CGFloat { look.rowHeight + 18 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // The island is dark whatever the system is: the disclosure triangles and scrollers follow.
        appearance = NSAppearance(named: .darkAqua)
        title.lineBreakMode = .byTruncatingMiddle
        branch.lineBreakMode = .byTruncatingTail
        applyLook()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        filterBox.isHidden = true
        emptyNote.isHidden = true
        emptyNote.alignment = .center
        for view in [scroll, title, branch, filterButton, visibilityButton, filterBox, emptyNote] {
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// The editor's font and colours, as they are now.
    func applyLook() {
        title.font = look.boldFont
        title.textColor = look.text
        branch.font = look.smallFont
        branch.textColor = look.muted
        for button in [filterButton, visibilityButton] {
            button.look = look
        }
        filterBox.look = look
        emptyNote.font = look.smallFont
        emptyNote.textColor = look.muted
        needsLayout = true
        needsDisplay = true
    }

    func show(name: String, branch name_: String) {
        title.stringValue = name
        branch.stringValue = name_.isEmpty ? "" : "\u{F062C} " + name_
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 14
        let hasBranch = !branch.stringValue.isEmpty
        title.sizeToFit()
        branch.sizeToFit()
        // The buttons right-aligned in the first line; the name takes what they leave.
        let side = max(22, look.rowHeight)
        let buttonY: CGFloat = hasBranch ? 6 : 8
        visibilityButton.frame = NSRect(x: bounds.width - inset + 4 - side, y: buttonY, width: side, height: side)
        filterButton.frame = NSRect(x: visibilityButton.frame.minX - side - 2, y: buttonY, width: side, height: side)
        let width = max(0, filterButton.frame.minX - inset - 4)
        title.frame = NSRect(x: inset, y: hasBranch ? 8 : 12, width: width, height: title.frame.height)
        branch.frame = NSRect(
            x: inset, y: title.frame.maxY + 1, width: bounds.width - 2 * inset, height: branch.frame.height
        )
        branch.isHidden = !hasBranch
        var top = max(headerHeight, branch.frame.maxY + 6)
        if filterVisible {
            let height = look.rowHeight + 6
            filterBox.frame = NSRect(x: 10, y: top - 4, width: bounds.width - 20, height: height)
            top += height
        }

        emptyNote.sizeToFit()
        emptyNote.frame = NSRect(x: inset, y: top + 12, width: bounds.width - 2 * inset, height: emptyNote.frame.height)
        scroll.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top - 6))
        // The one column is as wide as what shows, so the badges at a row's right edge are not beyond it.
        if let table = scroll.documentView as? NSTableView, let column = table.tableColumns.first {
            column.minWidth = 0
            column.width = scroll.contentSize.width
        }
    }

    override func draw(_: NSRect) {
        look.island.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Design.islandRadius, yRadius: Design.islandRadius).fill()
    }
}

/// A small icon at the sidebar's top: a Nerd Font glyph, in the quiet colour, in the accent while what it stands for is
/// on.
final class HeaderButton: NSButton {
    var look = TreeLook() {
        didSet { refresh() }
    }

    var glyph = "" {
        didSet { refresh() }
    }

    var isOn = false {
        didSet { refresh() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .noImage
        focusRingType = .none
        setButtonType(.momentaryChange)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
    /// Clicking an icon does not take the keyboard from where it was.
    override var acceptsFirstResponder: Bool { false }

    /// Under the pointer: a soft fill behind the icon, and the hand that says it can be clicked.
    private(set) var isHovering = false

    /// Where the pointer is a hand: all of it.
    func pointerRects() -> [NSRect] { [bounds] }

    override func resetCursorRects() {
        pointerRects().forEach { addCursorRect($0, cursor: .pointingHand) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self
        ))
    }

    override func mouseEntered(with _: NSEvent) { setHovering(true) }
    override func mouseExited(with _: NSEvent) { setHovering(false) }

    func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        window?.invalidateCursorRects(for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovering {
            look.text.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        super.draw(dirtyRect)
    }

    func refresh() {
        let font = NerdFont.font(size: look.iconSize) ?? look.font
        attributedTitle = NSAttributedString(string: glyph, attributes: [
            .font: font, .foregroundColor: isOn ? Design.accent : look.muted,
        ])
    }
}

/// The outline: vim's keys beside the arrows, and Escape (or Tab) back to the editor.
final class TreeOutline: NSOutlineView {
    var onEscape: (() -> Void)?
    /// Escape: what it does is the window's to say (`FrameModes`), for it depends on where the keyboard came from.
    var onCancel: (() -> Void)?
    /// The outline took the keyboard (a click, a key from elsewhere).
    var onFocused: (() -> Void)?
    /// Keys that are nvim's, not the tree's: the leader, `:` and Control chords. The keyboard goes to the editor with
    /// the
    /// key, so a sequence that starts here (`<leader>e`, `<C-w>l`, `:`) is finished there, whatever row is selected.
    var onForward: ((NSEvent) -> Void)?
    /// `I` and `H`: show or hide ignored files, show or hide dotfiles.
    var onToggleIgnored: (() -> Void)?
    var onToggleDotfiles: (() -> Void)?
    /// `/`: the filter.
    var onFilter: (() -> Void)?
    /// The characters that are nvim's leader and local leader (Space for most configs).
    var leaders: Set<String> = [" "]
    /// A node entered; `toEditor` when the keyboard should go along to the editor.
    var onActivate: ((TreeNode, _ toEditor: Bool) -> Void)?
    private var pendingG = false

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let taken = super.becomeFirstResponder()
        if taken { onFocused?() }
        return taken
    }

    /// The click that activates the window is the tree's too: a person who clicks a row means to use it.
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    /// A click gives the tree the keyboard itself: when the window or the app is not active yet, the table's own
    /// mouse-down selects the row but leaves the keyboard where it was, and keys go on to the editor.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    private func forward(_ event: NSEvent) {
        pendingG = false
        onForward?(event)
    }

    private func select(row: Int) {
        guard (0 ..< numberOfRows).contains(row) else { return }
        selectRowIndexes([row], byExtendingSelection: false)
        scrollRowToVisible(row)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags
        if flags.contains(.control), !flags.contains(.command) { return forward(event) }
        if flags.isDisjoint(with: [.command, .control, .option]),
           let typed = event.charactersIgnoringModifiers, typed == ":" || leaders.contains(typed)
        {
            return forward(event)
        }
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
              let key = event.charactersIgnoringModifiers else { return super.keyDown(with: event) }
        let node = item(atRow: selectedRow) as? TreeNode
        // `gg` is two keys: the first waits for the second.
        let wasG = pendingG
        pendingG = false
        switch key {
        case "j": select(row: max(selectedRow, -1) + 1)
        case "k": select(row: selectedRow < 0 ? 0 : selectedRow - 1)
        case "g":
            if wasG { select(row: 0) } else { pendingG = true }
        case "G": select(row: numberOfRows - 1)
        case "/": onFilter?()
        case "I": onToggleIgnored?()
        case "H": onToggleDotfiles?()
        case "l":
            if let node, node.isDirectory {
                if isItemExpanded(node) { select(row: selectedRow + 1) } else { expandItem(node) }
            } else if let node {
                onActivate?(node, false)
            }
        case "h":
            if let node, node.isDirectory, isItemExpanded(node) {
                collapseItem(node)
            } else if let parent = node?.parent.flatMap({ $0.parent == nil ? nil : $0 }) {
                select(row: row(forItem: parent))
            }
        case "\r", "o":
            if let node { onActivate?(node, true) }
        case "p", " ":
            if let node, !node.isDirectory { onActivate?(node, false) }
        case "\u{1B}": onCancel?()
        case "\t": onEscape?()
        default: super.keyDown(with: event)
        }
    }
}

/// A row: the selection a rounded fill, in the accent while the tree has the keyboard.
final class TreeRowView: NSTableRowView {
    var look = TreeLook()

    override func drawSelection(in _: NSRect) {
        let rect = bounds.insetBy(dx: 6, dy: 1)
        (isEmphasized ? look.focusedSelection : look.selection).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .dark }
}

/// A wavy line under a name: the worst diagnostic of a file, or of what is in a folder.
final class SquiggleView: NSView {
    var level: DiagnosticLevel? {
        didSet {
            guard level != oldValue else { return }
            isHidden = level == nil
            needsDisplay = true
        }
    }

    static func color(_ level: DiagnosticLevel) -> NSColor {
        switch level {
        case .error: Design.error
        case .warning: Design.modified
        case .info: NSColor(hex: 0x7FB4F0)
        case .hint: NSColor(hex: 0x4FD6BE)
        }
    }

    override var isFlipped: Bool { true }

    override func draw(_: NSRect) {
        guard let level else { return }
        Self.color(level).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        let step: CGFloat = 2
        var x: CGFloat = 0
        var up = false
        path.move(to: NSPoint(x: 0, y: bounds.height - 1))
        while x < bounds.width {
            x = min(x + step, bounds.width)
            up.toggle()
            path.line(to: NSPoint(x: x, y: up ? 0.5 : bounds.height - 0.5))
        }
        path.stroke()
    }
}

/// A row's content: the icon, the name, and what git says at the right.
final class TreeCellView: NSTableCellView {
    let squiggle = SquiggleView()
    let icon = NSTextField(labelWithString: "")
    let name = NSTextField(labelWithString: "")
    let badge = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        name.lineBreakMode = .byTruncatingMiddle
        badge.alignment = .right
        for view in [icon, name, badge] {
            view.isBordered = false
            addSubview(view)
        }
        squiggle.isHidden = true
        addSubview(squiggle)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    static func color(_ tint: FileIcon.Tint, look: TreeLook) -> NSColor {
        switch tint {
        case .folder: NSColor(frameRGB: TreePalette.mix(look.palette.foreground, 0x7C9CCB, 0.6))
        case .dotnet: Design.insert
        case .systems: NSColor(hex: 0xF0965F)
        case .web: NSColor(hex: 0x7FB4F0)
        case .script: Design.accent
        case .data: Design.modified
        case .project, .image: Design.visual
        case .plain, .docs: look.muted
        }
    }

    static func color(_ status: GitState.Status) -> NSColor {
        switch status {
        case .modified: Design.modified
        case .added, .untracked: Design.accent
        case .deleted, .conflicted: Design.error
        case .renamed: Design.insert
        }
    }

    static func letter(_ status: GitState.Status) -> String {
        switch status {
        case .modified: "M"
        case .added: "A"
        case .untracked: "U"
        case .deleted: "D"
        case .renamed: "R"
        case .conflicted: "!"
        }
    }

    func configure(_ node: TreeNode, expanded: Bool, look: TreeLook) {
        let kind = FileIcons.icon(name: node.name, isDirectory: node.isDirectory, expanded: expanded)
        icon.font = NerdFont.font(size: look.iconSize)
        icon.stringValue = NerdFont.has(kind.glyph) ? String(kind.glyph) : ""
        icon.textColor = Self.color(kind.tint, look: look)
        name.font = look.font
        badge.font = look.smallFont
        name.stringValue = node.name
        let changed = node.status
        name.textColor = changed.map(Self.color) ?? look.text
        if let changed {
            badge.stringValue = Self.letter(changed)
            badge.textColor = Self.color(changed)
        } else if node.changedBelow {
            badge.stringValue = "•"
            badge.textColor = Design.modified
        } else {
            badge.stringValue = ""
        }
        squiggle.level = node.diagnostic
        alphaValue = node.ignored ? 0.45 : 1
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        icon.sizeToFit()
        name.sizeToFit()
        badge.sizeToFit()
        icon.frame = NSRect(x: 0, y: (height - icon.frame.height) / 2, width: 20, height: icon.frame.height)
        icon.alignment = .center
        let badgeWidth: CGFloat = badge.stringValue.isEmpty ? 0 : 22
        badge.frame = NSRect(
            x: bounds.width - badgeWidth - 8, y: (height - badge.frame.height) / 2,
            width: badgeWidth, height: badge.frame.height
        )
        name.frame = NSRect(
            x: 26, y: (height - name.frame.height) / 2,
            width: max(0, badge.frame.minX - 26 - 4), height: name.frame.height
        )
        // The wave runs under the text, from where it starts to where it ends (a cell is not flipped: the baseline is
        // measured from the top of the label, so its y depends on which way the cell counts).
        let textWidth = ceil(name.attributedStringValue.boundingRect(
            with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]
        ).width)
        let drawn = max(0, min(textWidth, name.frame.width - 4))
        let offset = name.firstBaselineOffsetFromTop
        let baseline = isFlipped ? name.frame.minY + offset : name.frame.maxY - offset
        let top = isFlipped ? baseline + 0.5 : baseline - 0.5 - 3
        squiggle.frame = NSRect(x: name.frame.minX + 2, y: top, width: drawn, height: 3)
    }
}

/// The tree in the sidebar: a folder's files read as they are asked for, kept up to date by the file system's events
/// and by git, and the way into the editor: what is clicked or entered opens in nvim.
@MainActor
final class TreeController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
    let sidebar: SidebarView
    let outline = TreeOutline()
    private(set) var tree: FileTree?
    private var events: FileEvents?
    private var gitTask: Task<Void, Never>?
    private var diagnosticTask: Task<Void, Never>?
    /// Folders waiting to be looked at, the task that will, and how many were read again (for the self-check).
    private var changedFolders: Set<String> = []
    private var changeTask: Task<Void, Never>?
    private(set) var reloadsDone = 0
    private var fileDiagnostics: [String: DiagnosticLevel] = [:]
    private var pending: DispatchWorkItem?
    /// The editor's colours and font as they are now.
    private(set) var look = TreeLook()
    /// Ignored files and dotfiles: shown or not, remembered between starts.
    private(set) var showIgnored: Bool
    private(set) var showDotfiles: Bool
    private let persisting: Bool
    /// The filter: what its scan is doing, the folders it opened that were not open, and a keystroke waiting to be
    /// scanned.
    private var filterTask: Task<Void, Never>?
    private var filterDebounce: DispatchWorkItem?
    /// The folders that were open when the filter began, to open again when it ends: showing the matches reads the tree
    /// afresh, which shuts every folder.
    private var openBeforeFilter: [String]?
    var filterText: String { sidebar.filterBox.field.stringValue }
    /// A file is opened: the path, for the editor to show, and whether the keyboard goes to the editor with it.
    var onOpen: ((String, Bool) -> Void)?
    /// The workspace the tree is rooted in, as the chip says it: the git root's name, the branch, whether a worktree.
    var onChip: ((_ name: String, _ branch: String, _ isWorktree: Bool) -> Void)?
    /// Tab: on to the editor.
    var onEscape: (() -> Void)?
    /// Escape, in the tree or in its filter: the window's modes say what it does.
    var onCancel: (() -> Void)?
    /// The filter opened or closed (the tree's own mode), and the tree took the keyboard.
    var onFilterChange: ((_ open: Bool) -> Void)?
    var onFocused: (() -> Void)?
    /// A key that is nvim's: the editor takes the keyboard and the key.
    var onForward: ((NSEvent) -> Void)?
    /// The editor's colours changed (or the first arrived).
    var onPalette: ((TreePalette) -> Void)?

    /// The leader and local leader nvim has (its config's, known once it has started).
    var leaders: Set<String> {
        get { outline.leaders }
        set { outline.leaders = newValue }
    }

    init(sidebar: SidebarView, persisting: Bool = true) {
        self.sidebar = sidebar
        self.persisting = persisting
        let defaults = UserDefaults.standard
        showIgnored = persisting ? defaults.bool(forKey: "treeShowIgnored") : false
        showDotfiles = persisting ? defaults.object(forKey: "treeShowDotfiles") as? Bool ?? true : true
        super.init()
        sidebar.visibilityButton.target = self
        sidebar.visibilityButton.action = #selector(visibilityClicked(_:))
        sidebar.filterButton.glyph = "\u{F0B0}"
        sidebar.filterButton.target = self
        sidebar.filterButton.action = #selector(filterClicked(_:))
        sidebar.filterBox.field.delegate = self
        outline.onFilter = { [weak self] in self?.openFilter() }
        outline.onToggleIgnored = { [weak self] in self?.toggleIgnored() }
        outline.onToggleDotfiles = { [weak self] in self?.toggleDotfiles() }
        refreshButtons()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.backgroundColor = .clear
        outline.style = .plain
        outline.rowHeight = look.rowHeight
        outline.intercellSpacing = NSSize(width: 0, height: 2)
        outline.indentationPerLevel = look.indent
        outline.floatsGroupRows = false
        // The column stays as wide as the sidebar: by default it grows by an indent whenever a deeper folder opens.
        outline.autoresizesOutlineColumn = false
        outline.focusRingType = .none
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked(_:))
        outline.onEscape = { [weak self] in self?.onEscape?() }
        outline.onCancel = { [weak self] in self?.onCancel?() }
        outline.onFocused = { [weak self] in self?.onFocused?() }
        outline.onForward = { [weak self] event in self?.onForward?(event) }
        outline.onActivate = { [weak self] node, toEditor in self?.activate(node, toEditor: toEditor) }
        outline.doubleAction = #selector(doubleClicked(_:))
        sidebar.scroll.documentView = outline
    }

    /// The editor's colour scheme changed (or the first one arrived): the sidebar follows it.
    /// The colour scheme's selection colour (nvim's `Visual`), once nvim has said it: the tree's selection, and the
    /// tabs'.
    var themeSelection: Int? {
        didSet { if themeSelection != oldValue,
                    let last = lastColours { follow(background: last.0, foreground: last.1) }
        }
    }

    private var lastColours: (Int, Int)?

    func follow(background: Int, foreground: Int) {
        lastColours = (background, foreground)
        let palette = TreePalette(background: background, foreground: foreground, selection: themeSelection)
        guard palette != look.palette else { return }
        look.palette = palette
        applyLook()
        onPalette?(palette)
    }

    // MARK: The filter

    @objc private func filterClicked(_: Any?) {
        if sidebar.filterVisible { closeFilter() } else { openFilter() }
    }

    /// The input shows under the header and has the keyboard.
    func openFilter() {
        sidebar.filterVisible = true
        sidebar.filterButton.isOn = true
        onFilterChange?(true)
        sidebar.layoutSubtreeIfNeeded()
        let field = sidebar.filterBox.field
        field.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// The keyboard to the filter's input, when it is open.
    func focusFilter() {
        let field = sidebar.filterBox.field
        field.window?.makeFirstResponder(field)
    }

    /// The input goes, the filter with it, and the keyboard is the tree's.
    func closeFilter() {
        resetFilter()
        outline.window?.makeFirstResponder(outline)
    }

    private func resetFilter() {
        filterDebounce?.cancel()
        sidebar.filterBox.field.stringValue = ""
        let wasOpen = sidebar.filterVisible
        sidebar.filterVisible = false
        sidebar.filterButton.isOn = false
        if wasOpen { onFilterChange?(false) }
        applyFilter("")
    }

    func controlTextDidChange(_: Notification) {
        filterDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self.map { $0.applyFilter($0.filterText) } }
        }
        filterDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// Typing in the filter: Escape closes it, Return opens what it found, Tab goes to the results, the arrows move
    /// through it.
    func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
        case #selector(NSResponder.insertNewline(_:)):
            // Return opens what the filter found: the file selected with the arrows, or else the first one.
            outline.window?.makeFirstResponder(outline)
            if selectedNode == nil || selectedNode?.isDirectory == true { selectFirstFile() }
            if let node = selectedNode, !node.isDirectory { activate(node, toEditor: true) }
        case #selector(NSResponder.insertTab(_:)):
            // Tab goes to the results to walk them.
            outline.window?.makeFirstResponder(outline)
            if selectedNode == nil || selectedNode?.isDirectory == true { selectFirstFile() }
        case #selector(NSResponder.moveDown(_:)): move(by: 1)
        case #selector(NSResponder.moveUp(_:)): move(by: -1)
        default: return false
        }
        return true
    }

    private func move(by step: Int) {
        let row = min(max(outline.selectedRow + step, 0), outline.numberOfRows - 1)
        guard row >= 0 else { return }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        outline.scrollRowToVisible(row)
    }

    private func selectFirstFile() {
        guard let row = visibleNodes.firstIndex(where: { !$0.isDirectory }) else { return }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        outline.scrollRowToVisible(row)
    }

    /// Shows only what has `text` in its path, the way to it open; no text shows everything again. The folders are
    /// scanned off the main thread.
    func applyFilter(_ text: String) {
        filterTask?.cancel()
        guard let tree else { return }
        guard !text.isEmpty else {
            guard let open = openBeforeFilter else { return }
            openBeforeFilter = nil
            tree.setFilter("", result: nil)
            outline.reloadData()
            // What the filter opened is shut, and what was open before it is open again.
            outline.collapseItem(nil, collapseChildren: true)
            // By path: a folder the filter hid was forgotten, and is a new node now.
            for path in open {
                if let folder = tree.node(at: path) { outline.expandItem(folder) }
            }
            sidebar.emptyNote.isHidden = true
            return
        }
        if openBeforeFilter == nil {
            openBeforeFilter = visibleNodes.filter { $0.isDirectory && outline.isItemExpanded($0) }
                .map(\.path).sorted { $0.count < $1.count }
        }
        let root = tree.root.path, ignored = tree.git.ignored
        let (dotfiles, shown) = (tree.showDotfiles, tree.showIgnored)
        filterTask = Task { [weak self] in
            let result = await Task.detached {
                FileTree.scan(root: root, text: text, showDotfiles: dotfiles, showIgnored: shown, ignored: ignored)
            }.value
            guard !Task.isCancelled, let self, self.tree === tree, filterText == text else { return }
            tree.setFilter(text, result: result)
            outline.reloadData()
            for folder in tree.foldersToExpand() {
                outline.expandItem(folder)
            }
            sidebar.emptyNote.isHidden = result.paths.contains { $0 != root }
            selectFirstFile()
        }
    }

    // MARK: What is shown

    func toggleIgnored() { setVisibility(ignored: !showIgnored, dotfiles: nil) }
    func toggleDotfiles() { setVisibility(ignored: nil, dotfiles: !showDotfiles) }

    func setVisibility(ignored: Bool?, dotfiles: Bool?) {
        if let ignored { showIgnored = ignored }
        if let dotfiles { showDotfiles = dotfiles }
        if persisting {
            UserDefaults.standard.set(showIgnored, forKey: "treeShowIgnored")
            UserDefaults.standard.set(showDotfiles, forKey: "treeShowDotfiles")
        }
        refreshButtons()
        guard let tree else { return }
        for node in tree.setVisibility(ignored: showIgnored, dotfiles: showDotfiles) {
            show(node)
        }
    }

    /// The eye is open while anything that is usually left out is shown.
    private func refreshButtons() {
        sidebar.visibilityButton.glyph = showIgnored || !showDotfiles ? "\u{F06E}" : "\u{F070}"
        sidebar.visibilityButton.isOn = showIgnored || !showDotfiles
    }

    /// The choices behind the eye: each a switch, with the key that does it.
    func visibilityMenu() -> NSMenu {
        let menu = NSMenu()
        let ignored = menu.addItem(
            withTitle: "Show Ignored Files   I",
            action: #selector(ignoredChosen(_:)),
            keyEquivalent: ""
        )
        ignored.state = showIgnored ? .on : .off
        ignored.target = self
        let dotfiles = menu.addItem(
            withTitle: "Show Dotfiles   H",
            action: #selector(dotfilesChosen(_:)),
            keyEquivalent: ""
        )
        dotfiles.state = showDotfiles ? .on : .off
        dotfiles.target = self
        return menu
    }

    @objc private func ignoredChosen(_: Any?) { toggleIgnored() }
    @objc private func dotfilesChosen(_: Any?) { toggleDotfiles() }

    @objc private func visibilityClicked(_ sender: NSButton) {
        visibilityMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    /// The editor's font changed: names, rows and indents follow.
    func fontChanged() { applyLook() }

    private func applyLook() {
        sidebar.look = look
        outline.rowHeight = look.rowHeight
        outline.indentationPerLevel = look.indent
        outline.reloadData()
    }

    /// The tree now shows this folder (the same one again changes nothing).
    func setRoot(_ path: String) {
        let real = RealPath.of(path)
        guard tree?.root.path != real else { return }
        events = nil
        resetFilter()
        let tree = FileTree(root: real)
        tree.setVisibility(ignored: showIgnored, dotfiles: showDotfiles)
        self.tree = tree
        tree.children(of: tree.root)
        outline.reloadData()
        sidebar.show(name: tree.root.name, branch: "")
        showChip(for: tree.root.path)
        let events = FileEvents(root: real)
        events.onChange = { [weak self] paths in self?.changed(paths) }
        events.start()
        self.events = events
        // The first read at once, so what git ignores is not shown for longer than it takes git to say.
        readGit()
        setDiagnostics(fileDiagnostics)
    }

    var rootPath: String? { tree?.root.path }

    /// The row's content for a path, when it is on screen as a row (for the self-check).
    func cell(for path: String) -> TreeCellView? {
        guard let node = tree?.node(at: path) else { return nil }
        let row = outline.row(forItem: node)
        return row >= 0 ? outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? TreeCellView : nil
    }

    /// The files that have diagnostics, as nvim and the last build say them (absolute paths, their worst level). The
    /// folding up through the folders happens off the main thread; then only the rows whose mark changed are drawn
    /// again, so a flurry of diagnostics costs the screen nothing.
    func setDiagnostics(_ files: [String: DiagnosticLevel]) {
        fileDiagnostics = files
        guard let tree else { return }
        let root = tree.root.path
        diagnosticTask?.cancel()
        diagnosticTask = Task { [weak self] in
            let marks = await Task.detached(priority: .utility) {
                var real: [String: DiagnosticLevel] = [:]
                for (path, level) in files {
                    let path = RealPath.of(path)
                    real[path] = max(real[path] ?? level, level)
                }
                return DiagnosticMarks.fold(real, under: root)
            }.value
            guard !Task.isCancelled, let self, self.tree === tree else { return }
            for node in tree.apply(marks) where node !== tree.root {
                let row = outline.row(forItem: node)
                if row >= 0 { outline.reloadData(forRowIndexes: [row], columnIndexes: [0]) }
            }
        }
    }

    /// The chip at the foot: the git root's name and the branch, read from .git; the folder's name outside a
    /// repository.
    func showChip(for path: String) {
        if let info = GitHead.info(at: path) {
            onChip?(info.rootName, info.branch, info.isWorktree)
        } else {
            onChip?((path as NSString).lastPathComponent, "", false)
        }
    }

    /// The rows now showing, top to bottom.
    var visibleNodes: [TreeNode] {
        (0 ..< outline.numberOfRows).compactMap { outline.item(atRow: $0) as? TreeNode }
    }

    var selectedNode: TreeNode? { outline.item(atRow: outline.selectedRow) as? TreeNode }

    func isExpanded(_ node: TreeNode) -> Bool { outline.isItemExpanded(node) }

    func expand(_ path: String) {
        guard let node = tree?.node(at: path) else { return }
        outline.expandItem(node)
    }

    func focus() {
        outline.window?.makeFirstResponder(outline)
        if outline.selectedRow < 0,
           outline.numberOfRows > 0 { outline.selectRowIndexes([0], byExtendingSelection: false) }
    }

    // MARK: Following the files

    /// Files changed on disk: the folders showing them are looked at a moment after the last change (a build reports
    /// thousands in a second), their names compared off the main thread, and only those that gained or lost a name are
    /// read
    /// again and shown; git is asked afresh (it says what changed in the files themselves).
    private func changed(_ paths: [String]) {
        guard let tree else { return }
        for path in paths {
            // The nearest folder that is read: the file's own, or (a new folder, with files in it) the one it is in.
            var folder = (path as NSString).deletingLastPathComponent
            while folder.hasPrefix(tree.root.path) {
                if let node = tree.node(at: folder), node.children != nil {
                    changedFolders.insert(folder)
                    break
                }
                if folder == tree.root.path { break }
                folder = (folder as NSString).deletingLastPathComponent
            }
            // The path itself, when it was a folder that is now gone.
            if let node = tree.node(at: path), node.isDirectory, node.children != nil { changedFolders.insert(path) }
        }
        refreshGit()
        guard changeTask == nil else { return }
        changeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            self?.flushChanges()
        }
    }

    /// The folders that may have changed, now: those whose names are not what they were are read again.
    private func flushChanges() {
        changeTask = nil
        guard let tree, !changedFolders.isEmpty else { return }
        let before: [String: Set<String>?] = changedFolders.reduce(into: [:]) { known, folder in
            known[folder] = tree.node(at: folder)?.diskNames
        }
        changedFolders = []
        changeTask = Task { [weak self] in
            let different = await Task.detached(priority: .utility) {
                before.filter { folder, names in names.map { $0 != FileTree.namesOnDisk(folder) } ?? true }.map(\.key)
            }.value
            guard let self, let tree = self.tree else { return }
            changeTask = nil
            for folder in different.sorted(by: { $0.count < $1.count }) {
                guard let node = tree.node(at: folder) else { continue }
                tree.reload(node)
                reloadsDone += 1
                show(node)
            }
            if !filterText.isEmpty { applyFilter(filterText) }
            if !changedFolders.isEmpty {
                changeTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(400))
                    self?.flushChanges()
                }
            }
        }
    }

    private func show(_ node: TreeNode) {
        if node === tree?.root {
            outline.reloadItem(nil, reloadChildren: true)
        } else {
            outline.reloadItem(node, reloadChildren: true)
        }
    }

    /// Git is read off the main thread a moment after the last change, and the rows it touches shown again.
    func refreshGit() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.readGit() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func readGit() {
        guard let tree else { return }
        let root = tree.root.path
        gitTask?.cancel()
        gitTask = Task { [weak self] in
            let state = await Task.detached { GitState.read(in: root) }.value
            guard !Task.isCancelled, let self, self.tree === tree else { return }
            let affected = tree.apply(state)
            sidebar.show(name: tree.root.name, branch: state.branch)
            showChip(for: tree.root.path)
            for node in affected {
                show(node)
            }
            // Marks changed on rows that stayed: drawn again.
            outline.reloadData(forRowIndexes: IndexSet(0 ..< outline.numberOfRows), columnIndexes: [0])
        }
    }

    // MARK: The editor's side

    /// Shows the path in the tree: the folders on the way open, the row is selected and scrolled to.
    func reveal(_ path: String) {
        guard let tree else { return }
        let found = tree.reveal(path)
        for folder in found.folders where folder !== tree.root {
            outline.expandItem(folder)
        }
        guard let node = found.node else { return }
        let row = outline.row(forItem: node)
        guard row >= 0 else { return }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        outline.scrollRowToVisible(row)
    }

    /// A click opens a file and the keyboard stays in the tree, so the keys go on working; a double-click goes on to
    /// the
    /// editor.
    @objc private func clicked(_: Any?) {
        guard outline.clickedRow >= 0, let node = outline.item(atRow: outline.clickedRow) as? TreeNode else { return }
        activate(node, toEditor: false)
    }

    @objc private func doubleClicked(_: Any?) {
        guard outline.clickedRow >= 0, let node = outline.item(atRow: outline.clickedRow) as? TreeNode,
              !node.isDirectory else { return }
        activate(node, toEditor: true)
    }

    /// A folder opens or closes; a file opens in the editor, and `toEditor` has the keyboard follow it there.
    func activate(_ node: TreeNode, toEditor: Bool = false) {
        if node.isDirectory {
            if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
        } else {
            onOpen?(node.path, toEditor)
        }
    }

    // MARK: Data source and delegate

    func outlineView(_: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let tree else { return 0 }
        return tree.children(of: (item as? TreeNode) ?? tree.root).count
    }

    func outlineView(_: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let tree else { return NSNull() }
        return tree.children(of: (item as? TreeNode) ?? tree.root)[index]
    }

    func outlineView(_: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? TreeNode)?.isDirectory ?? false
    }

    func outlineView(_: NSOutlineView, rowViewForItem _: Any) -> NSTableRowView? {
        let row = TreeRowView()
        row.look = look
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor _: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? TreeNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? TreeCellView ?? {
            let made = TreeCellView(frame: .zero)
            made.identifier = identifier
            return made
        }()
        cell.configure(node, expanded: outlineView.isItemExpanded(node), look: look)
        return cell
    }

    func outlineViewItemDidExpand(_ notification: Notification) { reloadIcon(notification) }
    func outlineViewItemDidCollapse(_ notification: Notification) { reloadIcon(notification) }

    /// The folder's icon is open or closed.
    private func reloadIcon(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? TreeNode else { return }
        let row = outline.row(forItem: node)
        if row >= 0 { outline.reloadData(forRowIndexes: [row], columnIndexes: [0]) }
    }
}
