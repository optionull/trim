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
            // The command is the pane's own process, its line printed first (dimmed) so it reads as in a shell, and the
            // pane stays when it ends. Nothing is typed: a build says how it ended by a file the script writes.
            let marker = isBuild ? NSTemporaryDirectory() + "frame-build-\(UUID().uuidString).exit" : nil
            var script = "printf '\\033[2m❯ %s\\033[0m\\n' " + Runnables.quoted(entry.command) + "; "
            if let marker {
                // A build yields to the editor: at a lower priority (it and what it starts take every core they are
                // given).
                script += "(/usr/bin/nice -n 10 /bin/sh -c " + Runnables.quoted(entry.command) + "); c=$?; echo $c > "
                    + Runnables.quoted(marker) + "; exit $c"
            } else {
                script += entry.command
            }
            let surface = GhosttySurfaceView(launch: TerminalLaunch(
                directory: entry.directory, command: "/bin/sh -c " + Runnables.quoted(script),
                environment: entry.environment, waitAfterCommand: true
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
        if pane.isHidden {
            showBuildPane()
            return focus(.terminal)
        }
        if modes.surface == .terminal { return focusEditor() }
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

    /// A build says it has ended, and its exit code, by a file: then what it printed is read (off the main thread), the
    /// files it complained of are marked in the tree, and the pane comes up only when there are errors or warnings (or
    /// it
    /// failed): on its Problems tab, the keyboard where it was. A clean build is a line in the status bar and its
    /// problems are counts there, clickable.
    func watchBuild(_ pane: BuildPane, marker: String) {
        Task { [weak self, weak pane] in
            for _ in 0 ..< 7200 {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, let pane, runPane === pane else { return }
                guard let text = try? String(contentsOfFile: marker, encoding: .utf8),
                      let code = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
                try? FileManager.default.removeItem(atPath: marker)
                buildEnded(pane, code: code)
                return
            }
        }
    }

    func buildEnded(_ pane: BuildPane, code: Int) {
        Task { [weak self, weak pane] in
            // The terminal has the last of the output a moment after the command is done.
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, let pane, runPane === pane, let entry = pane.entry else { return }
            let text = pane.screenText() ?? "", directory = entry.directory
            let problems = await Task.detached { Problems.parse(text, directory: directory) }.value
            guard runPane === pane else { return }
            takeBuildProblems(problems)
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
        }
    }
}
