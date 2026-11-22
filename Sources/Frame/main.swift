import AppKit
import CoreText
import FrameModes
import FrameTree
import FrameWorkspaces
import MessagePack
import SillCore
import SillEditor
import SillNvim

// Frame (a working title): Shim's host, the start of a workspace of native panes around nvim. Today still nvim alone in
// a native window, drawn by sill's Metal grid, its command line, completion and messages as native views, with the
// person's own nvim config; a copy of Shim's, which then diverges. No title bar by default; the window keeps macOS's
// rounded corners
// and shadow, and moves by its margin. Settings are sill's (~/.config/sill/settings.toml): the font, its size and line
// height, and `title_bar` under [shell].

/// Where sill's runtime is: in the app's Resources, else (a `swift run` build) in the source tree.
enum FrameRuntime {
    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["SILL_RUNTIME"] { return URL(fileURLWithPath: override) }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("runtime"),
           FileManager.default.fileExists(atPath: bundled.appendingPathComponent("plugin/sill.lua").path)
        {
            return bundled
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("runtime")
    }
}

/// Where the status bar sits: under the grid next to the sidebar, or across the whole window under both.
enum StatusPlacement: String {
    case editor, window
}

/// How the window's panes are laid out, remembered between starts and across a switch of config.
enum PaneLayout {
    static var tabsPlacement: TabsPlacement {
        get { UserDefaults.standard.string(forKey: "tabsPlacement").flatMap(TabsPlacement.init) ?? .statusbar }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "tabsPlacement") }
    }

    /// At most this many tabs (0: no limit) before the ones never edited are closed, if `tabsAutoclose`.
    static var tabsMax: Int {
        get { UserDefaults.standard.object(forKey: "tabsMax") as? Int ?? 10 }
        set { UserDefaults.standard.set(newValue, forKey: "tabsMax") }
    }

    /// Where the tabs were before they were hidden, for "show" to go back to.
    static var tabsLastShown: TabsPlacement {
        get { UserDefaults.standard.string(forKey: "tabsLastShown").flatMap(TabsPlacement.init) ?? .statusbar }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "tabsLastShown") }
    }

    static var tabsAutoclose: Bool {
        get { UserDefaults.standard.object(forKey: "tabsAutoclose") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "tabsAutoclose") }
    }

    static var statusPlacement: StatusPlacement {
        get { UserDefaults.standard.string(forKey: "statusPlacement").flatMap(StatusPlacement.init) ?? .editor }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "statusPlacement") }
    }

    static let widthRange: ClosedRange<CGFloat> = 160 ... 520
    static let defaultWidth: CGFloat = 240

    static var sidebarWidth: CGFloat {
        get {
            let stored = UserDefaults.standard.double(forKey: "sidebarWidth")
            return stored == 0 ? defaultWidth : min(max(stored, widthRange.lowerBound), widthRange.upperBound)
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: "sidebarWidth") }
    }

    static var sidebarVisible: Bool {
        get { UserDefaults.standard.object(forKey: "sidebarVisible") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "sidebarVisible") }
    }
}

/// The strip between the sidebar and the grid: drag it to size the sidebar, double-click to size it back.
final class DividerView: NSView {
    weak var host: FrameView?
    private var startWidth: CGFloat = 0
    private var startX: CGFloat = 0

    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        guard let host else { return }
        if event.clickCount == 2 {
            host.sidebarWidth = PaneLayout.defaultWidth
            return
        }
        startWidth = host.sidebarWidth
        startX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        mouseDragged(from: startWidth, by: event.locationInWindow.x - startX)
    }

    /// The sidebar `distance` wider (or narrower) than `width`: what a drag from that width comes to.
    func mouseDragged(from width: CGFloat, by distance: CGFloat) {
        host?.sidebarWidth = width + distance
    }
}

/// The window's content: the sidebar, then the grid, inset by a margin the window moves by, and the native overlays
/// over the grid.
final class FrameView: NSView {
    let editor: EditorView
    let overlay: NSView
    let sidebar: SidebarView
    let statusBar: StatusBarView
    /// The workspace button under the sidebar, level with the status bar.
    let chip: WorkspaceChip
    /// The tabs: a strip over or under the grid, or a list beside it.
    let tabStrip: TabsView
    let tabList: TabsView
    var tabsPlacement: TabsPlacement = .statusbar {
        didSet {
            needsLayout = true
            if persisting { PaneLayout.tabsPlacement = tabsPlacement }
        }
    }

    static let tabListWidth: CGFloat = 210
    /// The terminal pane a run or build shows in, beside the code or under it (`RunPlacement`).
    var terminal: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let terminal { addSubview(terminal) }
            needsLayout = true
        }
    }

    let divider = DividerView()
    /// What is going on (servers loading and analysing, a build): a toast at the bottom left of the code.
    let progress = ProgressToastView()
    /// Whether the bar shows under the grid (a config can keep its own status line instead).
    var statusVisible = true {
        didSet { needsLayout = true }
    }

    /// Next to the sidebar (under the grid only), or across the window (the sidebar makes room for it too).
    var statusPlacement: StatusPlacement = .editor {
        didSet {
            needsLayout = true
            if persisting { PaneLayout.statusPlacement = statusPlacement }
        }
    }

    /// Room for the title bar's buttons when it shows.
    var top: CGFloat = 0 {
        didSet { needsLayout = true }
    }

    /// Whether changes to the layout are remembered (not in the self-check).
    private let persisting: Bool
    var sidebarVisible: Bool {
        didSet {
            needsLayout = true
            if persisting { PaneLayout.sidebarVisible = sidebarVisible }
        }
    }

    var sidebarWidth: CGFloat {
        didSet {
            sidebarWidth = min(max(sidebarWidth, PaneLayout.widthRange.lowerBound), PaneLayout.widthRange.upperBound)
            needsLayout = true
            if persisting { PaneLayout.sidebarWidth = sidebarWidth }
        }
    }

    static let margin: CGFloat = 8
    /// The gap between the sidebar and the grid, which is also what is grabbed to size it.
    static let dividerWidth: CGFloat = 8

    init(
        editor: EditorView, overlay: NSView, sidebar: SidebarView, statusBar: StatusBarView, chip: WorkspaceChip,
        tabStrip: TabsView, tabList: TabsView, persisting: Bool
    ) {
        self.editor = editor
        self.overlay = overlay
        self.sidebar = sidebar
        self.statusBar = statusBar
        self.chip = chip
        self.tabStrip = tabStrip
        self.tabList = tabList
        self.persisting = persisting
        sidebarVisible = persisting ? PaneLayout.sidebarVisible : true
        statusPlacement = persisting ? PaneLayout.statusPlacement : .editor
        tabsPlacement = persisting ? PaneLayout.tabsPlacement : .statusbar
        sidebarWidth = persisting ? PaneLayout.sidebarWidth : PaneLayout.defaultWidth
        super.init(frame: editor.frame)
        wantsLayer = true
        divider.host = self
        addSubview(sidebar)
        addSubview(divider)
        addSubview(editor)
        addSubview(overlay)
        addSubview(statusBar)
        addSubview(chip)
        addSubview(tabStrip)
        addSubview(tabList)
        progress.isHidden = true
        addSubview(progress)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    /// The margin moves the window: there is no title bar to drag.
    override var mouseDownCanMoveWindow: Bool { true }

    override func layout() {
        super.layout()
        let frame = bounds.insetBy(dx: Self.margin, dy: Self.margin)
        let y = frame.minY + top
        // The foot is a strip, the height of the status bar: the bar, and the workspace button where there is a sidebar
        // to put it under. The sidebar's island and the grid make room above them.
        let barHeight = StatusBarView.height(for: statusBar.look), gap: CGFloat = 6
        let across = statusPlacement == .window
        let barStrip = statusVisible ? barHeight + gap : 0
        // The button is the sidebar's, under it; with the bar across the window it is the bar's first segment instead.
        let chipShown = sidebarVisible && !across
        let sidebarStrip = across ? barStrip : (chipShown ? barHeight + gap : 0)
        statusBar.isHidden = !statusVisible
        chip.isHidden = !chipShown
        let top = frame.minY + top
        var x = frame.minX
        sidebar.isHidden = !sidebarVisible
        divider.isHidden = !sidebarVisible
        let footY = frame.maxY - barHeight
        if sidebarVisible {
            // Never more than half the window, so the grid is not squeezed out.
            let width = min(sidebarWidth, frame.width / 2)
            let height = max(0, frame.maxY - top - sidebarStrip)
            sidebar.frame = NSRect(x: x, y: top, width: width, height: height)
            divider.frame = NSRect(x: x + width, y: top, width: Self.dividerWidth, height: height)
            chip.frame = NSRect(x: x, y: footY, width: width, height: barHeight)
            window?.invalidateCursorRects(for: divider)
            x += width + Self.dividerWidth
        }

        // The grid's column, and the tabs in it: a strip over or under the grid, or a list at its right.
        var column = NSRect(x: x, y: top, width: frame.maxX - x, height: max(0, frame.maxY - top - barStrip))
        if let terminal, !terminal.isHidden {
            switch RunPlacement.for(width: bounds.width) {
            case .right:
                let width = max(RunPlacement.leastWidth, (column.width * RunPlacement.fraction).rounded())
                terminal.frame = NSRect(x: column.maxX - width, y: column.minY, width: width, height: column.height)
                column.size.width -= width + gap
            case .bottom:
                let height = max(RunPlacement.leastHeight, (column.height * RunPlacement.fraction).rounded())
                terminal.frame = NSRect(x: column.minX, y: column.maxY - height, width: column.width, height: height)
                column.size.height -= height + gap
            }
        }
        let tabsShown = Tabs.isShown(count: tabStrip.tabs.count, placement: tabsPlacement)
        let stripHeight = TabsView.stripHeight(for: statusBar.look)
        tabStrip.isHidden = !(tabsShown && tabsPlacement.isStrip)
        tabList.isHidden = !(tabsShown && tabsPlacement == .right)
        if tabsShown, tabsPlacement == .top {
            tabStrip.frame = NSRect(x: column.minX, y: column.minY, width: column.width, height: stripHeight)
            column.origin.y += stripHeight + gap
            column.size.height -= stripHeight + gap
        } else if tabsShown, tabsPlacement == .bottom {
            tabStrip.frame = NSRect(
                x: column.minX,
                y: column.maxY - stripHeight,
                width: column.width,
                height: stripHeight
            )
            column.size.height -= stripHeight + gap
        } else if tabsShown, tabsPlacement == .right {
            tabList.frame = NSRect(
                x: column.maxX - Self.tabListWidth, y: column.minY, width: Self.tabListWidth, height: column.height
            )
            column.size.width -= Self.tabListWidth + gap
        }
        editor.frame = column
        overlay.frame = editor.frame
        let toastHeight = progress.contentHeight
        progress.frame = NSRect(
            x: column.minX + 12, y: column.maxY - toastHeight - 12, width: min(380, max(0, column.width - 24)),
            height: toastHeight
        )
        let barX = across || !chipShown ? frame.minX : x
        statusBar.frame = NSRect(x: barX, y: footY, width: frame.maxX - barX, height: barHeight)
    }

    override func draw(_: NSRect) {
        NSColor(rgb: editor.screen.defaultBackground).setFill()
        bounds.fill()
    }
}

