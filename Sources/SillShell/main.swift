import AppKit
import CoreText
import SillCore
import SillEditor
import SillNvim

// The shell: nvim alone in a native window, drawn by sill's Metal grid, its command line, completion and messages as
// native views, with the person's own nvim config. No title bar by default; the window keeps macOS's rounded corners
// and shadow, and moves by its margin. Settings are sill's (~/.config/sill/settings.toml): the font, its size and line
// height, and `title_bar` under [shell].

/// Where sill's runtime is: in the app's Resources, else (a `swift run` build) in the source tree.
enum ShellRuntime {
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
final class ShellView: NSView {
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

@MainActor
final class ShellDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let session = EditorSession()
    private(set) var window: NSWindow!
    private(set) var editor: EditorView!
    private(set) var view: ShellView!
    private var externalUI: ExternalUI!
    private var watcher: SettingsWatcher?
    private var quitting = false

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
        editor = EditorView(channel: session.channel)
        externalUI = ExternalUI(editor: editor)
        view = ShellView(editor: editor, overlay: externalUI.overlay)
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
        window.contentView = view
        window.delegate = self
        window.setFrameAutosaveName("SillShell")
        apply()
        buildMenu()

        let session = session
        editor.onResize = { cols, rows in Task { await session.resize(cols: cols, rows: rows) } }
        editor.onKey = { [weak self] in self?.externalUI.keyPressed() }
        EditorFont.onChange = { [weak self] in self?.editor.fontChanged() }
        let updates = session.updates
        Task { [weak self] in
            for await update in updates {
                self?.editor.show(update.screen)
                self?.externalUI.update(update.screen)
                self?.view.needsDisplay = true
            }
            // nvim ended (:qa).
            NSApp.terminate(nil)
        }
        if ProcessInfo.processInfo.environment["SILL_SHELL_CHECK"] == "1" {
            window.setFrame(NSRect(x: 0, y: 0, width: 1100, height: 760), display: false)
            view.layoutSubtreeIfNeeded()
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        window.makeFirstResponder(editor)
        let (cols, rows) = editor.gridSize
        Task { [weak self] in
            guard let self else { return }
            do {
                let arguments = CommandLine.arguments.dropFirst()
                    .filter { !$0.hasPrefix("-psn") && !$0.hasPrefix("-NS") }
                let environment = NvimProcess.cachedEnv.merging(ProcessInfo.processInfo.environment) { _, own in own }
                let startup = EditorSession.startup(
                    environment: environment,
                    own: environment["SILL_SHELL_CHECK"] == "1"
                )
                try await session.start(
                    runtime: ShellRuntime.directory,
                    cols: cols,
                    rows: rows,
                    cwd: FileManager.default.currentDirectoryPath,
                    appName: startup.appName,
                    extraArgs: startup.arguments + ["-n"] + Array(arguments)
                )
                if ProcessInfo.processInfo.environment["SILL_SHELL_CHECK"] == "1" { await ShellCheck(self).run() }
            } catch {
                let alert = NSAlert(error: error)
                alert.messageText = "The shell could not start nvim"
                alert.runModal()
                NSApp.terminate(nil)
            }
        }
    }

    /// The settings that apply at once: the title bar, the font.
    private func apply() {
        let titleBar = Settings.shared.current.shellTitleBar
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = !titleBar
        }
        view.top = titleBar ? 22 : 0
        EditorFont.load(Settings.shared.current)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }

    /// Quitting with unsaved changes asks first, as nvim's :qa would refuse.
    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting, ProcessInfo.processInfo.environment["SILL_SHELL_CHECK"] == nil else { return .terminateNow }
        Task {
            let modified = await (try? session.channel.lua("""
            return #vim.tbl_filter(function(b) return vim.bo[b].modified and vim.bo[b].buflisted end, vim.api.nvim_list_bufs())
            """))?.integerValue ?? 0
            guard modified > 0 else { return NSApp.reply(toApplicationShouldTerminate: true) }
            let alert = NSAlert()
            alert.messageText = modified == 1 ? "A file has unsaved changes" : "\(modified) files have unsaved changes"
            alert.addButton(withTitle: "Save All")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Don't Save")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                let saved = await (try? session.channel.command("wall")) != nil
                NSApp.reply(toApplicationShouldTerminate: saved)
            case .alertThirdButtonReturn:
                quitting = true
                NSApp.reply(toApplicationShouldTerminate: true)
            default:
                NSApp.reply(toApplicationShouldTerminate: false)
            }
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
let delegate = ShellDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
