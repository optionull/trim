import AppKit
import FrameModes
import FrameRun
import SillCore
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
        /// Runs `entry` in the pane's terminal (a new shell each time), the keyboard staying where it was. A build runs
        /// unseen: the status bar shows it going, and the pane comes up only if it has errors or warnings to show.
        func run(_ entry: RunEntry, focusing: Bool = false) {
            guard view != nil else { return }
            let isBuild = entry.kind == .build
            let existed = runPane != nil
            let pane = ensureBuildPane()
            if isBuild, !existed {
                pane.isHidden = true
                view.needsLayout = true
            }
            GhosttyRuntime.font = (EditorFont.font(12).familyName ?? "JetBrains Mono", EditorFont.size)
            // A build says when it ended, and how, by a file: the shell it is typed into stays.
            let marker = isBuild ? NSTemporaryDirectory() + "frame-build-\(UUID().uuidString).exit" : nil
            let line = marker.map {
                "sh -c " + Runnables.quoted("(" + entry.command + "); echo $? > " + Runnables.quoted($0))
            } ?? entry.command
            let surface = GhosttySurfaceView(launch: TerminalLaunch(
                directory: entry.directory, initialInput: line + "\n", environment: entry.environment
            ))
            surface.onFocus = { [weak self] in self?.terminalFocused() }
            pane.setTerminal(surface, entry: entry) { [weak surface] in surface?.screenText() }
            UserDefaults.standard.set(entry.id, forKey: "frame.lastRun." + workspace)
            if let marker {
                takeBuildProblems([])
                setBuild(running: entry.title)
                watchBuild(pane, marker: marker)
            } else {
                showBuildPane()
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

    /// A build that ends (it says so by a file): what it printed is read, the files it complained of are marked in the
    /// tree, and the pane comes up only when there are errors or warnings (or it failed): on its Problems tab, the
    /// keyboard where it was. A clean build is a line in the status bar and its problems are counts there, clickable.
    func watchBuild(_ pane: BuildPane, marker: String) {
        Task { [weak self, weak pane] in
            for _ in 0 ..< 7200 {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, let pane, runPane === pane else { return }
                guard let text = try? String(contentsOfFile: marker, encoding: .utf8),
                      let code = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
                try? FileManager.default.removeItem(atPath: marker)
                // The terminal has the last of the output a moment after the command is done.
                try? await Task.sleep(for: .milliseconds(300))
                guard let entry = pane.entry else { return }
                takeBuildProblems(Problems.parse(pane.screenText() ?? "", directory: entry.directory))
                let complaints = buildProblems.contains { $0.level == .error || $0.level == .warning }
                if complaints || code != 0 {
                    setBuild(result: code == 0 ? "" : "✗ Build failed", failed: true)
                    showBuildPane()
                    pane.select(complaints ? .problems : .output)
                } else {
                    setBuild(result: "✓ Build succeeded")
                    try? await Task.sleep(for: .seconds(6))
                    if status.buildResult == "✓ Build succeeded" { setBuild() }
                }
                return
            }
        }
    }
}
