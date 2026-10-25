import AppKit
import Metal
import os
import SillCore
import SillEditor
import SillNvim
import SillRender
import SillSidecar
#if SILL_GHOSTTY
    import SillTerminal
#endif

/// `SILL_CHECK=1`: plays day 1 and day 2 of the plan in the real app, with key events sent through the window as if
/// typed, prints each step, and exits non-zero on the first failure. `SILL_CHECK_SHOT=<file.png>` also saves the
/// window with a pane open. Ghostty draws with Metal, which a view snapshot cannot capture, so the shot shows the
/// terminal's text as read back from the surface, drawn where the surface is.
@MainActor
final class SelfCheck {
    private let window: NSWindow
    private let editor: EditorView
    private let panes: TerminalPanes
    private let session: EditorSession
    private weak var app: AppDelegate?
    private var latest: Screen?
    /// The tag of the frame the editor submitted for the latest screen.
    private var latestTag: UInt64 = 0
    private let presented = OSAllocatedUnfairLock(initialState: [FrameTiming]())

    init(window: NSWindow, editor: EditorView, panes: TerminalPanes, session: EditorSession, app: AppDelegate) {
        self.window = window
        self.editor = editor
        self.panes = panes
        self.session = session
        self.app = app
    }

    func observe(_ update: ScreenUpdate) {
        latest = update.screen
        latestTag = editor.frameTag
    }

    func run() async {
        do {
            // As git's mergetool (driven by the mergetool script): resolve, leave or :cquit, and let sill end as it
            // does for git.
            if ProcessInfo.processInfo.environment["SILL_CHECK"] == "merge" {
                return try await mergeToolSteps()
            }
            // A probe (SILL_PROBE=<script>): sill as the person runs it, their nvim config and all, driven by a script
            // of steps, for looking at what it does on a real project.
            if let script = ProcessInfo.processInfo.environment["SILL_PROBE"] {
                try await probe(script)
                exit(0)
            }
            if let path = ProcessInfo.processInfo.environment["SILL_SHOWCASE"] {
                try await showcase(to: path)
                exit(0)
            }
            if ProcessInfo.processInfo.environment["SILL_CHECK"] == "telemetry" {
                try await telemetrySteps()
                print("sill check (telemetry): passed")
                fflush(stdout)
                exit(0)
            }
            if ProcessInfo.processInfo.environment["SILL_CHECK"] == "ask" {
                try await askSteps()
                print("sill check (ask): passed")
                fflush(stdout)
                exit(0)
            }
            if ProcessInfo.processInfo.environment["SILL_CHECK"] == "config" {
                try await configSteps()
                print("sill check (sill's own config): passed")
                fflush(stdout)
                exit(0)
            }
            if ProcessInfo.processInfo.environment["SILL_CHECK"] == "compat" {
                try await compatSteps()
                print("sill check (a person's own config): passed")
                fflush(stdout)
                exit(0)
            }
            if ProcessInfo.processInfo.environment["SILL_CHECK"] == "hooks" {
                try await hooksSteps()
                print("sill check (agent hooks): passed")
                fflush(stdout)
                exit(0)
            }
            if ProcessInfo.processInfo.environment["SILL_CHECK"] == "investigate" {
                try await investigateSteps()
                print("sill check (investigations): passed")
                fflush(stdout)
                exit(0)
            }
            if ProcessInfo.processInfo.environment["SILL_CHECK"] == "basket" {
                try await basketSteps()
                print("sill check (baskets): passed")
                fflush(stdout)
                exit(0)
            }
            if ProcessInfo.processInfo.environment["SILL_CHECK"] == "trace" {
                try await traceSteps()
                print("sill check (trace): passed")
                fflush(stdout)
                exit(0)
            }
            if ProcessInfo.processInfo.environment["SILL_CHECK"] == "map" {
                try await mapSteps()
                print("sill check (code map): passed")
                fflush(stdout)
                exit(0)
            }
            if ProcessInfo.processInfo.environment["SILL_CHECK"] == "refs" {
                try await referenceSteps()
                print("sill check (file references): passed")
                fflush(stdout)
                exit(0)
            }
            if ProcessInfo.processInfo.environment["SILL_CHECK"] == "follow" {
                try await followSteps()
                print("sill check (follow): passed")
                fflush(stdout)
                exit(0)
            }
            if ProcessInfo.processInfo.environment["SILL_CHECK"] == "reviewwalk" {
                try await reviewWalkSteps()
                print("sill check (review walkthrough): passed")
                fflush(stdout)
                exit(0)
            }
            if ProcessInfo.processInfo.environment["SILL_CHECK"] == "walk" {
                try await walkSteps()
                print("sill check (walkthroughs): passed")
                fflush(stdout)
                exit(0)
            }
            if ProcessInfo.processInfo.environment["SILL_CHECK"] == "review" {
                try await reviewSteps()
                print("sill check (review): passed")
                fflush(stdout)
                exit(0)
            }
            if ProcessInfo.processInfo.environment["SILL_CHECK"] == "agentdebug" {
                try await agentDebugSteps()
                print("sill check (agent debugging and profiling): passed")
                fflush(stdout)
                exit(0)
            }
            if ProcessInfo.processInfo.environment["SILL_CHECK"] == "debug" {
                try await debugSteps()
                print("sill check (debug): passed")
                fflush(stdout)
                exit(0)
            }
            if ProcessInfo.processInfo.environment["SILL_CHECK"] == "settings" {
                try await settingsSteps()
                print("sill check (settings): passed")
                fflush(stdout)
                exit(0)
            }
            if ProcessInfo.processInfo.environment["SILL_CHECK"] == "packages" {
                try await packagesSteps()
                print("sill check (packages): passed")
                fflush(stdout)
                exit(0)
            }
            if ProcessInfo.processInfo.environment["SILL_CHECK"] == "m8" {
                try await m8Steps()
                print("sill check (M8): passed")
                fflush(stdout)
                exit(0)
            }
            if ProcessInfo.processInfo.environment["SILL_CHECK"] == "servers" {
                try await serversSteps()
                print("sill check (servers): passed")
                fflush(stdout)
                exit(0)
            }
            if ProcessInfo.processInfo.environment["SILL_CHECK"] == "m7" {
                try await m7Steps()
                print("sill check (M7): passed")
                fflush(stdout)
                exit(0)
            }
            if ProcessInfo.processInfo.environment["SILL_CHECK"] == "solution" {
                try await solutionSteps()
                print("sill check (solution): passed")
                fflush(stdout)
                exit(0)
            }
            if ProcessInfo.processInfo.environment["SILL_CHECK"] == "project" {
                try await projectSteps()
                print("sill check (project): passed")
                fflush(stdout)
                exit(0)
            }
            if ProcessInfo.processInfo.environment["SILL_CHECK"] == "razor" {
                try await razorSteps()
                print("sill check (Razor): passed")
                fflush(stdout)
                exit(0)
            }
            if ProcessInfo.processInfo.environment["SILL_CHECK"] == "m6" {
                try await m6Steps()
                print("sill check (M6): passed")
                fflush(stdout)
                exit(0)
            }
            if ProcessInfo.processInfo.environment["SILL_CHECK"] == "m5" {
                try await m5Steps()
                print("sill check (M5): passed")
                fflush(stdout)
                exit(0)
            }
            if ProcessInfo.processInfo.environment["SILL_CHECK"] == "m4" {
                try await m4Steps()
                print("sill check (M4): passed")
                fflush(stdout)
                exit(0)
            }
            if ProcessInfo.processInfo.environment["SILL_CHECK"] == "m3" {
                try await m3Steps()
                print("sill check (M3): passed")
                fflush(stdout)
                exit(0)
            }
            if ProcessInfo.processInfo.environment["SILL_CHECK"] == "chrome" {
                try await chromeSteps()
                print("sill check (chrome): passed")
                fflush(stdout)
                exit(0)
            }
            try await steps()
            print("sill check: passed")
            fflush(stdout)
            exit(0)
        } catch {
            print("sill check: FAILED: \(error)")
            fflush(stdout)
            exit(1)
        }
    }

    private func steps() async throws {
        // Day 1: nvim --embed, keys in, a screen out.
        try await wait("nvim's first screen") { $0.placements.values.contains { $0.kind == .window } }
        type("ihello, sill")
        press("\u{1B}", keyCode: 53)
        try await wait("typed text in the window grid") { screen in
            screen.placements.contains { screen.grids[$0.key]?.line(0).hasPrefix("hello, sill") == true }
        }
        step("typed keys reach nvim and come back as a grid")

        try await day3()
        try await day4()
        try await day5()
        try await m2Protocol()

        let size = editor.gridSize
        try await wait("nvim's screen to fill the view, \(size.cols)x\(size.rows)") {
            $0.grids[1]?.cols == size.cols && $0.grids[1]?.rows == size.rows
        }
        step("nvim's screen is the view's size, \(size.cols)x\(size.rows) cells")

        // Day 2: a terminal pane over a placeholder window.
        type(":SillTerminal")
        press("\r", keyCode: 36)
        let opened = try await wait("a pane, current") { $0.currentPane == 1 && $0.paneRects.count == 1 }
        let rect = try require(opened.paneRects.first, "the pane's rect")
        let view = try await waitFor("the pane's surface") { self.panes.view(for: 1) }
        let expected = editor.rect(row: rect.row, col: rect.col, width: rect.width, height: rect.height)
        try expect(view.frame == expected, "surface at \(view.frame), placeholder window at \(expected)")
        try expect(view.superview === editor && !view.isHidden, "surface shown in the editor")
        try expect(window.firstResponder === editor, "the keyboard stays with nvim until i")
        step("the surface covers its placeholder window, \(rect.width)x\(rect.height) cells at \(rect.row),\(rect.col)")

        chord("w", keyCode: 13)
        type("h")
        try await wait("<C-w>h to the editor window") { $0.currentPane == nil && $0.cursorWindow != nil }
        chord("w", keyCode: 13)
        type("l")
        try await wait("<C-w>l back to the pane") { $0.currentPane == 1 }
        step("<C-w>h and <C-w>l cross the pane")

        type("i")
        try await waitFor("the terminal to have the keyboard") { self.window.firstResponder === view ? true : nil }
        step("i in the pane hands the keyboard to the terminal")

        #if SILL_GHOSTTY
            let surface = try require(view as? GhosttySurfaceView, "a Ghostty surface")
            // Only the command's output says sill-check; the typed line says sill check. Works in any shell.
            type("echo sill check | tr ' ' -")
            press("\r", keyCode: 36)
            _ = try await waitFor("the shell to run what was typed", timeout: .seconds(15)) {
                surface.visibleText()?.contains("sill-check") == true ? true : nil
            }
            step("typed keys reach the shell in the pane")

            // The pane follows the grid's font: ⌘+ twice makes its cells taller too, ⌘0 brings them back.
            let before = surface.cellHeight
            app?.fontBigger(nil)
            app?.fontBigger(nil)
            _ = try await waitFor("the pane's bigger cells", timeout: .seconds(5)) {
                surface.cellHeight > before ? true : nil
            }
            let bigger = surface.cellHeight
            app?.fontActual(nil)
            _ = try await waitFor("the pane's cells back", timeout: .seconds(5)) {
                surface.cellHeight == before ? true : nil
            }
            step("the pane follows the font: ⌘+ twice took its cells from \(before) to \(bigger) px, ⌘0 back")
        #endif

        if let path = ProcessInfo.processInfo.environment["SILL_CHECK_SHOT"] {
            try shot(to: path)
            step("saved \(path)")
        }

        chord("\\", keyCode: 42)
        chord("n", keyCode: 45)
        try await waitFor("the keyboard back with nvim") { self.window.firstResponder === self.editor ? true : nil }
        chord("w", keyCode: 13)
        type("h")
        try await wait("<C-w>h out of the pane") { $0.currentPane == nil }
        step("<C-\\><C-n> gives the keyboard back to nvim, and <C-w>h leaves the pane")

        type(":only")
        press("\r", keyCode: 36)
        try await wait("no panes") { $0.paneRects.isEmpty && $0.panes.isEmpty }
        _ = try await waitFor("the surface gone") { view.superview == nil ? true : nil }
        step(":only closes the pane and its terminal")
    }

