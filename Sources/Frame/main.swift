import AppKit
import CoreText
import FrameModes
import FrameTree
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

/// How the window's panes are laid out, remembered between starts and across a switch of config.
enum PaneLayout {
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
    let divider = DividerView()
    /// Whether the bar shows under the grid (a config can keep its own status line instead).
    var statusVisible = true {
        didSet { needsLayout = true }
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

    init(editor: EditorView, overlay: NSView, sidebar: SidebarView, statusBar: StatusBarView, persisting: Bool) {
        self.editor = editor
        self.overlay = overlay
        self.sidebar = sidebar
        self.statusBar = statusBar
        self.persisting = persisting
        sidebarVisible = persisting ? PaneLayout.sidebarVisible : true
        sidebarWidth = persisting ? PaneLayout.sidebarWidth : PaneLayout.defaultWidth
        super.init(frame: editor.frame)
        wantsLayer = true
        divider.host = self
        addSubview(sidebar)
        addSubview(divider)
        addSubview(editor)
        addSubview(overlay)
        addSubview(statusBar)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    /// The margin moves the window: there is no title bar to drag.
    override var mouseDownCanMoveWindow: Bool { true }

    override func layout() {
        super.layout()
        let frame = bounds.insetBy(dx: Self.margin, dy: Self.margin)
        let y = frame.minY + top, height = frame.height - top
        var x = frame.minX
        sidebar.isHidden = !sidebarVisible
        divider.isHidden = !sidebarVisible
        if sidebarVisible {
            // Never more than half the window, so the grid is not squeezed out.
            let width = min(sidebarWidth, frame.width / 2)
            sidebar.frame = NSRect(x: x, y: y, width: width, height: height)
            divider.frame = NSRect(x: x + width, y: y, width: Self.dividerWidth, height: height)
            window?.invalidateCursorRects(for: divider)
            x += width + Self.dividerWidth
        }
        // Under the grid, the bar: the grid is as tall as what is left.
        let barHeight = StatusBarView.height(for: statusBar.look), gap: CGFloat = 6
        statusBar.isHidden = !statusVisible
        let gridHeight = statusVisible ? max(0, height - barHeight - gap) : height
        editor.frame = NSRect(x: x, y: y, width: frame.maxX - x, height: gridHeight)
        overlay.frame = editor.frame
        statusBar.frame = NSRect(x: x, y: y + height - barHeight, width: frame.maxX - x, height: barHeight)
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

/// Where the frame remembers which nvim config it ran last. Its own state, not a setting: it changes by choosing, not
/// by
/// editing.
enum ConfigChoice {
    private static let key = "nvimConfig"
    static var remembered: String? {
        get { UserDefaults.standard.string(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
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
    private(set) var current = NvimConfig.builtIn
    private var switching = false
    /// nvim has ended, so quitting has no one to ask.
    private(set) var ended = false
    /// The tree, which stays through a switch of config: its view and its controller outlive any one nvim.
    private let sidebar = SidebarView()
    private(set) var tree: TreeController!
    /// The workspace switcher while it is up, and where the keyboard was.
    private(set) var switcher: SwitcherView?
    /// Which surface has the keyboard, and what Escape does from each: the window's modes.
    private(set) var modes = Modes() {
        didSet { if modes != oldValue { refreshStatus() } }
    }

    /// The bar under the grid: like the sidebar it outlives any one nvim, and says what it was last told.
    private let statusBar = StatusBarView()
    private var status = StatusState()

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
        sidebar.chip.onClick = { [weak self] in self?.switchWorkspace(nil) }
        tree.onPalette = { [weak self] palette in
            self?.styleWhichKey(palette)
            self?.statusBar.look = self?.tree.look ?? TreeLook()
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
        let environment = NvimProcess.cachedEnv.merging(ProcessInfo.processInfo.environment) { _, own in own }
        // NVIM_APPNAME, set when the frame starts, wins over the config chosen last.
        var startup = EditorSession.startup(environment: environment, own: checking)
        if !checking, environment["NVIM_APPNAME"] == nil, let name = ConfigChoice.remembered,
           let config = NvimConfigs.discover(environment: environment).first(where: { $0.appName == name })
        {
            startup = config.startup
        }
        current = NvimConfig(appName: startup.appName, isBuiltIn: !startup.userConfig)
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
        generation += 1
        let generation = generation
        session = EditorSession()
        editor = EditorView(channel: session.channel)
        externalUI = ExternalUI(editor: editor)
        view = FrameView(
            editor: editor, overlay: externalUI.overlay, sidebar: sidebar, statusBar: statusBar, persisting: !checking
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
        let names = configs().map(\.appName)
        _ = try await session.channel.lua(
            Self.commandLua, args: [.array(names.map { .string($0) }), .string(startup.appName)]
        )
        if !checking { ConfigChoice.remembered = startup.appName }
    }

    // MARK: Switching config

    /// Restarts nvim under another config, in this window, where it was: the same folder, the files it had open, the
    /// cursor. Unsaved changes are asked about first; a config that will not start is put back as it was.
    func switchConfig(to config: NvimConfig) {
        guard !switching, config != current else { return }
        switching = true
        Task { [weak self] in
            guard let self else { return }
            defer { switching = false }
            guard await resolveUnsaved() != .cancelled else { return }
            let place = await (try? session.channel.lua(Place.lua)).flatMap { Place($0) }
                ?? Place(cwd: FileManager.default.currentDirectoryPath)
            await restart(trying: [config, current], place: place)
        }
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
            await restart(trying: [current], place: Place(cwd: real))
        }
    }

    /// A new nvim in this window, in `place`, under the first of `configs` that starts; one that will not start is
    /// said so, and the last of them failing closes the window.
    private func restart(trying configs: [NvimConfig], place: Place) async {
        let previous = current
        let old = session
        makeSurface()
        window.makeFirstResponder(editor)
        await old.stop()
        for config in configs {
            do {
                try await launch(startup: config.startup, place: place, arguments: [])
                current = config
                return
            } catch {
                let alert = NSAlert(error: error)
                alert.messageText = "nvim could not start with the \(config.title) config"
                alert.runModal()
                await session.stop()
                if config == previous {
                    app.close(self)
                    return
                }
                makeSurface()
                window.makeFirstResponder(editor)
            }
        }
    }

    /// `:FrameConfig`, in each nvim the frame starts: with a name it switches to it, without one it lists the configs
    /// to
    /// choose from (`vim.ui.select`, so a picker plugin of the config's takes over).
    private static let commandLua = """
    local names, current = ...
    local function ask(name) vim.rpcnotify(vim.g.sill_channel, 'frame_config', name) end
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
    vim.keymap.set('n', '<Plug>(frame-workspace)', function() tell('frame_workspace', 'toggle') end, { desc = 'Switch workspace' })
    vim.keymap.set('n', '<Plug>(frame-tree-toggle)', function() tell('frame_tree', 'toggle') end, { desc = 'Show or hide the file tree' })
    vim.keymap.set('n', '<Plug>(frame-tree-focus)', function() tell('frame_tree', 'focus') end, { desc = 'Go into the file tree' })
    -- Default keys, each only where the config has not bound it: <leader>e shows and enters the tree, or hides it;
    -- <C-w>e enters it (showing it first); <leader>fw switches workspace.
    for _, key in ipairs({
      { '<leader>e', '<Plug>(frame-tree-toggle)', 'File tree' },
      { '<C-w>e', '<Plug>(frame-tree-focus)', 'File tree' },
      { '<leader>fw', '<Plug>(frame-workspace)', 'Switch workspace' },
    }) do
      if vim.fn.maparg(key[1], 'n') == '' then vim.keymap.set('n', key[1], key[2], { remap = true, desc = key[3] }) end
    end
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
    vim.api.nvim_create_user_command('FrameConfig', function(opts)
      if opts.args ~= '' then return ask(opts.args) end
      vim.ui.select(names, {
        prompt = 'Switch to nvim config',
        format_item = function(name) return name == current and (name .. '  (current)') or name end,
      }, function(choice) if choice then ask(choice) end end)
    end, {
      nargs = '?',
      complete = function(lead)
        return vim.tbl_filter(function(name) return name:sub(1, #lead) == lead end, names)
      end,
      desc = 'Restart nvim under another config, in this window',
    })
    """

    /// What nvim asked of the frame (`:FrameConfig`).
    private func nvimAsked(_ method: String, _ args: [MessagePackValue]) {
        switch method {
        case "frame_workspace": switchWorkspace(nil)
        case "frame_statusline": view?.statusVisible = args.first?.stringValue != "off"
        case "frame_status": if let map = args.first?.dictionaryValue { take(status: map) }
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
        guard method == "frame_config", let name = args.first?.stringValue else { return }
        guard let config = configs().first(where: { $0.appName == name }) else {
            let known = configs().map(\.appName).joined(separator: ", ")
            Task {
                _ = try? await session.channel.lua(
                    "vim.notify(..., vim.log.levels.ERROR)",
                    args: [.string("FrameConfig: no config named \(name) (there are: \(known))")]
                )
            }
            return
        }
        switchConfig(to: config)
    }

    /// A file opened from the tree: nvim shows it, and has the keyboard only when asked (Return, a double-click): a
    /// click or `l` leaves it in the tree, so the next key is the tree's.
    func open(file path: String, toEditor: Bool) {
        Task { [weak self] in
            guard let self else { return }
            _ = try? await session.channel.lua(
                """
                local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape((...)))
                if not ok then vim.notify(tostring(err), vim.log.levels.ERROR) end
                """,
                args: [.string(path)]
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
        }
    }

    /// The keyboard to a surface (the tree's filter if it is filtering; the editor if there is no sidebar to be in).
    private func focus(_ surface: Surface) {
        switch surface {
        case .tree where view.sidebarVisible:
            if modes.treeMode == .filter { tree.focusFilter() } else { tree.focus() }
        case .tree, .editor: window.makeFirstResponder(editor)
        case .switcher: if let panel = switcher { window.makeFirstResponder(panel.field) }
        }
    }

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
        status.lsp = map[.string("lsp")]?.arrayValue?.compactMap(\.stringValue) ?? []
        refreshStatus()
    }

    /// The bar says the mode the window is in (nvim's, or the tree's or the switcher's) and the branch, with the rest
    /// as it was last told.
    private func refreshStatus() {
        guard editor != nil else { return }
        status.mode = modes.label(editorMode: editor.screen.mode)
        status.branch = sidebar.chip.branch
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

    @objc func chooseConfig(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let config = configs().first(where: { $0.appName == name }) else { return }
        switchConfig(to: config)
    }

    /// The next config after this one, round again: one key to try them in turn.
    @objc func nextConfig(_: Any?) {
        let all = configs()
        guard all.count > 1 else { return }
        let at = all.firstIndex(of: current) ?? -1
        switchConfig(to: all[(at + 1) % all.count])
    }

    func configs() -> [NvimConfig] {
        let environment = NvimProcess.cachedEnv.merging(ProcessInfo.processInfo.environment) { _, own in own }
        var all = NvimConfigs.discover(environment: environment)
        // A config nvim runs under that is not in the list (NVIM_APPNAME pointing elsewhere) is still the one in use.
        if !all.contains(current) { all.append(current) }
        return all
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
        if !visible { modes.sidebarHidden() }
        if !visible, window.firstResponder === tree.outline { focusEditor() }
    }

    @objc func toggleSidebar(_: Any?) { setSidebar(visible: !view.sidebarVisible) }
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
        default: break
        }
        return true
    }

    @objc func bigger(_: Any?) { EditorFont.zoom(1) }
    @objc func smaller(_: Any?) { EditorFont.zoom(-1) }
    @objc func actual(_: Any?) { EditorFont.zoom(0) }

    /// sill's settings file, in nvim.
    @objc func openSettings(_: Any?) {
        let file = SettingsLoader.defaultFile()
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: file.path) {
            try? SettingsLoader.defaultSource.write(to: file, atomically: true, encoding: .utf8)
        }
        Task { _ = try? await session.channel.command("edit " + file.path.replacingOccurrences(of: " ", with: "\\ ")) }
    }
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
