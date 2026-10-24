import AppKit
import Metal
import os
import SillCore
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
            if let path = ProcessInfo.processInfo.environment["SILL_SHOWCASE"] {
                try await showcase(to: path)
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
            ("web/app.ts", "typescript", "total"),
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
            _ = try await session.channel.lua("vim.cmd('tabclose')")
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
        try expect(names == ["problems", "build", "read_file", "open_file"], "sill's tools: \(names.sorted())")
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
        // Packages is a tab of its own (board 3), not a sidebar view.
        root.activityBar.onSelect?(.packages)
        try await wait("the packages pane") { $0.currentPaneKind == "packages" }
        _ = try await session.channel.lua("vim.cmd('tabclose')")
        try await wait("the editor again") { $0.currentPaneKind != "packages" }
        root.activityBar.onSelect?(.explorer)
        try await waitFor("the explorer again") { tools.sidebar.activity == .explorer ? true : nil }
        step("the activity bar switches the sidebar between its views; packages opens its tab")

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
        try await session.channel.command("tabclose")
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
