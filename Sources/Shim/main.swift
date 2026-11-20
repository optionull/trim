import AppKit
import CoreText
import MessagePack
import SillCore
import SillEditor
import SillNvim

// The shim: nvim alone in a native window, drawn by sill's Metal grid, its command line, completion and messages as
// native views, with the person's own nvim config. No title bar by default; the window keeps macOS's rounded corners
// and shadow, and moves by its margin. Settings are sill's (~/.config/sill/settings.toml): the font, its size and line
// height, and `title_bar` under [shell].

/// Where sill's runtime is: in the app's Resources, else (a `swift run` build) in the source tree.
enum ShimRuntime {
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

/// The window's content: the grid inset by a margin the window moves by, and the native overlays over it.
final class ShimView: NSView {
    let editor: EditorView
    let overlay: NSView
    /// Room for the title bar's buttons when it shows.
    var top: CGFloat = 0 {
        didSet { needsLayout = true }
    }

    static let margin: CGFloat = 8

    init(editor: EditorView, overlay: NSView) {
        self.editor = editor
        self.overlay = overlay
        super.init(frame: editor.frame)
        wantsLayer = true
        addSubview(editor)
        addSubview(overlay)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    /// The margin moves the window: there is no title bar to drag.
    override var mouseDownCanMoveWindow: Bool { true }

    override func layout() {
        super.layout()
        let frame = bounds.insetBy(dx: Self.margin, dy: Self.margin)
        editor.frame = NSRect(x: frame.minX, y: frame.minY + top, width: frame.width, height: frame.height - top)
        overlay.frame = editor.frame
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

/// Where the shim remembers which nvim config it ran last. Its own state, not a setting: it changes by choosing, not by
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

@MainActor
final class ShimDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private(set) var session = EditorSession()
    private(set) var window: NSWindow!
    private(set) var editor: EditorView!
    private(set) var view: ShimView!
    private var externalUI: ExternalUI!
    private var watcher: SettingsWatcher?
    private var quitting = false
    /// Which session is the current one: a session that ends after a switch is not nvim quitting.
    private var generation = 0
    /// The config nvim runs under now, and whether a switch is under way.
    private(set) var current = NvimConfig.builtIn
    private var switching = false
    /// nvim has ended, so quitting has no one to ask.
    private var ended = false
    private let configMenu = NSMenu(title: "Config")

    private var checking: Bool { ProcessInfo.processInfo.environment["SILL_SHIM_CHECK"] == "1" }

    func applicationDidFinishLaunching(_: Notification) {
        // sill's settings: the font, and whether a title bar shows.
        let file = ProcessInfo.processInfo.environment["SILL_SETTINGS"].map { URL(fileURLWithPath: $0) } ??
            SettingsLoader.defaultFile()
        if FileManager.default.fileExists(atPath: file.path) {
            let watcher = SettingsWatcher(file: file) { source in
                Settings.shared.load(source)
                Task { @MainActor [weak self] in self?.apply() }
            }
            Settings.shared.load(watcher.start())
            self.watcher = watcher
        }
        EditorFont.load(Settings.shared.current)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Nothing of it is restored, so AppKit has no state of it to save (on the main thread, waiting on the disk).
        window.isRestorable = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.delegate = self
        window.setFrameAutosaveName("Shim")
        makeSurface()
        buildMenu()

        if checking {
            window.setFrame(NSRect(x: 0, y: 0, width: 1100, height: 760), display: false)
            view.layoutSubtreeIfNeeded()
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        window.makeFirstResponder(editor)
        let environment = NvimProcess.cachedEnv.merging(ProcessInfo.processInfo.environment) { _, own in own }
        // NVIM_APPNAME, set when the shim starts, wins over the config chosen last.
        var startup = EditorSession.startup(environment: environment, own: checking)
        if !checking, environment["NVIM_APPNAME"] == nil, let name = ConfigChoice.remembered,
           let config = NvimConfigs.discover(environment: environment).first(where: { $0.appName == name })
        {
            startup = config.startup
        }
        current = NvimConfig(appName: startup.appName, isBuiltIn: !startup.userConfig)
        let arguments = CommandLine.arguments.dropFirst()
            .filter { !$0.hasPrefix("-psn") && !$0.hasPrefix("-NS") }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await launch(
                    startup: startup,
                    place: Place(cwd: FileManager.default.currentDirectoryPath),
                    arguments: Array(arguments)
                )
                if checking { await ShimCheck(self).run() }
            } catch {
                let alert = NSAlert(error: error)
                alert.messageText = "The shim could not start nvim"
                alert.runModal()
                NSApp.terminate(nil)
            }
        }
    }

    /// A session, an editor on it and the view that holds them, in the window: what a switch of config makes anew.
    private func makeSurface() {
        generation += 1
        let generation = generation
        session = EditorSession()
        editor = EditorView(channel: session.channel)
        externalUI = ExternalUI(editor: editor)
        view = ShimView(editor: editor, overlay: externalUI.overlay)
        window.contentView = view
        apply()
        let session = session
        editor.onResize = { cols, rows in Task { await session.resize(cols: cols, rows: rows) } }
        editor.onKey = { [weak self] in self?.externalUI.keyPressed() }
        EditorFont.onChange = { [weak self] in self?.editor.fontChanged() }
        let updates = session.updates
        Task { [weak self] in
            for await update in updates {
                guard let self, self.generation == generation else { return }
                editor.show(update.screen)
                externalUI.update(update.screen)
                view.needsDisplay = true
            }
            // nvim ended (:qa), unless it was a switch that ended it. There is nothing left to ask about unsaved
            // changes, so quitting must not wait on it.
            guard let self, self.generation == generation else { return }
            ended = true
            NSApp.terminate(nil)
        }
    }

    /// Starts nvim in the current surface under `startup`, in `place`.
    private func launch(startup: EditorSession.Startup, place: Place, arguments: [String]) async throws {
        view.layoutSubtreeIfNeeded()
        let (cols, rows) = editor.gridSize
        try await session.start(
            runtime: ShimRuntime.directory,
            cols: cols,
            rows: rows,
            cwd: place.cwd,
            appName: startup.appName,
            extraArgs: startup.arguments + ["-n"] + arguments
        )
        if arguments.isEmpty, place.current != nil || !place.files.isEmpty {
            _ = try await session.channel.lua(Place.restoreLua, args: [place.argument])
        }
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
            let previous = current
            let old = session
            makeSurface()
            window.makeFirstResponder(editor)
            await old.stop()
            for config in [config, previous] {
                do {
                    try await launch(startup: config.startup, place: place, arguments: [])
                    current = config
                    return
                } catch {
                    let alert = NSAlert(error: error)
                    alert.messageText = "nvim could not start with the \(config.title) config"
                    alert.runModal()
                    await session.stop()
                    if config == previous { NSApp.terminate(nil) }
                    makeSurface()
                    window.makeFirstResponder(editor)
                }
            }
        }
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

    private func configs() -> [NvimConfig] {
        let environment = NvimProcess.cachedEnv.merging(ProcessInfo.processInfo.environment) { _, own in own }
        var all = NvimConfigs.discover(environment: environment)
        // A config nvim runs under that is not in the list (NVIM_APPNAME pointing elsewhere) is still the one in use.
        if !all.contains(current) { all.append(current) }
        return all
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === configMenu else { return }
        menu.removeAllItems()
        for (index, config) in configs().enumerated() {
            let item = menu.addItem(
                withTitle: config.title,
                action: #selector(chooseConfig(_:)),
                keyEquivalent: index < 9 ? String(index + 1) : ""
            )
            item.keyEquivalentModifierMask = [.control, .command]
            item.representedObject = config.appName
            item.state = config == current ? .on : .off
        }
        menu.addItem(.separator())
        let next = menu.addItem(withTitle: "Next Config", action: #selector(nextConfig(_:)), keyEquivalent: "]")
        next.keyEquivalentModifierMask = [.control, .command]
    }

    /// The settings that apply at once: the title bar, the font.
    private func apply() {
        let titleBar = Settings.shared.current.shellTitleBar
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = !titleBar
        }
        view?.top = titleBar ? 22 : 0
        EditorFont.load(Settings.shared.current)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }

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

    /// Quitting with unsaved changes asks first, as nvim's :qa would refuse.
    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting, !ended, ProcessInfo.processInfo.environment["SILL_SHIM_CHECK"] == nil else {
            return .terminateNow
        }
        Task {
            let outcome = await resolveUnsaved()
            if outcome == .discarded { quitting = true }
            NSApp.reply(toApplicationShouldTerminate: outcome != .cancelled)
        }
        return .terminateLater
    }