extension NSColor {
    convenience init(rgb: Int) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Lets the first of two racing tasks through, so a continuation is resumed once.
final class FirstOnly: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}

/// What carries over a switch of config: where nvim was and what it had open.
struct Place {
    var cwd: String
    var files: [String]
    var current: String?
    var line: Int
    var column: Int

    static let lua = """
    local files = {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      local name = vim.api.nvim_buf_get_name(b)
      if vim.bo[b].buflisted and vim.bo[b].buftype == '' and name ~= '' then files[#files + 1] = name end
    end
    local name = vim.api.nvim_buf_get_name(0)
    local at = vim.api.nvim_win_get_cursor(0)
    return { cwd = vim.fn.getcwd(), files = files,
             current = (vim.bo.buftype == '' and name ~= '') and name or nil, line = at[1], column = at[2] }
    """

    init(cwd: String, files: [String] = [], current: String? = nil, line: Int = 1, column: Int = 0) {
        self.cwd = cwd
        self.files = files
        self.current = current
        self.line = line
        self.column = column
    }

    init?(_ value: MessagePackValue) {
        guard let map = value.dictionaryValue, let cwd = map["cwd"]?.stringValue else { return nil }
        self.init(
            cwd: cwd,
            files: (map["files"]?.arrayValue ?? []).compactMap(\.stringValue),
            current: map["current"]?.stringValue,
            line: map["line"]?.integerValue.map(Int.init) ?? 1,
            column: map["column"]?.integerValue.map(Int.init) ?? 0
        )
    }

    /// Opens it again in a new nvim: the other files as buffers, the one that was current at its cursor.
    static let restoreLua = """
    local place = ...
    for _, f in ipairs(place.files) do vim.cmd.badd(vim.fn.fnameescape(f)) end
    if place.current then
      vim.cmd.edit(vim.fn.fnameescape(place.current))
      pcall(vim.api.nvim_win_set_cursor, 0, { place.line, place.column })
    end
    """

    var argument: MessagePackValue {
        var map: [MessagePackValue: MessagePackValue] = [
            "files": .array(files.map { .string($0) }), "line": .int(Int64(line)), "column": .int(Int64(column)),
        ]
        if let current { map["current"] = .string(current) }
        return .map(map)
    }
}

/// One window of the frame: a workspace, with its own nvim, tree and sidebar. The app (`FrameApp`) holds them.
@MainActor
final class FrameWindowController: NSObject, NSWindowDelegate, NSMenuItemValidation {
    unowned let app: FrameApp
    /// The folder it was opened on (real path), the first window's being the one the app started in.
    private(set) var workspace: String
    private let startArguments: [String]
    private let isFirst: Bool
    private(set) var session = EditorSession()
    private(set) var window: NSWindow!
    private(set) var editor: EditorView!
    private(set) var view: FrameView!
    private var externalUI: ExternalUI!
    /// Which session is the current one: a session that ends after a switch is not nvim quitting.
    private var generation = 0
    /// The config nvim runs under now, and whether a switch is under way.
    private var switching = false
    /// nvim has ended, so quitting has no one to ask.
    private(set) var ended = false
    /// The tree, which stays through a switch of config: its view and its controller outlive any one nvim.
    private let sidebar = SidebarView()
    private(set) var tree: TreeController!
    /// The workspace switcher while it is up, and where the keyboard was.
    private(set) var switcher: SwitcherView?
    /// The status bar's list of open files while it is up.
    private(set) var tabPicker: TabPickerView?
    /// A list of choices (the colour schemes) while it is up, and what to do if it is put away without one chosen.
    private(set) var listPicker: ListPickerView?
    /// The worst level of each file nvim has diagnostics for, and of each file the last build complained of.
    var nvimDiagnostics: [String: DiagnosticLevel] = [:]
    /// How many diagnostics nvim has of each level, in all files.
    var nvimCounts: [DiagnosticLevel: Int] = [:]
    /// What the language servers are busy with, as nvim last said.
    var lspProgress: [ProgressItem] = []
    var problemsReloading = false
    var problemsDirty = false
    var buildDiagnostics: [String: DiagnosticLevel] = [:]
    /// What the last build printed, as problems.
    var buildProblems: [ProblemRow] = []
    /// How many problems of each level there are in all, for the status bar (nil until counted).
    var problemTotals: [DiagnosticLevel: Int]?
    /// The build pane (Output and Problems), while one shows.
    var runPane: BuildPane?
    /// Which levels of problem the pane lists, kept as the person set them.
    var problemLevels = Set(DiagnosticLevel.allCases)
    /// Every problem the pane's list is built from, by its id.
    var problemRows: [String: ProblemRow] = [:]
    private var listCancelled: (() -> Void)?
    /// Which surface has the keyboard, and what Escape does from each: the window's modes.
    private(set) var modes = Modes() {
        didSet { if modes != oldValue { refreshStatus() } }
    }

    /// The bar under the grid: like the sidebar it outlives any one nvim, and says what it was last told.
    private let statusBar = StatusBarView()
    /// The workspace button under the sidebar; it, too, outlives any one nvim.
    let chip = WorkspaceChip()
    /// The tabs, drawn in the three places they can be; one list of them.
    let tabStrip = TabsView(axis: .horizontal)
    let tabList = TabsView(axis: .vertical)
    private(set) var tabs: [FrameTab] = [] {
        didSet {
            for list in [tabStrip, tabList] {
                list.tabs = tabs
            }
            view?.needsLayout = true
            refreshStatus()
            // The list of open files shows what is open now, and goes when there is nothing to choose between.
            if tabs.count > 1 { tabPicker?.set(tabs) } else if tabPicker != nil { apply(escapeFromPicker()) }
        }
    }

    private(set) var status = StatusState()

    init(app: FrameApp, folder: String, arguments: [String], isFirst: Bool) {
        self.app = app
        workspace = folder
        startArguments = arguments
        self.isFirst = isFirst
    }

    private var checking: Bool { ProcessInfo.processInfo.environment["SILL_FRAME_CHECK"] == "1" }

