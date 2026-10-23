import AppKit
import SillCore
import SillNvim
import SillRender
import SillSidecar

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private let session = EditorSession()
    private var editor: EditorView!
    private(set) var panes: TerminalPanes!
    private(set) var externalUI: ExternalUI!
    private(set) var root: RootView!
    private var check: SelfCheck?
    /// The .NET sidecar, started at launch; nil until it is ready, and after it failed to start.
    private(set) var sidecar: Sidecar?
    private(set) var sidecarReady: (ready: SidecarReady, seconds: Double)?
    private(set) var sidecarProblem: String?

    func applicationDidFinishLaunching(_: Notification) {
        let environment = ProcessInfo.processInfo.environment
        if environment["SILL_BENCH"] == "1" {
            Bench.run()
            return
        }
        buildMenu()
        let directory = environment["SILL_CWD"] ?? FileManager.default.currentDirectoryPath
        workingDirectory = directory == "/" ? NSHomeDirectory() : directory
        // The self-check's first part runs as days 1 to 5 had sill: no frame, no sidebar, no panel.
        chrome = environment["SILL_CHROME"] != "0" && environment["SILL_CHECK"] != "1"

        editor = EditorView(channel: session.channel, metrics: CellMetrics())
        panes = TerminalPanes(editor: editor, channel: session.channel, directory: workingDirectory)
        tools = ToolPanes(editor: editor, channel: session.channel, directory: workingDirectory)
        splitTabs = SplitTabs(editor: editor, channel: session.channel)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered,
            defer: false
        )
        window.title = "sill"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = Design.chrome
        externalUI = ExternalUI(editor: editor)
        root = RootView(editor: editor, overlay: externalUI.overlay)
        root.bare = !chrome
        window.contentView = root
        window.delegate = self
        if environment["SILL_SHOWCASE"] != nil {
            // The showcase's picture is the window at 1440x900, whatever a tiling window manager would make of it:
            // the window stays off screen, and the picture is composited, not captured.
            window.setFrame(NSRect(x: 0, y: 0, width: 1440, height: 900), display: false)
            root.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
            root.layoutSubtreeIfNeeded()
            window.makeFirstResponder(editor)
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(editor)
            NSApp.activate()
        }
        wireChrome()

        let session = session
        editor.onResize = { cols, rows in Task { await session.resize(cols: cols, rows: rows) } }
        editor.onFocus = { [weak self] in self?.panes.focusEditor() }
        editor.onKey = { [weak self] in self?.externalUI.keyPressed() }
        editor.keyInterceptor = { [weak self] event in self?.tools.handleKey(event) ?? false }

        if environment["SILL_CHECK"] != nil || environment["SILL_SHOWCASE"] != nil {
            check = SelfCheck(window: window, editor: editor, panes: panes, session: session, app: self)
        }
        startSidecar()
        let updates = session.updates
        Task { [weak self] in
            for await update in updates {
                self?.show(update)
            }
            // nvim exited (:qa).
            if self?.check == nil { NSApp.terminate(nil) }
        }
        let (cols, rows) = editor.gridSize
        let chrome = chrome, workingDirectory = workingDirectory
        Task { [weak self] in
            do {
                // Arguments after the binary are nvim's (files to open); `open` adds -psn and -NS ones of its own.
                var arguments = CommandLine.arguments.dropFirst()
                    .filter { !$0.hasPrefix("-psn") && !$0.hasPrefix("-NS") }
                // The self-check and the showcase run sill alone (no user config) and leave no swap files behind, even
                // when stopped half-way. SILL_NVIM_CONFIG=0 asks for sill alone too.
                let environment = NvimProcess.cachedEnv.merging(ProcessInfo.processInfo.environment) { _, own in own }
                let showcaseAlone = environment["SILL_SHOWCASE"] != nil && environment["SILL_SHOWCASE_USER"] != "1"
                let alone = environment["SILL_CHECK"] != nil || showcaseAlone || environment["SILL_NVIM_CONFIG"] == "0"
                if alone { arguments.insert("-n", at: 0) }
                let startup = EditorSession.startup(environment: environment, own: alone)
                // Days 1 to 5's check runs nvim as they had it: no base settings either.
                let base = environment["SILL_CHECK"] == "1" ? [] : startup.arguments
                try await session.start(
                    runtime: Runtime.directory, cols: cols, rows: rows, cwd: workingDirectory, appName: startup.appName,
                    extraArgs: base + Array(arguments)
                )
                if chrome {
                    do {
                        try await session.channel.command("SillChrome")
                    } catch {
                        // The editor works without its chrome; say why it is missing.
                        NSLog("sill: :SillChrome failed: \(error)")
                        Nvim.lua(session.channel, "vim.notify(...)", [.string("sill's chrome did not open: \(error)")])
                    }
                }
                await self?.check?.run()
            } catch {
                self?.fail(error)
            }
        }
    }

    private(set) var workingDirectory = NSHomeDirectory()
    private(set) var chrome = true
    private(set) var tools: ToolPanes!
    private(set) var splitTabs: SplitTabs!
    private var branch = ""
    private var branchFor = ""

    /// Everything that follows a new screen.
    private func show(_ update: ScreenUpdate) {
        let screen = update.screen
        editor.show(screen)
        externalUI.update(screen)
        root.tabBar.show(screen.tabs, current: screen.currentTab)
        root.showTabs(screen.tabs.count > 1)
        panes.update(update)
        tools.update(screen)
        editor.coveredGrids = panes.covered.union(tools.covered)
        splitTabs.update(screen)
        if screen.buffer.kind.isEmpty, !screen.buffer.path.isEmpty { tools.sidebar.explorer.reveal(screen.buffer.path) }
        updateFrame(screen)
        check?.observe(update)
    }

    /// The title bar and the status bar.
    private func updateFrame(_ screen: Screen) {
        // The branch of the folder sill works in, read again when the current file changes (a checkout shows then).
        if branchFor != screen.buffer.path || branchFor.isEmpty {
            branchFor = screen.buffer.path.isEmpty ? workingDirectory : screen.buffer.path
            let directory = workingDirectory
            Task.detached { [weak self] in
                let branch = Git.branch(in: directory)
                await MainActor.run { [weak self] in
                    guard let self, branch != self.branch else { return }
                    self.branch = branch
                    updateFrame(tools.screen)
                }
            }
        }
        let project = (workingDirectory as NSString).lastPathComponent
        root.titleBar.title = branch.isEmpty ? project : "\(project) · \(branch)"
        // nvim's title when it sets one (:set title), else the project and branch.
        let title = screen.title.isEmpty ? root.titleBar.title : screen.title
        if window.title != title { window.title = title }
        var state = StatusBarView.State()
        state.mode = panes.focused != nil ? "terminal" : screen.mode
        state.branch = branch
        state.pending = (screen.showmode + screen.showcmd).map(\.text).joined().trimmingCharacters(in: .whitespaces)
        state.services = [(".NET sidecar", sidecarReady != nil)]
        state.filetype = screen.buffer.filetype
        state.position = screen.buffer.kind.isEmpty ? screen.cursorPosition : nil
        state.modified = screen.buffer.modified
        root.statusBar.state = state
        root.activityBar.selected = screen.paneRects.contains { $0.kind == "sidebar" } ? tools.sidebar.activity : nil
    }

    private func wireChrome() {
        let channel = session.channel
        root.tabBar.onSelect = { handle in
            Task { _ = await channel.request("nvim_set_current_tabpage", params: [.int(Int64(handle))]) }
        }
        root.activityBar.onSelect = { [weak self] activity in
            guard let self else { return }
            let showing = tools.screen.paneRects.contains { $0.kind == "sidebar" }
            if showing, activity == tools.sidebar.activity {
                Nvim.lua(channel, "require'sill'.toggle('sidebar')")
            } else {
                tools.sidebar.show(activity)
                root.activityBar.selected = activity
                Nvim.lua(channel, "require'sill'.focus('sidebar')")
            }
        }
        root.titleBar.onRun = { [weak self] in self?.run() }
        tools.panel.onSendToAgent = { problems in
            let text = "Sending \(problems.count) problems to an agent comes with the heed bridge (M5). Until then: " +
                ":SillTerminal and run one there."
            Nvim.lua(channel, "vim.notify(...)", [.string(text)])
        }
    }

    /// Run: a terminal pane at the bottom running the project's run command, guessed from its files.
    func run(command override: String? = nil) {
        guard let command = override ?? RunCommand.guess(in: workingDirectory) else {
            Nvim.lua(session.channel, "vim.notify(...)", [.string(
                "Nothing to run here: no Package.swift, solution or project, Cargo.toml or package.json."
            )])
            return
        }
        panes.nextInput = command + "\n"
        Nvim.lua(session.channel, "require'sill'.open_pane('terminal', 'botright 12')")
    }

    /// Starts the sidecar on the user's dotnet. sill works without it; what went wrong is kept for the status line.
    private func startSidecar() {
        let sidecar = Sidecar()
        Task { [weak self] in
            let started = CACurrentMediaTime()
            do {
                let ready = try await sidecar.start(dll: SidecarFiles.dll)
                self?.sidecar = sidecar
                self?.sidecarReady = (ready, CACurrentMediaTime() - started)
            } catch {
                self?.sidecarProblem = "\(error)"
                NSLog("sill: the .NET sidecar did not start: \(error)")
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }

    func applicationWillTerminate(_: Notification) {
        let session = session, sidecar = sidecar
        Task {
            await session.stop()
            await sidecar?.stop()
        }
    }

    private func fail(_ error: Error) {
        // The self-check and the showcase run unattended: an alert would wait for no one.
        if check != nil {
            print("sill: could not start nvim: \(error)")
            fflush(stdout)
            exit(1)
        }
        let alert = NSAlert(error: error)
        alert.messageText = "sill could not start nvim"
        alert.runModal()
        NSApp.terminate(nil)
    }

    private func buildMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit sill", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        // Copy, cut and paste go to the first responder: the editor (Visual mode and nvim_paste) or a terminal
        // pane, which handles them itself before the menu sees them.
        let editItem = NSMenuItem()
        menu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editItem.submenu = editMenu
        NSApp.mainMenu = menu
    }
}

