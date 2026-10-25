import AppKit
import SillCore
import SillEditor
import SillNvim
#if SILL_GHOSTTY
    import SillTerminal
#endif

/// The terminal panes: one Ghostty surface per pane, laid over the cells of the placeholder window nvim keeps for it.
///
/// nvim decides where every pane is; this only follows. The keyboard is nvim's until a pane asks for it (`i` in its
/// window) or is clicked, and goes back to nvim on <C-\><C-n> in the terminal, a click on the editor, or when nvim
/// makes another window current.
@MainActor
final class TerminalPanes {
    private let editor: EditorView
    private let channel: NvimChannel
    private let directory: String
    private var views: [Int: NSView] = [:]
    /// The pane that has the keyboard.
    private(set) var focused: Int?
    /// The grids terminal surfaces cover.
    private(set) var covered: Set<Int> = []
    /// Typed into the next terminal opened (Run's command).
    var nextInput: String?
    private var lastCurrentPane: Int?
    /// <C-\> typed in the terminal and held back: the next key decides whether it starts <C-\><C-n>.
    private var pendingEscape: NSEvent?
    /// Set while a held-back key is replayed, so the filter lets it through.
    private var replaying = false

    init(editor: EditorView, channel: NvimChannel, directory: String) {
        self.editor = editor
        self.channel = channel
        self.directory = directory
    }

    /// The view drawing pane `pane`, if it is open.
    func view(for pane: Int) -> NSView? { views[pane] }

    /// Follows a new screen: places, shows, hides and closes surfaces, and gives the keyboard to a pane that asked.
    func update(_ update: ScreenUpdate) {
        let screen = update.screen
        // A window can be split, showing one pane twice; one surface can only be in one place, so it goes to the
        // current window, else to the first.
        var placed: [Int: PaneRect] = [:]
        for rect in screen.paneRects where rect.kind == "terminal" &&
            (placed[rect.pane] == nil || rect.win == screen.cursorWindow)
        {
            placed[rect.pane] = rect
        }
        for (pane, rect) in placed {
            let view = views[pane] ?? open(pane)
            view.frame = editor.rect(row: rect.row, col: rect.col, width: rect.width, height: rect.height)
            view.isHidden = false
        }
        let open = Set(screen.panes.values.filter { screen.paneKinds[$0] == "terminal" })
        for (pane, view) in views where placed[pane] == nil {
            if open.contains(pane) {
                view.isHidden = true // On another tab page: the shell keeps running.
            } else {
                view.removeFromSuperview()
                views[pane] = nil
                if focused == pane { focusEditor() }
            }
        }
        covered = Set(placed.values.map(\.grid))

        if let pane = update.focusPane {
            focus(pane)
        } else if let focused, screen.currentPane != lastCurrentPane, screen.currentPane != focused {
            // nvim made another window current; the keyboard follows.
            focusEditor()
        }
        lastCurrentPane = screen.currentPane
    }

    func focus(_ pane: Int) {
        guard let view = views[pane], !view.isHidden else { return }
        focused = pane
        pendingEscape = nil
        editor.window?.makeFirstResponder(view)
    }

    func focusEditor() {
        focused = nil
        pendingEscape = nil
        editor.window?.makeFirstResponder(editor)
    }

    private func open(_ pane: Int) -> NSView {
        #if SILL_GHOSTTY
            let surface = GhosttySurfaceView(launch: TerminalLaunch(
                directory: directory, initialInput: nextInput, environment: ["SILL_PANE": String(pane)]
            ))
            nextInput = nil
            surface.keyFilter = { [weak self] event in self?.filter(event, pane: pane) ?? false }
            surface.onClick = { [weak self] in self?.clicked(pane) }
            surface.onReference = { [weak self, weak surface] row, column in
                guard let self, let surface else { return false }
                return openReference(in: row, at: column, from: surface.workingDirectory)
            }
            // A link (OSC 8) to a file, ⌘-clicked: its line from a `#L7` fragment, as code hosts write it.
            surface.onOpenURL = { [weak self] url in
                guard url.isFileURL else { return false }
                let line = url.fragment.flatMap { $0.hasPrefix("L") ? Int($0.dropFirst().prefix { $0.isNumber }) : nil }
                return self?.openReference(in: url.path + (line.map { ":\($0)" } ?? ""), at: 0, from: nil) ?? false
            }
            let view: NSView = surface
        #else
            let view = StandInPane(pane: pane)
        #endif
        editor.addSubview(view)
        views[pane] = view
        return view
    }

    /// A file named in a pane's output (`src/Foo.cs:42`, ⌘-clicked) opens in the editor at that line.
    @discardableResult
    func openReference(in row: String, at column: Int, from shellDirectory: String?) -> Bool {
        let folder = shellDirectory.flatMap { URL(string: $0)?.isFileURL == true ? URL(string: $0)?.path : $0 }
        guard let reference = FileReference.find(in: row, at: column, directory: folder ?? directory, root: directory)
        else { return false }
        open(reference)
        return true
    }

    /// Opens `reference` in the editor, which gets the keyboard.
    func open(_ reference: FileReference) {
        focusEditor()
        // Only what is there: a nil reaches Lua as vim.NIL, not nil.
        let place = [reference.line, reference.line.flatMap { _ in reference.column }].compactMap(\.self)
        Nvim.lua(channel, "require'sill'.open(...)", [.string(reference.path)] + place.map { .int(Int64($0)) })
    }

    /// A click on a pane makes its window current in nvim and gives it the keyboard.
    private func clicked(_ pane: Int) {
        if let win = editor.screen.paneRects.first(where: { $0.pane == pane })?.win {
            let channel = channel
            Task { _ = await channel.request("nvim_set_current_win", params: [.int(Int64(win))]) }
        }
        focus(pane)
    }

    /// <C-\><C-n> leaves the terminal, as in nvim's own :terminal. <C-\> followed by anything else reaches the
    /// terminal as typed.
    private func filter(_ event: NSEvent, pane: Int) -> Bool {
        guard !replaying else { return false }
        let control = event.modifierFlags.contains(.control)
        let key = event.charactersIgnoringModifiers
        if let held = pendingEscape {
            pendingEscape = nil
            if control, key == "n" {
                focusEditor()
                return true
            }
            replaying = true
            views[pane]?.keyDown(with: held)
            replaying = false
            return false
        }
        if control, key == "\\" {
            pendingEscape = event
            return true
        }
        return false
    }
}

#if !SILL_GHOSTTY
    /// What a pane shows when sill is built without GhosttyKit (`mise run ghostty` builds it).
    final class StandInPane: NSView {
        private let pane: Int

        init(pane: Int) {
            self.pane = pane
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) { fatalError("not used") }

        override var acceptsFirstResponder: Bool { true }

        override func draw(_: NSRect) {
            NSColor(white: 0.08, alpha: 1).setFill()
            bounds.fill()
            let text = "terminal pane \(pane): built without GhosttyKit (mise run ghostty)" as NSString
            text.draw(at: NSPoint(x: 12, y: 12), withAttributes: [.foregroundColor: NSColor.secondaryLabelColor])
        }
    }
#endif

extension TerminalPanes {
    /// Terminal panes take the grid's font (a point smaller), now and as it changes: set before the font is first
    /// read.
    static func followGridFont() {
        EditorFont.onTerminalFont = { family, size in
            #if SILL_GHOSTTY
                if GhosttyRuntime.started {
                    GhosttyRuntime.shared.setFont(family: family, size: size)
                } else {
                    GhosttyRuntime.font = (family, size)
                }
            #endif
        }
    }
}
