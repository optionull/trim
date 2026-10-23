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
        await session.resize(cols: 150, rows: 46)
        try await wait("a 150x46 screen") { $0.grids[1]?.cols == 150 && $0.grids[1]?.rows == 46 }
        let file = ProcessInfo.processInfo.environment["SILL_SHOWCASE_FILE"] ??
            Runtime.directory.appendingPathComponent("plugin/sill.lua").path
        try await session.channel.command("edit \(file.replacingOccurrences(of: " ", with: "\\ "))")
        try await session.channel.command("set number cursorline")
        try await session.channel.command("call cursor(32, 5)")
        try await session.channel.command("SillTerminal")
        let pane = try await waitFor("the pane's surface") { self.panes.view(for: 1) }
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
        try await Task.sleep(for: .milliseconds(300))
        let screen = try require(latest, "a screen")
        try shot(to: path, cols: screen.grids[1]?.cols ?? 150, rows: screen.grids[1]?.rows ?? 46, cursor: true)
        print("sill showcase: saved \(path)")
        fflush(stdout)
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

    /// Renders the editor's current frame offscreen with a renderer of its own (the render thread's is not shared),
    /// then draws each terminal's text where its surface is.
    private func shot(to path: String) throws {
        try shot(
            to: path, cols: Int(editor.bounds.width / editor.metrics.width),
            rows: Int(editor.bounds.height / editor.metrics.height), cursor: false
        )
    }

    /// Renders `cols` x `rows` cells of the current screen, with the editor's cursor if `cursor`.
    private func shot(to path: String, cols: Int, rows: Int, cursor: Bool) throws {
        let scale = window.backingScaleFactor
        let device = try require(MTLCreateSystemDefaultDevice(), "a Metal device")
        let renderer = try GridRenderer(
            device: device, font: editor.metrics.regular, cellSize: editor.metrics.cellSize, scale: scale,
            pixelFormat: .bgra8Unorm
        )
        let grid = CGSize(width: CGFloat(cols) * editor.metrics.width, height: CGFloat(rows) * editor.metrics.height)
        // The tab strip above the grid, when it shows.
        let tabs: CGFloat = app?.root.tabBar.isHidden == false ? TabBarView.height : 0
        let size = CGSize(width: grid.width, height: grid.height + tabs)
        let (width, height) = (Int(size.width * scale), Int(size.height * scale))
        var frame = editor.currentFrame
        if cursor, frame.cursor == nil, let style = frame.screen.cursorStyle, style.cursorShape == .block {
            frame.cursor = Frame.Cursor(shape: .block, highlight: style.attrId)
        }
        let gridDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: Int(grid.width * scale), height: Int(grid.height * scale), mipmapped: false
        )
        gridDescriptor.usage = [.renderTarget, .shaderRead]
        gridDescriptor.storageMode = .shared
        let gridTexture = try require(device.makeTexture(descriptor: gridDescriptor), "a texture for the grid")
        let commands = try require(renderer.render(frame, to: gridTexture), "a command buffer")
        commands.waitUntilCompleted()
        let rep = try require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32
        ), "a bitmap for the shot")
        let pixels = try require(rep.bitmapData, "the shot's pixels")
        let top = Int(tabs * scale)
        let gridWidth = gridTexture.width, gridHeight = gridTexture.height
        gridTexture.getBytes(
            pixels + top * width * 4, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, gridWidth, gridHeight),
            mipmapLevel: 0
        )
        // The texture is BGRA; the bitmap is RGBA.
        for index in stride(from: top * width * 4, to: width * height * 4, by: 4) {
            (pixels[index], pixels[index + 2]) = (pixels[index + 2], pixels[index])
        }
        rep.size = size
        // Over the grid, the views that are not Metal: the tab strip, each terminal's text as read back from Ghostty
        // (a Metal surface a snapshot cannot capture), and the overlays. The bitmap's context is not flipped.
        let context = try require(NSGraphicsContext(bitmapImageRep: rep), "a context on the shot")
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        /// The view alone, into a clear bitmap: a rounded panel keeps its transparent corners.
        func paint(_ view: NSView, at frame: NSRect) {
            let pixels = view.convertToBacking(view.bounds).size
            guard let cached = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0
            ) else { return }
            // In points before the context is made, so the view draws at the backing scale.
            cached.size = view.bounds.size
            guard let viewContext = NSGraphicsContext(bitmapImageRep: cached) else { return }
            view.displayIgnoringOpacity(view.bounds, in: viewContext)
            cached.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        }
        /// A rect in the editor's coordinates (flipped, below the tab strip), in the bitmap's.
        func bitmap(_ rect: NSRect) -> NSRect {
            NSRect(x: rect.minX, y: size.height - tabs - rect.maxY, width: rect.width, height: rect.height)
        }
        if tabs > 0, let tabBar = app?.root.tabBar {
            paint(tabBar, at: NSRect(x: 0, y: size.height - tabs, width: size.width, height: tabs))
        }
        #if SILL_GHOSTTY
            for case let surface as GhosttySurfaceView in editor.subviews where !surface.isHidden {
                let frame = bitmap(surface.frame)
                Design.terminal.setFill()
                frame.fill()
                let text = (surface.visibleText() ?? "") as NSString
                text.draw(
                    in: frame.insetBy(dx: 14, dy: 10),
                    withAttributes: [.font: editor.metrics.regular, .foregroundColor: Design.text]
                )
            }
        #endif
        for view in app?.externalUI.overlay.subviews ?? [] where !view.isHidden {
            paint(view, at: bitmap(view.frame))
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
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