/// Where the sidecar is: in the app bundle's Resources (published by scripts/bundle.sh), or, for a `swift run` build,
/// as `dotnet build -c Release` leaves it in the source tree.
enum SidecarFiles {
    static var dll: URL {
        if let override = ProcessInfo.processInfo.environment["SILL_SIDECAR"] {
            return URL(fileURLWithPath: override)
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("sidecar/Sill.Sidecar.dll"),
           FileManager.default.fileExists(atPath: bundled.path)
        {
            return bundled
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("sidecar/Sill.Sidecar/bin/Release/net10.0/Sill.Sidecar.dll")
    }
}

/// Where sill's runtime (the nvim plugin that defines terminal panes) is: in the app bundle's Resources, or, for a
/// `swift run` build, in the source tree.
enum Runtime {
    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["SILL_RUNTIME"] {
            return URL(fileURLWithPath: override)
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("runtime"),
           FileManager.default.fileExists(atPath: bundled.appendingPathComponent("plugin/sill.lua").path)
        {
            return bundled
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("runtime")
    }
}

/// What Run runs, by what the folder holds.
enum RunCommand {
    static func guess(in directory: String) -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        if names.contains("Package.swift") { return "swift run" }
        if names.contains(where: { $0.hasSuffix(".sln") || $0.hasSuffix(".slnx") || $0.hasSuffix(".csproj") }) {
            return "dotnet run"
        }
        if names.contains("Cargo.toml") { return "cargo run" }
        if names.contains("package.json") { return "npm start" }
        return nil
    }
}
