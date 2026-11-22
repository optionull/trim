import AppKit
import FrameModes
import FrameRun
import SillEditor
#if SILL_GHOSTTY
    import SillTerminal
#endif

/// Where the build pane goes: beside the code when the window is wide, under it when it is not.
enum RunPlacement: Equatable {
    case right, bottom

    /// The window's width at which there is room for the pane to the right of the code.
    static let wideEnough: CGFloat = 1300

    static func `for`(width: CGFloat) -> RunPlacement { width >= wideEnough ? .right : .bottom }

    /// How much of the grid's column the pane takes, and the least it is given.
    static let fraction: CGFloat = 0.4
    static let leastWidth: CGFloat = 360
    static let leastHeight: CGFloat = 160
}

#if SILL_GHOSTTY

    extension FrameWindowController {
        /// Runs `entry` in the pane's terminal (a new shell each time), the keyboard staying where it was.
        func run(_ entry: RunEntry, focusing: Bool = false) {
            guard view != nil else { return }
            let pane = ensureBuildPane()
            GhosttyRuntime.font = (EditorFont.font(12).familyName ?? "JetBrains Mono", EditorFont.size)
            let surface = GhosttySurfaceView(launch: TerminalLaunch(
                directory: entry.directory, initialInput: entry.command + "\n", environment: entry.environment
            ))
            surface.onFocus = { [weak self] in self?.terminalFocused() }
            pane.setTerminal(surface, entry: entry) { [weak surface] in surface?.screenText() }
            UserDefaults.standard.set(entry.id, forKey: "frame.lastRun." + workspace)
            if entry.kind == .build {
                takeBuildProblems([])
                watchBuild(pane)
            }
            if focusing { focus(.terminal) }
        }
    }

#else

    extension FrameWindowController {
        func run(_: RunEntry, focusing _: Bool = false) { noTerminal() }
        func noTerminal() {
            Task {
                _ = try? await session.channel
                    .lua(
                        "vim.notify('Frame was built without its terminal (GhosttyKit): run `mise run ghostty`', vim.log.levels.WARN)"
                    )
            }
        }
    }

#endif

extension FrameWindowController {
    /// ⌘J: show the pane (or take the keyboard to it); from the pane, back to the code.
    @objc func toggleTerminal(_: Any?) {
        guard let pane = runPane else { return showRunPicker(nil) }
        if modes.surface == .terminal { return focusEditor() }
        _ = pane
        focus(.terminal)
    }

    @objc func closeTerminal(_: Any?) { hideTerminal() }

    func hideTerminal() {
        guard let pane = runPane else { return }
        runPane = nil
        let wasFocused = modes.surface == .terminal
        view.terminal = nil
        pane.removeFromSuperview()
        terminalGone()
        if wasFocused { focusEditor() }
    }

    func entries() -> [RunEntry] { RunEntries.find(in: workspace) }

    /// What F5 runs: what was run last here, else the first program; nothing found is a picker.
    func defaultRun(from all: [RunEntry]) -> RunEntry? {
        let last = UserDefaults.standard.string(forKey: "frame.lastRun." + workspace)
        return all.first { $0.id == last && $0.kind != .build } ?? all.first { $0.kind == .run }
    }

    /// What ⇧⌘B builds: the default build task, else the first build.
    func defaultBuild(from all: [RunEntry]) -> RunEntry? {
        all.first { $0.kind == .build && $0.isDefault } ?? all.first { $0.kind == .build }
    }

    @objc func runDefault(_: Any?) {
        let all = entries()
        if let entry = defaultRun(from: all) { run(entry) } else { showRunPicker(nil) }
    }

    @objc func buildDefault(_: Any?) {
        let all = entries()
        if let entry = defaultBuild(from: all) { run(entry) } else { showRunPicker(nil) }
    }

    /// Everything that can be run here, as a mode: Return runs it in the pane.
    @objc func showRunPicker(_: Any?) {
        guard listPicker == nil else { return }
        let all = entries()
        guard !all.isEmpty else {
            Task { [session] in
                _ = try? await session.channel
                    .lua("vim.notify('Frame: nothing to run or build in this folder', vim.log.levels.WARN)")
            }
            return
        }
        let items = all.map { entry in
            PickerItem(
                id: entry.id + "\t" + entry.command,
                title: entry.title,
                detail: entry.source + " · " + entry.kind.rawValue,
                subtitle: entry.command
            )
        }
        showList(title: "Run", items: items, current: nil, onChoose: { [weak self] item in
            guard let entry = all.first(where: { $0.id + "\t" + $0.command == item.id }) else { return }
            self?.run(entry)
        })
    }

    /// A build that has gone quiet: what it printed is read, the files it complained of are marked in the tree, and the
    /// pane shows its problems (the keyboard stays where it was). One pane and one mode for build and problems.
    func watchBuild(_ pane: BuildPane) {
        Task { [weak self, weak pane] in
            var last = "", quiet = 0
            for _ in 0 ..< 600 {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let pane, runPane === pane, let text = pane.screenText() else { return }
                quiet = text == last ? quiet + 1 : 0
                last = text
                guard quiet == 2, let entry = pane.entry else { continue }
                takeBuildProblems(Problems.parse(text, directory: entry.directory))
                if !buildProblems.isEmpty { pane.select(.problems) }
                return
            }
        }
    }
}