    /// Makes the window and starts nvim in it.
    func start() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Nothing of it is restored, so AppKit has no state of it to save (on the main thread, waiting on the disk).
        window.isRestorable = false
        // ARC holds it: closing must not release it a second time.
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.delegate = self
        // Only the first window remembers where it was: the rest would all claim one place.
        if isFirst { window.setFrameAutosaveName("Frame") }
        tree = TreeController(sidebar: sidebar, persisting: !checking)
        tree.onOpen = { [weak self] path, toEditor in self?.open(file: path, toEditor: toEditor) }
        tree.onEscape = { [weak self] in
            self?.focusEditor()
            self?.modes.handedToEditor()
        }
        tree.onCancel = { [weak self] in self?.escape() }
        tree.onFilterChange = { [weak self] open in self?.modes.filterChanged(open: open) }
        tree.onFocused = { [weak self] in self?.modes.focused(.tree) }
        chip.onClick = { [weak self] in self?.switchWorkspace(nil) }
        for list in [tabStrip, tabList] {
            list.onSelect = { [weak self] id in self?.selectTab(id) }
            list.onClose = { [weak self] id in self?.closeTab(id) }
        }
        statusBar.onWorkspaceClick = { [weak self] in self?.switchWorkspace(nil) }
        statusBar.onFileClick = { [weak self] in self?.showTabPicker() }
        statusBar.onProblemsClick = { [weak self] in self?.toggleBuildPane(on: .problems) }
        statusBar.onBuildClick = { [weak self] in self?.showBuildOutput() }
        tree.onChip = { [weak self] name, branch, isWorktree in
            self?.chip.show(name: name, branch: branch, isWorktree: isWorktree)
            self?.refreshStatus()
        }
        tree.onPalette = { [weak self] palette in
            self?.styleWhichKey(palette)
            self?.statusBar.look = self?.tree.look ?? TreeLook()
            self?.view.progress.look = self?.tree.look ?? TreeLook()
            self?.chip.look = self?.tree.look ?? TreeLook()
            for list in [self?.tabStrip, self?.tabList] {
                list?.look = self?.tree.look ?? TreeLook()
            }
            self?.view?.needsLayout = true
        }
        tree.onForward = { [weak self] event in
            guard let self else { return }
            focusEditor()
            editor.keyDown(with: event)
        }
        makeSurface()

