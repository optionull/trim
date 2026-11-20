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
    /// The selected row: the text's colour, faintly; more while the tree has the keyboard.
    var selection: NSColor { NSColor(frameRGB: palette.foreground, alpha: 0.10) }
    var focusedSelection: NSColor { NSColor(frameRGB: palette.foreground, alpha: 0.20) }

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

/// The column left of the grid: a rounded island with the folder's name and branch over the tree.
final class SidebarView: NSView {
    var look = TreeLook() {
        didSet { applyLook() }
    }

    let scroll = NSScrollView()
    private let title = NSTextField(labelWithString: "")
    private let branch = NSTextField(labelWithString: "")
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
        for view in [scroll, title, branch] {
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
        let width = bounds.width - 2 * inset
        title.frame = NSRect(x: inset, y: hasBranch ? 8 : 12, width: width, height: title.frame.height)
        branch.frame = NSRect(x: inset, y: title.frame.maxY + 1, width: width, height: branch.frame.height)
        branch.isHidden = !hasBranch
        let top = max(headerHeight, branch.frame.maxY + 6)
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

/// The outline: vim's keys beside the arrows, and Escape (or Tab) back to the editor.
final class TreeOutline: NSOutlineView {
    var onEscape: (() -> Void)?
    /// Keys that are nvim's, not the tree's: the leader, `:` and Control chords. The keyboard goes to the editor with
    /// the
    /// key, so a sequence that starts here (`<leader>e`, `<C-w>l`, `:`) is finished there, whatever row is selected.
    var onForward: ((NSEvent) -> Void)?
    /// The characters that are nvim's leader and local leader (Space for most configs).
    var leaders: Set<String> = [" "]
    /// A node entered; `toEditor` when the keyboard should go along to the editor.
    var onActivate: ((TreeNode, _ toEditor: Bool) -> Void)?
    private var pendingG = false

    override var acceptsFirstResponder: Bool { true }

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
        case "\u{1B}", "\t": onEscape?()
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

/// A row's content: the icon, the name, and what git says at the right.
final class TreeCellView: NSTableCellView {
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
    }
}

/// The tree in the sidebar: a folder's files read as they are asked for, kept up to date by the file system's events
/// and by git, and the way into the editor: what is clicked or entered opens in nvim.
@MainActor
final class TreeController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let sidebar: SidebarView
    let outline = TreeOutline()
    private(set) var tree: FileTree?
    private var events: FileEvents?
    private var gitTask: Task<Void, Never>?
    private var pending: DispatchWorkItem?
    /// The editor's colours and font as they are now.
    private(set) var look = TreeLook()
    /// A file is opened: the path, for the editor to show, and whether the keyboard goes to the editor with it.
    var onOpen: ((String, Bool) -> Void)?
    /// Back to the editor.
    var onEscape: (() -> Void)?
    /// A key that is nvim's: the editor takes the keyboard and the key.
    var onForward: ((NSEvent) -> Void)?

    /// The leader and local leader nvim has (its config's, known once it has started).
    var leaders: Set<String> {
        get { outline.leaders }
        set { outline.leaders = newValue }
    }

    init(sidebar: SidebarView) {
        self.sidebar = sidebar
        super.init()
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
        outline.onForward = { [weak self] event in self?.onForward?(event) }
        outline.onActivate = { [weak self] node, toEditor in self?.activate(node, toEditor: toEditor) }
        outline.doubleAction = #selector(doubleClicked(_:))
        sidebar.scroll.documentView = outline
    }

    /// The editor's colour scheme changed (or the first one arrived): the sidebar follows it.
    func follow(background: Int, foreground: Int) {
        let palette = TreePalette(background: background, foreground: foreground)
        guard palette != look.palette else { return }
        look.palette = palette
        applyLook()
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
        let tree = FileTree(root: real)
        self.tree = tree
        tree.children(of: tree.root)
        outline.reloadData()
        sidebar.show(name: tree.root.name, branch: "")
        let events = FileEvents(root: real)
        events.onChange = { [weak self] paths in self?.changed(paths) }
        events.start()
        self.events = events
        // The first read at once, so what git ignores is not shown for longer than it takes git to say.
        readGit()
    }

    var rootPath: String? { tree?.root.path }

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

    /// Files changed on disk: the folders showing them are read again, and git is asked afresh.
    private func changed(_ paths: [String]) {
        guard let tree else { return }
        var folders: Set<String> = []
        for path in paths {
            let folder = (path as NSString).deletingLastPathComponent
            if let node = tree.node(at: folder), node.children != nil { folders.insert(folder) }
            // The path itself, when it was a folder that is now gone.
            if let node = tree.node(at: path), node.isDirectory, node.children != nil { folders.insert(path) }
        }
        for folder in folders.sorted(by: { $0.count < $1.count }) {
            guard let node = tree.node(at: folder) else { continue }
            tree.reload(node)
            show(node)
        }
        refreshGit()
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