    func windowShouldClose(_: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }

    func applicationWillTerminate(_: Notification) {
        let session = session
        Task { await session.stop() }
    }

    // MARK: Menu

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

    private func buildMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        menu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editItem.submenu = editMenu
        let viewItem = NSMenuItem()
        menu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Bigger", action: #selector(bigger(_:)), keyEquivalent: "+")
        let bigger = viewMenu.addItem(withTitle: "Bigger", action: #selector(bigger(_:)), keyEquivalent: "=")
        bigger.isHidden = true
        bigger.allowsKeyEquivalentWhenHidden = true
        viewMenu.addItem(withTitle: "Smaller", action: #selector(smaller(_:)), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Actual Size", action: #selector(actual(_:)), keyEquivalent: "0")
        viewItem.submenu = viewMenu
        let configItem = NSMenuItem()
        menu.addItem(configItem)
        configMenu.delegate = self
        configItem.submenu = configMenu
        menuNeedsUpdate(configMenu)
        NSApp.mainMenu = menu
    }
}

// SILL_FONTS: a directory of fonts to use without installing them, for this process only.
if let directory = ProcessInfo.processInfo.environment["SILL_FONTS"],
   let files = FileManager.default.enumerator(at: URL(fileURLWithPath: directory), includingPropertiesForKeys: nil)
{
    let fonts = files.compactMap { $0 as? URL }.filter { ["ttf", "otf"].contains($0.pathExtension.lowercased()) }
    CTFontManagerRegisterFontURLs(fonts as CFArray, .process, false, nil)
}

let app = NSApplication.shared
let delegate = ShimDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