    /// `SILL_SHOWCASE=<file.png>`: a picture of sill at work, whatever size the window is. nvim is asked for a 150x46
    /// screen, `SILL_SHOWCASE_FILE` (else sill's own runtime) opens beside a terminal pane running `git log`, and the
    /// frame is rendered offscreen at that size. `SILL_SHOWCASE_SCENE` is `profile` (the profiler) or `agents` (the
    /// Agents sidebar over the heed at `HEED_CONTROL`).
    /// Runs a probe script: `wait <seconds>`, `cmd <ex command>`, `lua <code>` (prints what it returns), `keys
    /// <keys>` (nvim_input), `shot <png>`, `state` (panes, tab pages, buffers, problems), `messages`.
    private func probe(_ script: String) async throws {
        let lines = try String(contentsOfFile: script, encoding: .utf8).components(separatedBy: "\n")
        let started = ContinuousClock.now
        func say(_ text: String) {
            let seconds = Double((ContinuousClock.now - started).components.attoseconds) / 1e18 +
                Double((ContinuousClock.now - started).components.seconds)
            print("probe: [\(String(format: "%6.1f", seconds))] " + text)
            fflush(stdout)
        }
        for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty && !line.hasPrefix("#") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            let argument = parts.count > 1 ? parts[1] : ""
            say("> " + line)
            do {
                switch parts[0] {
                case "wait": try await Task.sleep(for: .seconds(Double(argument) ?? 1))
                case "cmd": try await session.channel.command(argument)
                case "lua": try await say("\(session.channel.lua(argument))")
                case "keys": _ = await session.channel.request("nvim_input", params: [.string(argument)])
                case "shot":
                    try shot(to: argument)
                    say("saved \(argument)")
                case "menu":
                    // A menu bar item by its title, chosen as a click would.
                    func find(_ menu: NSMenu?) -> NSMenuItem? {
                        for item in menu?.items ?? [] {
                            if item.title == argument { return item }
                            if let found = find(item.submenu) { return found }
                        }
                        return nil
                    }
                    if let item = find(NSApp.mainMenu), let action = item.action {
                        NSApp.sendAction(action, to: item.target, from: item)
                    } else {
                        say("no menu item \(argument)")
                    }
                case "messages": await say((try? session.channel.lua("return vim.fn.execute('messages')"))?
                        .stringValue ?? "")
                case "state":
                    let screen = latest ?? Screen()
                    say("panes: " + screen.paneRects.map { "\($0.kind)#\($0.pane) \($0.width)x\($0.height)" }
                        .joined(separator: ", "))
                    say("current pane: \(screen.currentPaneKind ?? "editor"); problems: \(screen.diagnostics.count)")
                    let tabs = try await session.channel.lua("""
                    local out = {}
                    for i, t in ipairs(vim.api.nvim_list_tabpages()) do
                      local names = {}
                      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(t)) do
                        local b = vim.api.nvim_win_get_buf(w)
                        table.insert(names, vim.fn.fnamemodify(vim.api.nvim_buf_get_name(b), ':t') .. '[' .. vim.bo[b].filetype .. ']')
                      end
                      table.insert(out, i .. ': ' .. table.concat(names, ', '))
                    end
                    return table.concat(out, ' | ')
                    """)
                    say("tabs: " + (tabs.stringValue ?? ""))
                default: say("unknown step")
                }
            } catch {
                say("failed: \(error)")
            }
        }
    }

    private func showcase(to path: String) async throws {
        try await wait("nvim's first screen") { $0.placements.values.contains { $0.kind == .window } }
        let root = try require(app?.root, "the root view")
        if app?.chrome == true {
            try await wait("the sidebar and the panel") { screen in
                screen.paneRects.contains { $0.kind == "sidebar" } && screen.paneRects.contains { $0.kind == "panel" }
            }
        }
        let file = ProcessInfo.processInfo.environment["SILL_SHOWCASE_FILE"] ??
            Runtime.directory.appendingPathComponent("lua/sill/init.lua").path
        try await session.channel.command("edit \(file.replacingOccurrences(of: " ", with: "\\ "))")
        try await session.channel.command("set number cursorline")
        try await session.channel.command("call cursor(32, 5)")
        // A problem for the panel, as a language server would report one.
        _ = try await session.channel.lua("""
        local ns = vim.api.nvim_create_namespace('showcase')
        vim.diagnostic.set(ns, 0, {
          { lnum = 31, col = 4, severity = vim.diagnostic.severity.ERROR, source = 'lua_ls', code = 'undefined-global',
            message = "Undefined global `notifyy`." },
          { lnum = 12, col = 0, severity = vim.diagnostic.severity.WARN, source = 'lua_ls', code = 'unused-local',
            message = "Unused local `next_pane`." },
        })
        """)
        if ProcessInfo.processInfo.environment["SILL_SHOWCASE_SCENE"] == "agents" {
            // The Agents sidebar over heed's sessions (heed at HEED_CONTROL), the rest as the default scene.
            _ = try await session.channel.lua("vim.cmd('SillAgent list')")
            _ = try await waitFor("heed's sessions", timeout: .seconds(10)) { self.app?.agents.sessions }
            _ = try await waitFor("the Agents sidebar") { self.app?.tools.sidebar.activity == .agents ? true : nil }
            try await session.channel.command("wincmd p")
        }
        if ProcessInfo.processInfo.environment["SILL_SHOWCASE_SCENE"] == "profile" {
            try await session.channel.command("SillProfile synthetic")
            let profile = try await waitFor("the profiler") {
                self.app?.tools.profile.flatMap { $0.isHidden ? nil : $0 }
            }
            if let hot = profile.profile.nodes.indices.filter({ profile.profile.nodes[$0].depth == 5 })
                .max(by: { profile.profile.nodes[$0].samples < profile.profile.nodes[$1].samples })
            {
                profile.select(hot, zoom: false)
            }
            try await Task.sleep(for: .milliseconds(300))
            try shot(of: root, to: path, cursor: false)
            print("sill showcase: saved \(path)")
            fflush(stdout)
            return
        }
        try await session.channel.command("SillTerminal")
        let pane = try await waitFor("the pane's surface") {
            self.panes.view(for: self.latest?.paneRects.first { $0.kind == "terminal" }?.pane ?? -1)
        }
        #if SILL_GHOSTTY
            if let surface = pane as? GhosttySurfaceView {
                try await Task.sleep(for: .seconds(1.5)) // The shell's prompt.
                surface.typeLine("git -C \(Runtime.directory.deletingLastPathComponent().path) log --oneline -12")
                try await Task.sleep(for: .seconds(1.5))
            }
        #else
            _ = pane
        #endif
        session.channel.send(keys: "<C-w>h")
        try await wait("the editor window current") { $0.currentPane == nil && $0.cursorWindow != nil }
        try await Task.sleep(for: .milliseconds(500))
        try shot(of: root, to: path, cursor: true)
        print("sill showcase: saved \(path)")
        fflush(stdout)
    }

    /// `SILL_CHECK=merge SILL_MERGE=theirs|leave|cq`, run by git's mergetool: every conflict taken as theirs and saved,
    /// the result saved as it is, or every conflict taken and saved and then `:cquit`. sill then ends as it would for a
    /// person (`endTool`).
    private func mergeToolSteps() async throws {
        // Opened: a merge reports its conflicts; a diff has two windows in diff mode.
        for attempt in 0 ... 300 {
            let opened = switch app?.tool {
            case .merge?: latest?.merge != nil
            case .diff?: await (try? session.channel.lua(
                    "return #vim.tbl_filter(function(w) return vim.wo[w].diff end, vim.api.nvim_list_wins())"
                ))?.int64Value == 2
            case nil: false
            }
            if opened {
                step(latest?.merge.map { "a merge of \($0.file): \($0.left) conflicts" } ?? "a diff: two windows")
                break
            }
            if attempt == 300 { throw CheckFailure(description: "timed out waiting for the merge or diff") }
            try await Task.sleep(for: .milliseconds(100))
        }
        switch ProcessInfo.processInfo.environment["SILL_MERGE"] ?? "theirs" {
        // nvim ends in these, so their answers may never come: how sill ends is what is checked. cq resolves and saves
        // first, so only nvim's own status says the merge was given up.
        case "theirs", "cq":
            let end = ProcessInfo.processInfo.environment["SILL_MERGE"] == "cq" ? "vim.cmd('wall') vim.cmd('cquit')" :
                "vim.cmd('wqa')"
            _ = try? await session.channel.lua("""
            local merge = require('sill.merge')
            local buf = vim.g.sill_merge_result
            if buf then vim.api.nvim_set_current_win(vim.fn.bufwinid(buf)) end
            for _ = 1, buf and 1000 or 0 do
              local first = merge.conflicts(buf)[1]
              if not first then break end
              vim.api.nvim_win_set_cursor(0, { first.start, 0 })
              merge.take('theirs')
            end
            \(end)
            """)
        default:
            _ = try? await session.channel.command("wqa")
        }
    }

    /// M9's settings (`SILL_CHECK=settings SILL_SETTINGS=<a file not there yet>`, with HEED_CONTROL set): the commented
    /// default written on first start; the window's controls write one value each in place, comments kept, and the
    /// file read back applies at once; an edit by hand, a typo and a syntax error reach the window; a variable set in
    /// the environment disables its row.
    private func settingsSteps() async throws {
        let app = try require(app, "the app")
        let file = try require(SettingsController.file, "SILL_SETTINGS")
        func text() -> String { (try? String(contentsOf: file, encoding: .utf8)) ?? "" }
        try expect(text() == SettingsLoader.defaultSource, "the commented default written on first start")
        try expect(Settings.shared.current == .default && Settings.shared.problems.isEmpty, "the defaults")
        step("first start wrote \(file.lastPathComponent) with every setting commented out at its default")

        app.showSettings(nil)
        let window = try require(app.settings.window, "the settings window")
        let size = try require(window.controls["editor.size"] as? NSStepper, "the size stepper")
        try expect(size.doubleValue == 13, "the size shown: \(size.doubleValue)")
        size.doubleValue = 15
        _ = size.target?.perform(size.action)
        let agent = try require(window.controls["agents.command"] as? NSTextField, "the agent field")
        agent.stringValue = "codex"
        _ = agent.target?.perform(agent.action)
        try await waitFor("the file read back", timeout: .seconds(5)) {
            Settings.shared.current.size == 15 && Settings.shared.value("SILL_AGENT") == "codex" ? true : nil
        }
        let written = text()
        try expect(
            written.contains("⌘0 comes back to this.\nsize = 15\n") &&
                written.contains("command = \"codex\"") && written.contains("# sill's settings."),
            "set in place, comments kept:\n\(written)"
        )
        step(
            "the window wrote size = 15 and command = \"codex\" in place, comments kept; read back, the agent is codex"
        )

        // The font, live: the size from the file reaches the grid, and nvim gets fewer, taller rows.
        func lines() async throws -> Int {
            try await Int(session.channel.lua("return vim.o.lines").int64Value ?? 0)
        }
        try await waitFor("the grid at 15 points") { EditorFont.metrics.regular.pointSize == 15 ? true : nil }
        let at15 = try await (cell: EditorFont.metrics.height, lines: lines())
        app.fontBigger(nil)
        app.fontBigger(nil)
        try expect(EditorFont.metrics.regular.pointSize == 17 && EditorFont.metrics.height > at15.cell, "⌘+ twice")
        var at17 = 0
        for _ in 0 ..< 50 {
            at17 = try await lines()
            if at17 < at15.lines { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try expect(at17 < at15.lines, "nvim told of the bigger cells: \(at15.lines) lines, then \(at17)")
        if let shot = ProcessInfo.processInfo.environment["SILL_CHECK_SHOT_GRID"] {
            _ = try await session.channel.lua("vim.cmd('edit ' .. vim.fn.fnameescape(...))", args: [.string(file.path)])
            try await Task.sleep(for: .milliseconds(500))
            try self.shot(to: shot)
            step("saved \(shot): the grid at 17 points")
        }
        app.fontActual(nil)
        try expect(EditorFont.metrics.regular.pointSize == 15, "⌘0 back to the settings' size")
        step("the font live: 15 pt from the file reached the grid (\(at15.lines) lines); ⌘+ twice made it 17 pt " +
            "(\(at17) lines); ⌘0 back to 15")

        // By hand, as in nvim: a smooth-scroll change and a typo.
        try (written + "\n[editor2]\nsize = 1\n").replacingOccurrences(
            of: "# smooth_scroll = true",
            with: "smooth_scroll = false"
        )
        .write(to: file, atomically: true, encoding: .utf8)
        try await waitFor("the edit by hand", timeout: .seconds(5)) {
            !Settings.shared.current.smoothScroll && !Settings.shared.problems.isEmpty ? true : nil
        }
        let toggle = try require(window.controls["editor.smooth_scroll"] as? NSSwitch, "the smooth scroll switch")
        try await waitFor("the window following the file") { toggle.state == .off ? true : nil }
        try expect(
            Settings.shared.problems.map(\.description) == ["editor2.size: is not a setting"],
            "the typo: \(Settings.shared.problems)"
        )
        step("an edit by hand applied at once (smooth scrolling off), and the window shows the typo: editor2.size")

        // Islands are on by default; the switch turns them off at once, flat panels again.
        try expect(Design.islands && !app.root.islands.isHidden, "islands by default")
        let islands = try require(window.controls["window.islands"] as? NSSwitch, "the islands switch")
        islands.state = .off
        _ = islands.target?.perform(islands.action)
        try await waitFor("flat panels", timeout: .seconds(5)) {
            !Design.islands && app.root.islands.isHidden ? true : nil
        }
        islands.state = .on
        _ = islands.target?.perform(islands.action)
        try await waitFor("islands again", timeout: .seconds(5)) { Design.islands ? true : nil }
        step("islands on by default; the switch turns them off and on at once")

        let good = text()
        try "[editor\nsize = 20\n".write(to: file, atomically: true, encoding: .utf8)
        try await waitFor("the syntax error", timeout: .seconds(5)) {
            Settings.shared.problems.first?.path == "" ? true : nil
        }
        try expect(
            Settings.shared.current.size == 15 && Settings.shared.value("SILL_AGENT") == "codex",
            "the last good settings kept"
        )
        step("a syntax error: \(Settings.shared.problems[0]); the last good settings kept")

        let heed = try require(window.controls["heed.control"], "the heed socket field")
        try expect(!heed.isEnabled && agent.isEnabled, "HEED_CONTROL from the environment disables its row only")
        step("HEED_CONTROL, set in the environment, disables its row")

        try good.write(to: file, atomically: true, encoding: .utf8)
        try await waitFor("the file fixed", timeout: .seconds(5)) {
            Settings.shared.problems.map(\.path) == ["editor2.size"] ? true : nil
        }
        window.refresh()
        if let shot = ProcessInfo.processInfo.environment["SILL_CHECK_SHOT"] {
            let view = try require(window.contentView, "the window's view")
            view.layoutSubtreeIfNeeded()
            let rep = try require(view.bitmapImageRepForCachingDisplay(in: view.bounds), "a bitmap")
            view.cacheDisplay(in: view.bounds, to: rep)
            try require(rep.representation(using: .png, properties: [:]), "png").write(to: URL(fileURLWithPath: shot))
            step("saved \(shot)")
        }
    }

    /// M9's packages (`SILL_CHECK=packages`, run in a copy of Tests/SillCoreTests/Fixtures/PackagesProject, with the
    /// network: nuget.org and osv.dev): board 3 from the SDK's answers; the worst first, its advisory read; Update
    /// security and patches edits the project, and the packages read again say what is left; Update on the one left
    /// moves it to the version its advisory says fixes it. `SILL_CHECK_SHOT` saves the view.
    private func packagesSteps() async throws {
        let app = try require(app, "the app")
        let project = (app.workingDirectory as NSString).appendingPathComponent("Pkgs.csproj")
        try await wait("the chrome") { $0.paneRects.contains { $0.kind == "panel" } }
        _ = try await session.channel.lua("vim.cmd('SillPackages')")
        try await wait("the packages pane") { $0.currentPaneKind == "packages" }
        let view = try await waitFor("the packages view") { app.tools.packages }
        let started = CACurrentMediaTime()
        let report = try await waitFor("the SDK's report", timeout: .seconds(240)) {
            app.packages.scanner.scanning ? nil : app.packages.scanner.report
        }
        try expect(report.packages.count == 5, "five packages: \(report.packages.map(\.id))")
        try expect(Set(report.vulnerable.map(\.id)) == ["Newtonsoft.Json", "System.Text.Json"], "vulnerable")
        try expect(report.deprecated.map(\.id) == ["Microsoft.AspNetCore.Mvc.Versioning"], "deprecated")
        try expect(report.outdated.count >= 3, "outdated: \(report.outdated.map(\.id))")
        step(
            "the SDK's report in \(Bench.format(CACurrentMediaTime() - started)) s: \(report.vulnerable.count) vulnerable, " +
                "\(report.outdated.count) outdated, \(report.deprecated.count) deprecated, \(report.packages.count) in all"
        )
        let first = try require(view.current, "a package selected")
        try expect(first.isVulnerable, "the worst first: \(first.id)")
        _ = try await waitFor("its advisories from osv.dev", timeout: .seconds(30)) {
            first.vulnerabilities
                .allSatisfy { app.packages.scanner.advisories[$0.id]?.fixed.isEmpty == false } ? true : nil
        }
        step("\(first.id) first, its advisories read: fixed in " +
            first.vulnerabilities.compactMap { app.packages.scanner.advisories[$0.id]?.fixed.joined(separator: "/") }
            .joined(separator: ", "))
        let origin = try await waitFor("how it got here, read off the main thread") {
            app.packages.scanner.origins[first.id].flatMap { $0.chain.isEmpty ? nil : $0 }
        }
        try expect(origin.chain.last == first.id && origin.file == project, "its origin: \(origin)")
        step("how it got here: \(origin.chain.joined(separator: " → ")), its version in Pkgs.csproj")
        if let shot = ProcessInfo.processInfo.environment["SILL_CHECK_SHOT"] {
            view.display()
            try self.shot(to: shot)
            step("saved \(shot)")
        }

        let safe = view.safe
        try expect(safe.count >= 4, "patches to apply: \(safe.map(\.id))")
        app.packages.update(safe.compactMap { package in package.safeUpdate.map { (package, $0) } })
        let text = try String(contentsOfFile: project, encoding: .utf8)
        try expect(
            text.contains("Include=\"System.Text.Json\" Version=\"8.0.") && !text.contains("Version=\"8.0.3\""),
            "System.Text.Json patched in the project"
        )
        let after = try await waitFor("the packages read again", timeout: .seconds(240)) {
            !app.packages.scanner.scanning && app.packages.scanner.report != report ? app.packages.scanner.report : nil
        }
        try expect(after.vulnerable.map(\.id) == ["Newtonsoft.Json"], "left vulnerable: \(after.vulnerable.map(\.id))")
        step("Update security and patches moved \(safe.count) packages in Pkgs.csproj; only Newtonsoft.Json is " +
            "still vulnerable (its fix is a major version)")

        view.scanned()
        let newtonsoft = try require(after.vulnerable.first, "Newtonsoft.Json")
        _ = try await waitFor("Newtonsoft's advisory", timeout: .seconds(30)) {
            newtonsoft.vulnerabilities.allSatisfy { app.packages.scanner.advisories[$0.id]?.fixed.isEmpty == false }
                ? true : nil
        }
        let version = try require(view.update(for: newtonsoft), "an update for it")
        app.packages.update([(newtonsoft, version)])
        let fixed = try await waitFor("read again", timeout: .seconds(240)) {
            !app.packages.scanner.scanning && app.packages.scanner.report != after ? app.packages.scanner.report : nil
        }
        try expect(fixed.vulnerable.isEmpty, "nothing vulnerable: \(fixed.vulnerable.map(\.id))")
        step("Update moves Newtonsoft.Json to \(version), the version its advisory names: nothing vulnerable left")
    }

    /// M8's exit (`SILL_CHECK=m8`, run in a copy of Tests/SillSidecarTests/Fixtures/Sample): breakpoints and stepping
    /// in C#. A breakpoint in the loop, F5: the program built, launched under sill's debug adapter and paused there,
    /// the
    /// line marked, the stack and locals in the Debug tab; F10 steps, F5 runs to the breakpoint's next hit; a
    /// breakpoint
    /// removed while paused reaches the adapter; Shift-F5 ends it. `SILL_CHECK_SHOT` saves the paused window.
    /// The debugger past M8 (`SILL_CHECK=debug`, in a copy of Tests/SillSidecarTests/Fixtures/Debuggee): a function
    /// breakpoint, a conditional one, evaluating (`:SillEval`, a watch, the hover), a logpoint, the exception the
    /// program does not handle (the one it handles does not stop it), then attaching to the program running on its own
    /// and detaching, which leaves it running.
    private func debugSteps() async throws {
        let app = try require(app, "the app")
        let debugger = try require(app.debugger, "the debugger")
        let program = (app.workingDirectory as NSString).appendingPathComponent("Program.cs")
        try await wait("the chrome") { $0.paneRects.contains { $0.kind == "panel" } }
        _ = try await waitFor("the sidecar", timeout: .seconds(20)) { app.sidecar }
        _ = try await session.channel.lua("require'sill'.open(...)", args: [.string(program), .int(10)])
        try await wait("Program.cs open") { $0.buffer.name == "Program.cs" }
        _ = try await session.channel.lua("vim.cmd('SillBreakpoint if i == 3')")
        _ = try await session.channel.lua("vim.cmd('SillBreakpoint fn Pricing.Total')")
        try await wait("the breakpoints") {
            $0.breakpoints[program] == [Screen.Breakpoint(line: 10, condition: "i == 3")] &&
                $0.functionBreakpoints == ["Pricing.Total"]
        }
        let sign = try await session.channel.lua("""
        local marks = vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_get_namespaces()['sill.breakpoints'], 0, -1,
          { details = true })
        return marks[1][4].sign_text
        """)
        try expect(sign.stringValue?.hasPrefix("◆") == true, "a conditional breakpoint's sign: \(sign)")
        step("a conditional breakpoint (◆, if i == 3) on line 10 and a function breakpoint on Pricing.Total")

        func locals() -> [String: String] {
            Dictionary(
                (debugger.scopeReference.flatMap { debugger.variables[$0] } ?? []).map { ($0.name, $0.value) },
                uniquingKeysWith: { first, _ in first }
            )
        }
        session.channel.send(keys: "<F5>")
        _ = try await waitFor("a pause", timeout: .seconds(180)) {
            if case .paused = debugger.state { return true }
            return nil
        }
        // The adapter calls a function breakpoint's stop a breakpoint.
        try expect(
            debugger.state == .paused(reason: "breakpoint"),
            "paused by the function breakpoint: \(debugger.state)"
        )
        try expect(
            debugger.frames.first?.name.contains("Total") == true,
            "in Pricing.Total: \(debugger.frames.first?.name ?? "")"
        )
        _ = try await waitFor("its locals") { locals()["seed"] }
        try expect(locals()["seed"] == "0", "seed 0: \(locals())")
        step("F5 stops in Pricing.Total first (the function breakpoint), seed = 0")

        _ = try await session.channel.lua("vim.cmd('SillBreakpoint fn Pricing.Total')")
        try await wait("the function breakpoint gone") { $0.functionBreakpoints.isEmpty }
        session.channel.send(keys: "<F5>")
        _ = try await waitFor("the condition", timeout: .seconds(30)) {
            debugger.state == .paused(reason: "breakpoint") && locals()["i"] != nil ? true : nil
        }
        try expect(locals()["i"] == "3" && debugger.frames.first?.line == 10, "stopped where i == 3: \(locals())")
        step("removed, it no longer stops there; the condition stops line 10 only when i == 3")

        _ = try await session.channel.lua("vim.cmd('SillEval orders.Count')")
        let evaluated = try await waitFor("the evaluation", timeout: .seconds(10)) { debugger.evaluated }
        try expect(evaluated.value == "3", "orders.Count = 3: \(evaluated)")
        _ = try await session.channel.lua("vim.cmd('SillWatch i * 10')")
        _ = try await waitFor("the watch", timeout: .seconds(10)) {
            debugger.watches.first?.value == "30" ? true : nil
        }
        app.hover("orders.Count", at: NSRect(x: 100, y: 100, width: 8, height: 16))
        _ = try await waitFor("the hover", timeout: .seconds(10)) {
            app.hoverShown == "orders.Count = 3" ? true : nil
        }
        _ = try await session.channel.lua("vim.cmd('SillEval orders.Nope')")
        _ = try await waitFor("the error", timeout: .seconds(10)) {
            debugger.evaluated?.expression == "orders.Nope" && debugger.evaluated?.value.hasPrefix("error:") == true
                ? true : nil
        }
        step("evaluated where it paused: :SillEval orders.Count = 3, a watch i * 10 = 30, the hover over " +
            "orders.Count, and orders.Nope says why it has no value")
        if let shot = ProcessInfo.processInfo.environment["SILL_CHECK_SHOT"] {
            try await Task.sleep(for: .milliseconds(300))
            try self.shot(to: shot)
            step("saved \(shot)")
        }

        // A logpoint instead: it writes and goes on.
        _ = try await session.channel.lua("vim.cmd('SillBreakpoint log order {i} for {orders.Count}')")
        try await wait("the logpoint") { $0.breakpoints[program]?.first?.log != nil }
        session.channel.send(keys: "<F5>")
        _ = try await waitFor("the unhandled exception", timeout: .seconds(60)) {
            debugger.state == .paused(reason: "exception") && debugger.exception != nil ? true : nil
        }
        let output = app.tools.panel.outputText
        try expect(output.contains("order 9 for 9"), "the logpoint wrote as the loop ran: \(output.suffix(400))")
        let exception = try require(debugger.exception, "the exception")
        try expect(exception.exceptionId.contains("ArgumentException"), "the unhandled ArgumentException: \(exception)")
        // The watch is evaluated again at this pause, where i is out of scope.
        _ = try await waitFor("the watch evaluated again", timeout: .seconds(10)) {
            debugger.watches.first?.value.hasPrefix("error:") == true ? true : nil
        }
        step("a logpoint wrote \"order 9 for 9\" without stopping; the handled exception did not stop it, the " +
            "unhandled one did: \(exception.exceptionId)")
        session.channel.send(keys: "<S-F5>")
        _ = try await waitFor("the session over", timeout: .seconds(20)) { debugger.state == .idle ? true : nil }

        // Attaching: the program as built, running on its own.
        let dll = (app.workingDirectory as NSString).appendingPathComponent("bin/Debug/net10.0/Debuggee.dll")
        let running = Process()
        running.executableURL = try Sidecar.findDotnet()
        running.arguments = [dll, "--wait"]
        running.standardOutput = FileHandle.nullDevice
        try running.run()
        defer { if running.isRunning { running.terminate() } }
        let pid = running.processIdentifier
        _ = try await waitFor("its diagnostics socket", timeout: .seconds(20)) {
            Debugger.dotnetProcesses().contains { $0.pid == pid } ? true : nil
        }
        _ = try await session.channel.lua("vim.api.nvim_win_set_cursor(0, { 10, 0 }) vim.cmd('SillBreakpoint')")
        _ = try await session.channel.lua("vim.api.nvim_win_set_cursor(0, { 33, 0 }) vim.cmd('SillBreakpoint')")
        try await wait("the breakpoint in Tick") { $0.breakpoints[program]?.map(\.line) == [33] }
        debugger.answer("attach \(pid)")
        _ = try await waitFor("paused in the running program", timeout: .seconds(60)) {
            debugger.state == .paused(reason: "breakpoint") && debugger.frames.first?.line == 33 ? true : nil
        }
        _ = try await waitFor("tick") { locals()["tick"] }
        step("attached to the program running on its own (pid \(pid), found by its diagnostics socket): " +
            "paused in Clock.Tick, tick = \(locals()["tick"] ?? "")")
        session.channel.send(keys: "<S-F5>")
        _ = try await waitFor("detached", timeout: .seconds(20)) { debugger.state == .idle ? true : nil }
        try await Task.sleep(for: .seconds(1))
        try expect(running.isRunning, "detaching leaves it running")
        step("Shift-F5 detaches and the program goes on running")
    }

    /// An agent debugging and profiling through sill's MCP tools while sill shows it (`SILL_CHECK=agentdebug`, in a
    /// folder holding copies of Tests/SillSidecarTests/Fixtures/Debuggee and Sample, with
    /// SILL_MCP_ALLOW=debug,profile):
    /// a conditional breakpoint shown as a sign, the program run to it, an expression evaluated and a step taken, the
    /// unhandled exception reached, all in sill's Debug tab as it goes; then the sample profiled twice, a heap snapshot
    /// between, and the two runs compared.
    private func agentDebugSteps() async throws {
        let app = try require(app, "the app")
        try await wait("the chrome") { $0.paneRects.contains { $0.kind == "panel" } }
        _ = try await waitFor("the sidecar", timeout: .seconds(20)) { app.sidecar }
        let socket = try await waitFor("sill's MCP server") { app.agents.socketPath }
        let agent = try McpClient(socket)
        defer { agent.close() }
        _ = try await agent.request("initialize", [
            "protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "check", "version": "1"],
        ])
        agent.notify("notifications/initialized")
        let tools = try await agent.request("tools/list", [:])
        let names = Set(((tools["tools"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String })
        let wanted: Set = [
            "debug_start",
            "debug_attach",
            "debug_breakpoint",
            "debug_step",
            "debug_state",
            "debug_evaluate",
            "debug_stop",
            "profile_start",
            "profile_snapshot",
            "profile_stop",
            "profile_compare",
        ]
        try expect(wanted.isSubset(of: names), "the debugging and profiling tools: \(names.sorted())")
        let debuggee = (app.workingDirectory as NSString).appendingPathComponent("Debuggee")
        let program = (debuggee as NSString).appendingPathComponent("Program.cs")
        let debugger = try require(app.debugger, "the debugger")

        _ = try await agent.call("debug_breakpoint", ["path": program, "line": 10, "condition": "i == 5"])
        try await wait("the agent's breakpoint as a sign") {
            $0.breakpoints[program] == [Screen.Breakpoint(line: 10, condition: "i == 5")]
        }
        let started = try await agent.call("debug_start", ["project": "Debuggee/Debuggee.csproj", "wait_seconds": 180])
        try expect(
            started.contains("paused (breakpoint) at \(program):10") && started.contains("i = 5"),
            "debug_start says where it paused: \(started)"
        )
        try expect(debugger.drivenByAgent && app.tools.panel.tab == .debug, "sill shows it, marked as the agent's")
        step("debug_breakpoint (i == 5) shows as a sign; debug_start runs to it: \(started.split(separator: "\n")[0])")
        if let shot = ProcessInfo.processInfo.environment["SILL_CHECK_SHOT"] {
            try await Task.sleep(for: .milliseconds(300))
            try self.shot(to: shot)
            step("saved \(shot)")
        }
        let count = try await agent.call("debug_evaluate", ["expression": "orders.Count"])
        try expect(count == "orders.Count = 5" && debugger.evaluated?.value == "5", "evaluated, in sill too: \(count)")
        let stepped = try await agent.call("debug_step", ["action": "next"])
        try expect(stepped.contains("paused (step)"), "a step: \(stepped.prefix(120))")
        _ = try await agent.call("debug_breakpoint", ["path": program, "line": 10, "remove": true])
        try await wait("the sign gone") { $0.breakpoints[program]?.isEmpty ?? true }
        let thrown = try await agent.call("debug_step", ["action": "continue"])
        try expect(thrown.contains("exception: CLR/System.ArgumentException"), "on to the exception: \(thrown)")
        _ = try await agent.call("debug_stop")
        _ = try await waitFor("the session over", timeout: .seconds(20)) { debugger.state == .idle ? true : nil }
        step("debug_evaluate orders.Count = 5, a step, the breakpoint removed and continue to the unhandled " +
            "ArgumentException; debug_stop ends it")

        // Profiling the sample twice, a snapshot between, and comparing.
        let sample = "Sample/Sample.csproj"
        let recording = try await agent.call("profile_start", ["project": sample])
        try expect(recording.hasPrefix("Recording Sample"), "profile_start: \(recording)")
        let view = try require(app.tools.profile, "the profile pane")
        try expect(view.drivenByAgent && view.subtitle.contains("an agent is profiling"), "marked: \(view.subtitle)")
        try await Task.sleep(for: .seconds(1))
        _ = try await agent.call("profile_snapshot")
        try await Task.sleep(for: .seconds(1.5))
        let heap = try await agent.call("profile_snapshot")
        try expect(
            heap.contains("Order") && heap.contains("what keeps") && heap.contains("OrderCache"),
            "the growth and its retainer: \(heap)"
        )
        try await Task.sleep(for: .seconds(1))
        let first = try await agent.call("profile_stop")
        try expect(first.contains("Pricing.Total") && first.contains("Program.cs"), "the hot frame: \(first)")
        _ = try await agent.call("profile_start", ["project": sample])
        try await Task.sleep(for: .seconds(2))
        let second = try await agent.call("profile_stop")
        try expect(second.contains("compared with the previous run:\ncpu: "), "compared with the first: \(second)")
        let compared = try await agent.call("profile_compare")
        try expect(
            compared.hasPrefix("cpu: ") && view.tab == .compare && view.comparison != nil,
            "the Compare tab: \(compared.prefix(80))"
        )
        if let shot = ProcessInfo.processInfo.environment["SILL_CHECK_SHOT"] {
            let compare = (shot as NSString).deletingPathExtension + "-compare.png"
            view.display()
            try self.shot(to: compare)
            step("saved \(compare)")
        }
        step("profile_start, two snapshots (Order grows, kept by OrderCache), profile_stop with Pricing.Total hot; " +
            "a second run compared with the first: \(compared.split(separator: "\n")[0])")
    }

    /// Review mode (`SILL_CHECK=review`, in a git repository with a.txt of twenty lines committed, SILL_AGENT=echo):
    /// an agent's changes (two places in a.txt, a new file) against the baseline taken when sill opened; one change
    /// taken
    /// back in the file, a comment on the other sent as a review; a turn's end taking a new baseline.
    private func reviewSteps() async throws {
        let app = try require(app, "the app")
        let reviewer = try require(app.reviewer, "the reviewer")
        let root = app.workingDirectory
        try await wait("the chrome") { $0.paneRects.contains { $0.kind == "panel" } }
        _ = try await waitFor("the baseline when sill opened", timeout: .seconds(10)) {
            reviewer.baselines.first?.name == "when sill opened" ? true : nil
        }
        // The agent's work, on disk.
        var lines = (1 ... 20).map { "line \($0)" }
        lines[2] = "line three"
        lines[16] = "line seventeen"
        try (lines.joined(separator: "\n") + "\n").write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        try "new\n".write(toFile: root + "/c.txt", atomically: true, encoding: .utf8)

        _ = try await session.channel.lua("vim.cmd('SillReview')")
        try await wait("the review pane") { $0.currentPaneKind == "review" }
        let view = try await waitFor("the review view") { app.tools.review }
        _ = try await waitFor("the changes", timeout: .seconds(10)) {
            reviewer.files.map(\.path) == ["a.txt", "c.txt"] && reviewer.diff?.hunks.count == 2 ? true : nil
        }
        let hunks = try require(reviewer.diff?.hunks, "a.txt's changes")
        try expect(reviewer.files[0].added == 2 && reviewer.files[1].status == .added, "\(reviewer.files)")
        step("since sill opened: a.txt (+2 −2, two changes) and c.txt added")
        if let shot = ProcessInfo.processInfo.environment["SILL_CHECK_SHOT"] {
            view.display()
            try self.shot(to: shot)
            step("saved \(shot)")
        }

        view.perform("reject", 1)
        _ = try await waitFor("the change taken back", timeout: .seconds(10)) {
            reviewer.diff?.hunks.count == 1 ? true : nil
        }
        let text = try String(contentsOfFile: root + "/a.txt", encoding: .utf8)
        try expect(text.contains("line three") && text.contains("line 17\n"), "line 17 as it was: \(text)")
        reviewer.keep(hunks[0])
        reviewer.comment(hunks[0], "call it line 3 again, the tests read it")
        try expect(reviewer.reviewText().contains("a.txt:3: call it line 3 again"), reviewer.reviewText())
        reviewer.sendReview()
        try await wait("the agent's pane", timeout: .seconds(10)) { $0.paneRects.contains { $0.kind == "terminal" } }
        try expect(reviewer.sentReviews == 1 && reviewer.comments.isEmpty, "sent and cleared")
        step("Take back restored line 17 in the file; a comment on line 3 went to the agent as a review")

        // A turn: the session here works, the file changes, it stops: a baseline after the turn. Sending the review
        // took one first.
        _ = try await waitFor("the baseline when the review was sent", timeout: .seconds(10)) {
            reviewer.baselines.last?.name == "when sent to an agent" ? true : nil
        }
        let before = reviewer.baselines.count
        reviewer.follow(("working", "fix"))
        try "turn\n".write(toFile: root + "/d.txt", atomically: true, encoding: .utf8)
        reviewer.follow(("idle", "fix"))
        do {
            _ = try await waitFor("the turn's baseline", timeout: .seconds(10)) {
                reviewer.baselines.count > before && reviewer.baselines.last?
                    .name == "after the agent's turn" ? true : nil
            }
        } catch {
            throw CheckFailure(description: "no turn baseline: \(reviewer.baselines.map(\.name)) (\(before) before)")
        }
        step("an agent's turn ending takes a baseline: \(reviewer.baselines.map(\.name).joined(separator: ", "))")
    }

    /// Walkthroughs (`SILL_CHECK=walk`, in a git copy of Tests/SillSidecarTests/Fixtures/Debuggee, SILL_AGENT=echo,
    /// CFFIXED_USER_HOME a scratch folder): a walkthrough's anchors found by Roslyn (one that names nothing reported),
    /// opened at a step through MCP, a question sent to the agent and its answer written back, and the skill installed.
    private func walkSteps() async throws {
        let app = try require(app, "the app")
        let walker = try require(app.walker, "the walker")
        let root = app.workingDirectory
        try await wait("the chrome") { $0.paneRects.contains { $0.kind == "panel" } }
        let program = root + "/Program.cs"
        _ = try await session.channel.lua("require'sill'.open(...)", args: [.string(program)])
        try await wait("Roslyn ready", timeout: .seconds(300)) { $0.languageServers["Roslyn"] == "ready" }
        let path = root + "/tour.walk.md"
        try """
        ---
        title: How the debuggee runs
        for: Debuggee.csproj
        ---
        A short tour.

        ## Pricing
        The total of an order: `seed` times each step.
        @code Pricing.Total
        @ask Why multiply by the seed?

        ## The clock
        @code Clock.Tick lines 1-3

        ## The project
        @code Debuggee.csproj:1
        @code Missing.Thing
        """.write(toFile: path, atomically: true, encoding: .utf8)

        let socket = try await waitFor("sill's MCP server") { app.agents.socketPath }
        let agent = try McpClient(socket)
        defer { agent.close() }
        _ = try await agent.request("initialize", [
            "protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "check", "version": "1"],
        ])
        agent.notify("notifications/initialized")
        // Roslyn may still be loading the project: check until Pricing.Total is found.
        var checked = ""
        for _ in 0 ..< 30 {
            checked = try await agent.call("walkthrough_check", ["path": path])
            if checked.hasPrefix("1 of 4 anchors not found") { break }
            try await Task.sleep(for: .seconds(1))
        }
        try expect(checked.contains("Missing.Thing") && checked.hasPrefix("1 of 4"), "only the missing one: \(checked)")
        step("walkthrough_check finds Pricing.Total, Clock.Tick and Debuggee.csproj, and reports Missing.Thing")

        _ = try await agent.call("walkthrough_open", ["path": path, "step": 1])
        try await wait("the walkthrough pane") { $0.currentPaneKind == "walk" }
        let view = try await waitFor("the walk view") { app.tools.walk }
        let total = try await waitFor("Pricing.Total found", timeout: .seconds(20)) { walker.found[safe: 0]?[1] }
        try expect(
            total.path == program && total.lines.first?.contains("Total(int seed)") == true &&
                total.lines.last?.trimmingCharacters(in: .whitespaces) == "}" && total.by.hasPrefix("roslyn"),
            "Pricing.Total whole, found by Roslyn: \(total)"
        )
        step(
            "walkthrough_open shows step 1: Pricing.Total, lines \(total.from)–\(total.to) of Program.cs, by \(total.by)"
        )
        if let shot = ProcessInfo.processInfo.environment["SILL_CHECK_SHOT"] {
            view.display()
            try self.shot(to: shot)
            step("saved \(shot)")
        }

        // The step's question to the agent, and its answer written back.
        walker.ask(line: 10)
        try await wait("the agent's pane", timeout: .seconds(10)) { $0.paneRects.contains { $0.kind == "terminal" } }
        _ = try await agent.call("walkthrough_answer", [
            "path": path,
            "line": 10,
            "answer": "So each order's total grows with its seed.",
        ])
        _ = try await waitFor("the answer shown", timeout: .seconds(10)) { () -> Bool? in
            guard case let .ask(_, answer, _)? = walker.walk?.steps[0].blocks.last else { return nil }
            return answer == "So each order's total grows with its seed." ? true : nil
        }
        let file = try String(contentsOfFile: path, encoding: .utf8)
        try expect(
            file.contains("@ask Why multiply by the seed?\n> So each order's total grows with its seed."),
            "written under the question: \(file)"
        )
        step("the question went to the agent; walkthrough_answer wrote its answer under it, and the pane shows it")

        walker.go(to: 1)
        let tick = try await waitFor("Clock.Tick") { walker.found[safe: 1]?[0] }
        try expect(tick.lines.count == 3 && tick.lines[0].contains("Tick(int tick)"), "Clock.Tick lines 1-3: \(tick)")
        _ = try await session.channel.lua("vim.cmd('SillWalk skill')")
        let skill = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            ".claude/skills/sill-walkthrough/SKILL.md"
        ).path
        _ = try await waitFor("the skill installed", timeout: .seconds(10)) {
            FileManager.default.fileExists(atPath: skill) ? true : nil
        }
        step("step 2 shows Clock.Tick's first three lines; :SillWalk skill installed the skill at \(skill)")
    }

    /// sill's own nvim (`SILL_CHECK=config`, `SILL_CHECK_CONFIG=1`, in a restored git copy of TraceShop): its colours
    /// in the editor, completion from the language server in the native menu as one types, `:find` fuzzy over git's
    /// files, problems shown under the cursor's line only.
    private func configSteps() async throws {
        let app = try require(app, "the app")
        let root = app.workingDirectory
        try await wait("the chrome") { $0.paneRects.contains { $0.kind == "panel" } }
        let colours = try await session.channel.lua(
            "return vim.g.colors_name .. ' ' .. string.format('#%06X', vim.api.nvim_get_hl(0, { name = 'Normal' }).bg)"
        ).stringValue
        try expect(colours == "sill #121418", "the editor in sill's colours: \(colours ?? "")")
        let found = try await session.channel.lua("return SillFind('pric', false)[1]").stringValue
        try expect(found == "Pricing.cs", "the first match for pric: \(found ?? "nothing")")
        let shown = try await session.channel.lua(
            "local c = vim.diagnostic.config() return tostring(c.virtual_text) .. ' ' .. vim.inspect(c.virtual_lines)"
        ).stringValue ?? ""
        try expect(shown.hasPrefix("false") && shown.contains("current_line = true"), "problems: \(shown)")
        step("sill's colours in the editor; :find fuzzy over git's files (pric: Pricing.cs); problems on the line only")

        _ = try await session.channel.lua("require'sill'.open(...)", args: [.string(root + "/Pricing.cs")])
        try await wait("Roslyn ready", timeout: .seconds(240)) { $0.languageServers["Roslyn"] == "ready" }
        // As one types: the language server's completion, in sill's native menu.
        _ = try await session.channel.lua("vim.api.nvim_win_set_cursor(0, { 5, 0 })")
        var menu: [String] = []
        for _ in 0 ..< 5 where menu.isEmpty {
            _ = await session.channel.request("nvim_input", params: [.string("oTax.")])
            for _ in 0 ..< 40 where menu.isEmpty {
                try await Task.sleep(for: .milliseconds(250))
                menu = latest?.popupMenu?.items.map(\.word) ?? []
            }
            if menu.isEmpty {
                _ = await session.channel.request("nvim_input", params: [.string("<Esc>u")])
                try await Task.sleep(for: .seconds(2))
            }
        }
        try expect(menu.contains("Of"), "Tax. offers Of: \(menu.prefix(8))")
        _ = await session.channel.request("nvim_input", params: [.string("<Esc>u")])
        if let shot = ProcessInfo.processInfo.environment["SILL_CHECK_SHOT"] {
            try await Task.sleep(for: .milliseconds(500))
            try self.shot(to: shot)
        }
        step("typing Tax. offers \(menu.prefix(3).joined(separator: ", ")) in sill's menu, from Roslyn")
    }

    /// A person's own config (`SILL_CHECK=compat`, its XDG_CONFIG_HOME holding an nvim config that opens a start screen
    /// and replaces vim.notify, as LazyVim's plugins do): what sill draws itself is turned off in it.
    private func compatSteps() async throws {
        try await wait("the chrome") { $0.paneRects.contains { $0.kind == "panel" } }
        var state = ""
        for _ in 0 ..< 40 where state != "0 true true true" {
            try await Task.sleep(for: .milliseconds(250))
            state = try await session.channel.lua("""
            local dashboards = 0
            for _, b in ipairs(vim.api.nvim_list_bufs()) do
              if vim.api.nvim_buf_is_valid(b) and vim.bo[b].filetype == 'snacks_dashboard' then dashboards = dashboards + 1 end
            end
            return dashboards .. ' ' .. tostring(vim.notify == package.loaded['sill.base'].notify) .. ' ' ..
              tostring(vim.g.sill) .. ' ' .. tostring(vim.g.user_config_loaded)
            """).stringValue ?? ""
        }
        try expect(
            state == "0 true true true",
            "dashboards, nvim's notify back, vim.g.sill, the user's config loaded: \(state)"
        )
        step("the person's config loaded and told it runs in sill; its start screen gone, messages back with sill")
    }

    /// Agent hooks (`SILL_CHECK=hooks`, in a restored git copy of TraceShop, `SILL_AGENT=echo`): `:SillHooks install`
    /// puts them beside the project's own local settings (kept as they were, never committed); then the installed
    /// command, run as Claude Code runs it, for a prompt in plan mode, the plan presented and approved, an edit and the
    /// turn's end: planning noticed, the plan a notebook with the code it names, baselines for the prompt, the
    /// approved plan and the turn, the edit followed, a log of the session. The agents sill starts get the hooks too;
    /// `:SillHooks remove` takes them out.
    private func hooksSteps() async throws {
        let app = try require(app, "the app")
        let hooks = try require(app.hooks, "the hooks")
        let root = app.workingDirectory
        try await wait("the chrome") { $0.paneRects.contains { $0.kind == "panel" } }
        try FileManager.default.createDirectory(atPath: root + "/.claude", withIntermediateDirectories: true)
        let theirs = #"{"permissions":{"allow":["Bash(ls)"]}}"#
        try theirs.write(toFile: root + "/.claude/settings.local.json", atomically: true, encoding: .utf8)
        _ = try await session.channel.lua("vim.cmd('SillHooks install')")
        _ = try await waitFor("installed") { hooks.installed ? true : nil }
        let settings = try require(
            JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: hooks.localSettings)))
                as? [String: Any], "the settings"
        )
        try expect((settings["permissions"] as? [String: Any]) != nil, "theirs kept: \(settings)")
        try expect(
            (try? String(contentsOfFile: hooks.localSettings + ".before-sill", encoding: .utf8)) == theirs,
            "the file as it was, kept beside it"
        )
        let command = try require(
            ((settings["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])?.first
                .flatMap { ($0["hooks"] as? [[String: Any]])?.first?["command"] as? String },
            "the hook command"
        )
        let status = (Review.git(["status", "--porcelain"], in: root) ?? "?").trimmingCharacters(in: .newlines)
        try expect(status.isEmpty, "git sees none of it: \(status)")
        step(":SillHooks install: sill's hooks beside the project's own settings (kept as they were); git sees none")

        /// The hook as Claude Code runs it, off the main thread (sill answers on it): the event on stdin; what it
        /// prints.
        @discardableResult
        func fire(_ event: [String: Any]) async throws -> String {
            let data = try JSONSerialization.data(withJSONObject: event, options: .prettyPrinted)
            let (status, output) = try await Task.detached { try Self.runHook(command, data) }.value
            try expect(status == 0, "the hook exits 0")
            return output
        }
        let base: [String: Any] = ["session_id": "check-1", "cwd": root]
        func names() -> [String] { app.reviewer?.baselines.map(\.name) ?? [] }
        // A change since sill opened: an unchanged worktree is no new baseline.
        try "notes".write(toFile: root + "/notes.txt", atomically: true, encoding: .utf8)
        try await fire(base.merging([
            "hook_event_name": "UserPromptSubmit",
            "permission_mode": "plan",
            "prompt": "Make the tax round once",
        ]) { $1 })
        _ = try await waitFor("planning noticed") { hooks.planning.contains("check-1") ? true : nil }
        _ = try await waitFor("the prompt's baseline", timeout: .seconds(10)) {
            names().contains("prompt: Make the tax round once") ? true : nil
        }
        step("a prompt in plan mode: planning noticed, a baseline named after the prompt")

        let plan = "# Round the tax once\n\n## Steps\n1. Stop rounding in Tax.cs:5.\n2. Round in Pricing.cs:6."
        // As Claude Code does it (seen in a real session): the plan written to ~/.claude/plans first.
        let plans = NSTemporaryDirectory() + "sill-check-home/.claude/plans"
        try FileManager.default.createDirectory(atPath: plans, withIntermediateDirectories: true)
        try plan.write(toFile: plans + "/round-tax.md", atomically: true, encoding: .utf8)
        try await fire(base.merging([
            "hook_event_name": "PostToolUse", "permission_mode": "plan", "tool_name": "Write",
            "tool_input": ["file_path": plans + "/round-tax.md", "content": plan],
        ]) { $1 })
        let draft = try await waitFor("the draft shown") { hooks.lastPlan }
        _ = try await waitFor("drafting") {
            (try? String(contentsOfFile: draft, encoding: .utf8))?.contains("status: drafting") == true ? true : nil
        }
        // Another file outside the worktree: no one's change here.
        let elsewhere = NSTemporaryDirectory() + "sill-check-elsewhere.txt"
        try "x".write(toFile: elsewhere, atomically: true, encoding: .utf8)
        try await fire(base.merging([
            "hook_event_name": "PostToolUse", "permission_mode": "plan", "tool_name": "Write",
            "tool_input": ["file_path": elsewhere],
        ]) { $1 })
        try await Task.sleep(for: .milliseconds(500))
        try expect(
            app.follower?.touched.keys.contains {
                $0.contains("round-tax") || $0.contains("elsewhere") || $0.contains(".claude/")
            } != true,
            "files outside the worktree are not followed: \(app.follower?.touched.keys.sorted() ?? [])"
        )
        try await fire(base.merging([
            "hook_event_name": "PreToolUse",
            "permission_mode": "plan",
            "tool_name": "ExitPlanMode",
            "tool_input": ["plan": plan],
        ]) { $1 })
        let notebook = try await waitFor("the plan's notebook") {
            (try? String(contentsOfFile: draft, encoding: .utf8))?.contains("status: presented") == true ? hooks
                .lastPlan : nil
        }
        try expect(notebook == draft, "the same notebook, drafted then presented")
        try await wait("the plan shown") { $0.currentPaneKind == "walk" }
        let walk = Walkthrough((try? String(contentsOfFile: notebook, encoding: .utf8)) ?? "")
        try expect(
            notebook.hasPrefix(root + "/.sill/plans/") && walk.title == "Round the tax once" &&
                walk.status == "presented" && walk.steps.map(\.title) == ["Steps", "Code it names"] &&
                walk.steps[1].blocks.map { if case let .code(anchor, _) = $0 { anchor.text } else { "" } } ==
                ["Tax.cs:3-11", "Pricing.cs:4-12"],
            "the plan: \(notebook) \(walk.title) \(walk.steps.map(\.title))"
        )
        if let shot = ProcessInfo.processInfo.environment["SILL_CHECK_SHOT"] {
            _ = try await waitFor("its code found", timeout: .seconds(30)) {
                app.walker?.resolving == false && app.walker?.found.isEmpty == false ? true : nil
            }
            app.tools.walk?.display()
            try self.shot(to: shot)
        }
        try await fire(base.merging([
            "hook_event_name": "PostToolUse",
            "permission_mode": "plan",
            "tool_name": "ExitPlanMode",
            "tool_input": [:],
            "tool_response": ["plan": plan],
        ]) { $1 })
        _ = try await waitFor("approved", timeout: .seconds(10)) {
            names().contains { $0.hasSuffix("plan approved: Round the tax once") } &&
                (try? String(contentsOfFile: notebook, encoding: .utf8))?
                .contains("status: approved") == true ? true : nil
        }
        step(
            "the plan drafted (a Write to ~/.claude/plans, not followed) then presented: one notebook in .sill/plans " +
                "with the code it names, shown; approved: a baseline"
        )

        let pricing = root + "/Pricing.cs"
        try (String(contentsOfFile: pricing, encoding: .utf8)).replacingOccurrences(of: "3.5m", with: "3.6m")
            .write(toFile: pricing, atomically: true, encoding: .utf8)
        try await fire(base.merging([
            "hook_event_name": "PostToolUse",
            "permission_mode": "acceptEdits",
            "tool_name": "Edit",
            "tool_input": ["file_path": pricing],
        ]) { $1 })
        _ = try await waitFor("the edit followed") { app.follower?.touched["Pricing.cs"] != nil ? true : nil }
        try expect(!hooks.planning.contains("check-1"), "planning over")
        try await fire(base.merging(["hook_event_name": "Stop", "permission_mode": "acceptEdits"]) { $1 })
        _ = try await waitFor("the turn's baseline", timeout: .seconds(10)) {
            names().last == "turn ended" ? true : nil
        }
        let log = (try? String(contentsOfFile: root + "/.sill/sessions/check-1.jsonl", encoding: .utf8)) ?? ""
        try expect(log.split(separator: "\n").count == 7 && log.contains("\"tool_name\":\"Edit\""), "the log: \(log)")
        step("an edit: followed as the agent's, planning over; the turn's end: a baseline; seven events in the log")

        // An investigation open: an edit is reminded of and noted, a turn without findings marks it stopped.
        let socket = try await waitFor("sill's MCP server") { app.agents.socketPath }
        let agent = try McpClient(socket)
        defer { agent.close() }
        _ = try await agent.request("initialize", [
            "protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "check", "version": "1"],
        ])
        agent.notify("notifications/initialized")
        _ = try await agent.call("basket_create", ["title": "Why the rounding", "by": "claude"])
        let investigation = try require(app.baskets.investigating, "the investigation open")
        func basket() -> String { (try? String(contentsOfFile: investigation, encoding: .utf8)) ?? "" }
        let edit: [String: Any] = [
            "tool_name": "Edit",
            "permission_mode": "default",
            "tool_input": ["file_path": root + "/Tax.cs"],
        ]
        let before = try await fire(base.merging(edit) { $1 }.merging(["hook_event_name": "PreToolUse"]) { $1 })
        try expect(
            before.contains("additionalContext") && before.contains("read-only") &&
                !before.contains("permissionDecision"),
            "a reminder, not a refusal: \(before)"
        )
        try await fire(base.merging(edit) { $1 }.merging(["hook_event_name": "PostToolUse"]) { $1 })
        _ = try await waitFor("the edit noted", timeout: .seconds(10)) {
            basket().contains("## Edits made while investigating\n`Tax.cs` (Edit)") ? true : nil
        }
        try await fire(base.merging(["hook_event_name": "Stop", "permission_mode": "default"]) { $1 })
        _ = try await waitFor("stopped", timeout: .seconds(10)) { basket().contains("status: stopped") ? true : nil }
        app.baskets.open(investigation)
        try await wait("the basket pane") { $0.currentPaneKind == "basket" }
        let view = try await waitFor("the basket view") { app.tools.basket }
        try view.handleKey(require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3
        ), "f"))
        _ = try await waitFor("the findings asked for") {
            app.agents.lastPrompt?.hasPrefix("Conclude the investigation: Why the rounding") == true ? true : nil
        }
        _ = try await agent.call("basket_conclude", [
            "basket": (investigation as NSString).lastPathComponent,
            "answer": "It rounds once.",
        ])
        _ = try await waitFor("concluded", timeout: .seconds(10)) { basket().contains("status: concluded") ? true : nil
        }
        try expect(app.baskets.investigating == nil, "no investigation open once concluded")
        let after = try await fire(base.merging(edit) { $1 }.merging(["hook_event_name": "PreToolUse"]) { $1 })
        try expect(!after.contains("additionalContext"), "no reminder once concluded: \(after)")
        step("an investigation open: an edit gets a reminder (not a refusal) and is noted; a turn without findings " +
            "marks it stopped, f asks for them; once concluded, neither")

        try expect(
            app.agents.agentCommand(prompt: "x").contains("--settings '\(hooks.settingsPath)'"),
            "the agents sill starts get the hooks"
        )
        try expect(
            FileManager.default.contents(atPath: hooks.settingsPath).map { String(decoding: $0, as: UTF8.self) }?
                .contains(Hooks.marker) == true,
            "in their settings"
        )
        _ = try await session.channel.lua("vim.cmd('SillHooks remove')")
        _ = try await waitFor("removed") { hooks.installed ? nil : true }
        let left = try require(
            JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: hooks.localSettings)))
                as? [String: Any], "the settings"
        )
        try expect(
            NSDictionary(dictionary: left).isEqual(to: ["permissions": ["allow": ["Bash(ls)"]]]),
            "as it was: \(left)"
        )
        step("the agents sill starts get them with --settings; :SillHooks remove leaves the settings as they were")
    }

    /// A hook command run as an agent runs it: `input` on stdin; its status and what it printed.
    private nonisolated static func runHook(_ command: String, _ input: Data) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        stdin.fileHandleForWriting.write(input)
        try stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }

    /// Investigations (`SILL_CHECK=investigate`, in a restored git copy of TraceShop, `SILL_AGENT=echo`, a scratch
    /// home): `:SillInvestigate` asks the agent with the skill's steps; then, as an agent would over MCP, a basket
    /// made,
    /// a symbol, lines and a whole file added in sections, a call tree and a ruled-out note, the basket listed and read
    /// (code and tree as they are now), concluded; the notebook shows it all. `:SillInvestigate skill` installs it.
    private func investigateSteps() async throws {
        let app = try require(app, "the app")
        let root = app.workingDirectory
        let baskets = try require(app.baskets, "the baskets")
        try await wait("the chrome") { $0.paneRects.contains { $0.kind == "panel" } }
        // Roslyn has the project before the trees are asked for.
        let line = "    public static decimal Of(decimal amount) => Math.Round(amount * Rate, 2);"
        let column = line.distance(from: line.startIndex, to: line.range(of: "Of(")!.lowerBound) + 1
        var ready = false
        for _ in 0 ..< 90 where !ready {
            ready = await app.tracer.trace(
                path: root + "/Tax.cs",
                line: 5,
                column: column,
                direction: .incoming,
                show: false
            ) && app.tracer.tree?.nodes[0].children?.isEmpty == false
            if !ready { try await Task.sleep(for: .seconds(1)) }
        }
        try expect(ready, "Roslyn ready: \(app.tracer.problem ?? "")")

        _ = try await session.channel.lua("vim.cmd('SillInvestigate Why does the report total differ from checkout?')")
        let prompt = try await waitFor("the agent asked", timeout: .seconds(10)) { app.agents.lastPrompt }
        try expect(
            prompt.hasPrefix("Investigate: Why does the report total differ from checkout?") &&
                prompt.contains("sill-investigate") && prompt.contains("basket_create") && prompt.contains("read-only"),
            "the prompt: \(prompt.prefix(500))"
        )
        step(":SillInvestigate asks the agent, with the skill's steps")

        let socket = try await waitFor("sill's MCP server") { app.agents.socketPath }
        let agent = try McpClient(socket)
        defer { agent.close() }
        _ = try await agent.request("initialize", [
            "protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "check", "version": "1"],
        ])
        agent.notify("notifications/initialized")
        let made = try await agent.call("basket_create", [
            "title": "Report and checkout totals", "question": "Why does the report total differ?", "by": "claude",
        ])
        try expect(made == "Made report-and-checkout-totals.basket.md; sill shows it.", "basket_create: \(made)")
        let name = "report-and-checkout-totals.basket.md"
        try await wait("the basket pane") { $0.currentPaneKind == "basket" }
        for (arguments, answer) in [
            (["basket": name, "symbol": "Tax.Of", "note": "the tax, rounded", "section": "The tax"], "Added Tax.Of."),
            ([
                "basket": name,
                "path": "Pricing.cs",
                "from": 3,
                "to": 7,
                "note": "where the tax is added",
                "section": "The tax",
            ], "Added Pricing.cs:3-7."),
            (["basket": name, "path": "Report.cs", "section": "Who reaches it"], "Added Report.cs."),

            // From another worktree of the repository: stored from the root, read where sill is open.
            (
                ["basket": name, "path": root + "-feature/Program.cs", "from": 2, "to": 3, "section": "Who reaches it"],
                "Added Program.cs:2-3."
            ),
        ] as [([String: Any], String)] {
            let added = try await agent.call("basket_add", arguments)
            try expect(added.hasPrefix(answer), "basket_add: \(added)")
            // What sill found about it comes with the answer: Report is reached by a test.
            if answer == "Added Report.cs." {
                try expect(
                    added.contains("Tests reaching it: Prints") && added.contains("Context: in TraceShop"),
                    "Report.cs's context: \(added)"
                )
            }
        }
        _ = try await agent.call("basket_note", [
            "basket": name, "text": "@trace Pricing.Total callers 2", "section": "Who reaches it",
        ])
        _ = try await agent.call("basket_note", [
            "basket": name, "text": "Rounding: both round the same way.", "section": "Ruled out",
        ])
        let wrong = try await agent.call("basket_add", ["basket": "nope", "symbol": "Tax.Of"])
        try expect(wrong.hasPrefix("No such basket"), "an unknown basket: \(wrong)")
        step("basket_create, basket_add (a symbol, lines, a whole file, in sections), basket_note (a tree, ruled out)")

        let list = try await agent.call("basket_list")
        try expect(list == "\(name): Report and checkout totals [open, by claude] (current)", "basket_list: \(list)")
        let read = try await agent.call("basket_read", ["basket": name])
        try expect(
            read.hasPrefix("Report and checkout totals (\(name), open)\nQuestion: Why does the report total differ?") &&
                read.contains("## The tax\nthe tax, rounded\nTax.cs:5-5") &&
                read.contains("return net + Tax.Of(net);") && read.contains("Report.cs:1-4") &&
                read.contains("Checkout.Run(int)  Checkout.cs:3") && read.contains("## Ruled out\nRounding"),
            "basket_read: \(read)"
        )
        step("basket_list names it; basket_read gives the code and the call tree as they are now")

        _ = try await agent.call(
            "basket_conclude",
            ["basket": name, "answer": "They do not differ: both add `Tax.Of` once."]
        )
        let walk = try await waitFor("concluded") {
            baskets.walker.walk?.status == "concluded" ? baskets.walker.walk : nil
        }
        try expect(
            walk.steps.map(\.title) == ["The tax", "Who reaches it", "Ruled out", "Findings"],
            "its sections: \(walk.steps.map(\.title))"
        )
        let view = try await waitFor("the basket view") { app.tools.basket }
        _ = try await waitFor("the tree in it", timeout: .seconds(30)) {
            baskets.walker.traces["Pricing.Total callers"]?.contains("Checkout.Run") == true ? true : nil
        }
        view.display()
        let files = Set(view.fileTops.map { ($0.path as NSString).lastPathComponent })
        try expect(files == ["Tax.cs", "Pricing.cs", "Report.cs", "Program.cs"], "its files: \(files)")
        try expect(view.fileTops.allSatisfy { $0.path.hasPrefix(root + "/") }, "read where sill is open")
        let feature = SillFolder.path(for: root + "-feature")
        try expect(feature == root + "/.sill", "the feature worktree's .sill is this one: \(feature)")
        if let shot = ProcessInfo.processInfo.environment["SILL_CHECK_SHOT"] { try self.shot(to: shot) }
        step("basket_conclude: the notebook shows the sections, the tree, the files (one from another worktree, read " +
            "here) and the findings; the feature worktree's .sill is this one")

        _ = try await session.channel.lua("vim.cmd('SillInvestigate skill')")
        let skill = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/skills/sill-investigate/SKILL.md").path
        _ = try await waitFor("the skill installed") { FileManager.default.fileExists(atPath: skill) ? true : nil }
        step(":SillInvestigate skill installs it at \(skill)")
    }

    /// Context baskets (`SILL_CHECK=basket`, in a restored git copy of the TraceShop fixture, `SILL_AGENT=echo`): one
    /// made, lines added (touching lines joining), a whole file, a caller from the trace pane; the notebook with its
    /// files; a piece changed on disk marked; one removed; the basket sent with a question (closed, the next piece in
    /// a new basket), the agent's answer written in by basket_conclude; git sees nothing of it.
    private func basketSteps() async throws {
        let app = try require(app, "the app")
        let root = app.workingDirectory
        let baskets = try require(app.baskets, "the baskets")
        try await wait("the chrome") { $0.paneRects.contains { $0.kind == "panel" } }
        _ = try await session.channel.lua("vim.cmd('SillBasket new Is tax applied twice?')")
        try await wait("the basket pane") { $0.currentPaneKind == "basket" }
        let path = try await waitFor("the basket made") { baskets.current }
        try expect(path == root + "/.sill/baskets/is-tax-applied-twice.basket.md", "made at \(path)")
        step("SillBasket new: .sill/baskets/is-tax-applied-twice.basket.md, current, open")

        func source() -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
        func until(_ what: String, _ test: @escaping () -> Bool) async throws {
            _ = try await waitFor(what, timeout: .seconds(10)) { test() ? true : nil }
        }
        _ = try await session.channel.lua("""
        vim.cmd('tabprevious'); require'sill'.open(...); vim.cmd('3,5SillBasket add the total')
        """, args: [.string(root + "/Pricing.cs")])
        try await until("Pricing.cs:3-5 in it") { source().contains("@code Pricing.cs:3-5 #") }
        // Adding keeps you in the editor.
        try await wait("still in the editor") { $0.currentPaneKind == nil }
        _ = try await session.channel.lua("vim.cmd('6,7SillBasket add')")
        try await until("joined into 3-7") { source().contains("@code Pricing.cs:3-7 #") }
        _ = try await session.channel.lua(
            "require'sill'.open(...); vim.cmd('%SillBasket add')",
            args: [.string(root + "/Tax.cs")]
        )
        try await until("Tax.cs whole") { source().contains("@code Tax.cs\n") || source().hasSuffix("@code Tax.cs") }
        step(":3,5SillBasket add, then :6,7 joining it into Pricing.cs:3-7; :%SillBasket add takes Tax.cs whole")

        // A caller, from the trace pane.
        let tax = root + "/Tax.cs"
        let line = "    public static decimal Of(decimal amount) => Math.Round(amount * Rate, 2);"
        let column = line.distance(from: line.startIndex, to: line.range(of: "Of(")!.lowerBound) + 1
        var traced = false
        for _ in 0 ..< 90 where !traced {
            traced = await app.tracer.trace(path: tax, line: 5, column: column, direction: .incoming, show: false) &&
                app.tracer.tree?.nodes[0].children?.isEmpty == false
            if !traced { try await Task.sleep(for: .seconds(1)) }
        }
        try expect(traced, "a trace of Tax.Of: \(app.tracer.problem ?? "")")
        app.tracer.addToBasket(1)
        try await until("Pricing.Total from the trace") { source().contains("Pricing.Total(int) calls Tax.Of(decimal)")
        }
        try expect(source().components(separatedBy: "@code Pricing.cs:").count == 2, "Pricing.Total's lines joined 3-7")
        step("b in the trace pane adds Pricing.Total with how it calls Tax.Of, joining the lines already there")

        baskets.open(path)
        try await wait("the basket pane") { $0.currentPaneKind == "basket" }
        let view = try await waitFor("the basket view") { app.tools.basket }
        _ = try await waitFor("its code found", timeout: .seconds(30)) {
            baskets.walker.resolving || baskets.walker.found.isEmpty ? nil : true
        }
        view.display()
        let files = Set(view.fileTops.map { ($0.path as NSString).lastPathComponent })
        try expect(files == ["Pricing.cs", "Tax.cs"], "its files: \(files)")
        try expect(baskets.walker.moved.isEmpty, "nothing changed yet: \(baskets.walker.moved)")
        try view.handleKey(require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48
        ), "Tab"))
        try expect(view.side == .files, "Tab shows the files")
        view.display()
        step("the notebook: Pricing.cs and Tax.cs in its files menu (Tab)")

        // What sill collected about the pieces, beside the basket.
        let collected = try await waitFor("Pricing.cs:3-7's context", timeout: .seconds(60)) {
            baskets.context.pieces["Pricing.cs:3-7"].flatMap { $0.symbol != nil && $0.last != nil ? $0 : nil }
        }
        try expect(
            collected.project == "TraceShop" && collected.symbol?.contains("Total") == true &&
                collected.changes == 1 && collected.last?.subject == "base",
            "the context: \(collected)"
        )
        try expect(FileManager.default.fileExists(atPath: BasketContext.file(for: path)), "kept beside the basket")
        try expect(!source().contains("TraceShop"), "the basket itself stays prose: \(source())")
        let chips = baskets.context.chips("Pricing.cs:3-7")
        try expect(chips.first == "TraceShop" && chips.contains { $0.hasPrefix("1 change, last") }, "chips: \(chips)")
        try view.handleKey(require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48
        ), "Tab"))
        try expect(view.side == .context, "Tab again shows the context")
        let projects = view.overview?().first { $0.heading == "Projects" }?.rows ?? []
        try expect(projects.first?.hasPrefix("TraceShop") == true, "the projects: \(projects)")
        _ = try await waitFor("every piece's context", timeout: .seconds(60)) {
            Set(baskets.context.pieces.keys) == ["Pricing.cs:3-7", "Tax.cs"] ? true : nil
        }
        try expect(
            view.overview?().first { $0.heading == "Projects" }?.rows == ["TraceShop  2"],
            "two pieces, no stale ones: \(baskets.context.pieces.keys.sorted())"
        )
        try view.handleKey(require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "i", charactersIgnoringModifiers: "i", isARepeat: false, keyCode: 34
        ), "i"))
        try expect(!view.expanded.isEmpty, "i opens the piece's context")
        view.display()
        if let shot = ProcessInfo.processInfo.environment["SILL_CHECK_SHOT"] { try self.shot(to: shot) }
        step("context collected beside the basket: Pricing.cs:3-7 in TraceShop, \(collected.symbol ?? ""), " +
            "\(collected.changes) change (\"\(collected.last?.subject ?? "")\"); chips, the Context menu, i for details")

        // The code moves on: the piece that shows it is marked.
        let pricing = try String(contentsOfFile: root + "/Pricing.cs", encoding: .utf8)
        try pricing.replacingOccurrences(of: "3.5m", with: "3.75m").write(
            toFile: root + "/Pricing.cs", atomically: true, encoding: .utf8
        )
        await baskets.walker.read()
        try expect(baskets.walker.moved.count == 1, "Pricing.cs:3-7 marked: \(baskets.walker.moved)")
        step("Pricing.cs changed on disk: its piece is marked changed since it was added")

        let removed = try require(baskets.walker.walk?.steps.first?.blocks.compactMap { block -> Int? in
            if case let .code(.file("Tax.cs", nil), at) = block { return at }
            return nil
        }.first, "Tax.cs's anchor")
        view.onRemove?(removed)
        try await until("Tax.cs gone") { !source().contains("@code Tax.cs") }
        step("Remove takes Tax.cs out")

        baskets.send(question: "Is the tax applied twice?")
        let prompt = try await waitFor("the agent asked", timeout: .seconds(20)) { app.agents.lastPrompt }
        try expect(
            prompt.hasPrefix("Is the tax applied twice?") && prompt.contains("is-tax-applied-twice.basket.md") &&
                prompt.contains("Pricing.cs:3-7 (changed since it was added)") && prompt.contains("3.75m") &&
                prompt.contains("the total") && prompt.contains("basket_conclude"),
            "the prompt: \(prompt.prefix(900))"
        )
        try await until("sent") { source().contains("status: sent") }
        try expect(baskets.current == nil, "a sent basket is not current")
        step("send: the question, the notes and the code as it is now (marked changed); the basket sent, closed")

        let socket = try await waitFor("sill's MCP server") { app.agents.socketPath }
        let agent = try McpClient(socket)
        defer { agent.close() }
        _ = try await agent.request("initialize", [
            "protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "check", "version": "1"],
        ])
        agent.notify("notifications/initialized")
        let concluded = try await agent.call("basket_conclude", [
            "basket": "is-tax-applied-twice.basket.md", "answer": "Once: `Pricing.Total` adds `Tax.Of` once.",
        ])
        try expect(concluded.hasPrefix("Written into"), "basket_conclude: \(concluded)")
        try await until("concluded") { source().contains("status: concluded") && source().contains("## Findings") }
        _ = try await session.channel.lua(
            "vim.cmd('tabfirst'); require'sill'.open(...); vim.cmd('1SillBasket add')",
            args: [.string(root + "/Program.cs")]
        )
        let next = try await waitFor("a new basket for the next piece") { baskets.current }
        try expect(next != path && next.contains("/.sill/baskets/collected-"), "the next: \(next)")
        let status = (Review.git(["status", "--porcelain"], in: root) ?? "?").trimmingCharacters(in: .newlines)
        try expect(status == " M Pricing.cs", "git sees only Pricing.cs: \(status)")
        step("basket_conclude writes the findings; the next piece starts a new basket; git sees nothing of .sill")

        // The keys and the Code menu: every key the menu names is set, and the menu's Add to Basket takes a selection.
        let keys = try await session.channel.lua("""
        local out = {}
        for _, key in ipairs(require'sill'.keys) do
          local map = vim.fn.maparg(key[2], key[1], false, true)
          table.insert(out, key[1] .. ' ' .. key[2]:gsub('<leader>', '␣') .. ' ' .. (map.desc == key[4] and 'set' or 'missing'))
        end
        return out
        """).arrayValue?.compactMap(\.stringValue) ?? []
        try expect(keys.count == 12 && keys.allSatisfy { $0.hasSuffix(" set") }, "the keys: \(keys)")
        let codeMenu = try require(
            NSApp.mainMenu?.items.first { $0.submenu?.title == "Code" }?.submenu,
            "the Code menu"
        )
        let hints = codeMenu.items.compactMap(\.toolTip)
        for hint in hints {
            let key = String(hint.split(separator: " ").first ?? "")
            try expect(keys.contains { $0.contains(" \(key) ") }, "\(hint) names a key that is set")
        }
        _ = try await session.channel.lua(
            "require'sill'.open(...); vim.cmd('normal! 3GVj')",
            args: [.string(root + "/Report.cs")]
        )
        let add = try require(codeMenu.items.first { $0.title == "Add to Basket" } as? ClosureItem, "Add to Basket")
        try expect(add.keyEquivalent == "b" && add.keyEquivalentModifierMask == [.command, .shift], "⇧⌘B")
        add.chosen()
        _ = try await waitFor("Report.cs:3-4 in it", timeout: .seconds(10)) {
            ((try? String(contentsOfFile: next, encoding: .utf8)) ?? "").contains("@code Report.cs:3-4 #") ? true : nil
        }
        step(
            "\(keys.count) keys under ␣i, each named in the Code menu (\(hints.count) entries); its Add to Basket (⇧⌘B) " +
                "takes the Visual selection"
        )
    }

    /// Tracing a symbol (`SILL_CHECK=trace`, in a restored copy of the TraceShop fixture, `SILL_AGENT=echo`): Roslyn's
    /// callers of Tax.Of opened a level at a time (Pricing.Total, then Checkout.Run and Report.Print), a row opening
    /// at its call, callees by d, the agent asked to explain a path with its code, and `trace_symbol` by name.
    private func traceSteps() async throws {
        let app = try require(app, "the app")
        let root = app.workingDirectory
        try await wait("the chrome") { $0.paneRects.contains { $0.kind == "panel" } }
        let tax = root + "/Tax.cs"
        let line = "    public static decimal Of(decimal amount) => Math.Round(amount * Rate, 2);"
        let column = line.distance(from: line.startIndex, to: line.range(of: "Of(")!.lowerBound) + 1
        // Roslyn loads the project first: until then there is nothing to trace.
        let started = CACurrentMediaTime()
        var tree: TraceTree?
        for _ in 0 ..< 90 {
            _ = try await session.channel.lua("require'sill'.open(...); vim.cmd('SillTrace')", args: [
                .string(tax), .int(5), .int(Int64(column)),
            ])
            try? await Task.sleep(for: .milliseconds(300))
            for _ in 0 ..< 30 where app.tracer.busy {
                try await Task.sleep(for: .milliseconds(100))
            }
            if let found = app.tracer.tree, found.nodes[0].children?.isEmpty == false {
                tree = found
                break
            }
            try await Task.sleep(for: .seconds(1))
        }
        let first = try require(tree, "a trace of Tax.Of: \(app.tracer.problem ?? "none")")
        try await wait("the trace pane") { $0.currentPaneKind == "trace" }
        func names(_ tree: TraceTree?) -> [String] { tree?.visible.map { tree!.nodes[$0].item.name } ?? [] }
        try expect(names(first) == ["Tax.Of(decimal)", "Pricing.Total(int)"], "callers of Of: \(names(first))")
        step("callers of Tax.Of: Pricing.Total, in \(Bench.format(CACurrentMediaTime() - started)) s from opening")

        let view = try await waitFor("the trace view") { app.tools.trace }
        let total = try require(first.nodes.firstIndex { $0.item.name.hasPrefix("Pricing.Total") }, "Total")
        await app.tracer.open(total)
        let opened = try require(app.tracer.tree, "the tree")
        try expect(
            names(opened) == ["Tax.Of(decimal)", "Pricing.Total(int)", "Checkout.Run(int)", "Report.Print(int)"],
            "a level more: \(names(opened))"
        )
        let run = try require(opened.nodes.firstIndex { $0.item.name.hasPrefix("Checkout.Run") }, "Run")
        try expect(opened.nodes[run].item.at == 5, "Run calls Total at line 5: \(opened.nodes[run].item.at ?? 0)")
        app.tracer.reveal(run)
        var at = ""
        for _ in 0 ..< 50 where at != "Checkout.cs:5" {
            try await Task.sleep(for: .milliseconds(100))
            at = try await session.channel.lua(
                "return vim.fn.expand('%:t') .. ':' .. vim.api.nvim_win_get_cursor(0)[1]"
            ).stringValue ?? ""
        }
        try expect(at == "Checkout.cs:5", "Run opened at \(at), not where it calls")
        step("opening Total gives Checkout.Run (calling at line 5) and Report.Print; Run opens at its call")

        app.tracer.explain(run)
        let prompt = try await waitFor("the agent asked") { app.agents.lastPrompt }
        try expect(
            prompt.hasPrefix("Explain how Checkout.Run(int) reaches Tax.Of(decimal)") &&
                prompt.contains("1. Checkout.Run(int) at Checkout.cs:3") && prompt
                .contains("3. Tax.Of(decimal) at Tax.cs:5") && prompt.contains("return net + Tax.Of(net);"),
            "the prompt: \(prompt.prefix(600))"
        )
        step("e asks the agent to explain Run → Total → Of, each step with its code")

        if let path = ProcessInfo.processInfo.environment["SILL_CHECK_SHOT"] {
            _ = try await session.channel.lua("require'sill'.show_pane('trace')")
            try await wait("the trace pane") { $0.currentPaneKind == "trace" }
            view.display()
            try shot(to: path)
        }

        await app.tracer.turn()
        let callees = names(app.tracer.tree)
        try expect(
            app.tracer.tree?.direction == .outgoing && callees == ["Tax.Of(decimal)", "Tax.Rate"],
            "callees of Of: \(callees)"
        )
        step("d turns it: Of uses Tax.Rate (Roslyn lists what is in source, not Math.Round)")

        let socket = try await waitFor("sill's MCP server") { app.agents.socketPath }
        let agent = try McpClient(socket)
        defer { agent.close() }
        _ = try await agent.request("initialize", [
            "protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "check", "version": "1"],
        ])
        agent.notify("notifications/initialized")
        let text = try await agent.call("trace_symbol", ["symbol": "Tax.Of", "depth": 3])
        try expect(
            text.hasPrefix("Callers of Tax.Of(decimal) (Tax.cs:5):") &&
                text.contains("    Checkout.Run(int)  Checkout.cs:3, calls at line 5") &&
                text.contains("    Report.Print(int)  Report.cs:3"),
            "trace_symbol: \(text)"
        )
        step("trace_symbol Tax.Of, three levels: Total, then Run and Print under it")
    }

    /// The code map (`SILL_CHECK=map`, in a git copy of the MapShop fixture whose Pricing.cs changed in three commits,
    /// with `SILL_AGENT=echo`): the projects in rows (the tests, the web app, the library it references), a hot file
    /// opening on a click, the agent asked for a summary with the map, and the summary it gives back shown on top.
    private func mapSteps() async throws {
        let app = try require(app, "the app")
        try await wait("the chrome") { $0.paneRects.contains { $0.kind == "panel" } }
        _ = try await session.channel.lua("vim.cmd('SillMap')")
        try await wait("the map pane") { $0.currentPaneKind == "map" }
        let map = try await waitFor("the map", timeout: .seconds(10)) { app.mapper.map }
        let rows = map.layers.map { $0.map { map.projects[$0].name } }
        try expect(rows == [["Shop.Web"], ["Shop.Core"], ["Shop.Tests"]], "rows \(rows)")
        let web = try require(map.projects.first { $0.name == "Shop.Web" }, "Shop.Web")
        try expect(web.kind == .web && web.references == ["Shop.Core"], "Shop.Web is \(web.kind), \(web.references)")
        try expect(
            web.entryPoints.first == .init(path: "src/Shop.Web/Program.cs", line: 1, label: "web host"),
            "Shop.Web starts at \(web.entryPoints)"
        )
        let core = try require(map.projects.first { $0.name == "Shop.Core" }, "Shop.Core")
        try expect(
            core.hot.first?.path == "src/Shop.Core/Pricing.cs" && core.hot.first?.changes == 3,
            "hot \(core.hot)"
        )
        step("the map: Shop.Web (a web host at Program.cs:1) above Shop.Core, then Shop.Tests; Pricing.cs changed most")

        let view = try await waitFor("the map view") { app.tools.map }
        view.display()
        let webCard = try require(
            view.cards[map.projects.firstIndex { $0.name == "Shop.Web" }!],
            "Shop.Web's card (bounds \(view.bounds), cards \(view.cards), summary \(app.mapper.summary ?? "none"))"
        )
        let coreCard = try require(view.cards[map.projects.firstIndex { $0.name == "Shop.Core" }!], "Shop.Core's card")
        try expect(webCard.maxY < coreCard.minY, "Shop.Web's card \(webCard) above Shop.Core's \(coreCard)")
        let link = try require(view.links.first { $0.1 == "src/Shop.Core/Pricing.cs" }, "Pricing.cs on the map")
        let point = NSPoint(x: link.0.midX, y: link.0.midY)
        let click = try require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ), "a click")
        view.mouseDown(with: click)
        var name = ""
        for _ in 0 ..< 50 where name != "Pricing.cs" {
            try await Task.sleep(for: .milliseconds(100))
            name = try await session.channel.lua("return vim.fn.expand('%:t')").stringValue ?? ""
        }
        try expect(name == "Pricing.cs", "a click on Pricing.cs left the editor at \(name)")
        step("Shop.Web's card is drawn above Shop.Core's; a click on Pricing.cs opened it")

        app.mapper.askForSummary()
        let prompt = try await waitFor("the agent asked") { app.agents.lastPrompt }
        try expect(
            prompt.hasPrefix("Summarise this codebase") && prompt.contains("- Shop.Web [web, C#]") &&
                prompt.contains("code_map_summary"),
            "the prompt: \(prompt.prefix(300))"
        )
        let socket = try await waitFor("sill's MCP server") { app.agents.socketPath }
        let agent = try McpClient(socket)
        defer { agent.close() }
        _ = try await agent.request("initialize", [
            "protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "check", "version": "1"],
        ])
        agent.notify("notifications/initialized")
        let text = try await agent.call("code_map")
        try expect(text.hasPrefix("Code map of ") && text.contains("references Shop.Core"), "code_map: \(text)")
        let summary = "A tiny shop: `Shop.Web` serves totals that `Shop.Core` prices."
        _ = try await agent.call("code_map_summary", ["summary": summary])
        try expect(app.mapper.summary == summary, "the summary is \(app.mapper.summary ?? "none")")
        try await wait("the map pane again") { $0.currentPaneKind == "map" }
        let kept = app.workingDirectory + "/.sill/map/summary.md"
        try expect((try? String(contentsOfFile: kept, encoding: .utf8)) == summary, "kept in .sill")
        let status = Review.git(["status", "--porcelain"], in: app.workingDirectory) ?? "?"
        try expect(status.isEmpty, "git sees nothing of .sill: \(status)")
        if let path = ProcessInfo.processInfo.environment["SILL_CHECK_SHOT"] {
            view.display()
            try shot(to: path)
        }
        step(
            "s asked the agent with the map; code_map answers it; code_map_summary put the summary on top, kept in .sill"
        )
    }

    /// File references in a terminal (`SILL_CHECK=refs`, in a folder with src/a.txt of twenty lines): what a shell
    /// prints as `src/a.txt:7`, ⌘-clicked, opens in the editor at line 7 and gives the keyboard back to nvim.
    private func referenceSteps() async throws {
        #if SILL_GHOSTTY
            try await wait("the chrome") { $0.paneRects.contains { $0.kind == "panel" } }
            _ = try await session.channel.lua("vim.cmd('SillTerminal')")
            let pane = try await wait("a terminal, current") { screen in
                screen.paneRects.contains { $0.kind == "terminal" && $0.pane == screen.currentPane }
            }.currentPane!
            let surface = try await waitFor("the pane's surface") { self.panes.view(for: pane) as? GhosttySurfaceView }
            panes.focus(pane)
            // The typed line says sill-ref too, but only the output starts with it.
            type("printf '%s %s\\n' sill-ref src/a.txt:7")
            press("\r", keyCode: 36)
            let row = try await waitFor("the shell's output", timeout: .seconds(15)) {
                (surface.visibleText() ?? "").components(separatedBy: "\n").firstIndex { $0.hasPrefix("sill-ref ") }
            }
            let size = surface.cellSize
            let column = "sill-ref src/a".count
            let point = NSPoint(
                x: GhosttyRuntime.padding.x + (CGFloat(column) + 0.5) * size.width,
                y: surface.bounds.height - GhosttyRuntime.padding.y - (CGFloat(row) + 0.5) * size.height
            )
            let (text, clicked) = try require(surface.row(at: point), "the row under the click")
            try expect(text.hasPrefix("sill-ref ") && clicked == column, "read column \(clicked) of \(text)")
            let click = try require(NSEvent.mouseEvent(
                with: .leftMouseDown, location: surface.convert(point, to: nil), modifierFlags: .command,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: 1
            ), "a ⌘-click")
            surface.mouseDown(with: click)
            var at = ""
            for _ in 0 ..< 50 where at != "a.txt:7" {
                try await Task.sleep(for: .milliseconds(100))
                at = try await session.channel.lua(
                    "return vim.fn.expand('%:t') .. ':' .. vim.api.nvim_win_get_cursor(0)[1]"
                ).stringValue ?? ""
            }
            try expect(at == "a.txt:7", "the editor at \(at), not a.txt:7")
            try expect(window.firstResponder === editor, "the keyboard back with nvim")
            step("⌘-click on src/a.txt:7 in the terminal opened a.txt at line 7 in the editor")

            // What another app hands over: a sill:// link with a line and column, and a file.
            let app = try require(app, "the app")
            let root = app.workingDirectory
            try "one\ntwo\n".write(toFile: root + "/b.txt", atomically: true, encoding: .utf8)
            func place() async throws -> String {
                try await session.channel.lua("""
                local at = vim.api.nvim_win_get_cursor(0)
                return vim.fn.expand('%:t') .. ':' .. at[1] .. ':' .. (at[2] + 1)
                """).stringValue ?? ""
            }
            func opened(_ url: String, at expected: String) async throws {
                try app.application(NSApp, open: [require(URL(string: url), url)])
                var at = ""
                for _ in 0 ..< 50 where at != expected {
                    try await Task.sleep(for: .milliseconds(100))
                    at = try await place()
                }
                try expect(at == expected, "\(url) left the editor at \(at), not \(expected)")
            }
            try await opened("sill://open?path=\(root)/src/a.txt&line=12&column=4", at: "a.txt:12:4")
            try await opened(URL(fileURLWithPath: root + "/b.txt").absoluteString, at: "b.txt:1:1")
            step("sill://open?path=…/a.txt&line=12&column=4 opened a.txt at 12:4; a file URL opened b.txt")
        #endif
    }

    /// Following an agent (`SILL_CHECK=follow`, in a git repository with a.txt of twenty lines and b.txt committed and
    /// *.log ignored): changes on disk open in the Follow tab at their first changed line and are marked in the
    /// explorer; the person's own writes, build output and ignored files are not followed.
    private func followSteps() async throws {
        let app = try require(app, "the app")
        let follower = try require(app.follower, "the follower")
        let root = app.workingDirectory
        try await wait("the chrome") { $0.paneRects.contains { $0.kind == "panel" } }
        _ = try await session.channel.lua("vim.cmd('SillFollow')")
        _ = try await waitFor("following") { follower.following ? true : nil }
        func cursor() async throws -> (String, Int) {
            let at = try await session.channel.lua("""
            for _, t in ipairs(vim.api.nvim_list_tabpages()) do
              if vim.t[t].sill_follow then
                local win = vim.api.nvim_tabpage_get_win(t)
                return { vim.fn.fnamemodify(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)), ':t'),
                         vim.api.nvim_win_get_cursor(win)[1] }
              end
            end
            return { '', 0 }
            """)
            let pair = at.arrayValue ?? []
            return (pair.first?.stringValue ?? "", Int(pair.last?.integerValue ?? 0))
        }
        // An agent's first change to a.txt (sill has not read it): its first changed line, from git.
        var lines = (1 ... 20).map { "line \($0)" }
        lines[14] = "line fifteen"
        try (lines.joined(separator: "\n") + "\n").write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        for _ in 0 ..< 50 where try await cursor() != ("a.txt", 15) {
            try await Task.sleep(for: .milliseconds(100))
        }
        try await expect(try cursor() == ("a.txt", 15), try "the Follow tab at a.txt:15: \(cursor())")
        try expect(
            follower.touched.keys.contains("a.txt") && app.tools.sidebar.explorer.touched.contains("a.txt"),
            "a.txt marked in the explorer"
        )
        // Its next change, against what sill saw.
        lines[2] = "line three"
        try (lines.joined(separator: "\n") + "\n").write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        for _ in 0 ..< 50 where try await cursor() != ("a.txt", 3) {
            try await Task.sleep(for: .milliseconds(100))
        }
        try await expect(try cursor() == ("a.txt", 3), try "then at a.txt:3: \(cursor())")
        try expect(app.root.statusBar.state.debug == "following · a.txt:3", "\(app.root.statusBar.state.debug ?? "")")
        step("an agent's changes open in the Follow tab as they land: a.txt:15, then a.txt:3; marked in the explorer")

        // Not followed: the person's own write, build output, an ignored file.
        _ = try await session.channel.lua("""
        vim.cmd('tabnew ' .. vim.fn.fnameescape(...))
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'mine' })
        vim.cmd('silent write')
        """, args: [.string(root + "/b.txt")])
        try FileManager.default.createDirectory(atPath: root + "/obj", withIntermediateDirectories: true)
        try "built\n".write(toFile: root + "/obj/out.txt", atomically: true, encoding: .utf8)
        try "noise\n".write(toFile: root + "/run.log", atomically: true, encoding: .utf8)
        try "seen\n".write(toFile: root + "/c.txt", atomically: true, encoding: .utf8)
        _ = try await waitFor("c.txt followed", timeout: .seconds(5)) { follower.touched["c.txt"] }
        try expect(
            Set(follower.touched.keys) == ["a.txt", "c.txt"],
            "only the agent's: \(follower.touched.keys.sorted())"
        )
        step("not followed: b.txt (written from sill), obj/out.txt and run.log (ignored); c.txt is")
    }

    /// Asking about code (`SILL_CHECK=ask`, in a copy of Tests/SillSidecarTests/Fixtures/Debuggee, SILL_AGENT=echo):
    /// lines and a question to the agent with the code, and its answer through `annotate` under the lines.
    private func askSteps() async throws {
        let app = try require(app, "the app")
        let program = app.workingDirectory + "/Program.cs"
        try await wait("the chrome") { $0.paneRects.contains { $0.kind == "panel" } }
        _ = try await session.channel.lua("require'sill'.open(...)", args: [.string(program), .int(20)])
        try await wait("Program.cs open") { $0.buffer.name == "Program.cs" }
        _ = try await session.channel.lua("vim.cmd('20,25SillAsk Why does Total multiply by the seed?')")
        try await wait("the agent's pane", timeout: .seconds(10)) { $0.paneRects.contains { $0.kind == "terminal" } }
        let prompt = try require(app.agents.lastPrompt, "the prompt")
        try expect(
            prompt.contains("Why does Total multiply by the seed?") && prompt.contains("About Program.cs:20-25") &&
                prompt.contains("20\t    public static double Total(int seed)") && prompt.contains("line 25"),
            "the question with its code: \(prompt)"
        )
        step(":20,25SillAsk sends the question with Program.cs:20-25 to the agent")

        let socket = try await waitFor("sill's MCP server") { app.agents.socketPath }
        let agent = try McpClient(socket)
        defer { agent.close() }
        _ = try await agent.request("initialize", [
            "protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "check", "version": "1"],
        ])
        agent.notify("notifications/initialized")
        _ = try await agent.call("annotate", [
            "path": program,
            "line": 25,
            "text": "So each order's total scales with its seed: a stand-in for real pricing.",
        ])
        let shown = try await session.channel.lua("""
        local buf = vim.fn.bufnr(...)
        return require'sill.ask'.annotations(buf)
        """, args: [.string(program)])
        let first = shown.arrayValue?.first?.arrayValue ?? []
        try expect(
            first.first?.integerValue == 25 && first.last?.stringValue?.contains("scales with its seed") == true,
            "under line 25: \(shown)"
        )
        _ = try await session.channel.lua("require'sill'.open(...)", args: [.string(program), .int(18)])
        if let shot = ProcessInfo.processInfo.environment["SILL_CHECK_SHOT"] {
            try await Task.sleep(for: .milliseconds(400))
            try self.shot(to: shot)
            step("saved \(shot)")
        }
        _ = try await session.channel.lua("vim.cmd('SillAsk clear')")
        let cleared = try await session.channel.lua(
            "return #require'sill.ask'.annotations(vim.fn.bufnr(...))",
            args: [.string(program)]
        )
        try expect(cleared.integerValue == 0, "cleared")
        step("the agent's answer through annotate shows under line 25; :SillAsk clear removes it")
    }

    /// A running program's logs, traces and metrics (`SILL_CHECK=telemetry`, in a built copy of
    /// Tests/SillSidecarTests/Fixtures/Shop): the shop run on its own, watched through MCP, its logs, its slowest
    /// traces and its metrics read back by an agent and shown in the pane.
    private func telemetrySteps() async throws {
        let app = try require(app, "the app")
        let watch = try require(app.telemetry, "the telemetry")
        try await wait("the chrome") { $0.paneRects.contains { $0.kind == "panel" } }
        _ = try await waitFor("the sidecar", timeout: .seconds(20)) { app.sidecar }
        let shop = Process()
        shop.executableURL = try Sidecar.findDotnet()
        shop.arguments = [app.workingDirectory + "/bin/Debug/net10.0/Shop.dll", "http://127.0.0.1:5297"]
        shop.standardOutput = FileHandle.nullDevice
        shop.standardError = FileHandle.nullDevice
        try shop.run()
        // Killed, not asked: ASP.NET's graceful shutdown can outlast the check's exit.
        defer { if shop.isRunning { kill(shop.processIdentifier, SIGKILL) } }
        let pid = shop.processIdentifier
        _ = try await waitFor("its diagnostics socket", timeout: .seconds(20)) {
            Debugger.dotnetProcesses().contains { $0.pid == pid } ? true : nil
        }
        let socket = try await waitFor("sill's MCP server") { app.agents.socketPath }
        let agent = try McpClient(socket)
        defer { agent.close() }
        _ = try await agent.request("initialize", [
            "protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "check", "version": "1"],
        ])
        agent.notify("notifications/initialized")
        let watched = try await agent.call("telemetry_watch", ["pid": Int(pid)])
        try expect(watched.hasPrefix("Watching Shop.dll"), "telemetry_watch: \(watched)")
        try await wait("the telemetry pane") { $0.currentPaneKind == "telemetry" }
        // A few seconds of orders: every seventh is slow, every fifth warns.
        _ = try await waitFor("orders priced", timeout: .seconds(30)) {
            watch.store.traces.contains { $0.durationMs > 100 } && watch.store.logs
                .contains { $0.level == 3 } ? true : nil
        }
        let warnings = try await agent.call("telemetry_logs", ["level": "warning"])
        try expect(warnings.contains("warning") && warnings.contains("is slow to price"), "the warnings: \(warnings)")
        // Spans come in batches, and a request already under way when the watch began has no client span (its
        // activity was made before anyone listened): a complete slow trace among the slowest five.
        var traces = ""
        for _ in 0 ..< 20 {
            let five = try await agent.call("telemetry_traces", ["slowest": 5])
            if let whole = five.components(separatedBy: "\n\n").first(where: {
                $0.contains("price order") && $0.contains("order.id") && $0.contains("\n  GET")
            }) {
                traces = whole
                break
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        try expect(
            traces.contains("price order") && traces.contains("order.id") && traces.contains("GET"),
            "the slowest trace with its spans: \(traces)"
        )
        let metrics = try await agent.call("telemetry_metrics", ["name": "shop.orders"])
        try expect(metrics.hasPrefix("shop.orders: "), "the shop's counter: \(metrics)")
        let duration = try await agent.call("telemetry_metrics", ["name": "http.server.request.duration"])
        try expect(
            duration.contains("http.server.request.duration") && duration.contains("p50"),
            "ASP.NET's histogram: \(duration)"
        )
        step("an agent watched the shop (pid \(pid)) through MCP: its warnings, its slowest trace " +
            "(\(traces.split(separator: "\n").first ?? "")) and its metrics (\(metrics.split(separator: "\n").first ?? ""))")
        if let shot = ProcessInfo.processInfo.environment["SILL_CHECK_SHOT"], let view = app.tools.telemetry {
            for tab in [TelemetryView.Tab.logs, .traces, .metrics] {
                view.select(tab: tab)
                view.display()
                let path = (shot as NSString).deletingPathExtension + "-\(tab.rawValue.lowercased()).png"
                try self.shot(to: path)
                step("saved \(path)")
            }
        }
        _ = try await session.channel.lua("vim.cmd('SillTelemetry stop')")
        _ = try await waitFor("stopped", timeout: .seconds(10)) { watch.run == nil ? true : nil }
        step(":SillTelemetry stop ends it; the shop goes on running: \(shop.isRunning)")
    }

    /// A review walkthrough (`SILL_CHECK=reviewwalk`, in a git copy of Tests/SillSidecarTests/Fixtures/Orders,
    /// SILL_AGENT=echo): the agent's change reviewed, a walkthrough of it asked for (a throwaway inside .git), written
    /// as the agent would (a diff, a symbol, a .NET 10 script using the changed library), checked through MCP (its
    /// example run), and read as a notebook: one scroll, an outline, the example run in place.
    private func reviewWalkSteps() async throws {
        let app = try require(app, "the app")
        let reviewer = try require(app.reviewer, "the reviewer")
        let walker = try require(app.walker, "the walker")
        let root = app.workingDirectory
        try await wait("the chrome") { $0.paneRects.contains { $0.kind == "panel" } }
        _ = try await waitFor("the baseline", timeout: .seconds(10)) { reviewer.baselines.first }
        // The agent's change.
        try """
        namespace Orders;

        /// <summary>An order's price.</summary>
        public static class Pricing
        {
            public static double Total(int seed) => seed * 3.5;

            public static double Discounted(int seed, double off) => Total(seed) * (1 - off);
        }
        """.write(toFile: root + "/Pricing.cs", atomically: true, encoding: .utf8)
        _ = try await session.channel.lua("vim.cmd('SillReview')")
        _ = try await waitFor("the change", timeout: .seconds(10)) {
            reviewer.files.map(\.path) == ["Pricing.cs"] ? true : nil
        }
        reviewer.askForWalkthrough()
        let path = try await waitFor("the walkthrough asked for", timeout: .seconds(10)) { reviewer.walkthroughAsked }
        try await wait("the agent's pane", timeout: .seconds(10)) { $0.paneRects.contains { $0.kind == "terminal" } }
        let prompt = try require(app.agents.lastPrompt, "the prompt")
        let base = try require(reviewer.baselines.first?.tree, "the base")
        try expect(
            path.contains("/.sill/reviews/") && prompt.contains("git diff \(base) ") &&
                prompt.contains(path) && prompt.contains("M Pricing.cs") && prompt.contains("#:project") &&
                prompt.contains("absolute paths in \(root)"),
            "asked with the diff, the place and the examples: \(prompt.prefix(400))"
        )
        step("Walkthrough asks the agent for one: the diff since \(reviewer.baselines.first?.name ?? ""), to " +
            "\(path.replacingOccurrences(of: root + "/", with: ""))")

        // The agent writes it, as the skill says.
        let folder = (path as NSString).deletingLastPathComponent
        try """
        #:project \(root)/Orders.csproj
        using Orders;
        Console.WriteLine($"Total(4) = {Pricing.Total(4)}");
        Console.WriteLine($"Discounted(4, 10%) = {Pricing.Discounted(4, 0.1)}");
        """.write(toFile: folder + "/examples/discount.cs", atomically: true, encoding: .utf8)
        try """
        ---
        title: Review: pricing scales by 3.5 and gains a discount
        base: \(base)
        ---
        Two changes to `Pricing`: the rate, and a discount on top of it.

        ## The rate is 3.5 now
        Every total grows by 75%: check the callers expect it.
        @diff Pricing.cs
        @code Pricing.Total

        ## A discount on the total
        `Discounted` takes a fraction off the total.
        @example examples/discount.cs
        @ask Should a discount over 1 be refused?
        """.write(toFile: path, atomically: true, encoding: .utf8)
        let socket = try await waitFor("sill's MCP server") { app.agents.socketPath }
        let agent = try McpClient(socket)
        defer { agent.close() }
        _ = try await agent.request("initialize", [
            "protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "check", "version": "1"],
        ])
        agent.notify("notifications/initialized")
        let checked = try await agent.call("walkthrough_check", ["path": path])
        try expect(checked == "2 steps, 1 anchors all found, 1 examples all ran.", "walkthrough_check: \(checked)")
        _ = try await agent.call("walkthrough_open", ["path": path])
        try await wait("the walkthrough pane") { $0.currentPaneKind == "walk" }
        let view = try await waitFor("the walk view") { app.tools.walk }
        let example = folder + "/examples/discount.cs"
        let run = try await waitFor("the example's run") { walker.runs[example].flatMap { $0.running ? nil : $0 } }
        try expect(
            run.status == 0 && run.output.contains("Total(4) = 14") && run.output.contains("Discounted(4, 10%) = 12.6"),
            "the example ran: \(run.output)"
        )
        let diff = try require(walker.diffs["Pricing.cs"], "Pricing.cs's change")
        try expect(
            diff.hunks.first?.lines
                .contains { $0.contains("+    public static double Total(int seed) => seed * 3.5;") } == true,
            "the diff: \(diff.hunks.first?.lines ?? [])"
        )
        step("walkthrough_check: \(checked) (Total(4) = 14, Discounted(4, 10%) = 12.6); walkthrough_open shows it")

        view.display()
        try expect(view.sectionTops.count == 2 && view.currentSection == 0, "two sections, the first in view")
        if let shot = ProcessInfo.processInfo.environment["SILL_CHECK_SHOT"] {
            try self.shot(to: shot)
            step("saved \(shot)")
        }
        view.show(section: 1)
        view.display()
        try expect(view.scroll > 0 && view.currentSection == 1, "the outline scrolls to the second: \(view.scroll)")
        if let shot = ProcessInfo.processInfo.environment["SILL_CHECK_SHOT"] {
            let second = (shot as NSString).deletingPathExtension + "-example.png"
            try self.shot(to: second)
            step("saved \(second)")
        }
        step("a notebook: one scroll with the diff, the code and the example's output; the outline goes to a section")
    }

    private func m8Steps() async throws {
        let app = try require(app, "the app")
        let debugger = try require(app.debugger, "the debugger")
        let program = (app.workingDirectory as NSString).appendingPathComponent("Program.cs")
        try await wait("the chrome") { $0.paneRects.contains { $0.kind == "panel" } }
        _ = try await waitFor("the sidecar", timeout: .seconds(20)) { app.sidecar }
        _ = try await session.channel.lua("require'sill'.open(...)", args: [.string(program), .int(5)])
        try await wait("Program.cs open") { $0.buffer.name == "Program.cs" }
        _ = try await session.channel.lua("vim.cmd('SillBreakpoint')")
        try await wait("the breakpoint") { $0.breakpoints[program]?.map(\.line) == [5] }
        step("F9's command sets a breakpoint on line 5, a sign that moves with the text")

        let started = CACurrentMediaTime()
        session.channel.send(keys: "<F5>")
        _ = try await waitFor("the program paused", timeout: .seconds(180)) {
            if case .paused = debugger.state { return true }
            return nil
        }
        let frame = try require(debugger.frames.first, "a frame")
        try expect(
            frame.line == 5 && frame.source?.path?.hasSuffix("Program.cs") == true,
            "paused at Program.cs:5: \(frame.name) \(frame.line)"
        )
        func locals() -> [String: String] {
            Dictionary(
                (debugger.scopeReference.flatMap { debugger.variables[$0] } ?? []).map { ($0.name, $0.value) },
                uniquingKeysWith: { first, _ in first }
            )
        }
        _ = try await waitFor("the locals") { locals()["i"] }
        try expect(locals()["i"] == "0", "i is 0: \(locals())")
        let marked = try await session.channel.lua("return require'sill.debug'.where()")
        try expect(marked.arrayValue?.last?.intValue == 5, "line 5 marked in the editor: \(marked)")
        try expect(app.tools.panel.tab == .debug, "the Debug tab shows")
        try expect(
            app.root.statusBar.state.debug == "paused at Program.cs:5",
            "\(app.root.statusBar.state.debug ?? "")"
        )
        step("F5 builds and launches it under the debugger, paused at the breakpoint in " +
            "\(Bench.format(CACurrentMediaTime() - started)) s: line 5 marked, \(frame.name), i = 0")
        if let shot = ProcessInfo.processInfo.environment["SILL_CHECK_SHOT"] {
            try await Task.sleep(for: .milliseconds(300))
            try self.shot(to: shot)
            step("saved \(shot)")
        }

        session.channel.send(keys: "<F10>")
        _ = try await waitFor("the step", timeout: .seconds(30)) {
            debugger.state == .paused(reason: "step") ? true : nil
        }
        step("F10 steps")
        session.channel.send(keys: "<F5>")
        _ = try await waitFor("the next hit", timeout: .seconds(30)) {
            debugger.state == .paused(reason: "breakpoint") && locals()["i"] == "2000" ? true : nil
        }
        step("F5 runs to the breakpoint's next hit: i = 2000")

        _ = try await session.channel.lua("vim.cmd('SillBreakpoint')")
        _ = try await waitFor("the adapter told", timeout: .seconds(10)) {
            debugger.answered[program]?.isEmpty == true ? true : nil
        }
        step("removed while paused, the breakpoint is removed in the program")

        session.channel.send(keys: "<S-F5>")
        _ = try await waitFor("the session over", timeout: .seconds(20)) { debugger.state == .idle ? true : nil }
        let after = try await session.channel.lua("return require'sill.debug'.where()")
        try expect(after == .nil, "no line marked: \(after)")
        step("Shift-F5 ends it: no line marked")
    }

    /// M7's language servers (`SILL_CHECK=servers`, run in a copy of Tests/SillCoreTests/Fixtures/Polyglot): each kind
    /// of file opened gets its server, found or provisioned by sill, and the server answers for it: the file's symbols,
    /// and TypeScript's error.
    private func serversSteps() async throws {
        let app = try require(app, "the app")
        let root = app.workingDirectory
        try await wait("the chrome") { $0.paneRects.contains { $0.kind == "panel" } }
        let files: [(path: String, server: String, symbol: String)] = [
            ("src/main.rs", "rust_analyzer", "total"), ("swift/Sources/poly/main.swift", "sourcekit", "total"),
            ("docs/README.md", "marksman", "Totals"), ("web/index.html", "html", "main"),
            ("web/site.css", "cssls", ".totals"), ("web/data.json", "jsonls", "totals"),
            ("web/app.ts", "typescript", "total"), ("fsharp/Pricing.fs", "fsautocomplete", "total"),
        ]
        for file in files {
            let started = CACurrentMediaTime()
            let path = (root as NSString).appendingPathComponent(file.path)
            _ = try await session.channel.lua("require'sill'.open(...)", args: [.string(path)])
            try await wait("\(file.path) open") { $0.buffer.path == path }
            let client = "sill_" + file.server
            // Found or provisioned (the first time, downloaded or installed with npm).
            let resolved = try await waitFor("\(file.server) found", timeout: .seconds(300)) {
                app.servers.resolved[file.server]
            }
            if case let .failure(why) = resolved { throw CheckFailure(description: "no \(file.server): \(why)") }
            var symbols: [String] = []
            for _ in 0 ..< 60 {
                let answer = try await session.channel.lua("""
                local names = {}
                local function walk(list)
                  for _, s in ipairs(list or {}) do
                    table.insert(names, s.name)
                    walk(s.children)
                  end
                end
                if #vim.lsp.get_clients({ bufnr = 0, name = ... }) == 0 then return names end
                local result = vim.lsp.buf_request_sync(0, 'textDocument/documentSymbol',
                  { textDocument = vim.lsp.util.make_text_document_params(0) }, 5000)
                for _, r in pairs(result or {}) do walk(r.result) end
                return names
                """, args: [.string(client)])
                symbols = (answer.arrayValue ?? []).compactMap(\.stringValue)
                if symbols.contains(where: { $0.contains(file.symbol) }) { break }
                try await Task.sleep(for: .milliseconds(500))
            }
            try expect(
                symbols.contains { $0.contains(file.symbol) },
                "\(client) lists \(file.symbol) in \(file.path): \(symbols.prefix(8))"
            )
            step("\(file.path): \(LanguageServers.label(file.server)) answers with its symbols (\(file.symbol)) in " +
                "\(Bench.format(CACurrentMediaTime() - started)) s")
        }
        // TypeScript's error, from its own server.
        let error = try await wait("TypeScript's error", timeout: .seconds(60)) { screen in
            screen.diagnostics.contains { $0.path.hasSuffix("web/app.ts") && $0.severity == 1 }
        }.diagnostics.first { $0.path.hasSuffix("web/app.ts") && $0.severity == 1 }
        try expect(error?.line == 5, "on line 5: \(error.map { "\($0.line) \($0.message)" } ?? "")")
        step("TypeScript reports the string assigned to a number, on line 5")
        // F#'s, from fsautocomplete once it has loaded the project.
        let fsharp = try await wait("F#'s error", timeout: .seconds(120)) { screen in
            screen.diagnostics.contains { $0.path.hasSuffix("fsharp/Pricing.fs") && $0.severity == 1 }
        }.diagnostics.first { $0.path.hasSuffix("fsharp/Pricing.fs") && $0.severity == 1 }
        try expect(fsharp?.line == 5, "on line 5: \(fsharp.map { "\($0.line) \($0.message)" } ?? "")")
        step("F# reports the string given where an int is wanted, on line 5")
    }

    /// M7's exit (`SILL_CHECK=m7`, run in a copy of Tests/SillCoreTests/Fixtures/RustSample or SwiftSample): a native
    /// program profiled, samply for Rust and xctrace for Swift, viewable as the .NET one is: its hot frame the sample's
    /// hot loop, with its source line. `SILL_CHECK_SHOT` saves the CPU view.
    private func m7Steps() async throws {
        let app = try require(app, "the app")
        let kind = try require(NativeRecorder.kind(in: app.workingDirectory), "a Cargo or Swift package")
        try await wait("the chrome") { $0.paneRects.contains { $0.kind == "panel" } }
        _ = try await session.channel.lua("vim.cmd('SillProfile')")
        try await wait("the profile pane") { $0.currentPaneKind == "profile" }
        let view = try await waitFor("the profiler") { app.tools.profile.flatMap { $0.isHidden ? nil : $0 } }
        let started = CACurrentMediaTime()
        // Under the runner's own timeout, so a stall says where (the build, or the recorder starting).
        _ = try await waitFor("the program to run (\(view.subtitle))", timeout: .seconds(300)) {
            view.isRecording ? true : nil
        }
        try expect(!view.canSnapshot, "no heap snapshots for a native program")
        step("\(kind.engine): built in release with line tables and running in " +
            "\(Bench.format(CACurrentMediaTime() - started)) s")
        try await Task.sleep(for: .seconds(kind == .swift ? 6 : 3))
        _ = try await session.channel.lua("vim.cmd('SillProfile stop')")
        let document = try await waitFor("the CPU profile", timeout: .seconds(120)) { view.document }
        try expect(document.samples > 500, "\(document.samples) samples")
        let hot = try require(view.selected, "a hot frame selected")
        let name = view.name(hot)
        try expect(name.contains(kind == .rust ? "pricing::total" : "Pricing.total"), "the hot loop: \(name)")
        let source = try require(view.source(of: name), "its source")
        try expect(source.file.hasSuffix(kind == .rust ? "main.rs" : "main.swift"), "in the sample: \(source.file)")
        view.select(tab: .flameGraph)
        view.display()
        try expect(view.blocksDrawn > 3, "\(view.blocksDrawn) blocks")
        try expect(view.cpuPayload(hot).contains("runtime: \(kind.rawValue)"), "the payload names the runtime")
        // CPU over time, from the samples' own times: a stretch rebuilt here, not asked of anyone.
        try expect(document.timeline?.reduce(0, +) == document.samples, "every sample on the strip")
        view.pick(from: 0, to: 0.5)
        let half = try await waitFor("the first half", timeout: .seconds(30)) {
            view.stretch != nil ? view.document : nil
        }
        try expect(half.samples > 0 && half.samples < document.samples, "the first half: \(half.samples)")
        view.display()
        if let shot = ProcessInfo.processInfo.environment["SILL_CHECK_SHOT"] {
            try self.shot(to: shot)
            step("saved \(shot)")
        }
        step("stopped: \(document.samples) samples; the hot frame \(name) at " +
            "\((source.file as NSString).lastPathComponent):\(source.line), in the flame graph; the first half of " +
            "the run alone is \(half.samples) samples")
    }

    /// The explorer and the .slnx (`SILL_CHECK=solution`, run in a copy of Tests/SillCoreTests/Fixtures/Solution): the
    /// solution's tree and how it differs from the disk (also in Problems); the files, nested as Visual Studio nests
    /// them, with a project's kind and the files it removes; a nested file revealed; `:SillSlnx sync` as a diff and
    /// `apply` writing it. `SILL_CHECK_SHOT` saves the solution's tree; with `-files`, the files.
    private func solutionSteps() async throws {
        let app = try require(app, "the app")
        let explorer = try require(app.tools?.sidebar.explorer, "the explorer")
        let environment = ProcessInfo.processInfo.environment
        let root = app.workingDirectory
        let slnx = root + "/Shop.slnx"
        try await wait("the chrome") { $0.paneRects.contains { $0.kind == "panel" } }
        let drift = try await waitFor("the solution read", timeout: .seconds(10)) { explorer.solution?.drift }
        try expect(explorer.mode == .solution, "a folder with a .slnx opens on the solution")
        try expect(drift.count == 3, "three differences: \(drift.map(\.message))")
        let problems = try await wait("the drift in Problems", timeout: .seconds(10)) { screen in
            screen.diagnostics.count(where: { $0.code == "slnx" }) == 3
        }.diagnostics.filter { $0.code == "slnx" }
        try expect(problems.allSatisfy { $0.path == slnx }, "on the .slnx")
        try expect(problems.contains { $0.message.contains("README.MD is README.md on disk") }, "the case")
        step("the solution's tree; three differences from the disk, on the .slnx in Problems: " +
            drift.map(\.message).joined(separator: "; "))

        // The tree: /src/ holds Web; Cli, misplaced in /src/, is there too, a project marked by its kind.
        func row(_ name: String) -> ExplorerView.Row? { explorer.rows.first { $0.name == name } }
        _ = try explorer.handleKey(key("l", on: explorer, selecting: "src"))
        let web = try await waitFor("Web in /src/") { row("Web") }
        try expect(web.project?.kind == .web, "Web is a web project")
        try expect(row("Cli")?.project?.kind == .app, "Cli is an app")
        if let shot = environment["SILL_CHECK_SHOT"] {
            _ = try explorer.handleKey(key("l", on: explorer, selecting: "Web"))
            _ = try await waitFor("Web open") { row("Components") }
            try await Task.sleep(for: .milliseconds(200))
            try self.shot(to: shot)
            step("saved \(shot)")
        }
        step("solution folders, projects marked by kind (web, app)")

        // The files: nesting, and what a project removes.
        explorer.show(.files)
        let counter = root + "/src/Web/Components/Pages/Counter.razor.cs"
        _ = try await session.channel.lua("require'sill'.open(...)", args: [.string(counter)])
        try await wait("Counter.razor.cs open") { $0.buffer.name == "Counter.razor.cs" }
        let nested = try await waitFor("Counter.razor.cs revealed under Counter.razor", timeout: .seconds(5)) {
            explorer.rows.first { $0.name == "Counter.razor.cs" }
        }
        let parent = try require(row("Counter.razor"), "Counter.razor")
        try expect(parent.nested == 2 && nested.depth == parent.depth + 1, "nested under it, with the .css")
        try expect(explorer.rows[explorer.selected].name == "Counter.razor.cs", "and selected")
        try expect(
            row("appsettings.json")?.nested == 1 && row("appsettings.Development.json") == nil,
            "appsettings.Development.json nested, closed"
        )
        _ = try explorer.handleKey(key("l", on: explorer, selecting: "Legacy"))
        let old = try await waitFor("Legacy open") { row("Old.cs") }
        try expect(old.excluded, "Old.cs is removed from Web's items, so dimmed")
        try expect(row("Web")?.project?.kind == .web, "the project's folder marked in the files too")
        if let shot = environment["SILL_CHECK_SHOT"] {
            try await Task.sleep(for: .milliseconds(200))
            let files = (shot as NSString).deletingPathExtension + "-files.png"
            try self.shot(to: files)
            step("saved \(files)")
        }
        step("files nested as Visual Studio nests them, revealed when open; what Web removes dimmed")

        // :SillSlnx sync shows it rewritten, apply writes it.
        let before = try String(contentsOfFile: slnx, encoding: .utf8)
        _ = try await session.channel.lua("vim.cmd('SillSlnx sync')")
        let proposal = try await waitFor("the proposal", timeout: .seconds(10)) { app.solutions.lastProposal }
        try await wait("the diff", timeout: .seconds(10)) { $0.tabs.count > 1 }
        let proposed = try String(contentsOfFile: proposal, encoding: .utf8)
        try expect(try String(contentsOfFile: slnx, encoding: .utf8) == before, "sync writes nothing")
        try expect(try proposed == Slnx(text: before).synced(in: root).text, "the proposal is the synced solution")
        _ = try await session.channel.lua("vim.cmd('tabclose')")
        _ = try await session.channel.lua("vim.cmd('SillSlnx apply')")
        _ = try await waitFor("the .slnx written", timeout: .seconds(10)) {
            (try? String(contentsOfFile: slnx, encoding: .utf8)) == proposed ? true : nil
        }
        _ = try await waitFor("no drift left", timeout: .seconds(10)) {
            explorer.solution?.drift.isEmpty == true ? true : nil
        }
        try await wait("Problems clear of it", timeout: .seconds(10)) { screen in
            !screen.diagnostics.contains { $0.code == "slnx" }
        }
        try expect(proposed.contains("<Folder Name=\"/src/tooling/\">"), "Cli in /src/tooling/")
        try expect(proposed.contains("<File Path=\"README.md\" />"), "README.md in the disk's case")
        step(":SillSlnx sync shows the rewrite as a diff and writes nothing; apply writes it, and the drift is gone")
    }

    /// A key for the explorer, with `name`'s row selected first.
    private func key(_ key: String, on explorer: ExplorerView, selecting name: String) throws -> NSEvent {
        if let index = explorer.rows.firstIndex(where: { $0.name == name }) { explorer.select(index) }
        return try require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0
        ), "a key")
    }

    /// A real project (`SILL_CHECK=project`, `SILL_CWD` its folder; docs-builder is the one it was written against):
    /// how
    /// long each step takes there, and whether the UI ever waits. The main thread is watched throughout (a block
    /// scheduled every 10 ms, how late it ran) and nvim is asked a round trip every 100 ms; each phase reports its
    /// worst, and the check fails on a main-thread stall over `SILL_CHECK_STALL_MS` (100 by default).
    private func projectSteps() async throws {
        let app = try require(app, "the app")
        let tools = try require(app.tools, "the tools")
        let limit = Double(ProcessInfo.processInfo.environment["SILL_CHECK_STALL_MS"] ?? "") ?? 100
        // A person watching has sill in front, where App Nap never applies; the check's window is behind others or off
        // screen, where macOS naps it and its run loop waits seconds through a build. So the check holds App Nap
        // off, as being in front does; SILL_CHECK_NAP=1 lets it nap.
        let activity = ProcessInfo.processInfo.environment["SILL_CHECK_NAP"] != "1"
            ? ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "check") : nil
        defer { activity.map(ProcessInfo.processInfo.endActivity) }
        let watch = MainThreadWatch()
        watch.start()
        defer { watch.stop() }
        // nvim's round trips, by phase.
        let pings = PingLog()
        let pinging = Task { [session] in
            while !Task.isCancelled {
                let sent = CACurrentMediaTime()
                _ = try? await session.channel.lua("return 1")
                pings.add(watch.current, (CACurrentMediaTime() - sent) * 1000)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { pinging.cancel() }
        var rows: [(String, Double)] = []
        func phase<T>(_ name: String, _ body: () async throws -> T) async throws -> T {
            watch.enter(name)
            let started = CACurrentMediaTime()
            let result = try await body()
            rows.append((name, CACurrentMediaTime() - started))
            return result
        }

        try await phase("launch") {
            try await wait("the chrome", timeout: .seconds(20)) { $0.paneRects.contains { $0.kind == "panel" } }
        }
        try await phase("explorer") {
            tools.sidebar.show(.explorer)
            _ = try await waitFor("git's status in the explorer", timeout: .seconds(30)) {
                tools.sidebar.explorer.gitRead ? true : nil
            }
        }
        var filtered = 0
        try await phase("explorer filter") {
            // Typing a filter over the whole tree, as a person would: "/" then "Changelog".
            for key in ["/"] + "Changelog".map(String.init) {
                _ = try tools.sidebar.explorer.handleKey(require(NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                    characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0
                ), "a key"))
                try await Task.sleep(for: .milliseconds(30))
            }
            // Read off the main thread, the matches come a moment after the keys.
            let matches = try await waitFor("the filter's matches", timeout: .seconds(10)) {
                let files = tools.sidebar.explorer.rows.filter { !$0.isDirectory && $0.name.contains("Changelog") }
                return files.isEmpty ? nil : files.count
            }
            filtered = matches
            _ = try tools.sidebar.explorer.handleKey(require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53
            ), "escape"))
        }
        // SILL_CHECK_SAMPLE: sample(1) the app from here until the file is open, to say what a stall there is. Its
        // attaching pauses the app: that lands in this phase, not the open.
        if let out = ProcessInfo.processInfo.environment["SILL_CHECK_SAMPLE"] {
            let sample = Process()
            sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            sample.arguments = ["\(ProcessInfo.processInfo.processIdentifier)", "5", "1", "-file", out]
            sample.standardOutput = FileHandle.nullDevice
            sample.standardError = FileHandle.nullDevice
            try sample.run()
        }
        try await phase("source control") {
            tools.sidebar.show(.sourceControl)
            tools.sidebar.sourceControl.refresh()
            try await Task.sleep(for: .seconds(1))
            tools.sidebar.show(.explorer)
        }
        // The largest C# file under src: a real one to open, edit nothing. Looked for off the main thread, which is
        // the check's own work, not sill's.
        let source = app.workingDirectory + "/src"
        let file = try await require(Task.detached {
            (FileManager.default.enumerator(atPath: source)?.compactMap { $0 as? String } ?? [])
                .filter { $0.hasSuffix(".cs") && !$0.contains("/obj/") && !$0.contains("/bin/") }
                .map { source + "/" + $0 }
                .max { Self.size($0) < Self.size($1) }
        }.value, "a C# file under src")
        try await phase("open \((file as NSString).lastPathComponent)") {
            _ = try await session.channel.lua("require'sill'.open(...)", args: [.string(file)])
            try await wait("the file open", timeout: .seconds(10)) { $0.buffer.path == file }
        }
        try await phase("Roslyn loads the solution") {
            try await wait("Roslyn ready", timeout: .seconds(600)) { $0.languageServers["Roslyn"] == "ready" }
        }
        let completion = try await phase("completion") {
            try await session.channel.lua("""
            local l = vim.fn.search('\\\\<return\\\\>', 'nw')
            if l == 0 then l = 1 end
            local result = vim.lsp.buf_request_sync(0, 'textDocument/completion', {
              textDocument = { uri = vim.uri_from_bufnr(0) }, position = { line = l - 1, character = 8 },
              context = { triggerKind = 1 } }, 30000)
            local n = 0
            for _, r in pairs(result or {}) do n = n + #(r.result and (r.result.items or r.result) or {}) end
            return n
            """)
        }
        try await phase("diagnostics") {
            try await Task.sleep(for: .seconds(5))
        }
        let packages = try await phase("packages (board 3)") {
            _ = try await session.channel.lua("vim.cmd('SillPackages')")
            let report = try await waitFor("the packages", timeout: .seconds(600)) { () -> PackageReport? in
                if app.packages.scanner.scanning { return nil }
                return app.packages.scanner.report
                    ?? app.packages.scanner.problem.map { _ in PackageReport(packages: []) }
            }
            try expect(app.packages.scanner.problem == nil, "the packages read: \(app.packages.scanner.problem ?? "")")
            _ = try await session.channel.lua("require'sill'.close_pane(require'sill'.pane_window('packages'))")
            return report
        }
        step("the packages: \(packages.packages.count) in all, \(packages.vulnerable.count) vulnerable, " +
            "\(packages.outdated.count) outdated, \(packages.deprecated.count) deprecated; " +
            "\(app.packages.scanner.problems.count) projects the SDK could not read")
        // SILL_CHECK_CLEAN=1: dotnet clean first, so ⌘B compiles everything and its warnings stream in.
        if ProcessInfo.processInfo.environment["SILL_CHECK_CLEAN"] == "1" {
            let directory = app.workingDirectory
            try await phase("dotnet clean (not timed for sill)") {
                try await Task.detached {
                    let clean = Process()
                    clean.executableURL = URL(fileURLWithPath: "/bin/sh")
                    clean.arguments = ["-c", "dotnet clean -nologo -v q"]
                    clean.currentDirectoryURL = URL(fileURLWithPath: directory)
                    clean.standardOutput = FileHandle.nullDevice
                    clean.standardError = FileHandle.nullDevice
                    try clean.run()
                    clean.waitUntilExit()
                }.value
            }
        }
        // SILL_CHECK_SAMPLE_BUILD: sample(1) the app (or with SILL_CHECK_SAMPLE_PID, another process: nvim) through the
        // build, every 10 ms.
        if let out = ProcessInfo.processInfo.environment["SILL_CHECK_SAMPLE_BUILD"] {
            let sample = Process()
            sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            let pid = ProcessInfo.processInfo.environment["SILL_CHECK_SAMPLE_PID"] == "nvim"
                ? try await session.channel.lua("return vim.fn.getpid()").intValue
                : Int(ProcessInfo.processInfo.processIdentifier)
            sample.arguments = ["\(pid)", "170", "10", "-file", out]
            sample.standardOutput = FileHandle.nullDevice
            sample.standardError = FileHandle.nullDevice
            try sample.run()
            try await Task.sleep(for: .seconds(2))
        }
        let build = try await phase("build (⌘B)") {
            app.builds.build()
            return try await waitFor("the build", timeout: .seconds(900)) { app.builds.last }
        }
        try await phase("after the build") {
            try await Task.sleep(for: .seconds(3))
        }

        print("")
        print("  phase                          time      main worst / p99      nvim worst / p99")
        for (name, seconds) in rows {
            let main = watch.summary(name)
            let nvim = pings.summary(name)
            print("  " + name.padding(toLength: 30, withPad: " ", startingAt: 0) +
                String(
                    format: "%7.2f s %9.0f / %3.0f ms %11.0f / %3.0f ms",
                    seconds,
                    main.worst,
                    main.p99,
                    nvim.worst,
                    nvim.p99
                ))
        }
        print("")
        fflush(stdout)
        step("the explorer's filter found \(filtered) files named like Changelog across the tree")
        step("\(file.replacingOccurrences(of: app.workingDirectory + "/", with: "")): completion offered " +
            "\(completion.intValue) items; the build \(build.succeeded ? "succeeded" : "failed") with " +
            "\(build.diagnostics.count) problems")
        for trip in pings.slowTrips.prefix(12) {
            print(String(format: "  nvim slow %6.0f ms at %6.1f s in %@", trip.milliseconds, trip.at, trip.phase))
        }
        let stalls = watch.allStalls.filter { $0.milliseconds > limit }
        for stall in stalls.prefix(12) {
            print(String(format: "  stall %6.0f ms at %6.1f s in %@", stall.milliseconds, stall.at, stall.phase))
        }
        fflush(stdout)
        try expect(stalls.isEmpty, "\(stalls.count) main-thread stalls over \(Int(limit)) ms")
        step("the main thread never waited more than \(Int(limit)) ms")
    }

    private nonisolated static func size(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int) ?? 0
    }

    /// M6's Razor (`SILL_CHECK=razor`, run in a Blazor app as `dotnet new blazor` makes it, with a solution): Razor,
    /// cohosted in Roslyn's server, answers for a component: its C# broken, the error shows in Problems at the
    /// component's own line, once; hover names a component; completion offers components and the C#. The build agrees.
    private func razorSteps() async throws {
        let app = try require(app, "the app")
        try await wait("the chrome") { $0.paneRects.contains { $0.kind == "panel" } }
        let counter = try require(
            FileManager.default.enumerator(atPath: app.workingDirectory)?.compactMap { $0 as? String }
                .first { $0.hasSuffix("Pages/Counter.razor") && !$0.contains("/obj/") },
            "Counter.razor"
        )
        let path = (app.workingDirectory as NSString).appendingPathComponent(counter)
        let original = try String(contentsOfFile: path, encoding: .utf8)
        defer { try? original.write(toFile: path, atomically: true, encoding: .utf8) }
        _ = try await session.channel.lua("require'sill'.open(...)", args: [.string(path)])
        try await wait("Counter.razor open") { $0.buffer.name == "Counter.razor" && $0.buffer.filetype == "razor" }
        let started = CACurrentMediaTime()
        try await wait("Roslyn ready", timeout: .seconds(300)) { $0.languageServers["Roslyn"] == "ready" }
        let server = try require(app.roslyn, "the provisioned server")
        step(
            "Roslyn \(server.version) ready for a Razor component in \(Bench.format(CACurrentMediaTime() - started)) s" +
                (server.downloaded ? " (downloaded)" : " (cached)")
        )

        // The component's C# broken: Razor reports it on the component's own line, once.
        let line = try await session.channel.lua("""
        local line = vim.fn.search('currentCount++;')
        vim.api.nvim_buf_set_lines(0, line - 1, line, false, { '        currentCount += "x";' })
        return line
        """)
        let broken = try await wait("Razor's CS0029", timeout: .seconds(120)) { screen in
            screen.diagnostics.contains { $0.code == "CS0029" && $0.path == path && $0.source != "build" }
        }
        // Another pull would have come by now if one were coming.
        try await Task.sleep(for: .seconds(3))
        let errors = (latest ?? broken).diagnostics.filter {
            $0.code == "CS0029" && $0.path == path && $0.source != "build"
        }
        try expect(errors.count == 1, "reported once, not once per Roslyn source: \(errors.count)")
        try expect(errors[0].line == line.intValue, "at the component's line \(line.intValue): \(errors[0].line)")
        step("Razor reports CS0029 in Counter.razor at line \(errors[0].line), once")

        // Hover on a component, and completion: components in markup, the C# in @code.
        let hover = try await session.channel.lua("""
        local l = vim.fn.search('<PageTitle>', 'nw')
        local c = vim.fn.getline(l):find('PageTitle', 1, true) + 1
        local result = vim.lsp.buf_request_sync(0, 'textDocument/hover', {
          textDocument = { uri = vim.uri_from_bufnr(0) }, position = { line = l - 1, character = c } }, 20000)
        for _, r in pairs(result or {}) do
          if r.result and r.result.contents then return r.result.contents.value or '' end
        end
        return ''
        """)
        try expect(hover.stringValue?.contains("PageTitle") == true, "hover names the component: \(hover)")
        let completion = try await session.channel.lua("""
        local function complete(pattern, offset)
          local l = vim.fn.search(pattern, 'nw')
          local c = vim.fn.getline(l):find(pattern, 1, true) - 1 + offset
          local result = vim.lsp.buf_request_sync(0, 'textDocument/completion', {
            textDocument = { uri = vim.uri_from_bufnr(0) }, position = { line = l - 1, character = c },
            context = { triggerKind = 1 } }, 20000)
          local labels = {}
          for _, r in pairs(result or {}) do
            for _, item in ipairs(r.result and (r.result.items or r.result) or {}) do labels[item.label] = true end
          end
          return labels
        end
        return { markup = complete('<PageTitle>', 3)['PageTitle'] == true,
                 code = complete('currentCount +=', 4)['currentCount'] == true }
        """)
        let found = completion.dictionaryValue ?? [:]
        try expect(found[.string("markup")]?.boolValue == true, "PageTitle offered in markup")
        try expect(found[.string("code")]?.boolValue == true, "currentCount offered in @code")
        step("hover names PageTitle; completion offers PageTitle in markup and currentCount in @code")

        // The markup's HTML, and the CSS in a <style>, from the HTML server through Razor (plan §5's bridge).
        let markup = try await session.channel.lua("""
        local function at(pattern, offset)
          local l = vim.fn.search(pattern, 'nw')
          local c = vim.fn.getline(l):find(pattern, 1, true) - 1 + offset
          return { textDocument = { uri = vim.uri_from_bufnr(0) }, position = { line = l - 1, character = c },
                   context = { triggerKind = 1 } }
        end
        local function labels(params)
          local found = {}
          local result = vim.lsp.buf_request_sync(0, 'textDocument/completion', params, 30000)
          for _, r in pairs(result or {}) do
            for _, item in ipairs(r.result and (r.result.items or r.result) or {}) do found[item.label] = true end
          end
          return found
        end
        local hover = ''
        for _ = 1, 30 do
          local result = vim.lsp.buf_request_sync(0, 'textDocument/hover', at('<h1>', 2), 30000)
          for _, r in pairs(result or {}) do
            if r.result and r.result.contents then hover = r.result.contents.value or '' end
          end
          if hover ~= '' then break end
          vim.wait(1000)
        end
        local tags = labels(at('<h1>', 1))
        -- A <style> under the heading, its property half typed.
        local l = vim.fn.search('<h1>', 'nw')
        vim.api.nvim_buf_set_lines(0, l, l, false, { '<style>', '    h1 { colo }', '</style>' })
        local css = {}
        for _ = 1, 20 do
          vim.wait(1000)
          css = labels(at('colo }', 4))
          if css['color'] then break end
        end
        vim.api.nvim_buf_set_lines(0, l, l + 3, false, {})
        return { hover = hover, div = tags['div'] == true, page = tags['PageTitle'] == true,
                 color = css['color'] == true, svg = hover:find('data:image') ~= nil }
        """)
        let html = markup.dictionaryValue ?? [:]
        let heading = html[.string("hover")]?.stringValue ?? ""
        try expect(heading.contains("h1 element"), "HTML's hover on <h1>: \(heading.prefix(120))")
        try expect(html[.string("svg")]?.boolValue == false, "no inline pictures in the hover")
        try expect(
            html[.string("div")]?.boolValue == true && html[.string("page")]?.boolValue == true,
            "HTML's tags beside Razor's components"
        )
        try expect(html[.string("color")]?.boolValue == true, "CSS's color in a <style>")
        step("the HTML server answers through Razor: <h1>'s hover (\"\(heading.prefix(44))\"), div among the " +
            "components, and color in a <style>")

        // The build agrees, at the same line of the component.
        _ = try await session.channel.lua("vim.cmd('silent write')")
        app.builds.build()
        let built = try await waitFor("the build", timeout: .seconds(180)) { app.builds.last }
        try expect(!built.succeeded, "the build fails")
        let fromBuild = try require(built.diagnostics.first { $0.code == "CS0029" }, "the build's CS0029")
        try expect(
            fromBuild.path == path && fromBuild.line == errors[0].line,
            "the build's error at the same place: \(fromBuild.path):\(fromBuild.line), not \(path):\(errors[0].line)"
        )
        step("Build (⌘B) finds the same CS0029 in Counter.razor")
    }

    /// M6's exit (`SILL_CHECK=m6`, run in a folder with a .NET program that has a hot method and a growing cache, as
    /// Tests/SillSidecarTests/Fixtures/Sample): its CPU profile and a heap diff, then the hot frame to an agent (with
    /// `SILL_AGENT=echo` and no heed, in a terminal pane). `SILL_CHECK_SHOT` saves the CPU view; with `-heap` before
    /// its extension, the heap view.
    private func m6Steps() async throws {
        let app = try require(app, "the app")
        let environment = ProcessInfo.processInfo.environment
        try await wait("the chrome") { $0.paneRects.contains { $0.kind == "panel" } }
        _ = try await waitFor("the sidecar", timeout: .seconds(20)) { app.sidecar }
        _ = try await session.channel.lua("vim.cmd('SillProfile')")
        try await wait("the profile pane") { $0.currentPaneKind == "profile" }
        let view = try await waitFor("the profiler") { app.tools.profile.flatMap { $0.isHidden ? nil : $0 } }
        _ = try await waitFor("the program to run", timeout: .seconds(60)) { view.isRecording ? true : nil }
        try expect(view.title == "Sample", "profiling the sample: \(view.title)")
        step("`:SillProfile` builds the project in Release and runs it under the profiler")

        try await Task.sleep(for: .seconds(1))
        _ = try await session.channel.lua("vim.cmd('SillProfile snapshot')")
        _ = try await waitFor("snapshot #1", timeout: .seconds(30)) { view.heaps.count == 1 ? true : nil }
        try await Task.sleep(for: .seconds(1.5))
        app.profiler.snapshot()
        _ = try await waitFor("snapshot #2", timeout: .seconds(30)) { view.heaps.count == 2 ? true : nil }
        let comparison = try require(view.heaps.last?.comparison, "the comparison")
        let orders = try require(comparison.types.first { $0.name == "Order" }, "Order in the comparison")
        try expect(orders.objectsDelta > 1000, "Order grew: \(orders.objectsDelta)")
        try expect(view.tab == .heapDiff, "the heap diff shows")
        view.display()
        try expect(view.tiles.contains { $0.name == "Order" }, "Order has a tile: \(view.tiles.map(\.name))")
        view.select(type: "Order")
        try expect(view.agentPrompt()?.headline == "Stop Order growing", "\(view.agentPrompt()?.headline ?? "")")
        // Who keeps them alive: the shortest paths from a GC root, read from the snapshot's graph.
        let kept = try await waitFor("what keeps Order alive", timeout: .seconds(30)) { view.retainers["Order"] }
        let path = try require(kept.first, "a retention path")
        try expect(
            path.steps.contains { $0.contains("OrderCache") } || path.root.contains("OrderCache"),
            "OrderCache keeps them: \(path)"
        )
        try expect(view.heapPayload()?.contains("retainer: ") == true, "the agent is told the retainer")
        view.display()
        if let shot = environment["SILL_CHECK_SHOT"] {
            let heap = (shot as NSString).deletingPathExtension + "-heap.png"
            try self.shot(to: heap)
            step("saved \(heap)")
        }
        step("two heap snapshots, compared object by object: Order +\(orders.objectsDelta.formatted()) objects, " +
            "\(comparison.newObjects.formatted()) new in all; kept by " +
            ([path.root] + path.steps).joined(separator: " → "))

        _ = try await session.channel.lua("vim.cmd('SillProfile stop')")
        let document = try await waitFor("the CPU profile", timeout: .seconds(30)) { view.document }
        try expect(document.samples > 100, "\(document.samples) samples")
        let hot = try require(view.selected, "the hottest frame selected")
        try expect(view.name(hot).hasPrefix("Pricing.Total"), "the hot frame: \(view.name(hot))")
        let source = try require(view.source(of: view.name(hot)), "its source")
        try expect(source.file.hasSuffix("Program.cs"), "written in Program.cs: \(source.file)")
        view.select(tab: .flameGraph)
        view.display()
        try expect(view.blocksDrawn > 3, "\(view.blocksDrawn) blocks")
        try expect(view.cpuPayload(hot).contains("file: \(source.file):\(source.line)"), "the payload says where")
        // CPU over time: the strip, and a stretch of the run read from the sidecar.
        let strip = try require(document.timeline, "the strip's samples")
        try expect(strip.count == 120 && strip.reduce(0, +) > 0, "120 stretches: \(strip.reduce(0, +)) samples")
        view.pick(from: 0.25, to: 0.5)
        let part = try await waitFor("the stretch", timeout: .seconds(30)) {
            view.stretch != nil ? view.document : nil
        }
        try expect(part.samples > 0 && part.samples < document.samples, "a quarter of the run: \(part.samples)")
        view.display()
        if let shot = environment["SILL_CHECK_SHOT"] {
            try self.shot(to: shot)
            step("saved \(shot)")
        }
        step("stopped: \(document.samples) samples; the hot frame \(view.name(hot)) at " +
            "\((source.file as NSString).lastPathComponent):\(source.line), the flame graph from the real call tree; " +
            "the CPU over time strip, and 25% to 50% of the run is \(part.samples) samples")
        view.clearStretch()
        try expect(view.stretch == nil && view.document?.samples == document.samples, "the whole run again")

        // The hot spot's source, from the call tree.
        view.select(tab: .callTree)
        _ = try view.handleKey(require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        ), "a key event"))
        try await wait("Program.cs open") { $0.buffer.name == "Program.cs" }
        step("Return on a hot spot opens its source")

        // To an agent: no heed here, so a terminal pane running SILL_AGENT with the prompt.
        let prompt = try require(view.agentPrompt(), "a prompt")
        try expect(prompt.headline == "Make Pricing Total faster", "titled: \(prompt.headline)")
        app.agents.send(headline: prompt.headline, prompt.prompt)
        try await wait("the agent's pane", timeout: .seconds(10)) { $0.paneRects.contains { $0.kind == "terminal" } }
        step("Send to agent: \"\(prompt.headline)\" with the hot frame, its path and its source")
    }

    /// M5's exit (`SILL_CHECK=m5`): Send to agent goes to heed and the session shows in the editor. Needs a heed
    /// with its control socket at `HEED_CONTROL` whose claude agent is a stand-in that logs what it is given to
    /// `SILL_CHECK_AGENT_LOG`, and that heed's `heed` at `SILL_CHECK_HEED` (to report the agent asking, as its hooks
    /// would). `SILL_CHECK_SHOT` saves the window with the Agents sidebar.
    private func m5Steps() async throws {
        let app = try require(app, "the app")
        let environment = ProcessInfo.processInfo.environment
        let log = try require(environment["SILL_CHECK_AGENT_LOG"], "SILL_CHECK_AGENT_LOG")
        let heedBinary = try require(environment["SILL_CHECK_HEED"], "SILL_CHECK_HEED")
        try? FileManager.default.removeItem(atPath: log)
        try await wait("the chrome") { $0.paneRects.contains { $0.kind == "panel" } }
        let before = try await waitFor("heed's sessions", timeout: .seconds(10)) { app.agents.sessions }
        try expect(app.agents.sessionHere == nil, "no session works here yet (a fresh folder)")
        step("sill follows heed's sessions over its control socket: \(before.count) before")

        let path = (app.workingDirectory as NSString).appendingPathComponent("Program.cs")
        let problem = Diagnostic(
            severity: 1, message: "'int' does not contain a definition for 'Lines'", source: "build",
            code: "CS1061", path: path, buffer: 0, line: 2, col: 19
        )
        app.agents.send([problem])
        let sent = try await waitFor("Send to agent to reach heed", timeout: .seconds(10)) { app.agents.lastSent }
        try expect(sent.error == nil, "heed took it: \(sent.error ?? "")")
        let id = try require(sent.session, "the new session's id")
        let shown = try await waitFor("the session in the Agents view", timeout: .seconds(10)) {
            app.tools.sidebar.agents.ordered.first { $0.id == id }
        }
        try expect(AgentsView.isHere(shown, app.workingDirectory), "it works in this folder: \(shown.directory ?? "")")
        try expect(shown.agent == "claude", "with claude: \(shown.agent)")
        try expect(shown.title == "Fix CS1061", "titled by the problem: \(shown.title)")
        let started = try await waitFor("the agent to start", timeout: .seconds(10)) {
            (try? String(contentsOfFile: log, encoding: .utf8)).flatMap { $0.contains("CS1061") ? $0 : nil }
        }
        try expect(
            started.contains("--mcp-config") && started.contains(app.agents.configPath),
            "heed started it with sill's MCP config: \(started.prefix(300))"
        )
        step("Send to agent starts claude in heed, given sill's MCP config and the problems; \"\(shown.title)\" " +
            "shows in Agents")

        // Again: the problems go to the session that already works here, typed in, not a second session.
        app.agents.send([problem])
        _ = try await waitFor("the second send", timeout: .seconds(10)) {
            app.agents.lastSent.flatMap { $0.session == id ? $0 : nil }
        }
        _ = try await waitFor("the agent to be told again", timeout: .seconds(10)) {
            (try? String(contentsOfFile: log, encoding: .utf8)).flatMap {
                $0.contains("typed: Fix CS1061") ? true : nil
            }
        }
        try expect(app.agents.lastSent?.error == nil, "sent: \(app.agents.lastSent?.error ?? "")")
        try expect(
            (app.agents.sessions ?? []).count { AgentsView.isHere($0, app.workingDirectory) } == 1,
            "still one session here"
        )
        step("a second Send to agent types the problems into that session")

        // The agent asks (its hook says so): it needs you, in the sidebar and on the activity bar.
        let hook = Process()
        hook.executableURL = URL(fileURLWithPath: heedBinary)
        hook.arguments = ["state", "asking", "--reason", "which project?"]
        var hookEnvironment = environment
        hookEnvironment["HEED_SESSION_ID"] = id
        hookEnvironment["HEED_SOCKET"] = ((environment["HEED_CONTROL"] ?? "") as NSString)
            .deletingLastPathComponent + "/heed.sock"
        hook.environment = hookEnvironment
        try hook.run()
        hook.waitUntilExit()
        _ = try await waitFor("it to need you", timeout: .seconds(10)) {
            app.tools.sidebar.agents.ordered.first.flatMap { $0.id == id && $0.needsYou ? true : nil }
        }
        let waiting = (app.agents.sessions ?? []).count(where: \.needsYou)
        try expect(
            waiting >= 1 && app.root.activityBar.badges[.agents] == waiting,
            "the activity bar counts what needs you (\(waiting)): \(app.root.activityBar.badges)"
        )
        app.agents.send([problem])
        _ = try await waitFor("the refusal", timeout: .seconds(10)) {
            app.agents.lastSent.flatMap { $0.error }
        }
        try expect(
            app.agents.lastSent?.error?.contains("asking you something") == true,
            "heed holds the problems while it asks: \(app.agents.lastSent?.error ?? "")"
        )
        step("asking, it comes first in Agents as needing you, with a count on the activity bar; a send waits")

        _ = try await session.channel.lua("vim.cmd('SillAgent list')")
        try await wait("the sidebar") { $0.paneRects.contains { $0.kind == "sidebar" } }
        _ = try await waitFor("the sidebar to show Agents") { app.tools.sidebar.activity == .agents ? true : nil }
        if let shot = environment["SILL_CHECK_SHOT"] {
            try await Task.sleep(for: .milliseconds(300))
            try self.shot(to: shot)
            step("saved \(shot)")
        }
        step(":SillAgent list shows the Agents sidebar")
    }

    /// M4's exit (`SILL_CHECK=m4`, run in a .NET solution with an error, `SILL_MCP_ALLOW=build`): an agent, connected
    /// only through sill's MCP server as `nc -U` puts it, fixes the build error end to end. Scripted here; with
    /// `SILL_LIVE_AGENT=1` Claude Code (haiku) then fixes a fresh error on its own.
    private func m4Steps() async throws {
        let app = try require(app, "the app")
        try await wait("the chrome") { $0.paneRects.contains { $0.kind == "panel" } }
        let socket = try await waitFor("sill's MCP server") { app.agents.socketPath }
        let program = try require(
            FileManager.default.enumerator(atPath: app.workingDirectory)?.compactMap { $0 as? String }
                .first { $0.hasSuffix("Program.cs") && !$0.contains("/obj/") }, "Program.cs"
        )
        let path = (app.workingDirectory as NSString).appendingPathComponent(program)
        _ = try await session.channel.lua("require'sill'.open(...)", args: [.string(path)])
        try await wait("Program.cs open") { $0.buffer.name == "Program.cs" }

        // The agent's side: only the MCP server, through nc -U.
        let agent = try McpClient(socket)
        defer { agent.close() }
        _ = try await agent.request("initialize", [
            "protocolVersion": "2025-06-18",
            "capabilities": [:],
            "clientInfo": ["name": "check", "version": "1"],
        ])
        agent.notify("notifications/initialized")
        let tools = try await agent.request("tools/list", [:])
        let names = Set(((tools["tools"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String })
        try expect(
            names.isSuperset(of: ["problems", "build", "read_file", "open_file"]),
            "sill's tools: \(names.sorted())"
        )
        step("an agent connects through nc -U and sees sill's tools: \(names.sorted().joined(separator: ", "))")

        let failed = try await agent.call("build")
        try expect(
            failed.contains("Build failed") && failed.contains("CS1061"),
            "the build tool reports CS1061: \(failed)"
        )
        let problems = try await agent.call("problems")
        try expect(problems.contains("CS1061"), "the problems tool lists it")
        let read = try await agent.call("read_file", ["path": program])
        try expect(read.contains("2\tConsole.WriteLine(order.Lines);"), "read_file gives the file with line numbers")
        step("the agent builds, sees CS1061 in problems, and reads the file as the editor has it")

        // The agent fixes the file on disk, as agents do, and checks with a build.
        try "var order = 1;\nConsole.WriteLine(order);\n".write(toFile: path, atomically: true, encoding: .utf8)
        let fixed = try await agent.call("build")
        try expect(fixed.hasPrefix("Build succeeded"), "after the fix, the build tool: \(fixed)")
        let remaining = try await agent.call("problems")
        try expect(!remaining.contains("[build]"), "no build problems left: \(remaining)")
        let buffer = try await session.channel.lua(
            "return vim.api.nvim_buf_get_lines(vim.fn.bufnr(...), 0, -1, false)",
            args: [.string(path)]
        )
        try expect(
            (buffer.arrayValue ?? []).compactMap(\.stringValue) == ["var order = 1;", "Console.WriteLine(order);"],
            "the editor read the agent's fix again"
        )
        try expect(app.agents.calls.count(where: { $0 == "build" }) == 2, "both builds went through sill")
        step("the agent's fix builds, the problems clear, and the open file shows the fix")

        // Send to agent (board 9): the agent's command in a terminal pane, given the problems and sill's MCP config.
        let command = app.agents.agentCommand(prompt: "Fix it")
        try expect(
            command.contains("--mcp-config") && command.contains(app.agents.configPath),
            "the agent gets sill's MCP config"
        )
        let config = try JSONSerialization
            .jsonObject(with: Data(contentsOf: URL(fileURLWithPath: app.agents.configPath)))
        let server = ((config as? [String: Any])?["mcpServers"] as? [String: Any])?["sill"] as? [String: Any]
        try expect(
            server?["command"] as? String == "/usr/bin/nc" && (server?["args"] as? [String]) == ["-U", socket],
            "the config starts nc -U on sill's socket"
        )
        #if SILL_GHOSTTY
            app.agents.send([Diagnostic(
                severity: 1,
                message: "check",
                source: "build",
                code: "CS0000",
                path: path,
                buffer: 0,
                line: 1,
                col: 1
            )])
            let pane = try await wait("the agent's terminal") { $0.paneRects.contains { $0.kind == "terminal" } }
            let paneId = try require(pane.paneRects.first { $0.kind == "terminal" }?.pane, "the pane")
            let surface = try await waitFor("its surface") { self.panes.view(for: paneId) as? GhosttySurfaceView }
            _ = try await waitFor("the agent started with the problems", timeout: .seconds(15)) {
                (surface.visibleText() ?? "").contains("--mcp-config") ? true : nil
            }
        #endif
        step("Send to agent starts the agent in a terminal with sill's MCP server and the problems")

        if ProcessInfo.processInfo.environment["SILL_LIVE_AGENT"] == "1" {
            try await liveAgent(app: app, path: path)
        }
    }

    /// A real agent: Claude Code (haiku, the cheapest), given only sill's MCP server and file edits, fixes a fresh
    /// error. Printed, not interactive; it uses the person's Claude Code login.
    private func liveAgent(app: AppDelegate, path: String) async throws {
        try "var order = 1;\nConsole.WriteLine(order.Total);\n".write(toFile: path, atomically: true, encoding: .utf8)
        _ = try await session.channel.lua("vim.cmd('silent! checktime')")
        let prompt = "This project does not build. Use sill's tools: build to see the errors, read_file to read the " +
            "file, then fix it with your edit tool keeping what it prints the same, and call build again until it " +
            "succeeds. Be brief."
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "claude -p --model haiku --strict-mcp-config --mcp-config \(shellQuote(app.agents.configPath)) " +
                "--allowedTools mcp__sill__build mcp__sill__problems mcp__sill__read_file Read Edit " +
                "--permission-mode acceptEdits \(shellQuote(prompt))",
        ]
        process.currentDirectoryURL = URL(fileURLWithPath: app.workingDirectory)
        process.environment = NvimProcess.cachedEnv
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let started = CACurrentMediaTime()
        try process.run()
        let collected = Collected()
        output.fileHandleForReading.readabilityHandler = { collected.append($0.availableData) }
        while process.isRunning, CACurrentMediaTime() - started < 300 {
            try await Task.sleep(for: .milliseconds(200))
        }
        if process.isRunning { process.terminate() }
        let said = String(decoding: collected.data, as: UTF8.self)
        print("live agent said: \(said.prefix(600))")
        let builds = app.agents.calls.count(where: { $0 == "build" })
        let source = try String(contentsOfFile: path, encoding: .utf8)
        try expect(!source.contains("order.Total"), "the agent changed the file: \(source)")
        try expect(builds >= 4, "the agent built through sill (\(builds - 2) builds)")
        try expect(app.builds.last?.succeeded == true, "the last build succeeded")
        step("Claude Code (haiku) fixed a fresh build error through sill's tools in " +
            "\(Bench.format(CACurrentMediaTime() - started)) s, \(builds - 2) builds")
    }

    /// M3's exit (`SILL_CHECK=m3`, run in a .NET solution with an error): Roslyn provisioned and reporting it, a build
    /// capturing it into Problems, and Return there going to it; fixed, the build passes and the problems go.
    private func m3Steps() async throws {
        let app = try require(app, "the app")
        let tools = app.tools!, root = app.root!
        try await wait("the chrome") { $0.paneRects.contains { $0.kind == "panel" } }
        let program = try require(
            FileManager.default.enumerator(atPath: app.workingDirectory)?.compactMap { $0 as? String }
                .first { $0.hasSuffix("Program.cs") && !$0.contains("/obj/") },
            "Program.cs in the solution"
        )
        let path = (app.workingDirectory as NSString).appendingPathComponent(program)
        _ = try await session.channel.lua("require'sill'.open(...)", args: [.string(path)])
        try await wait("Program.cs open") { $0.buffer.name == "Program.cs" }

        // Roslyn: provisioned (downloaded the first time), started for the C# file, and reporting the error.
        let started = CACurrentMediaTime()
        try await wait("Roslyn ready", timeout: .seconds(240)) { $0.languageServers["Roslyn"] == "ready" }
        let server = try require(app.roslyn, "the provisioned server")
        step("Roslyn \(server.version) ready in \(Bench.format(CACurrentMediaTime() - started)) s" +
            (server.downloaded ? " (downloaded)" : " (cached)"))
        let fromRoslyn = try await wait("Roslyn's CS1061", timeout: .seconds(90)) { screen in
            screen.diagnostics.contains { $0.code == "CS1061" && $0.source != "build" }
        }
        let roslynError = try require(fromRoslyn.diagnostics.first { $0.code == "CS1061" && $0.source != "build" }, "")
        try await waitFor("Roslyn in the status bar") {
            root.statusBar.state.services.contains { $0.name == "Roslyn" && $0.ready } ? true : nil
        }
        step("Roslyn reports CS1061 at line \(roslynError.line), as the file is edited")

        // A file opened once the solution has loaded, with an error on disk and never edited: its problems show.
        let later = (path as NSString).deletingLastPathComponent + "/Later.cs"
        try "class Later\n{\n    void M()\n    {\n        var broken = ;\n    }\n}\n"
            .write(toFile: later, atomically: true, encoding: .utf8)
        _ = try await session.channel.lua("require'sill'.open(...)", args: [.string(later)])
        try await wait("Later.cs's CS1525, unedited", timeout: .seconds(60)) { screen in
            screen.diagnostics.contains { $0.code == "CS1525" && $0.path.hasSuffix("/Later.cs") }
        }
        _ = try await session.channel.lua("vim.cmd('bwipeout! ' .. vim.fn.fnameescape(...))", args: [.string(later)])
        try FileManager.default.removeItem(atPath: later)
        _ = try await session.channel.lua("require'sill'.open(...)", args: [.string(path)])
        step("a file opened after the solution loaded shows its error before it is edited")

        // Build: captured into Problems, at the same place.
        app.builds.build()
        let built = try await waitFor("the build", timeout: .seconds(120)) { app.builds.last }
        try expect(!built.succeeded, "the build fails")
        let buildError = try require(built.diagnostics.first { $0.code == "CS1061" }, "the build's CS1061")
        try expect(buildError.line == roslynError.line && buildError.path == path, "the build's error at the same line")
        try await wait("the build's error in Problems") { screen in
            screen.diagnostics.contains { $0.code == "CS1061" && $0.source == "build" }
        }
        try expect(tools.panel.tab == .problems, "the panel shows Problems after a failed build")
        try expect(tools.panel.output.contains { $0.contains("error CS1061") }, "the build's log in Output")
        step("Build (⌘B) captures CS1061 into Problems and the log into Output")

        // Jump: from the panel, Return goes to the error.
        _ = try await session.channel.lua("vim.cmd('normal! gg')")
        _ = try await session.channel.lua("require'sill'.focus('panel')")
        try await wait("the panel current") { $0.currentPaneKind == "panel" }
        press("\r", keyCode: 36)
        try await wait("the error's line") { $0.currentPane == nil && $0.cursorPosition?.line == buildError.line }
        step("Return in Problems goes to \(program):\(buildError.line)")

        // Fixed, the build passes and its problems go.
        _ = try await session.channel.lua("""
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'var order = 1;', 'Console.WriteLine(order);' })
        """)
        app.builds.build()
        try await waitFor("the second build", timeout: .seconds(120)) {
            app.builds.running == nil && app.builds.last?.succeeded == true ? true : nil
        }
        try await wait("the build's problems gone") { !$0.diagnostics.contains { $0.source == "build" } }
        step("fixed and saved, the build passes and its problems go")
    }

    /// M2's chrome (`SILL_CHECK=chrome`): the frame, the sidebar and its activities, the explorer, the panel's
    /// problems, Run, and the status bar following nvim.
    private func chromeSteps() async throws {
        let app = try require(app, "the app")
        let root = app.root!, tools = app.tools!
        try await wait("the sidebar and the panel") { screen in
            screen.paneRects.contains { $0.kind == "sidebar" } && screen.paneRects.contains { $0.kind == "panel" }
        }
        try expect(!root.titleBar.isHidden && root.titleBar.frame.height == TitleBarView.height, "the title bar")
        try expect(
            editor.frame.minX == ActivityBarView.width && editor.frame.minY == TitleBarView.height,
            "the editor right of the activity bar and under the title bar, at \(editor.frame.origin)"
        )
        try expect(root.statusBar.frame.maxY == root.bounds.maxY, "the status bar along the bottom")
        let sidebarRect = try require(latest?.paneRects.first { $0.kind == "sidebar" }, "the sidebar's window")
        try await waitFor("the sidebar on its window") {
            tools.sidebar.frame == self.editor.rect(
                row: sidebarRect.row,
                col: sidebarRect.col,
                width: sidebarRect.width,
                height: sidebarRect.height
            ) && !tools.sidebar.isHidden ? true : nil
        }
        try expect(
            root.titleBar.title.hasPrefix((app.workingDirectory as NSString).lastPathComponent),
            "the project in the title"
        )
        step("the frame: title bar, activity bar, status bar; the sidebar and the panel on their windows")
        let swap = try await session.channel.lua("return vim.o.updatecount")
        try expect(swap.intValue == 0, "no swap files ('updatecount' \(swap.intValue))")
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("sill-unsaved-\(UUID().uuidString).txt")
        try "saved\n".write(to: file, atomically: true, encoding: .utf8)
        try await session.channel.command("edit \(file.path)")
        _ = try await session.channel.lua("vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'changed' })")
        let unsaved = await app.unsavedFiles()
        try expect(unsaved == [file.lastPathComponent], "the unsaved file found for the quit question: \(unsaved)")
        try await session.channel.command("edit! | bwipeout")
        step("no swap files; quitting knows which files are unsaved")

        try await waitFor("the status bar's cursor") { root.statusBar.state.position != nil ? true : nil }
        type("i")
        try await waitFor("INSERT in the status bar") { root.statusBar.state.mode.hasPrefix("insert") ? true : nil }
        press("\u{1B}", keyCode: 53)
        try await waitFor("NORMAL again") { root.statusBar.state.mode == "normal" ? true : nil }
        try expect(StatusBarView.badge("insert").text == "INSERT", "the badge")
        step("the status bar follows the mode and the cursor")

        // The explorer: focus it from the activity bar, walk it with the keyboard, open a file.
        let explorer = tools.sidebar.explorer
        try await waitFor("the explorer's rows, with git's view") {
            explorer.gitRead && explorer.rows.count > 3 ? true : nil
        }
        root.activityBar.onSelect?(.explorer) // Selected and showing: hides the sidebar.
        try await wait("the sidebar hidden") { !$0.paneRects.contains { $0.kind == "sidebar" } }
        try expect(root.activityBar.selected == nil, "no activity selected while the sidebar is hidden")
        root.activityBar.onSelect?(.explorer)
        try await wait("the explorer current") { $0.currentPaneKind == "sidebar" }
        let target = try require(
            explorer.rows.firstIndex { $0.name == "Package.swift" },
            "Package.swift in the explorer"
        )
        type("g")
        for _ in 0 ..< target {
            type("j")
        }
        try expect(explorer.selected == target, "j walks down to Package.swift (\(explorer.selected), \(target))")
        press("\r", keyCode: 36)
        try await wait("Package.swift open") { $0.buffer.name == "Package.swift" && $0.currentPane == nil }
        try await waitFor("the status bar's file type") { root.statusBar.state.filetype == "swift" ? true : nil }
        step("the explorer: j/k and Return open a file in the editor; the activity bar hides and shows it")

        let splitTabs = try require(app.splitTabs, "the tab strips")
        let strip = try await waitFor("a tab strip with Package.swift") {
            splitTabs.strips.values.first { $0.tabs.tabs.contains { $0.name == "Package.swift" } }
        }
        let window = try require(latest?.placements.first { $0.value.win == strip.tabs.win }?.value, "its window")
        try expect(
            strip.frame == editor.rect(row: window.row, col: window.col, width: window.width, height: 1),
            "the strip on the window's winbar row"
        )
        step("each editor window has a strip of its tabs on its winbar row")

        // Drag-to-resize: the separator right of the sidebar, dragged four columns left, narrows it by four.
        // Once the layout has held still: a sidebar just reopened may still be fitting the window.
        var before = try require(latest?.paneRects.first { $0.kind == "sidebar" }, "the sidebar")
        for _ in 0 ..< 20 {
            try await Task.sleep(for: .milliseconds(150))
            let now = try require(latest?.paneRects.first { $0.kind == "sidebar" }, "the sidebar")
            if now == before { break }
            before = now
        }
        let separator = before.col + before.width
        // Left, narrowing the sidebar: the current editor window keeps 'winwidth' (20) columns, so in a narrow
        // window widening the sidebar would rightly be refused.
        try await drag(from: (row: 6, col: separator), to: (row: 6, col: separator - 4))
        try await wait("a narrower sidebar") { $0.paneRects.first { $0.kind == "sidebar" }?.width == before.width - 4 }
        step("dragging the separator resizes the window: the sidebar \(before.width) to \(before.width - 4) columns")

        root.activityBar.onSelect?(.sourceControl)
        let changes = Git.status(in: app.workingDirectory).count
        try await waitFor("the source control view") {
            tools.sidebar.activity == .sourceControl && tools.sidebar.sourceControl.entries
                .count == changes ? true : nil
        }
        step("source control lists git's \(changes) changes")
        // The map is a pane, not a sidebar view: its icon is lit while it shows.
        root.activityBar.onSelect?(.map)
        try await wait("the map pane") { $0.currentPaneKind == "map" }
        try await waitFor("the map's icon lit") { root.activityBar.currentPane == "map" ? true : nil }
        // In place of the code, not a tab page of its own; q puts the code back.
        try expect(latest?.tabs.count ?? 0 <= 1, "the map in place, not in a tab page: \(latest?.tabs.count ?? 0) tabs")
        _ = await session.channel.request("nvim_input", params: [.string("q")])
        try await wait("the editor again") { $0.currentPaneKind != "map" && !$0.paneRects.contains { $0.kind == "map" }
        }
        root.activityBar.onSelect?(.explorer)
        try await waitFor("the explorer again") { tools.sidebar.activity == .explorer ? true : nil }
        // The bar's focus on the sidebar reaches nvim on its own: zen before it lands would see it reopen the sidebar.
        try await wait("the sidebar current") { $0.currentPaneKind == "sidebar" }
        step("the activity bar switches the sidebar between its views; the map opens in place, its icon lit, q back")

        // Zen: only the text, in a column in the middle; again, everything back.
        let hadPanes = Set(latest?.paneRects.map(\.kind) ?? [])
        _ = try await session.channel.lua("vim.cmd('SillZen')")
        do {
            try await wait("zen") { $0.zen && !$0.paneRects.contains { $0.kind == "sidebar" || $0.kind == "panel" } }
        } catch {
            throw CheckFailure(description: "no zen: zen \(latest?.zen ?? false), panes " +
                "\(latest?.paneRects.map(\.kind) ?? []), current \(latest?.currentPaneKind ?? "-")")
        }
        root.layoutSubtreeIfNeeded()
        try expect(root.statusBar.isHidden && root.activityBar.isHidden, "no bars in zen")
        let column = root.editor.frame
        try expect(
            abs(column.midX - root.bounds.midX) < 1 && column.width <= CGFloat(root.zenColumns) *
                EditorFont.metrics.width + 2 * Design.islandGap + 1,
            "a centred column: \(column)"
        )
        if let shot = ProcessInfo.processInfo.environment["SILL_CHECK_SHOT"] {
            let zenShot = (shot as NSString).deletingPathExtension + "-zen.png"
            try self.shot(to: zenShot)
            step("saved \(zenShot)")
        }
        _ = try await session.channel.lua("vim.cmd('SillZen')")
        try await wait("out of zen") { screen in
            !screen.zen && hadPanes.isSubset(of: Set(screen.paneRects.map(\.kind)))
        }
        root.layoutSubtreeIfNeeded()
        try expect(!root.statusBar.isHidden, "the bars back")
        step(":SillZen hides the bars, the explorer and the panel and centres a \(Int(column.width))-point column; " +
            "again brings them back")

        // Problems: a diagnostic in the panel, opened from it.
        _ = try await session.channel.lua("""
        local buf = vim.api.nvim_win_get_buf(require'sill'.editor_window())
        vim.diagnostic.set(vim.api.nvim_create_namespace('check'), buf, {
          { lnum = 9, col = 2, severity = 1, message = 'a check problem', source = 'check' } })
        """)
        try await waitFor("the problem in the panel") { tools.panel.problems.count == 1 ? true : nil }
        _ = try await session.channel.lua("vim.cmd('normal! gg')")
        _ = try await session.channel.lua("require'sill'.focus('panel')")
        try await wait("the panel current") { $0.currentPaneKind == "panel" }
        press("\r", keyCode: 36)
        try await wait("the problem's line") { $0.currentPane == nil && $0.cursorPosition?.line == 10 }
        step("the panel lists nvim's diagnostics, and Return goes to one")

        // Smooth scrolling: <C-d> slides the window half a page, and the slide ends.
        // In a scratch buffer: the check never changes a file's buffer.
        _ = try await session.channel.lua("""
        vim.cmd('enew')
        vim.bo.buftype = 'nofile'
        vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.tbl_map(tostring, vim.fn.range(400)))
        """)
        _ = try await session.channel.lua("vim.cmd('normal! gg')")
        try await Task.sleep(for: .milliseconds(300))
        let loop = try require(editor.loop, "the render loop")
        let framesBefore = loop.framesDrawn
        chord("d", keyCode: 2)
        _ = try await waitFor("a slide", timeout: .seconds(2)) { self.editor.isSliding ? true : nil }
        let started = CACurrentMediaTime()
        _ = try await waitFor("the slide to end", timeout: .seconds(2)) { self.editor.isSliding ? nil : true }
        let lasted = (CACurrentMediaTime() - started) * 1000
        let frames = loop.framesDrawn - framesBefore
        try expect(frames >= 4, "\(frames) frames drawn for a slide")
        step("<C-d> slides the window: \(frames) frames over \(Bench.format(lasted)) ms")

        // The right-click menu: Compare file with › a branch puts the file beside its version there.
        _ = try await session.channel.lua("require'sill'.open(...)", args: [
            .string((app.workingDirectory as NSString).appendingPathComponent("Package.swift")),
        ])
        try await wait("Package.swift to compare") { $0.buffer.name == "Package.swift" }
        let menu = try require(editor.contextMenu?(), "the context menu")
        let compare = try require(menu.items.first { $0.title == "Compare file with" }?.submenu, "Compare file with")
        let branch = try require(compare.items.compactMap { $0 as? ClosureItem }.first, "a branch to compare with")
        branch.choose()
        // The file's version at the branch, beside it in diff mode (in a tab page of its own in a narrow window).
        let diffQuery = """
        local found, diffed = false, 0
        for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):find(' @ ', 1, true) then found = true end
          if vim.wo[w].diff then diffed = diffed + 1 end
        end
        return found and diffed or 0
        """
        var diffed = 0
        for _ in 0 ..< 50 where diffed != 2 {
            try await Task.sleep(for: .milliseconds(100))
            diffed = try await session.channel.lua(diffQuery).intValue
        }
        try expect(diffed == 2, "the file and its version at \(branch.title) in diff mode")
        _ = try await session.channel.lua("""
        for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):find(' @ ', 1, true) then vim.api.nvim_win_close(w, true) end
        end
        vim.cmd('diffoff!')
        if #vim.api.nvim_list_tabpages() > 1 then vim.cmd('tabclose') end
        """)
        step("the right-click menu compares the file with \(branch.title)")

        try expect(RunCommand.guess(in: app.workingDirectory) == "swift run", "Run guesses swift run for a package")
        app.run(command: "echo sill-run-check")
        let runPane = try await wait("Run's terminal") { $0.paneRects.contains { $0.kind == "terminal" } }
        let pane = try require(runPane.paneRects.first { $0.kind == "terminal" }, "the terminal")
        #if SILL_GHOSTTY
            let surface = try await waitFor("Run's surface") { self.panes.view(for: pane.pane) as? GhosttySurfaceView }
            _ = try await waitFor("Run's command run", timeout: .seconds(15)) {
                (surface.visibleText() ?? "").components(separatedBy: "sill-run-check").count > 2 ? true : nil
            }
        #endif
        step("Run opens a terminal at the bottom running the project's command")

        // The profiler: a profile pane in a tab page of its own, the flame graph drawn by level of detail.
        try await session.channel.command("SillProfile synthetic")
        try await wait("the profile pane") { $0.currentPaneKind == "profile" }
        let profile = try await waitFor("the profiler") { tools.profile.flatMap { $0.isHidden ? nil : $0 } }
        profile.display()
        try expect(profile.blocksDrawn > 10, "\(profile.blocksDrawn) blocks drawn")
        let hot = try require(
            profile.profile.nodes.indices.filter { profile.profile.nodes[$0].depth == 4 }
                .max { profile.profile.nodes[$0].samples < profile.profile.nodes[$1].samples },
            "a hot frame"
        )
        profile.select(hot, zoom: true)
        try expect(profile.path(hot).count == 5 && profile.path(hot).first == 0, "the hot path from the root")
        try expect(profile.to - profile.from == Double(profile.profile.nodes[hot].samples), "zoomed to the frame")
        if let path = ProcessInfo.processInfo.environment["SILL_CHECK_PROFILE_SHOT"] {
            try shot(to: path)
            step("saved \(path)")
        }
        _ = try await session.channel.lua("require'sill'.close_pane()")
        try await wait("back from the profile") { $0.currentPaneKind != "profile" }
        step(
            "the profiler: \(profile.profile.totalSamples.formatted()) samples as \(profile.blocksDrawn) blocks, a frame's hot path"
        )

        // Merge, last: it takes the window over. A real conflict; the status bar counts it down.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sill-check-merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func write(_ name: String, _ text: String) throws -> String {
            let path = folder.appendingPathComponent(name).path
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            return path
        }
        let paths = try [
            write("l.txt", "a\nours\n"),
            write("b.txt", "a\nbase\n"),
            write("r.txt", "a\ntheirs\n"),
            write("m.txt", "a\n<<<<<<< ours\nours\n=======\ntheirs\n>>>>>>> theirs\n"),
        ]
        _ = try await session.channel.lua("require('sill.merge').open(...)", args: paths.map { .string($0) })
        try await waitFor("MERGE in the status bar") {
            root.statusBar.state.merge?.left == 1 ? true : nil
        }
        type("gg]x")
        session.channel.send(keys: "\\t")
        try await waitFor("resolved") { root.statusBar.state.merge?.left == 0 ? true : nil }
        step("a merge: ours, result and theirs, and the status bar counts the conflicts down")
        if let path = ProcessInfo.processInfo.environment["SILL_CHECK_SHOT"] {
            try shot(to: path)
            step("saved \(path)")
        }
    }

    /// Day 3 on screen: the Metal grid draws nothing while idle, and how long a key takes to reach the display.
    private func day3() async throws {
        let loop = try require(editor.loop, "the render loop")
        let presented = presented
        loop.onPresented = { timing in presented.withLock { $0.append(timing) } }

        try await Task.sleep(for: .milliseconds(300))
        let before = loop.framesDrawn
        try await Task.sleep(for: .seconds(1.5))
        let idle = loop.framesDrawn - before
        try expect(idle == 0, "\(idle) frames drawn while idle")
        try expect(loop.isPaused, "the display link still running while idle")
        step("idle: no frames drawn in 1.5 s, and the display link paused")

        // Insert mode on a new line, then one key at a time: from the key event to the frame showing it on screen.
        type("o")
        try await wait("insert mode") { $0.mode.hasPrefix("insert") }
        var latencies: [Double] = []
        var measured = 0
        var stages: [[Double]] = [[], [], []]
        for count in 1 ... 40 {
            let sent = CACurrentMediaTime()
            type("x")
            let typed = String(repeating: "x", count: count)
            try await wait("x number \(count)") { screen in
                screen.placements.contains { screen.grids[$0.key]?.line(1).hasPrefix(typed) == true }
            }
            let tag = latestTag
            let timing = try await waitFor("the frame with x number \(count) on screen") {
                presented.withLock { $0.first { $0.tag >= tag } }
            }
            // When the system gives no presented time, the frame's commit stands in, which leaves out the wait for
            // the display.
            if timing.presented > 0 { measured += 1 }
            stages[0].append((timing.submitted - sent) * 1000)
            stages[1].append((timing.committed - timing.submitted) * 1000)
            stages[2].append(timing.presented > 0 ? (timing.presented - timing.committed) * 1000 : -1)
            latencies.append(((timing.presented > 0 ? timing.presented : timing.committed) - sent) * 1000)
            try await Task.sleep(for: .milliseconds(30))
        }
        press("\u{1B}", keyCode: 53)
        loop.onPresented = nil
        let median = Bench.percentile(latencies, 0.5), worst = Bench.percentile(latencies, 0.95)
        print("latency stages (median ms): key to submit \(Bench.format(Bench.percentile(stages[0], 0.5))), " +
            "submit to commit \(Bench.format(Bench.percentile(stages[1], 0.5))), " +
            "commit to presented \(Bench.format(Bench.percentile(stages[2], 0.5))), presented \(measured)/40")
        fflush(stdout)
        try expect(median < 50, "median key-to-screen latency \(Bench.format(median)) ms")
        let source = measured == latencies.count ? "to the frame's presented time" :
            "\(latencies.count - measured) of \(latencies.count) frames gave no presented time and were measured " +
            "to their commit, which leaves out the wait for the display"
        step("key to screen: median \(Bench.format(median)) ms, p95 \(Bench.format(worst)) ms over 40 keys; \(source)")
        let busy = loop.framesDrawn - before
        step("frames drawn while typing: \(busy) for 40 keys")
    }

    /// Day 4: the cursor follows nvim's mode info, input methods compose at the cursor, the mouse clicks and scrolls,
    /// ⌘V pastes, and the window takes nvim's title.
    private func day4() async throws {
        type(":enew!")
        press("\r", keyCode: 36)
        try await wait("an empty buffer") { $0.cursorRow == 0 && $0.mode == "normal" }
        let normal = try require(latest?.cursorStyle, "a cursor in normal mode")
        try expect(normal.cursorShape == .block, "block cursor in normal mode, not \(normal.cursorShape)")
        try expect(editor.currentFrame.cursor?.shape == .block, "the frame draws a block")
        type("i")
        let insert = try await wait("insert mode") { $0.mode.hasPrefix("insert") }
        let style = try require(insert.cursorStyle, "a cursor in insert mode")
        try expect(style.cursorShape == .vertical && style.cellPercentage == 25, "ver25 in insert mode")
        try expect(editor.currentFrame.cursor?.shape == .vertical, "the frame draws a bar")
        step("the cursor is nvim's: a block in normal mode, ver25 in insert mode")

        // An input method composing, then committing. The candidate window goes under the cursor, and asking where
        // that is does not wait on nvim.
        editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange())
        try expect(editor.hasMarkedText() && editor.subviews.contains { $0 is MarkedTextView }, "marked text shown")
        let started = CACurrentMediaTime()
        let candidates = editor.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)
        let asked = (CACurrentMediaTime() - started) * 1000
        let expected = window.convertToScreen(editor.convert(editor.cursorRect, to: nil))
        try expect(candidates == expected, "candidates at \(candidates), cursor at \(expected)")
        editor.insertText("日本語", replacementRange: NSRange(location: NSNotFound, length: 0))
        try expect(!editor.hasMarkedText() && !editor.subviews.contains { $0 is MarkedTextView }, "marked text gone")
        editor.setMarkedText("´", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange())
        editor.insertText("é", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await wait("the committed text") { screen in
            screen.placements.contains { screen.grids[$0.key]?.line(0).hasPrefix("日本語é") == true }
        }
        step(
            "input methods: marked text at the cursor, committed text reaches nvim, firstRect in \(Bench.format(asked)) ms"
        )
        press("\u{1B}", keyCode: 53)

        // A click on a cell moves nvim's cursor there.
        type(":call setline(1, map(range(300), 'printf(\"line %d\", v:val)'))")
        press("\r", keyCode: 36)
        let filled = try await wait("300 lines") { screen in
            screen.placements.contains { screen.grids[$0.key]?.line(5).hasPrefix("line 5") == true }
        }
        let windowGrid = try require(filled.placements.first { $0.value.kind == .window }, "the window grid")
        click(row: windowGrid.value.row + 4, col: windowGrid.value.col + 3)
        try await wait("the cursor at the click") {
            $0.cursorGrid == windowGrid.key && $0.cursorRow == 4 && $0.cursorCol == 3
        }
        step("a click moves the cursor to the cell clicked")

        // The wheel: three notches down scroll three lines a notch (nvim's default 'mousescroll').
        wheel(lines: -3, row: windowGrid.value.row + 2, col: windowGrid.value.col + 2)
        try await wait("scrolled") { screen in
            screen.grids[windowGrid.key]?.line(0).hasPrefix("line 9") == true
        }
        step("the wheel scrolls the window under the pointer")

        // ⌘V pastes the pasteboard through nvim_paste. The clipboard is put back afterwards.
        let saved = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("pasted from the pasteboard", forType: .string)
        type("gg0")
        editor.paste(nil)
        try await wait("the paste") { screen in
            screen.placements.contains { screen.grids[$0.key]?.line(0).contains("pasted from the pasteboard") == true }
        }
        step("⌘V pastes through nvim_paste")

        type(":set title titlestring=sill\\ title\\ check")
        press("\r", keyCode: 36)
        try await waitFor("the window title") { self.window.title == "sill title check" ? true : nil }
        step("the window takes nvim's title")
        type(":enew!")
        press("\r", keyCode: 36)
    }

    /// Day 5: the .NET sidecar started on the user's dotnet, said which protocol it speaks, and answers.
    private func day5() async throws {
        let ready = try await waitFor("the sidecar", timeout: .seconds(20)) { () -> (SidecarReady, Double)? in
            if let problem = self.app?.sidecarProblem { return (
                SidecarReady(protocol: -1, runtime: problem, processId: 0),
                0
            ) }
            return self.app?.sidecarReady
        }
        try expect(ready.0.protocol == Sidecar.protocolVersion, "the sidecar did not start: \(ready.0.runtime)")
        let sidecar = try require(app?.sidecar, "the sidecar")
        struct Text: Codable { var text: String }
        let started = CACurrentMediaTime()
        let pong = try await sidecar.request("ping", Text(text: "from sill"), as: Text.self)
        let roundTrip = (CACurrentMediaTime() - started) * 1000
        try expect(pong.text == "from sill", "the sidecar answered \(pong.text)")
        step("the .NET sidecar runs on \(ready.0.runtime), ready in \(Bench.format(ready.1 * 1000)) ms, " +
            "a ping round trip in \(Bench.format(roundTrip)) ms")
    }

    /// M2, step 1: the command line, messages, completion and tabs are sill's views, not nvim's grid.
    private func m2Protocol() async throws {
        let ui = try require(app?.externalUI, "the external UI")
        let root = try require(app?.root, "the root view")
        type(":echo 'from the command line'")
        try await wait("the command line") { $0.commandLine?.text == "echo 'from the command line'" }
        try await waitFor("the command line panel") { ui.commandLineView.isHidden ? nil : true }
        let panel = ui.commandLineView.frame
        try expect(
            panel.minY < ui.overlay.bounds.height / 2 && abs(panel.midX - ui.overlay.bounds.midX) < 2,
            "the command line panel centred in the top half, at \(panel)"
        )
        press("\r", keyCode: 36)
        try await waitFor("a notification") {
            ui.toastViews.contains { ($0 as? ToastView)?.message?.text == "from the command line" } ? true : nil
        }
        try expect(ui.commandLineView.isHidden, "the command line panel gone after Return")
        step("the command line is a panel of sill's, and :echo a notification")

        type(":call nosuchfunction()")
        press("\r", keyCode: 36)
        try await waitFor("an error notification") {
            ui.toastViews.contains { ($0 as? ToastView)?.message?.isError == true } ? true : nil
        }
        step("an error is an error notification")

        type(":ls")
        press("\r", keyCode: 36)
        try await waitFor("the output panel") { ui.outputView.isHidden ? nil : true }
        try expect(ui.outputView.frame.maxY == ui.overlay.bounds.maxY, "the output panel along the bottom")
        press("\u{1B}", keyCode: 53)
        try await waitFor("the output panel dismissed") { ui.outputView.isHidden ? true : nil }
        step(":ls opens the output panel, and a key closes it")

        type(":call setline(1, ['alpha', 'alphabet', 'alpine', ''])")
        press("\r", keyCode: 36)
        type("Goal")
        chord("n", keyCode: 45)
        let menu = try await wait("the completion popup") { $0.popupMenu != nil }
        try await waitFor("the popup view") { ui.popupView.isHidden ? nil : true }
        let anchor = try require(menu.popupMenu, "a popup")
        let placement = try require(menu.placements[anchor.grid], "the popup's grid")
        let cell = editor.rect(row: placement.row + anchor.row, col: placement.col + anchor.col, width: 1, height: 1)
        try expect(
            ui.popupView.frame.minY >= cell.maxY || ui.popupView.frame.maxY <= cell.minY,
            "the popup beside the word's row, not over it"
        )
        if let shotPath = ProcessInfo.processInfo.environment["SILL_CHECK_POPUP_SHOT"] {
            try shot(to: shotPath)
            step("saved \(shotPath)")
        }
        press("\u{1B}", keyCode: 53)
        try await waitFor("the popup gone") { ui.popupView.isHidden ? true : nil }
        step("completion is a popup of sill's under the word")

        type(":tabnew")
        press("\r", keyCode: 36)
        try await waitFor("the tab strip") { root.tabBar.isHidden ? nil : true }
        try expect(editor.frame.minY == TabBarView.height, "the editor below the tab strip")
        type(":tabclose")
        press("\r", keyCode: 36)
        try await waitFor("the tab strip gone") { root.tabBar.isHidden ? true : nil }
        try expect(editor.frame.minY == 0, "the editor back at the top")
        step("tab pages are a strip of sill's above the grid")
        type(":enew!")
        press("\r", keyCode: 36)
    }

    private func click(row: Int, col: Int) {
        let point = editor.convert(
            NSPoint(x: (CGFloat(col) + 0.5) * editor.metrics.width, y: (CGFloat(row) + 0.5) * editor.metrics.height),
            to: nil
        )
        // Straight to the editor: through the window, a click on an inactive window only activates it, and the
        // check may run while another app is frontmost.
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ) else { continue }
            if type == .leftMouseDown { editor.mouseDown(with: event) } else { editor.mouseUp(with: event) }
        }
    }

    /// A left-button drag from one cell of grid 1 to another, straight to the editor, spaced as a hand moves a mouse:
    /// nvim drops a drag that arrives with its press still unread.
    private func drag(from: (row: Int, col: Int), to: (row: Int, col: Int)) async throws {
        func point(_ cell: (row: Int, col: Int)) -> NSPoint {
            editor.convert(NSPoint(
                x: (CGFloat(cell.col) + 0.5) * editor.metrics.width,
                y: (CGFloat(cell.row) + 0.5) * editor.metrics.height
            ), to: nil)
        }
        func event(_ type: NSEvent.EventType, _ location: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        }
        if let down = event(.leftMouseDown, point(from)) { editor.mouseDown(with: down) }
        for step in 1 ... 4 {
            try await Task.sleep(for: .milliseconds(40))
            let col = from.col + (to.col - from.col) * step / 4
            if let dragged = event(.leftMouseDragged, point((to.row, col))) { editor.mouseDragged(with: dragged) }
        }
        try await Task.sleep(for: .milliseconds(40))
        if let up = event(.leftMouseUp, point(to)) { editor.mouseUp(with: up) }
    }

    private func wheel(lines: Int32, row: Int, col: Int) {
        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0
        ) else { return }
        let point = editor.convert(
            NSPoint(x: (CGFloat(col) + 0.5) * editor.metrics.width, y: (CGFloat(row) + 0.5) * editor.metrics.height),
            to: nil
        )
        cgEvent.location = window.convertPoint(toScreen: point).flipped(in: window.screen)
        if let event = NSEvent(cgEvent: cgEvent) { editor.scrollWheel(with: event) }
    }

    // MARK: Keys, sent through the window as typed keys are

    private func type(_ text: String) {
        for character in text {
            let string = String(character)
            let (code, shift) = Self.keyCodes[character] ?? (0, false)
            send(string, unmodified: string, keyCode: code, flags: shift ? .shift : [])
        }
    }

    private func press(_ characters: String, keyCode: UInt16) {
        send(characters, unmodified: characters, keyCode: keyCode, flags: [])
    }

    /// A control chord: Ctrl+`key`.
    private func chord(_ key: String, keyCode: UInt16) {
        let control = key.unicodeScalars.first.map { String(UnicodeScalar($0.value & 0x1F)!) } ?? key
        send(control, unmodified: key, keyCode: keyCode, flags: .control)
    }

    private func send(_ characters: String, unmodified: String, keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: unmodified, isARepeat: false, keyCode: keyCode
        ) else { return }
        // As NSApplication does: key equivalents first (where control chords go), then the first responder.
        if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
    }

    /// US ANSI key codes, enough for the text the check types. Ghostty reads the key code, not only the text.
    private static let keyCodes: [Character: (UInt16, Bool)] = {
        var map: [Character: (UInt16, Bool)] = [:]
        let letters: [(Character, UInt16)] = [
            ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9),
            ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17), ("o", 31), ("u", 32),
            ("i", 34), ("p", 35), ("l", 37), ("j", 38), ("k", 40), ("n", 45), ("m", 46),
        ]
        for (letter, code) in letters {
            map[letter] = (code, false)
            map[Character(letter.uppercased())] = (code, true)
        }
        let others: [(Character, UInt16, Bool)] = [
            ("1", 18, false), ("2", 19, false), ("3", 20, false), ("4", 21, false), ("6", 22, false),
            ("5", 23, false), ("9", 25, false), ("7", 26, false), ("8", 28, false), ("0", 29, false),
            ("-", 27, false), ("=", 24, false), (" ", 49, false), (",", 43, false), (".", 47, false),
            ("/", 44, false), (";", 41, false), (":", 41, true), ("$", 21, true), ("(", 25, true), (")", 29, true),
            ("*", 28, true), ("!", 18, true), ("|", 42, true), ("'", 39, false),
        ]
        for (character, code, shift) in others {
            map[character] = (code, shift)
        }
        return map
    }()

    // MARK: Waiting and reporting

    @discardableResult
    private func wait(
        _ what: String, timeout: Duration = .seconds(5), _ predicate: (Screen) -> Bool
    ) async throws -> Screen {
        try await waitFor(what, timeout: timeout) { self.latest.flatMap { predicate($0) ? $0 : nil } }
    }

    @discardableResult
    private func waitFor<T>(_ what: String, timeout: Duration = .seconds(5), _ value: () -> T?) async throws -> T {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let value = value() { return value }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CheckFailure(description: "timed out waiting for \(what)")
    }

    private func require<T>(_ value: T?, _ what: String) throws -> T {
        guard let value else { throw CheckFailure(description: "no \(what)") }
        return value
    }

    private func expect(_ condition: Bool, _ what: String) throws {
        if !condition { throw CheckFailure(description: what) }
    }

    private func step(_ text: String) {
        print("ok    \(text)")
        fflush(stdout)
    }

    /// The whole window as it stands, composited: the frame views and tool views drawn as they draw themselves, the
    /// grid rendered by a renderer of its own (the render thread's is not shared), each terminal's text read back
    /// from Ghostty (a Metal surface no snapshot captures), and the overlays.
    private func shot(to path: String) throws {
        let root = try require(app?.root, "the root view")
        try shot(of: root, to: path, cursor: false)
    }

    private func shot(of root: RootView, to path: String, cursor: Bool) throws {
        let scale = window.backingScaleFactor
        let size = root.bounds.size
        let (width, height) = (Int(size.width * scale), Int(size.height * scale))
        let rep = try require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32
        ), "a bitmap for the shot")
        rep.size = size
        let context = try require(NSGraphicsContext(bitmapImageRep: rep), "a context on the shot")
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        Design.bar(Design.chrome).setFill()
        NSRect(origin: .zero, size: size).fill()

        /// A rect in the root's (flipped) coordinates, in the bitmap's.
        func bitmap(_ rect: NSRect, in view: NSView) -> NSRect {
            let rect = root.convert(rect, from: view)
            return NSRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height)
        }
        /// A view alone, into a clear bitmap, so a rounded panel keeps its transparent corners.
        func paint(_ view: NSView) {
            let pixels = view.convertToBacking(view.bounds).size
            guard pixels.width >= 1, pixels.height >= 1, let cached = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0
            ) else { return }
            // In points before the context is made, so the view draws at the backing scale.
            cached.size = view.bounds.size
            guard let viewContext = NSGraphicsContext(bitmapImageRep: cached) else { return }
            view.displayIgnoringOpacity(view.bounds, in: viewContext)
            cached.draw(
                in: bitmap(view.bounds, in: view),
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: false,
                hints: nil
            )
        }

        for view in [root.titleBar, root.activityBar, root.statusBar, root.tabBar] as [NSView] where !view.isHidden {
            paint(view)
        }

        // The grid.
        let device = try require(MTLCreateSystemDefaultDevice(), "a Metal device")
        let renderer = try GridRenderer(
            device: device, font: editor.metrics.regular, cellSize: editor.metrics.cellSize, scale: scale,
            pixelFormat: .bgra8Unorm
        )
        let grid = editor.bounds.size
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: Int(grid.width * scale), height: Int(grid.height * scale), mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try require(device.makeTexture(descriptor: descriptor), "a texture for the grid")
        var frame = editor.currentFrame
        if cursor, frame.cursor == nil, let style = frame.screen.cursorStyle, style.cursorShape == .block {
            frame.cursor = Frame.Cursor(shape: .block, highlight: style.attrId)
        }
        let commands = try require(renderer.render(frame, to: texture), "a command buffer")
        commands.waitUntilCompleted()
        let gridRep = try require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: texture.width, pixelsHigh: texture.height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: texture.width * 4, bitsPerPixel: 32
        ), "a bitmap for the grid")
        let pixels = try require(gridRep.bitmapData, "the grid's pixels")
        texture.getBytes(
            pixels,
            bytesPerRow: texture.width * 4,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0
        )
        // The texture is BGRA; the bitmap is RGBA.
        for index in stride(from: 0, to: texture.width * texture.height * 4, by: 4) {
            (pixels[index], pixels[index + 2]) = (pixels[index + 2], pixels[index])
        }
        gridRep.size = grid
        gridRep.draw(in: bitmap(editor.bounds, in: editor))

        // What sits over the grid: terminals, tool views, overlays.
        for view in editor.subviews where !view.isHidden {
            #if SILL_GHOSTTY
                if let surface = view as? GhosttySurfaceView {
                    let rect = bitmap(surface.bounds, in: surface)
                    Design.terminal.setFill()
                    rect.fill()
                    ((surface.visibleText() ?? "") as NSString).draw(
                        in: rect.insetBy(dx: 14, dy: 10),
                        withAttributes: [.font: editor.metrics.regular, .foregroundColor: Design.text]
                    )
                    continue
                }
            #endif
            paint(view)
        }
        // The islands' canvas, over the grid and its panes, under the popups.
        if !root.islands.isHidden { paint(root.islands) }
        for view in app?.externalUI.overlay.subviews ?? [] where !view.isHidden {
            paint(view)
        }
        context.flushGraphics()
        let data = try require(rep.representation(using: .png, properties: [:]), "PNG data")
        try data.write(to: URL(fileURLWithPath: path))
    }
}

