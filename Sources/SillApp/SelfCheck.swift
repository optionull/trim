import AppKit
import Metal
import os
import SillCore
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
            if let path = ProcessInfo.processInfo.environment["SILL_SHOWCASE"] {
                try await showcase(to: path)
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
    /// frame is rendered offscreen at that size.
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
        root.activityBar.onSelect?(.packages)
        try await waitFor("the packages view") { tools.sidebar.activity == .packages ? true : nil }
        try expect(root.activityBar.selected == .packages, "packages selected")
        root.activityBar.onSelect?(.explorer)
        try await waitFor("the explorer again") { tools.sidebar.activity == .explorer ? true : nil }
        step("the activity bar switches the sidebar between its views")

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

        tools.panel.onSendToAgent?(tools.panel.problems)
        try await wait("the heed notice") { $0.messages.contains { $0.text.contains("heed bridge") } }
        step("Send all to agent says it comes with the heed bridge")

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
        Design.chrome.setFill()
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
