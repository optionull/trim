import AppKit
import SillAgent
import SillCore
import SillEditor
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
    /// As git's mergetool or difftool (`Sill merge LOCAL BASE REMOTE MERGED`, `Sill diff A B`): how sill ends tells git
    /// whether the merge is done.
    enum Tool { case merge(merged: String), diff }
    let tool: Tool? = {
        let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn") && !$0.hasPrefix("-NS") }
        if arguments.first == "merge", arguments.count == 5 { return .merge(merged: arguments[4]) }
        if arguments.first == "diff", arguments.count == 3 { return .diff }
        return nil
    }()

    private(set) var sidecarReady: (ready: SidecarReady, seconds: Double)?
    private(set) var sidecarProblem: String?

    let settings = SettingsController()

    func applicationDidFinishLaunching(_: Notification) {
        // Before anything reads a setting.
        settings.start()
        settings.onApplied = { [weak self] in
            guard let self, chrome else { return }
            if Design.islands != Settings.shared.current.islands { root.setIslands(Settings.shared.current.islands) }
        }
        let environment = ProcessInfo.processInfo.environment
        if environment["SILL_BENCH"] == "1" {
            Bench.run()
            return
        }
        buildMenu()
        // Started to open a file (from Finder, `open -a`, a sill:// link): in its repository, not in /.
        let launchedFor = pendingOpens.first.flatMap { reference in
            Review.git(["rev-parse", "--show-toplevel"], in: (reference.path as NSString).deletingLastPathComponent)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let directory = environment["SILL_CWD"] ??
            (FileManager.default.currentDirectoryPath == "/" ? launchedFor : nil) ??
            FileManager.default.currentDirectoryPath
        // The folder as the file system names it (/tmp is /private/tmp): language servers report real paths, and a
        // diagnostic's file must be the buffer's.
        let real = realPath(directory)
        workingDirectory = real == "/" ? NSHomeDirectory() : real
        // The self-check's first part runs as days 1 to 5 had sill: no frame, no sidebar, no panel.
        chrome = Settings.shared.value("SILL_CHROME") != "0" && environment["SILL_CHECK"] != "1"

        TerminalPanes.followGridFont()
        EditorFont.load(Settings.shared.current)
        editor = EditorView(channel: session.channel)
        panes = TerminalPanes(editor: editor, channel: session.channel, directory: workingDirectory)
        tools = ToolPanes(editor: editor, channel: session.channel, directory: workingDirectory)
        splitTabs = SplitTabs(editor: editor, channel: session.channel)
        builds = BuildRunner(directory: workingDirectory, channel: session.channel, panel: tools.panel)
        agents = AgentBridge(app: self, channel: session.channel, directory: workingDirectory)
        agents.start()
        profiler = Profiler(app: self, channel: session.channel, directory: workingDirectory)
        tools.onProfileMade = { [weak self] view in self?.profiler.attach(view) }
        solutions = Solutions(app: self, channel: session.channel, directory: workingDirectory)
        servers = LanguageServers(channel: session.channel, directory: workingDirectory)
        debugger = Debugger(app: self, channel: session.channel, directory: workingDirectory)
        packages = Packages(app: self, channel: session.channel, directory: workingDirectory)
        reviewer = Reviewer(app: self, channel: session.channel, directory: workingDirectory)
        walker = Walker(app: self, channel: session.channel, directory: workingDirectory)
        follower = Follower(app: self, channel: session.channel, directory: workingDirectory)
        telemetry = TelemetryWatch(app: self, channel: session.channel)
        tools.makeTelemetry = { [weak self] in
            guard let self else { fatalError("the app is gone") }
            let view = TelemetryView(watch: telemetry)
            telemetry.onChange = { [weak view] in view?.changed() }
            return view
        }
        follower.onChange = { [weak self] in
            guard let self else { return }
            tools.sidebar.explorer.touched = Set(follower.touched.keys)
            updateFrame(tools.screen)
        }
        tools.makeWalk = { [weak self] in
            guard let self else { fatalError("the app is gone") }
            let view = WalkView(walker: walker)
            walker.onChange = { [weak view] in view?.changed() }
            return view
        }
        tools.makeReview = { [weak self] in
            guard let self else { fatalError("the app is gone") }
            let view = ReviewView(reviewer: reviewer)
            reviewer.onChange = { [weak view] in view?.changed() }
            reviewer.refresh()
            return view
        }
        tools
            .makePackages = { [weak self] in
                self?.packages.makeView() ?? PackagesView(scanner: PackageScanner(directory: ""))
            }
        tools.panel.debug.debugger = debugger
        // Paused, an expression under the pointer shows its value.
        editor.onHover = { [weak self] expression, rect in
            guard let self, case .paused = debugger.state else { return }
            Task {
                guard let value = await self.debugger.value(of: expression, context: "hover"),
                      !value.hasPrefix("error:"), self.debugger.frames.isEmpty == false else { return }
                self.showHover("\(expression) = \(value)", at: rect)
            }
        }
        editor.onHoverEnd = { [weak self] in self?.hoverPopover?.close() }
        debugger.onChange = { [weak self] in
            self?.tools.panel.debug.needsDisplay = true
            self?.tools.panel.needsDisplay = true
            if let screen = self?.tools.screen { self?.updateFrame(screen) }
        }
        tools.sidebar.explorer.onSolutionRead = { [weak self] path, slnx, drift in
            self?.solutions.read(path, slnx, drift)
        }
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
        root.setIslands(chrome && Settings.shared.current.islands)
        window.contentView = root
        window.delegate = self
        if environment["SILL_SHOWCASE"] != nil || environment["SILL_OFFSCREEN"] == "1" {
            // The showcase's picture is the window at 1440x900, whatever a tiling window manager would make of it:
            // the window stays off screen, and the picture is composited, not captured. SILL_OFFSCREEN=1 runs a check
            // so, for shots at that size (one that needs real key events cannot).
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
        EditorFont.onChange = { [weak self] in
            guard let self else { return }
            editor.fontChanged()
            for view in [root as NSView?, tools?.sidebar, tools?.panel].compactMap(\.self) {
                view.needsLayout = true
                view.needsDisplay = true
            }
        }
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
            if self?.tool != nil {
                await self?.endTool()
            } else if self?.check == nil {
                NSApp.terminate(nil)
            }
        }
        let (cols, rows) = editor.gridSize
        let chrome = chrome, workingDirectory = workingDirectory
        Task { [weak self] in
            do {
                // Arguments after the binary are nvim's (files to open); `open` adds -psn and -NS ones of its own.
                var arguments = CommandLine.arguments.dropFirst()
                    .filter { !$0.hasPrefix("-psn") && !$0.hasPrefix("-NS") }
                // As git's mergetool and difftool: `Sill merge LOCAL BASE REMOTE MERGED`, `Sill diff A B`.
                let tool = Array(arguments)
                let merging = tool.first == "merge" && tool.count == 5,
                    diffing = tool.first == "diff" && tool.count == 3
                if merging || diffing { arguments = [] }
                // The self-check and the showcase run sill alone (no user config). SILL_NVIM_CONFIG=0 asks for sill
                // alone too.
                let environment = NvimProcess.cachedEnv.merging(ProcessInfo.processInfo.environment) { _, own in own }
                let showcaseAlone = environment["SILL_SHOWCASE"] != nil && environment["SILL_SHOWCASE_USER"] != "1"
                let alone = environment["SILL_CHECK"] != nil || showcaseAlone || Settings.shared
                    .value("SILL_NVIM_CONFIG") == "0"
                // No swap files, ever (-n), whatever a config sets: a swap file left by a stopped nvim only brings a
                // prompt the next time the file opens. Unsaved changes are guarded at quit instead.
                arguments.insert("-n", at: 0)
                let startup = EditorSession.startup(environment: environment, own: alone)
                // Days 1 to 5's check runs nvim as they had it: no base settings either.
                let base = environment["SILL_CHECK"] == "1" ? [] : startup.arguments
                try await session.start(
                    runtime: Runtime.directory, cols: cols, rows: rows, cwd: workingDirectory, appName: startup.appName,
                    extraArgs: base + Array(arguments)
                )
                if merging {
                    _ = try await session.channel.lua(
                        "require('sill.merge').open(...)",
                        args: tool.dropFirst().map { .string($0) }
                    )
                } else if diffing {
                    _ = try await session.channel.lua(
                        "require('sill.merge').diff(...)",
                        args: tool.dropFirst().map { .string($0) }
                    )
                }
                if chrome {
                    do {
                        try await session.channel.command("SillChrome")
                    } catch {
                        // The editor works without its chrome; say why it is missing.
                        NSLog("sill: :SillChrome failed: \(error)")
                        Nvim.lua(session.channel, "vim.notify(...)", [.string("sill's chrome did not open: \(error)")])
                    }
                }
                self?.editorReady = true
                for reference in self?.pendingOpens ?? [] {
                    self?.panes.open(reference)
                }
                self?.pendingOpens = []
                await self?.check?.run()
            } catch {
                self?.fail(error)
            }
        }
    }

    private(set) var workingDirectory = NSHomeDirectory()
    /// Files other apps asked to open before nvim was up.
    private var pendingOpens: [FileReference] = []
    private var editorReady = false

    /// Files from Finder or `open -a Sill`, and `sill://open?path=…&line=…&column=…` links: what a terminal or an
    /// agent's session hands over.
    func application(_: NSApplication, open urls: [URL]) {
        // AppKit hands over files named on the command line too; nvim opens those (and git's merge files are not to
        // be opened as files).
        let cwd = FileManager.default.currentDirectoryPath
        let named = Set(CommandLine.arguments.dropFirst().map {
            URL(fileURLWithPath: $0, relativeTo: URL(fileURLWithPath: cwd)).standardizedFileURL.path
        })
        let references = urls.compactMap(FileReference.init(url:)).filter { !named.contains($0.path) }
        guard editorReady else { return pendingOpens += references }
        for reference in references {
            panes.open(reference)
        }
        NSApp.activate()
    }

    private(set) var chrome = true
    private(set) var tools: ToolPanes!
    private(set) var splitTabs: SplitTabs!
    private(set) var builds: BuildRunner!
    private(set) var agents: AgentBridge!
    private(set) var profiler: Profiler!
    private(set) var solutions: Solutions!
    private(set) var servers: LanguageServers!
    private(set) var debugger: Debugger!
    private(set) var packages: Packages!
    private(set) var reviewer: Reviewer!
    private(set) var walker: Walker!
    private(set) var follower: Follower!
    private(set) var telemetry: TelemetryWatch!
    private var asksHandled = 0
    /// Roslyn's provisioning: what the status bar says while it downloads.
    private(set) var roslynStatus: String?
    private(set) var roslyn: RoslynServer?
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
        root.islands.update(screen, editor: editor)
        if root.zen != screen.zen { root.zen = screen.zen }
        if screen.buffer.kind.isEmpty, !screen.buffer.path.isEmpty { tools.sidebar.explorer.reveal(screen.buffer.path) }
        updateFrame(screen)
        servers.answer(screen.serverAsks)
        debugger.update(screen)
        packages.update(screen)
        reviewer.update(screen)
        walker.update(screen)
        follower.update(screen)
        telemetry.update(screen)
        for asked in screen.askQuestions.dropFirst(asksHandled) {
            agents.ask(path: asked.path, from: asked.from, to: asked.to, lines: asked.lines, question: asked.question)
        }
        asksHandled = screen.askQuestions.count
        // Turns come from heed's sessions: without heed there are none to follow.
        if agents.sessions != nil { reviewer.follow(agents.sessionHere.map { ($0.state, $0.title) }) }
        if let ask = screen.slnxAsk, ask.serial != slnxAskSeen {
            slnxAskSeen = ask.serial
            solutions.answer(ask.action)
        }
        if let ask = screen.profileAsk, ask.serial != profileAskSeen {
            profileAskSeen = ask.serial
            profiler.answer(ask.action)
        }
        if let ask = screen.agentAsk, ask.serial != agentAskSeen {
            agentAskSeen = ask.serial
            answerAgentAsk(ask.action)
        }
        check?.observe(update)
    }

    private var agentAskSeen = 0
    private var profileAskSeen = 0
    private var slnxAskSeen = 0

    /// `:SillAgent next|send|list`.
    private func answerAgentAsk(_ action: String) {
        switch action {
        case "send": agents.send(tools.screen.diagnostics)
        case "list":
            tools.sidebar.show(.agents)
            root.activityBar.selected = .agents
            Nvim.lua(session.channel, "require'sill'.focus('sidebar')")
        default: agents.openNextWaiting()
        }
    }

    /// heed's sessions changed (nil: heed went away): the Agents sidebar and its badge.
    func agentsChanged(_ sessions: [HeedSession]?) {
        tools.sidebar.agents.sessions = sessions
        root?.activityBar.badges = [.agents: tools.sidebar.agents.waiting]
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
        if let roslynStatus {
            state.services.append((roslynStatus, false))
        } else if let status = screen.languageServers["Roslyn"] {
            state.services.append(("Roslyn" + (status == "ready" ? "" : " " + status), status == "ready"))
        }
        // The current file's server, when sill started it.
        let serving = [
            "rust": "rust-analyzer", "swift": "sourcekit-lsp", "markdown": "marksman", "html": "HTML", "css": "CSS",
            "scss": "CSS", "json": "JSON", "jsonc": "JSON", "typescript": "TypeScript", "javascript": "TypeScript",
            "typescriptreact": "TypeScript", "javascriptreact": "TypeScript",
        ][screen.buffer.filetype]
        if let serving, let status = screen.languageServers[serving] {
            state.services.append((serving + (status == "ready" ? "" : " " + status), status == "ready"))
        }
        state.filetype = screen.buffer.filetype
        state.position = screen.buffer.kind.isEmpty ? screen.cursorPosition : nil
        state.modified = screen.buffer.modified
        state.merge = screen.merge.map { ($0.left, $0.current) }
        state.debug = debugger?.status ?? follower?.status
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
            // The packages take a tab page of their own (board 3), as the profiler does.
            if activity == .packages { return Nvim.lua(channel, "vim.cmd('SillPackages')") }
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
        editor.contextMenu = { [weak self] in
            guard let self else { return NSMenu() }
            return ContextMenu.menu(directory: workingDirectory, channel: channel) { [weak self] command in
                self?.run(command: command)
            }
        }
        tools.panel.onSendToAgent = { [weak self] problems in self?.agents.send(problems) }
        tools.sidebar.agents.onOpen = { [weak self] session in self?.agents.open(session) }
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
                await self?.provisionRoslyn(sidecar)
            } catch {
                self?.sidecarProblem = "\(error)"
                NSLog("sill: the .NET sidecar did not start: \(error)")
            }
        }
    }

    /// C#: Roslyn's language server for a folder with .NET projects, downloaded by the sidecar the first time.
    private func provisionRoslyn(_ sidecar: Sidecar) async {
        guard BuildCapture.command(in: workingDirectory)?.hasPrefix("dotnet") == true,
              ProcessInfo.processInfo.environment["SILL_ROSLYN"] != "0" else { return }
        roslynStatus = "Roslyn"
        do {
            let server = try await sidecar.roslyn { [weak self] progress in
                let text = progress.stage == "downloading" && progress.total > 0 ?
                    "Roslyn downloading \(progress.bytes * 100 / progress.total)%" : "Roslyn \(progress.stage)"
                Task { @MainActor in
                    self?.roslynStatus = text
                    if let self { self.updateFrame(self.tools.screen) }
                }
            }
            roslyn = server
            roslynStatus = nil
            let logs = Sidecar.cache.deletingLastPathComponent().appendingPathComponent("logs").path
            _ = try await session.channel.lua("require('sill.roslyn').setup(...)", args: [
                .string(server.dll), .string(logs),
            ])
        } catch {
            roslynStatus = nil
            NSLog("sill: Roslyn did not start: \(error)")
            Nvim.lua(
                session.channel,
                "vim.notify(...)",
                [.string("Roslyn's language server is not available: \(error)")]
            )
        }
        updateFrame(tools.screen)
    }

    @objc func buildProject(_: Any?) { builds.build() }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }

    /// Quitting (⌘Q, or closing the window) with files nvim has unsaved changes in asks first: save them all, throw
    /// them away, or stay. Without swap files nothing would be left to recover them from.
    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        guard check == nil, !quitting else { return .terminateNow }
        Task { [weak self] in
            guard let self else { return }
            await confirmQuit(unsavedFiles())
        }
        return .terminateLater
    }

    /// The files nvim has unsaved changes in, by name; none when nvim is gone.
    func unsavedFiles() async -> [String] {
        let result = try? await session.channel.lua("""
        return vim.tbl_map(function(b) local n = vim.api.nvim_buf_get_name(b)
          return n ~= '' and vim.fn.fnamemodify(n, ':t') or '[No Name]' end,
          vim.tbl_filter(function(b) return vim.bo[b].modified and vim.bo[b].buflisted end, vim.api.nvim_list_bufs()))
        """)
        return result?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    private var quitting = false

    private func confirmQuit(_ modified: [String]) {
        guard !modified.isEmpty else {
            NSApp.reply(toApplicationShouldTerminate: true)
            return
        }
        let alert = NSAlert()
        alert.messageText = modified.count == 1 ? "\(modified[0]) has unsaved changes" :
            "\(modified.count) files have unsaved changes"
        alert.informativeText = modified.count == 1 ? "Save it before quitting?" :
            modified.prefix(8).joined(separator: ", ") + (modified.count > 8 ? ", …" : "")
        alert.addButton(withTitle: modified.count == 1 ? "Save" : "Save All")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let channel = session.channel
            Task {
                // :wall stops at a file it cannot write; then quitting waits, and nvim says why.
                let saved = await (try? channel.command("wall")) != nil
                NSApp.reply(toApplicationShouldTerminate: saved)
            }
        case .alertThirdButtonReturn:
            quitting = true
            NSApp.reply(toApplicationShouldTerminate: true)
        default:
            NSApp.reply(toApplicationShouldTerminate: false)
        }
    }

    /// Closing the window quits, through the same question.
    func windowShouldClose(_: NSWindow) -> Bool {
        guard check == nil else { return true }
        NSApp.terminate(nil)
        return false
    }

    /// The exit status git reads with `trustExitCode`: nvim's own (`:cquit` is 1), and 1 for a merge whose result
    /// still has conflicts in it, whatever nvim said.
    func toolStatus(nvim: Int32) -> Int32 {
        guard case let .merge(merged) = tool, nvim == 0 else { return nvim }
        let left = MergeConflicts.count(inFile: merged)
        guard left > 0 else { return 0 }
        FileHandle.standardError.write(Data(
            "sill: \(left) conflict\(left == 1 ? "" : "s") left in \((merged as NSString).lastPathComponent)\n".utf8
        ))
        return 1
    }

    /// nvim ended in merge or diff mode: sill ends with the status git should see.
    private func endTool() async {
        let status = await toolStatus(nvim: session.channel.exitStatus() ?? 1)
        agents?.stop()
        await sidecar?.stop()
        exit(status)
    }

    func applicationWillTerminate(_: Notification) {
        // Quit (⌘Q, the window closed) in merge or diff mode: what the result file says.
        if tool != nil { exit(toolStatus(nvim: 0)) }
        agents?.stop()
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

    private var hoverPopover: NSPopover?
    /// What the debugger's hover showed last, for the self-check.
    private(set) var hoverShown: String?

    private func showHover(_ text: String, at rect: NSRect) {
        hoverPopover?.close()
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = EditorFont.metrics.regular
        label.textColor = Design.text
        label.preferredMaxLayoutWidth = 520
        let size = label.fittingSize
        label.frame = NSRect(x: 10, y: 6, width: size.width, height: size.height)
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: size.width + 20, height: size.height + 12))
        controller.view.addSubview(label)
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.behavior = .transient
        hoverShown = text
        if editor.window?.isVisible == true {
            popover.show(relativeTo: rect, of: editor, preferredEdge: .maxY)
        }
        hoverPopover = popover
    }

    /// The self-check's way to rest the pointer on an expression.
    func hover(_ expression: String, at rect: NSRect) { editor.onHover?(expression, rect) }

    @objc func toggleZen(_: Any?) { Nvim.lua(session.channel, "vim.cmd('SillZen')") }
    @objc func fontBigger(_: Any?) { EditorFont.zoom(1) }
    @objc func fontSmaller(_: Any?) { EditorFont.zoom(-1) }
    @objc func fontActual(_: Any?) { EditorFont.zoom(0) }

    @objc func showSettings(_: Any?) {
        settings.onOpenFile = { [weak self] path in
            guard let self else { return }
            Nvim.lua(session.channel, "require'sill'.open(...)", [.string(path)])
            window.makeKeyAndOrderFront(nil)
        }
        settings.show()
    }

    private func buildMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
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
        // The grid's font for this session: bigger, smaller, back to the settings' size.
        let viewItem = NSMenuItem()
        menu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Bigger", action: #selector(fontBigger(_:)), keyEquivalent: "+")
        let bigger = viewMenu.addItem(withTitle: "Bigger", action: #selector(fontBigger(_:)), keyEquivalent: "=")
        bigger.isHidden = true
        bigger.allowsKeyEquivalentWhenHidden = true
        viewMenu.addItem(withTitle: "Smaller", action: #selector(fontSmaller(_:)), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Actual Size", action: #selector(fontActual(_:)), keyEquivalent: "0")
        viewMenu.addItem(.separator())
        let zen = viewMenu.addItem(withTitle: "Zen", action: #selector(toggleZen(_:)), keyEquivalent: "z")
        zen.keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = viewMenu
        let projectItem = NSMenuItem()
        menu.addItem(projectItem)
        let projectMenu = NSMenu(title: "Project")
        projectMenu.addItem(withTitle: "Build", action: #selector(buildProject(_:)), keyEquivalent: "b")
        projectItem.submenu = projectMenu
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
