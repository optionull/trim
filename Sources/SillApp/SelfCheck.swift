import AppKit
import SillCore
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
    private var latest: Screen?

    init(window: NSWindow, editor: EditorView, panes: TerminalPanes, session: EditorSession) {
        self.window = window
        self.editor = editor
        self.panes = panes
        self.session = session
    }

    func observe(_ update: ScreenUpdate) {
        latest = update.screen
    }

    func run() async {
        do {
            try await steps()
            print("sill check: passed")
            exit(0)
        } catch {
            print("sill check: FAILED: \(error)")
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
    }

    private func shot(to path: String) throws {
        editor.displayIfNeeded()
        let rep = try require(editor.bitmapImageRepForCachingDisplay(in: editor.bounds), "bitmap for the shot")
        editor.cacheDisplay(in: editor.bounds, to: rep)
        #if SILL_GHOSTTY
            // Over each surface, its text as read back from Ghostty. The bitmap's context is not flipped.
            let context = try require(NSGraphicsContext(bitmapImageRep: rep), "a context on the shot")
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            for case let surface as GhosttySurfaceView in editor.subviews where !surface.isHidden {
                let frame = NSRect(
                    x: surface.frame.minX, y: editor.bounds.height - surface.frame.maxY,
                    width: surface.frame.width, height: surface.frame.height
                )
                NSColor(rgb: 0x15171A).setFill()
                frame.fill()
                let text = (surface.visibleText() ?? "") as NSString
                text.draw(
                    in: frame.insetBy(dx: 14, dy: 10),
                    withAttributes: [.font: editor.metrics.regular, .foregroundColor: NSColor(rgb: 0xCFD3D8)]
                )
            }
            context.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
        #endif
        let data = try require(rep.representation(using: .png, properties: [:]), "PNG data")
        try data.write(to: URL(fileURLWithPath: path))
    }
}

struct CheckFailure: Error, CustomStringConvertible {
    var description: String
}