struct CheckFailure: Error, CustomStringConvertible {
    var description: String
}

extension NSPoint {
    /// A point in AppKit's screen coordinates (origin bottom left) in Quartz's (origin top left).
    func flipped(in screen: NSScreen?) -> CGPoint {
        CGPoint(x: x, y: (NSScreen.screens.first?.frame.height ?? screen?.frame.height ?? 0) - y)
    }
}

/// An MCP client over `nc -U`, as an agent connects: for the self-check.
final class McpClient: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let lock = NSLock()
    private var replies: [Int: [String: Any]] = [:]
    private var buffer = Data()
    private var next = 1

    init(_ socket: String) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        process.arguments = ["-U", socket]
        process.standardInput = input
        let output = Pipe()
        process.standardOutput = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.received(handle.availableData) }
        try process.run()
    }

    private func received(_ data: Data) {
        lock.withLock {
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex ..< newline]
                buffer = Data(buffer[buffer.index(after: newline)...])
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                   let id = object["id"] as? Int
                {
                    replies[id] = object
                }
            }
        }
    }

    private func send(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        try? input.fileHandleForWriting.write(contentsOf: data)
    }

    func notify(_ method: String) {
        send(["jsonrpc": "2.0", "method": method])
    }

    func request(_ method: String, _ params: [String: Any], timeout: TimeInterval = 180) async throws -> [String: Any] {
        let id = lock.withLock { () -> Int in
            next += 1
            return next
        }
        send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let reply = lock.withLock({ replies[id] }) {
                if let error = reply["error"] as? [String: Any] {
                    throw CheckFailure(description: "\(method): \(error["message"] ?? "")")
                }
                return reply["result"] as? [String: Any] ?? [:]
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CheckFailure(description: "no reply to \(method)")
    }

    /// A tool's text.
    func call(_ tool: String, _ arguments: [String: Any] = [:]) async throws -> String {
        let result = try await request("tools/call", ["name": tool, "arguments": arguments])
        return ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    }

    func close() { process.terminate() }
}