        if checking {
            window.setFrame(NSRect(x: 0, y: 0, width: 1100, height: 760), display: false)
            view.layoutSubtreeIfNeeded()
        } else {
            if let near = app.controllers.last(where: { $0 !== self })?.window {
                // Beside the window it was opened from, a step down and to the right.
                var frame = near.frame
                frame.origin.x += 26
                frame.origin.y -= 26
                window.setFrame(frame, display: false)
            } else {
                window.center()
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        window.makeFirstResponder(editor)
        let startup = FrameNvim.startup
        let folder = workspace, arguments = startArguments
        tree.setRoot(folder)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await launch(
                    startup: startup,
                    place: Place(cwd: folder),
                    arguments: arguments
                )
                if checking, isFirst { await FrameCheck(self, app: app).run() }
            } catch {
                let alert = NSAlert(error: error)
                alert.messageText = "The frame could not start nvim"
                alert.runModal()
                NSApp.terminate(nil)
            }
        }
    }

    /// A session, an editor on it and the view that holds them, in the window: what a switch of config makes anew.
    private func makeSurface() {
        closeSwitcher(restoring: false)
        closeTabPicker(restoring: false)
        closeList(restoring: false)
        generation += 1
        let generation = generation
        session = EditorSession()
        editor = EditorView(channel: session.channel)
        // A status line that went away must not show through the window that took its place.
        editor.windowsCover = true
        // A scroll while another still slides goes on from where the window is drawn, not back to where the first
        // began.
        editor.chainsScrolls = true
        editor.wheelLinesPerStep = 3
        editor.pixelScrolling = FrameSettings.load()["editor"]?.table?["pixelscroll"]?.bool ?? true
        // A card over the grid (the switcher, the list of open files) has the pointer: no I-beam over its rows.
        editor.isCovered = { [weak self] event in self?.cardHasPointer(event) ?? false }
        externalUI = ExternalUI(editor: editor)
        // What nvim says about its own routine (a file written, a search count) does not interrupt the code.
        externalUI.showsAsToast = { message in
            !Self.routineMessageKinds.contains(message.kind) && !message.text.hasPrefix("watch.watch")
        }
        view = FrameView(
            editor: editor, overlay: externalUI.overlay, sidebar: sidebar, statusBar: statusBar, chip: chip,
            tabStrip: tabStrip, tabList: tabList, persisting: !checking
        )
        window.contentView = view
        apply()
        let session = session
        editor.onResize = { cols, rows in Task { await session.resize(cols: cols, rows: rows) } }
        editor.onKey = { [weak self] in self?.externalUI.keyPressed() }
        editor.keyInterceptor = { [weak self] event in self?.escapeToTree(event) ?? false }
        // A click into the editor is the person's own going in: Escape there is nvim's.
        editor.onFocus = { [weak self] in self?.modes.focused(.editor, byClick: true) }
        // A fresh editor (the landing page) has not been entered from anywhere: the tree is where Escape goes.
        modes.editorRestarted()
        status = StatusState()
        let updates = session.updates
        Task { [weak self] in
            for await update in updates {
                guard let self, self.generation == generation else { return }
                tree.follow(background: update.screen.defaultBackground, foreground: update.screen.defaultForeground)
                editor.show(update.screen)
                externalUI.update(update.screen)
                refreshStatus()
                view.needsDisplay = true
            }
            // nvim ended (:qa), unless it was a switch that ended it. There is nothing left to ask about unsaved
            // changes, so quitting must not wait on it.
            guard let self, self.generation == generation else { return }
            ended = true
            app.close(self)
        }
    }

    /// Starts nvim in the current surface under `startup`, in `place`.
    private func launch(startup: EditorSession.Startup, place: Place, arguments: [String]) async throws {
        view.layoutSubtreeIfNeeded()
        let (cols, rows) = editor.gridSize
        await session.onFrontEndNotification(prefix: "frame_") { [weak self] method, args in
            Task { @MainActor in self?.nvimAsked(method, args) }
        }
        try await session.start(
            runtime: FrameRuntime.directory,
            cols: cols,
            rows: rows,
            cwd: place.cwd,
            appName: startup.appName,
            extraArgs: startup.arguments + ["-n"] + arguments
        )
        if arguments.isEmpty, place.current != nil || !place.files.isEmpty {
            _ = try await session.channel.lua(Place.restoreLua, args: [place.argument])
        }
        // The keys that are the leader here, so the tree hands them to nvim.
        let leaders = await (try? session.channel.lua(
            "return { vim.g.mapleader or '\\\\', vim.g.maplocalleader or '\\\\' }"
        ))?.arrayValue?.compactMap(\.stringValue)
        if let leaders { tree.leaders = Set(leaders.filter { $0.count == 1 }) }
        styleWhichKey(tree.look.palette)
        _ = try await session.channel.lua(Self.commandLua)
        configureTabs()
    }

    /// This window on another workspace: nvim starts again in its folder (under the same config, with nothing carried
    /// over from the last one) and the tree is rooted there. Unsaved changes are asked about first.
    func move(to folder: String) {
        let real = RealPath.of(folder)
        guard !switching, real != (tree.rootPath ?? workspace) else { return }
        switching = true
        Task { [weak self] in
            guard let self else { return }
            defer { switching = false }
            guard await resolveUnsaved() != .cancelled else { return }
            workspace = real
            tree.setRoot(real)
            if !FrameApp.checking { WorkspaceHistory.touch(real) }
            await restart(place: Place(cwd: real))
        }
    }

    /// A new nvim in this window, in `place`; one that will not start is said so, and the window closes.
    private func restart(place: Place) async {
        let old = session
        makeSurface()
        window.makeFirstResponder(editor)
        await old.stop()
        do {
            try await launch(startup: FrameNvim.startup, place: place, arguments: [])
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "nvim could not start"
            alert.runModal()
            await session.stop()
            app.close(self)
        }
    }

    /// What the frame's nvim gets once it runs: the tree and the bar follow the editor, and the commands and keys.
    private static let commandLua = """
    local function tell(method, arg) vim.rpcnotify(vim.g.sill_channel, method, arg) end
    -- The tree follows the editor: the file in the window, and the folder nvim is in.
    local group = vim.api.nvim_create_augroup('FrameTree', { clear = true })
    local function shown(buf)
      local name = vim.api.nvim_buf_get_name(buf)
      if vim.bo[buf].buftype == '' and name ~= '' then tell('frame_buffer', name) end
    end
    vim.api.nvim_create_autocmd('BufEnter', { group = group, callback = function(a) shown(a.buf) end })
    vim.api.nvim_create_autocmd('DirChanged', { group = group, callback = function() tell('frame_cwd', vim.fn.getcwd()) end })
    tell('frame_cwd', vim.fn.getcwd())
    shown(vim.api.nvim_get_current_buf())
    -- The status bar: what only nvim knows, sent to it; nvim's own status line steps aside while it shows.
    require('frame.status').start()
    -- The tabs: the open files, and keeping there from being too many.
    require('frame.tabs').start()
    -- The colour scheme's selection colour, for the tree and the tabs.
    require('frame.theme').start()
    -- Choices nvim or a plugin asks for (code actions among them) are the frame's list, not a prompt in the message area.
    require('frame.ui').setup()
    -- The tree's wavy lines: the worst diagnostic of each file.
    require('frame.diag').start()
    -- The servers the folder's project files call for start now, without a file open, and report in the background.
    local function autostart() vim.defer_fn(function() require('frame.lsp').autostart(vim.fn.getcwd()) end, 300) end
    autostart()
    vim.api.nvim_create_autocmd('DirChanged', { group = group, callback = autostart })
    -- Each mode on the leader, where the config has bound nothing: <leader>e, E, o, O (and fw, fo).
    require('frame.keys').apply()
    -- :FrameTree shows, hides or goes into the sidebar; <Plug> mappings to bind your own keys to.
    local actions = { 'toggle', 'show', 'hide', 'focus', 'filter', 'ignored', 'dotfiles' }
    vim.api.nvim_create_user_command('FrameTree', function(opts)
      local action = opts.args ~= '' and opts.args or 'toggle'
      if not vim.tbl_contains(actions, action) then
        return vim.notify('FrameTree: ' .. action .. ' is not one of ' .. table.concat(actions, ', '), vim.log.levels.ERROR)
      end
      tell('frame_tree', action)
    end, {
      nargs = '?',
      complete = function(lead)
        return vim.tbl_filter(function(name) return name:sub(1, #lead) == lead end, actions)
      end,
      desc = 'Show, hide or go into the file tree; ignored and dotfiles show or hide those files',
    })
    vim.api.nvim_create_user_command('FrameWorkspace', function() tell('frame_workspace', 'toggle') end,
      { desc = 'Switch workspace: a repository or worktree, in a window of its own' })
    vim.keymap.set('n', '<Plug>(frame-packages)', function() tell('frame_packages', '') end, { desc = 'Packages' })
    vim.api.nvim_create_user_command('FramePackages', function() tell('frame_packages', '') end, { desc = 'Browse, install and remove packages' })
    for plug, what in pairs({ run = 'default', build = 'build', ['run-pick'] = 'pick', terminal = 'terminal', ['terminal-close'] = 'close', problems = 'problems' }) do
      vim.keymap.set('n', '<Plug>(frame-' .. plug .. ')', function() tell('frame_run', what) end, { desc = 'Run: ' .. what })
    end
    vim.api.nvim_create_user_command('FrameRun', function(opts) tell('frame_run', opts.args ~= '' and opts.args or 'default') end, {
      nargs = '?', complete = function() return { 'default', 'build', 'pick', 'terminal', 'close', 'problems' } end,
      desc = 'Run (default), build, pick what to run, or show/close the terminal pane',
    })
    vim.keymap.set('n', '<Plug>(frame-find)', function() tell('frame_find', 'files') end, { desc = 'Find file' })
    vim.keymap.set('n', '<Plug>(frame-grep)', function() tell('frame_find', 'grep') end, { desc = 'Find in files' })
    vim.api.nvim_create_user_command('FrameFind', function() tell('frame_find', 'files') end, { desc = 'Find a file in the workspace' })
    vim.api.nvim_create_user_command('FrameGrep', function() tell('frame_find', 'grep') end, { desc = 'Find text in the workspace' })
    vim.keymap.set('n', '<Plug>(frame-theme)', function() tell('frame_theme_pick', '') end, { desc = 'Colour scheme' })
    vim.api.nvim_create_user_command('FrameTheme', function(opts)
      if opts.args == '' then return tell('frame_theme_pick', '') end
      if pcall(vim.cmd.colorscheme, opts.args) then
        tell('frame_theme_set', opts.args)
      else
        vim.notify('FrameTheme: no colour scheme named ' .. opts.args, vim.log.levels.ERROR)
      end
    end, {
      nargs = '?',
      complete = function() return vim.fn.getcompletion('', 'color') end,
      desc = "Choose the colour scheme: a mode with a preview as you move, or by name (saved in Frame's settings)",
    })
    vim.keymap.set('n', '<Plug>(frame-workspace)', function() tell('frame_workspace', 'toggle') end, { desc = 'Switch workspace' })
    vim.keymap.set('n', '<Plug>(frame-tree-toggle)', function() tell('frame_tree', 'toggle') end, { desc = 'Show or hide the file tree' })
    vim.keymap.set('n', '<Plug>(frame-tree-focus)', function() tell('frame_tree', 'focus') end, { desc = 'Go into the file tree' })
    -- The filter, as a <Plug> to bind; the default keys are set after everything they are for is defined (below).
    vim.keymap.set('n', '<Plug>(frame-tree-filter)', function() tell('frame_tree', 'filter') end, { desc = 'Filter the file tree' })
    -- <C-w>h from the leftmost window goes on into the tree (a mapping of the config's own is left alone).
    for _, lhs in ipairs({ '<C-w>h', '<C-w><C-h>' }) do
      if vim.fn.maparg(lhs, 'n') == '' then
        vim.keymap.set('n', lhs, function()
          local before = vim.api.nvim_get_current_win()
          vim.cmd.wincmd('h')
          if vim.api.nvim_get_current_win() == before then tell('frame_focus', 'tree') end
        end, { desc = 'Window to the left, or the tree' })
      end
    end
    """

    /// Messages that are nvim reporting what it just did, not something to act on.
    static let routineMessageKinds: Set<String> = [
        "bufwrite",
        "progress",
        "search_count",
        "undo",
        "quickfix",
        "verbose",
    ]

    /// What nvim asked of the frame.
    private func nvimAsked(_ method: String, _ args: [MessagePackValue]) {
        switch method {
        case "frame_workspace": switchWorkspace(nil)
        case "frame_theme_pick": showThemePicker(nil)
        case "frame_packages": showPackages(nil)
        case "frame_select": showSelect(args)
        case "frame_diag":
            // What changed since the last time (the first time, everything): a file's worst level, 0 for none left.
            let map = args.first?.dictionaryValue ?? [:]
            for (key, value) in map[.string("files")]?.dictionaryValue ?? [:] {
                guard let path = key.stringValue, let raw = value.integerValue else { continue }
                if let level = DiagnosticLevel(rawValue: Int(raw)) { nvimDiagnostics[path] = level } else {
                    nvimDiagnostics[path] = nil
                }
            }
            if let counts = map[.string("counts")]?.arrayValue?.compactMap(\.integerValue), counts.count == 4 {
                nvimCounts = [
                    .error: Int(counts[0]),
                    .warning: Int(counts[1]),
                    .info: Int(counts[2]),
                    .hint: Int(counts[3]),
                ]
            }
            sendDiagnosticsToTree()
            reloadProblems()
        case "frame_progress":
            lspProgress = (args.first?.arrayValue ?? []).compactMap { entry in
                guard let map = entry.dictionaryValue, let id = map[.string("id")]?.stringValue else { return nil }
                let percentage = map[.string("percentage")]?.integerValue.map(Int.init)
                return ProgressItem(
                    id: id, client: map[.string("client")]?.stringValue ?? "",
                    title: map[.string("title")]?.stringValue ?? "",
                    message: map[.string("message")]?.stringValue ?? "",
                    percentage: percentage.flatMap { $0 >= 0 ? $0 : nil }
                )
            }
            updateProgressToast()
        case "frame_run":
            switch args.first?.stringValue {
            case "build": buildDefault(nil)
            case "pick": showRunPicker(nil)
            case "terminal": toggleTerminal(nil)
            case "close": closeTerminal(nil)
            case "problems": showProblems(nil)
            default: runDefault(nil)
            }
        case "frame_find": findFiles(grep: args.first?.stringValue == "grep")
        case "frame_theme_set":
            if let name = args.first?.stringValue, !name.isEmpty { FrameSettings.set(
                ["theme", "colorscheme"],
                to: .string(name)
            ) }
        case "frame_lsp_ask":
            if let name = args.first?
                .stringValue { provisionServer(name, in: args.dropFirst().first?.stringValue ?? "/") }
        case "frame_statusline": view?.statusVisible = args.first?.stringValue != "off"
        case "frame_statusbar": StatusPlacement(rawValue: args.first?.stringValue ?? "")
            .map { app.setStatusPlacement($0) }
        case "frame_status": if let map = args.first?.dictionaryValue { take(status: map) }
        case "frame_tabs": take(tabs: args.first?.arrayValue ?? [])
        case "frame_theme":
            tree.themeSelection = args.first?.dictionaryValue?[.string("selection")]?.integerValue.map { Int($0) }
        case "frame_tabs_option": tabsOption(args.first?.stringValue ?? "", args.dropFirst().first?.stringValue ?? "")
        case "frame_buffer":
            if let path = args.first?.stringValue { tree.reveal(path) }
            return
        case "frame_cwd":
            if let path = args.first?.stringValue { tree.setRoot(path) }
            return
        case "frame_focus":
            tree.focus()
            return
        case "frame_tree":
            switch args.first?.stringValue {
            case "show": setSidebar(visible: true)
            case "hide": setSidebar(visible: false)
            case "focus": focusSidebar(nil)
            case "filter":
                setSidebar(visible: true)
                tree.openFilter()
            case "ignored": tree.toggleIgnored()
            case "dotfiles": tree.toggleDotfiles()
            default:
                // Toggle: shown and entered, or hidden.
                if view.sidebarVisible { setSidebar(visible: false) } else { focusSidebar(nil) }
            }
            return
        default: break
        }
    }

    /// A file opened from the tree: nvim shows it, and has the keyboard only when asked (Return, a double-click): a
    /// click or `l` leaves it in the tree, so the next key is the tree's.
    func open(file path: String, toEditor: Bool, line: Int? = nil) {
        Task { [weak self] in
            guard let self else { return }
            _ = try? await session.channel.lua(
                """
                local path, line = ...
                local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(path))
                if not ok then return vim.notify(tostring(err), vim.log.levels.ERROR) end
                if line and line > 0 then
                  pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
                  vim.cmd('normal! zz')
                end
                """,
                args: [.string(path), line.map { .int(Int64($0)) } ?? .nil]
            )
            if toEditor {
                focusEditor()
                modes.handedToEditor()
            }
        }
    }

    /// Escape in the editor, when it is the keyboard's: in normal mode, after the tree handed it over (or on a fresh
    /// editor), it goes back to the tree and nvim does not see the key. Whether it does is the modes' to say.
    func escapeToTree(_ event: NSEvent) -> Bool {
        guard event.keyCode == 53, event.modifierFlags.isDisjoint(with: [.control, .command, .option]) else {
            return false
        }
        // The editor has the keys, so it is where the keyboard is, whatever was last told.
        modes.focused(.editor)
        let effect = modes.escape(editorMode: editor.screen.mode, sidebarVisible: view.sidebarVisible)
        guard effect != .pass else { return false }
        apply(effect)
        return true
    }

    /// Escape from the tree, its filter or the switcher: what the modes decide, done.
    func escape() {
        guard view != nil else { return }
        apply(modes.escape(editorMode: editor.screen.mode, sidebarVisible: view.sidebarVisible))
    }

    /// What the modes asked for: the keyboard somewhere, a filter closed, the switcher away.
    private func apply(_ effect: ModeEffect) {
        switch effect {
        case .pass: break
        case let .focus(surface): focus(surface)
        case .closeFilter: tree.closeFilter()
        case let .closeSwitcher(restoring): closeSwitcher(restoring: true, to: restoring)
        case let .closePicker(restoring): closeTabPicker(restoring: true, to: restoring)
        case .endPickerFilter: tabPicker?.endFilter()
        case let .closeList(restoring): closeList(restoring: true, to: restoring)
        case .endListFilter: listPicker?.endFilter()
        }
    }

    /// The keyboard to a surface (the tree's filter if it is filtering; the editor if there is no sidebar to be in).
    /// The status bar's counts are every problem there is (all files, the build's too).
    func applyProblemTotals() {
        guard let totals = problemTotals else { return }
        status.errors = totals[.error] ?? 0
        status.warnings = totals[.warning] ?? 0
        status.infos = totals[.info] ?? 0
        status.hints = totals[.hint] ?? 0
        refreshStatus()
    }

    /// The toast of what is going on: the servers' work, and the build.
    func updateProgressToast() {
        var items = lspProgress
        if !status.building.isEmpty {
            items.append(ProgressItem(
                id: "build",
                client: "Build",
                title: status.building,
                message: "",
                percentage: nil
            ))
        }
        view?.progress.items = items
    }

    /// How the build in the status bar is going: running (its title), or how it ended, for a while.
    func setBuild(running title: String = "", result: String = "", failed: Bool = false) {
        status.building = title
        updateProgressToast()
        status.buildResult = result
        status.buildFailed = failed
        refreshStatus()
    }

    /// What the tree marks: nvim's diagnostics and the build's, the worse of the two for a file.
    func sendDiagnosticsToTree() {
        tree.setDiagnostics(nvimDiagnostics.merging(buildDiagnostics) { max($0, $1) })
    }

    func terminalFocused() { modes.focused(.terminal) }
    func terminalGone() { modes.terminalHidden() }

    func focus(_ surface: Surface) {
        switch surface {
        case .terminal:
            if let pane = runPane { window.makeFirstResponder(pane.focusView) }
        case .tree where view.sidebarVisible:
            if modes.treeMode == .filter { tree.focusFilter() } else { tree.focus() }
        case .tree, .editor: window.makeFirstResponder(editor)
        case .switcher: if let panel = switcher { window.makeFirstResponder(panel.field) }
        case .picker: if let picker = tabPicker { window.makeFirstResponder(picker) }
        case .list: if let picker = listPicker { window.makeFirstResponder(picker) }
        }
    }

    // MARK: Tabs

    /// What nvim told of the open files (`frame_tabs`).
    private func take(tabs list: [MessagePackValue]) {
        tabs = list.compactMap { entry -> FrameTab? in
            guard let map = entry.dictionaryValue, let id = map[.string("id")]?.integerValue,
                  let path = map[.string("path")]?.stringValue else { return nil }
            return FrameTab(
                id: Int(id), path: path, modified: map[.string("modified")]?.boolValue ?? false,
                edited: map[.string("edited")]?.boolValue ?? false, current: map[.string("current")]?.boolValue ?? false
            )
        }
    }

    /// A tab clicked, or asked for by number: nvim shows it, and the keyboard is the editor's.
    func selectTab(_ id: Int) {
        Task { [weak self] in
            _ = try? await self?.session.channel.lua("require('frame.tabs').select(\(id))")
        }
        focusEditor()
    }

    func closeTab(_ id: Int) {
        Task { [weak self] in
            _ = try? await self?.session.channel.lua("require('frame.tabs').close(\(id))")
        }
    }

    /// The options, as the app has them, to the nvim that applies them: past the maximum, tabs never edited are closed
    /// (not while the tabs are hidden: what is not seen is not tidied).
    func configureTabs() {
        let max = app.tabsMax
        let autoclose = app.tabsAutoclose && (view?.tabsPlacement ?? .statusbar) != .hidden
        Task { [weak self] in
            _ = try? await self?.session.channel.lua(
                "require('frame.tabs').configure({ max = \(max), autoclose = \(autoclose) })"
            )
        }
    }

    /// `:FrameTabs top|bottom|right|statusbar|list|hide|show|toggle|autoclose [on|off]|max N`: what nvim cannot do
    /// itself.
    private func tabsOption(_ word: String, _ argument: String) {
        switch word {
        case "top", "bottom", "right", "statusbar": TabsPlacement(rawValue: word).map { app.setTabs(placement: $0) }
        case "hide", "hidden": app.setTabs(placement: .hidden)
        case "list": showTabPicker()
        case "show": app.setTabs(placement: app.tabsLastShown)
        case "toggle": app.setTabs(placement: view?.tabsPlacement == .hidden ? app.tabsLastShown : .hidden)
        case "autoclose": app.setTabsAutoclose(argument.isEmpty ? !app.tabsAutoclose : argument == "on")
        case "max": Int(argument).map { app.setTabsMax(max($0, 0)) }
        default: break
        }
    }

    /// Whether a card over the window is where the pointer is (a point of the window's, as an event gives it).
    func cardHasPointer(_ event: NSEvent) -> Bool {
        guard view != nil, let hit = view.hitTest(view.convert(event.locationInWindow, from: nil)) else { return false }
        return [switcher, tabPicker, listPicker].contains { card in
            card.map { hit === $0 || hit.isDescendant(of: $0) } ?? false
        }
    }

    /// The status bar's list of open files, up over the file's name, or put away if it is up.
    func showTabPicker() {
        if tabPicker != nil { return apply(escapeFromPicker()) }
        guard tabs.count > 1, view != nil else { return }
        let picker = TabPickerView(look: tree.look)
        picker.frame = view.bounds
        picker.autoresizingMask = [.width, .height]
        picker.set(tabs)
        // Over the file's name when it is the button; else at the bar's left.
        let button = statusBar.fileButton.isEmpty ? nil : statusBar.convert(statusBar.fileButton, to: view)
        picker.anchor = NSPoint(x: button?.minX ?? statusBar.frame.minX + 12, y: statusBar.frame.minY)
        picker.onDismiss = { [weak self] in self?.escape() }
        picker.onFilterChange = { [weak self] open in self?.modes.pickerFilterChanged(open: open) }
        picker.onChoose = { [weak self] id in
            guard let self else { return }
            closeTabPicker()
            selectTab(id)
        }
        picker.onClose = { [weak self] id in self?.closeTab(id) }
        modes.openPicker()
        view.addSubview(picker)
        tabPicker = picker
        window.makeFirstResponder(picker)
    }

    private func escapeFromPicker() -> ModeEffect { modes.escape(
        editorMode: editor.screen.mode,
        sidebarVisible: view.sidebarVisible
    ) }

    /// A list of choices up over the window as a mode (`title` is its word in the status bar): moving the keyboard is
    /// told
    /// to `onMove`, a choice to `onChoose`; put away any other way, `onCancel` runs (a colour scheme tried is put
    /// back).
    func showList(
        title: String, items: [PickerItem], current: String?, onMove: ((PickerItem) -> Void)? = nil,
        onChoose: @escaping (PickerItem) -> Void, onCancel: (() -> Void)? = nil, keepsOpen: Bool = false,
        configure: ((ListPickerView) -> Void)? = nil
    ) {
        guard listPicker == nil, view != nil else { return }
        let picker = ListPickerView(title: title, look: tree.look)
        picker.frame = view.bounds
        picker.autoresizingMask = [.width, .height]
        configure?(picker)
        picker.set(items, current: current)
        picker.onMove = onMove
        picker.onDismiss = { [weak self] in self?.escape() }
        picker.onFilterChange = { [weak self] open in self?.modes.listFilterChanged(open: open) }
        picker.onChoose = { [weak self] item in
            guard let self else { return }
            if !keepsOpen {
                listCancelled = nil
                closeList()
            }
            onChoose(item)
        }
        listCancelled = onCancel
        modes.openList(title: title)
        view.addSubview(picker)
        listPicker = picker
        window.makeFirstResponder(picker)
    }

    /// What `vim.ui.select` asked: a list of choices, answered back to nvim by index (or nothing, put away).
    private func showSelect(_ args: [MessagePackValue]) {
        guard args.count == 3, let id = args[0].integerValue, let rows = args[2].arrayValue else { return }
        func answer(_ index: String?) {
            let argument: MessagePackValue = index.flatMap { Int64($0) }.map { .int($0) } ?? .nil
            Task {
                _ = try? await self.session.channel.lua("require('frame.ui').chosen(...)", args: [.int(id), argument])
            }
        }
        let items = rows.compactMap { row -> PickerItem? in
            guard let pair = row.arrayValue, pair.count >= 2, let index = pair[0].stringValue,
                  let title = pair[1].stringValue else { return nil }
            return PickerItem(
                id: index, title: title, detail: pair.count > 2 ? pair[2].stringValue ?? "" : "",
                file: pair.count > 3 ? pair[3].stringValue.flatMap { $0.isEmpty ? nil : $0 } : nil
            )
        }
        // Another list is up: nothing is asked of the person twice, the question is let go.
        guard listPicker == nil, !items.isEmpty else { return answer(nil) }
        showList(
            title: args[1].stringValue ?? "Choose", items: items, current: nil,
            onChoose: { answer($0.id) }, onCancel: { answer(nil) }
        )
    }

    /// The list of choices away, the keyboard back where it was; a list put away with nothing chosen runs its
    /// `onCancel`.
    func closeList(restoring: Bool = true, to surface: Surface? = nil) {
        guard let picker = listPicker else { return }
        listPicker = nil
        picker.removeFromSuperview()
        let back = modes.closeList()
        let cancelled = listCancelled
        listCancelled = nil
        cancelled?()
        if restoring { focus(surface ?? back) }
    }

    /// The list away; the keyboard goes back to where it was.
    func closeTabPicker(restoring: Bool = true, to surface: Surface? = nil) {
        guard let picker = tabPicker else { return }
        tabPicker = nil
        picker.removeFromSuperview()
        let back = modes.closePicker()
        if restoring { focus(surface ?? back) }
    }

    @objc func showOpenFiles(_: Any?) { showTabPicker() }

    // MARK: Packages

    /// A row of the package browser as nvim's catalog gave it.
    struct PackageRow {
        var name: String, kind: String, description: String, version: String, status: String
        var dir: String, repo: String, tag: String, commit: String
    }

    static func packageItem(_ row: PackageRow, busy: String?) -> PickerItem {
        let state = busy ?? (row.status == "available" ? row.version : row.status)
        return PickerItem(
            id: row.name, title: row.name, detail: row.kind + " · " + state, subtitle: row.description,
            isCurrent: ["bundled", "installed"].contains(row.status) && busy == nil
        )
    }

    /// The packages as a mode: Return installs one, or switches a bundled one off or on (from the next start), `x`
    /// removes an
    /// installed one. The list stays up while it works.
    @objc func showPackages(_: Any?) {
        guard listPicker == nil else { return }
        Task { [weak self] in
            guard let self, listPicker == nil else { return }
            var rows = await packageRows()
            guard !rows.isEmpty else { return }
            var busy: [String: String] = [:]
            @MainActor func refresh(keep name: String?) {
                listPicker?.set(rows.map { Self.packageItem($0, busy: busy[$0.name]) }, current: name)
            }
            func say(_ text: String) {
                Task { _ = try? await self.session.channel.lua("vim.notify(...)", args: [.string(text)]) }
            }
            @MainActor func toggle(_ row: PackageRow) {
                let nowDisabled = row.status != "disabled"
                let names = rows.filter { $0.name == row.name ? nowDisabled : $0.status == "disabled" }.map(\.name)
                FrameSettings.set(["plugins", "disabled"], to: .array(names.map { .string($0) }))
                if let at = rows.firstIndex(where: { $0.name == row.name }) {
                    rows[at].status = nowDisabled ? "disabled" : "bundled"
                }
                busy[row.name] = nowDisabled ? "off after a restart" : "on after a restart"
                refresh(keep: row.name)
            }
            @MainActor func install(_ row: PackageRow) {
                guard busy[row.name] == nil else { return }
                busy[row.name] = "installing…"
                refresh(keep: row.name)
                Task { @MainActor in
                    do {
                        try await FramePackages.install(repo: row.repo, tag: row.tag, commit: row.commit, to: row.dir)
                        _ = try? await self.session.channel.lua(
                            "require('frame.catalog').loaded(...)", args: [.string(row.name)]
                        )
                        say("Installed \(row.name) \(row.tag)")
                    } catch {
                        say("Could not install \(row.name): \(error)")
                    }
                    busy[row.name] = nil
                    rows = await self.packageRows()
                    refresh(keep: row.name)
                }
            }
            @MainActor func remove(_ row: PackageRow) {
                do { try FramePackages.remove(row.dir) } catch { return say("Could not remove \(row.name): \(error)") }
                Task { @MainActor in
                    _ = try? await self.session.channel.lua(
                        "require('frame.catalog').unloaded(...)", args: [.string(row.name)]
                    )
                    busy[row.name] = "gone after a restart"
                    rows = await self.packageRows()
                    refresh(keep: row.name)
                }
            }
            showList(
                title: "Packages", items: rows.map { Self.packageItem($0, busy: nil) }, current: nil,
                onChoose: { item in
                    guard let row = rows.first(where: { $0.name == item.id }) else { return }
                    switch row.status {
                    case "available": install(row)
                    case "bundled", "disabled": toggle(row)
                    default: say("\(row.name) is installed: x removes it")
                    }
                },
                keepsOpen: true,
                configure: { picker in
                    picker.onKey = { key, item in
                        guard key == "x", let row = rows.first(where: { $0.name == item.id }), row.status == "installed"
                        else { return false }
                        remove(row)
                        return true
                    }
                }
            )
        }
    }

    func packageRows() async -> [PackageRow] {
        let reply = await (try? session.channel.lua("return require('frame.catalog').list()"))?.arrayValue ?? []
        return reply.compactMap { value in
            guard let map = value.dictionaryValue else { return nil }
            func text(_ key: String) -> String { map[.string(key)]?.stringValue ?? "" }
            return PackageRow(
                name: text("name"), kind: text("kind"), description: text("description"), version: text("version"),
                status: text("status"), dir: text("dir"), repo: text("repo"), tag: text("tag"), commit: text("commit")
            )
        }
    }

    // MARK: The finder

    @objc func showFinder(_: Any?) { findFiles(grep: false) }
    @objc func showGrep(_: Any?) { findFiles(grep: true) }

    /// Files of the workspace, or lines in them, as a list that asks as you type: the files ranked off the main thread,
    /// the
    /// lines by git grep after a short pause. Return opens the file (at the line).
    func findFiles(grep: Bool) {
        guard listPicker == nil else { return }
        let root = workspace
        var files: [String] = []
        var pending: Task<Void, Never>?
        func items(_ paths: [String]) -> [PickerItem] {
            paths.map { path in
                let name = (path as NSString).lastPathComponent
                return PickerItem(
                    id: path,
                    title: name,
                    detail: (path as NSString).deletingLastPathComponent,
                    file: name
                )
            }
        }
        showList(
            title: grep ? "Find in files" : "Find file", items: [], current: nil,
            onChoose: { [weak self] item in
                let parts = item.id.split(separator: "\t", maxSplits: 1).map(String.init)
                self?.open(file: root + "/" + parts[0], toEditor: true, line: parts.count > 1 ? Int(parts[1]) : nil)
            },
            onCancel: { pending?.cancel() },
            configure: { [weak self] picker in
                picker.liveQuery = true
                picker.onQuery = { query in
                    pending?.cancel()
                    pending = Task { @MainActor [weak picker] in
                        if grep {
                            try? await Task.sleep(for: .milliseconds(120))
                            guard !Task.isCancelled else { return }
                            let hits = await FileIndex.grep(query, in: root)
                            guard !Task.isCancelled else { return }
                            picker?.set(hits.map {
                                PickerItem(
                                    id: "\($0.path)\t\($0.line)", title: $0.text, detail: "\($0.path):\($0.line)",
                                    file: ($0.path as NSString).lastPathComponent
                                )
                            }, current: nil)
                        } else {
                            let snapshot = files
                            let ranked = await Task.detached { FileIndex.rank(query, in: snapshot) }.value
                            guard !Task.isCancelled else { return }
                            picker?.set(items(ranked), current: nil)
                        }
                    }
                }
                guard !grep else { return }
                Task { @MainActor [weak picker] in
                    files = await FileIndex.files(in: root)
                    if let picker, picker.all.isEmpty { picker.set(
                        items(FileIndex.rank(picker.filter ?? "", in: files)),
                        current: nil
                    ) }
                    _ = self
                }
            }
        )
    }

    // MARK: Language servers

    /// A server nvim asked for: its program found or provisioned off the main thread, then told to nvim's supervisor;
    /// when
    /// there is none, nvim is told so, and why (Node missing, say).
    func provisionServer(_ name: String, in directory: String) {
        Task { [weak self] in
            let result: Result<[String], FrameServers.Failure>
            do {
                result = try await .success(FrameServers.command(for: name, in: directory))
            } catch {
                result = .failure((error as? FrameServers.Failure) ?? FrameServers.Failure(description: "\(error)"))
            }
            guard let self else { return }
            switch result {
            case let .success(command):
                _ = try? await session.channel.lua(
                    "require('frame.lsp').ready(...)", args: [
                        .string(name),
                        .array(command.map(MessagePackValue.string)),
                    ]
                )
            case let .failure(why):
                _ = try? await session.channel.lua("require('frame.lsp').ready(..., nil)", args: [.string(name)])
                _ = try? await session.channel.lua("vim.notify(..., vim.log.levels.WARN)", args: [
                    .string("No \(FrameServers.label(name)) language server: \(why.description)"),
                ])
            }
        }
    }

    // MARK: The colour scheme

    /// The colour schemes as choices: Frame's own first, then nvim's.
    static func themeItems(_ names: [String], current: String) -> [PickerItem] {
        let bundled = ["tokyonight", "catppuccin", "rose-pine"]
        func isLight(_ name: String) -> Bool {
            ["day", "latte", "dawn", "light", "morning", "shine", "peachpuff", "delek", "zellner"]
                .contains { name.contains($0) }
        }
        func rank(_ name: String) -> Int { bundled.firstIndex { name.hasPrefix($0) } ?? bundled.count }
        return names.sorted { (rank($0), $0) < (rank($1), $1) }.map { name in
            let kind = rank(name) < bundled.count ? "Frame" : "nvim"
            return PickerItem(
                id: name,
                title: name,
                detail: kind + (isLight(name) ? " · light" : ""),
                isCurrent: name == current
            )
        }
    }

    /// The colour schemes as a mode: moving through them tries each (the sidebar, tabs and bar follow), Return keeps
    /// one
    /// and saves it in the settings, Escape puts back the one there was.
    @objc func showThemePicker(_: Any?) {
        if listPicker != nil { return apply(escapeFromPicker()) }
        Task { [weak self] in
            guard let self, listPicker == nil else { return }
            let reply = await (try? session.channel.lua(
                "return { vim.g.colors_name or '', vim.fn.getcompletion('', 'color') }"
            ))?.arrayValue
            guard let reply, reply.count == 2, let names = reply[1].arrayValue?.compactMap(\.stringValue),
                  !names.isEmpty
            else { return }
            let original = reply[0].stringValue ?? ""
            // Every highlight as it is, to put back exactly if the list is put away with nothing chosen.
            _ = try? await session.channel.lua("require('frame.theme').snapshot()")
            func apply(_ name: String) {
                Task {
                    _ = try? await self.session.channel.lua("pcall(vim.cmd.colorscheme, ...)", args: [.string(name)])
                }
            }
            showList(
                title: "Colour scheme", items: Self.themeItems(names, current: original), current: original,
                onMove: { apply($0.id) },
                onChoose: { item in
                    apply(item.id)
                    FrameSettings.set(["theme", "colorscheme"], to: .string(item.id))
                },
                onCancel: {
                    Task { _ = try? await self.session.channel.lua("require('frame.theme').restore()") }
                }
            )
        }
    }

    @objc func nextTab(_: Any?) { stepTab(1) }
    @objc func previousTab(_: Any?) { stepTab(-1) }

    private func stepTab(_ step: Int) {
        guard let id = Tabs.neighbor(of: tabs.first { $0.current }?.id, in: tabs, by: step) else { return }
        selectTab(id)
    }

    @objc func closeCurrentTab(_: Any?) {
        if let current = tabs.first(where: \.current) { closeTab(current.id) }
    }

    @objc func chooseTabsPlacement(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let placement = TabsPlacement(rawValue: raw) {
            app.setTabs(placement: placement)
        }
    }

    @objc func chooseTabsMax(_ sender: NSMenuItem) {
        if let limit = sender.representedObject as? Int { app.setTabsMax(limit) }
    }

    @objc func toggleTabsAutoclose(_: Any?) { app.setTabsAutoclose(!app.tabsAutoclose) }

    /// What nvim told the bar (`frame_status`): the buffer's state, the cursor, the diagnostics, the servers.
    private func take(status map: [MessagePackValue: MessagePackValue]) {
        func text(_ key: String) -> String { map[.string(key)]?.stringValue ?? "" }
        func number(_ key: String) -> Int { Int(map[.string(key)]?.integerValue ?? 0) }
        func flag(_ key: String) -> Bool { map[.string(key)]?.boolValue ?? false }
        let path = text("path")
        let buftype = text("buftype")
        status.path = path.isEmpty ? (buftype.isEmpty ? "[No name]" : "[\(buftype)]") : StatusLine.displayPath(
            path,
            root: tree.rootPath
        )
        status.name = path.isEmpty ? "" : (path as NSString).lastPathComponent
        status.filetype = text("ft")
        status.modified = flag("modified")
        status.readonly = flag("readonly")
        status.recording = text("recording")
        status.line = number("line")
        status.col = number("col")
        status.lines = number("lines")
        status.top = number("top")
        status.bottom = number("bottom")
        status.errors = number("errors")
        status.warnings = number("warnings")
        status.infos = number("infos")
        status.hints = number("hints")
        // The bar counts every problem (all files, the build's too), not only the file in the window.
        if let totals = problemTotals {
            status.errors = totals[.error] ?? 0
            status.warnings = totals[.warning] ?? 0
            status.infos = totals[.info] ?? 0
            status.hints = totals[.hint] ?? 0
        }
        status.lsp = map[.string("lsp")]?.arrayValue?.compactMap(\.stringValue) ?? []
        refreshStatus()
    }

    /// The bar says the mode the window is in (nvim's, or the tree's or the switcher's) and the branch, with the rest
    /// as it was last told.
    func refreshStatus() {
        guard editor != nil else { return }
        status.mode = modes.label(editorMode: editor.screen.mode)
        // The sidebar says the branch (under the folder's name, and in the chip), so the bar does when it is not there.
        status.branch = view.sidebarVisible ? "" : chip.branch
        status.workspace = chip.name
        status.workspaceIsWorktree = chip.isWorktree
        status.showsWorkspace = view.statusPlacement == .window
        // The tabs in the status bar: the file's name is the way to the others, when there are others.
        status.picker = view.tabsPlacement == .statusbar && tabs.count > 1 ? tabs.count : 0
        statusBar.state = status
    }

    func focusEditor() {
        window.makeFirstResponder(editor)
        modes.focused(.editor)
    }

    // MARK: The workspace switcher

    /// ⌘⇧O, `:FrameWorkspace`: the switcher up, or down again.
    @objc func switchWorkspace(_: Any?) {
        if switcher == nil { showSwitcher() } else { closeSwitcher() }
    }

    func showSwitcher() {
        guard switcher == nil, view != nil else { return }
        let panel = SwitcherView(look: tree.look)
        panel.frame = view.bounds
        panel.autoresizingMask = [.width, .height]
        panel.onDismiss = { [weak self] in self?.escape() }
        panel.onChoose = { [weak self] workspace, newWindow in
            guard let self else { return }
            closeSwitcher()
            app.go(to: workspace.path, from: self, newWindow: newWindow)
        }
        modes.openSwitcher()
        view.addSubview(panel)
        switcher = panel
        window.makeFirstResponder(panel.field)
        app.loadWorkspaces { [weak panel] workspaces, done in
            panel?.set(workspaces, loading: !done)
        }
    }

    /// The switcher away; the keyboard goes back to where it was (the tree, if that is where it came from).
    func closeSwitcher(restoring: Bool = true, to surface: Surface? = nil) {
        guard let panel = switcher else { return }
        switcher = nil
        panel.removeFromSuperview()
        // Escape has already told the modes; anything else (a choice, the chip) tells them now.
        let back = modes.closeSwitcher()
        if restoring { focus(surface ?? back) }
    }

    /// A which-key.nvim window in the sidebar's colours: the colours go to nvim, which applies them whenever the colour
    /// scheme does.
    func styleWhichKey(_ palette: TreePalette) {
        let colors = [palette.sidebar, palette.foreground, palette.muted].map(String.init).joined(separator: ", ")
        Task { [weak self] in
            _ = try? await self?.session.channel.lua("require('frame.whichkey').style(\(colors))")
        }
    }

    @objc func focusSidebar(_: Any?) {
        setSidebar(visible: true)
        tree.focus()
        modes.focused(.tree)
    }

    /// The settings that apply at once: the title bar, the font.
    func apply() {
        let titleBar = Settings.shared.current.shellTitleBar
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = !titleBar
        }
        view?.top = titleBar ? 22 : 0
        EditorFont.load(Settings.shared.current)
    }

    func fontChanged() {
        editor.fontChanged()
        tree.fontChanged()
    }

    enum Unsaved { case clean, saved, discarded, cancelled }

    /// What is asked of nvim before leaving it, so a reason to ask again when it does not answer.
    private static let unsavedLua = """
    return #vim.tbl_filter(function(b) return vim.bo[b].modified and vim.bo[b].buflisted end, vim.api.nvim_list_bufs())
    """

    /// Asks what to do with unsaved changes, when there are any: save them all, drop them, or not go on.
    func resolveUnsaved() async -> Unsaved {
        // An nvim that does not answer in two seconds (stuck at a prompt, say) must not hold quitting for ever, and
        // must not be taken for having nothing unsaved either: ask.
        let channel = session.channel
        let answer: Int64? = await withCheckedContinuation { continuation in
            let first = FirstOnly()
            Task {
                let count = await (try? channel.lua(Self.unsavedLua))?.integerValue ?? 0
                if first.claim() { continuation.resume(returning: count) }
            }
            Task {
                try? await Task.sleep(for: .seconds(2))
                if first.claim() { continuation.resume(returning: nil) }
            }
        }
        guard let modified = answer else {
            let alert = NSAlert()
            alert.messageText = "nvim is not responding"
            alert.informativeText = "Changes it has not saved may be lost."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Go On Anyway")
            return alert.runModal() == .alertSecondButtonReturn ? .discarded : .cancelled
        }
        guard modified > 0 else { return .clean }
        let alert = NSAlert()
        alert.messageText = modified == 1 ? "A file has unsaved changes" : "\(modified) files have unsaved changes"
        alert.addButton(withTitle: "Save All")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return await (try? session.channel.command("wall")) != nil ? .saved : .cancelled
        case .alertThirdButtonReturn:
            return .discarded
        default:
            return .cancelled
        }
    }

    /// Closing the window asks about its unsaved changes, then stops its nvim; the last window closing quits.
    func windowShouldClose(_: NSWindow) -> Bool {
        if app.controllers.count <= 1 {
            NSApp.terminate(nil)
            return false
        }
        Task { [weak self] in
            guard let self, await resolveUnsaved() != .cancelled else { return }
            app.close(self)
        }
        return false
    }

    /// Ends this window's nvim and lets go of the window.
    func shutDown() async {
        generation += 1
        window.delegate = nil
        window.orderOut(nil)
        await session.stop()
        window.close()
    }

    /// Stops nvim (quitting).
    func stop() async { await session.stop() }

    // MARK: Menu

    /// Shows or hides the sidebar. Hidden while it has the keyboard, the keyboard goes back to the editor.
    func setSidebar(visible: Bool) {
        view.sidebarVisible = visible
        refreshStatus()
        if !visible { modes.sidebarHidden() }
        if !visible, window.firstResponder === tree.outline { focusEditor() }
    }

    @objc func toggleSidebar(_: Any?) { setSidebar(visible: !view.sidebarVisible) }
    @objc func toggleStatusAcrossWindow(_: Any?) {
        app.setStatusPlacement(view.statusPlacement == .window ? .editor : .window)
    }

    @objc func filterTree(_: Any?) {
        setSidebar(visible: true)
        tree.openFilter()
    }

    @objc func toggleIgnoredFiles(_: Any?) { tree.toggleIgnored() }
    @objc func toggleDotfiles(_: Any?) { tree.toggleDotfiles() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleIgnoredFiles(_:)): item.state = tree.showIgnored ? .on : .off
        case #selector(toggleDotfiles(_:)): item.state = tree.showDotfiles ? .on : .off
        case #selector(toggleSidebar(_:)): item.state = view.sidebarVisible ? .on : .off
        case #selector(toggleStatusAcrossWindow(_:)): item.state = view.statusPlacement == .window ? .on : .off
        case #selector(chooseTabsPlacement(_:)): item.state = (item.representedObject as? String) == view.tabsPlacement
            .rawValue ? .on : .off
        case #selector(chooseTabsMax(_:)): item.state = (item.representedObject as? Int) == app.tabsMax ? .on : .off
        case #selector(toggleTabsAutoclose(_:)): item.state = app.tabsAutoclose ? .on : .off
        case #selector(nextTab(_:)), #selector(previousTab(_:)), #selector(closeCurrentTab(_:)): return !tabs.isEmpty
        case #selector(showOpenFiles(_:)): return tabs.count > 1 || tabPicker != nil
        default: break
        }
        return true
    }

    @objc func bigger(_: Any?) { EditorFont.zoom(1) }
    @objc func smaller(_: Any?) { EditorFont.zoom(-1) }
    @objc func actual(_: Any?) { EditorFont.zoom(0) }

    /// Frame's settings, as a window.
    @objc func openSettings(_: Any?) { app.showSettings() }
}

// SILL_FONTS: a directory of fonts to use without installing them, for this process only.
if let directory = ProcessInfo.processInfo.environment["SILL_FONTS"],
   let files = FileManager.default.enumerator(at: URL(fileURLWithPath: directory), includingPropertiesForKeys: nil)
{
    let fonts = files.compactMap { $0 as? URL }.filter { ["ttf", "otf"].contains($0.pathExtension.lowercased()) }
    CTFontManagerRegisterFontURLs(fonts as CFArray, .process, false, nil)
}

// The icon font that ships in the app, before anything is drawn or the grid looks for a fallback.
NerdFont.register()

let app = NSApplication.shared
let delegate = FrameApp()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
