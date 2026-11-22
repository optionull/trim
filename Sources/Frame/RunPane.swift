import AppKit
import FrameModes
import FrameRun
import SillEditor
#if SILL_GHOSTTY
    import SillTerminal
#endif

/// Where the terminal pane goes: beside the code when the window is wide, under it when it is not.
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

    /// What a run or build shows in: a header with what runs, over a real terminal (libghostty) that stays after the
    /// command ends, so the output can be read, scrolled and the shell used.
    final class RunPane: NSView {
        let entry: RunEntry
        let surface: GhosttySurfaceView
        var look: TreeLook {
            didSet { needsDisplay = true }
        }

        static let headerHeight: CGFloat = 30

        init(entry: RunEntry, look: TreeLook) {
            self.entry = entry
            self.look = look
            GhosttyRuntime.font = (EditorFont.font(12).familyName ?? "JetBrains Mono", EditorFont.size)
            surface = GhosttySurfaceView(launch: TerminalLaunch(
                directory: entry.directory, initialInput: entry.command + "\n", environment: entry.environment
            ))
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = 10
            layer?.masksToBounds = true
            addSubview(surface)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) { fatalError("not used") }

        override var isFlipped: Bool { true }

        override func layout() {
            super.layout()
            surface.frame = NSRect(
                x: 0, y: Self.headerHeight, width: bounds.width, height: max(0, bounds.height - Self.headerHeight)
            )
        }

        override func draw(_: NSRect) {
            look.island.setFill()
            bounds.fill()
            let title = NSAttributedString(string: entry.title, attributes: [
                .font: look.boldFont, .foregroundColor: look.text,
            ])
            let detail = NSAttributedString(string: "  " + entry.command, attributes: [
                .font: look.smallFont, .foregroundColor: look.muted,
            ])
            let line = NSMutableAttributedString(attributedString: title)
            line.append(detail)
            line.draw(
                with: NSRect(x: 14, y: 7, width: bounds.width - 28, height: Self.headerHeight - 8),
                options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin]
            )
        }
    }

    extension FrameWindowController {
        /// Runs `entry` in the terminal pane (a new shell each time), the keyboard staying where it was.
        func run(_ entry: RunEntry, focusing: Bool = false) {
            guard view != nil else { return }
            let pane = RunPane(entry: entry, look: tree.look)
            pane.surface.onFocus = { [weak self] in self?.terminalFocused() }
            showRunPane(pane)
            UserDefaults.standard.set(entry.id, forKey: "frame.lastRun." + workspace)
            if entry.kind == .build { watchBuild(pane) }
            if focusing { focus(.terminal) }
        }

        /// What the pane's output says is wrong: errors and warnings, as a mode; Return opens the file at the line.
        @objc func showProblems(_: Any?) {
            guard listPicker == nil else { return }
            guard let pane = runPane, let text = pane.surface.screenText() else {
                return notify("Frame: run or build something first; its problems are read from the terminal pane")
            }
            let problems = Problems.parse(text, directory: pane.entry.directory)
            guard !problems.isEmpty else { return notify("Frame: no errors or warnings in the terminal pane") }
            let root = pane.entry.directory
            let items = problems.map { problem in
                PickerItem(
                    id: "\(problem.path)\t\(problem.line)", title: problem.message,
                    detail: Self.relative(problem.path, to: root) + ":\(problem.line)",
                    glyph: problem.severity == .error ? "\u{f057}" : "\u{f071}",
                    subtitle: problem.code, file: (problem.path as NSString).lastPathComponent
                )
            }
            let errors = problems.count(where: { $0.severity == .error })
            showList(
                title: "Problems (\(errors) errors, \(problems.count - errors) warnings)", items: items, current: nil,
                onChoose: { [weak self] item in
                    let parts = item.id.split(separator: "\t").map(String.init)
                    self?.open(file: parts[0], toEditor: true, line: parts.count > 1 ? Int(parts[1]) : nil)
                }
            )
        }

        static func relative(_ path: String, to root: String) -> String {
            path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
        }

        func notify(_ message: String) {
            Task { [session] in
                _ = try? await session.channel.lua("vim.notify(..., vim.log.levels.INFO)", args: [.string(message)])
            }
        }

        /// A build that has gone quiet: said how it went, once, so the problems are one key away.
        func watchBuild(_ pane: RunPane) {
            Task { [weak self, weak pane] in
                var last = "", quiet = 0
                for _ in 0 ..< 600 {
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, let pane, runPane === pane, let text = pane.surface.screenText() else { return }
                    quiet = text == last ? quiet + 1 : 0
                    last = text
                    guard quiet == 2 else { continue }
                    let problems = Problems.parse(text, directory: pane.entry.directory)
                    let errors = problems.count(where: { $0.severity == .error })
                    notify(problems.isEmpty
                        ? "Frame: \(pane.entry.title) is quiet, no problems found"
                        :
                        "Frame: \(pane.entry.title): \(errors) errors, \(problems.count - errors) warnings (⇧⌘M lists them)")
                    return
                }
            }
        }

        func showRunPane(_ pane: RunPane) {
            runPane?.removeFromSuperview()
            runPane = pane
            view.terminal = pane
        }

        func hideTerminal() {
            guard let pane = runPane else { return }
            runPane = nil
            let wasFocused = modes.surface == .terminal
            view.terminal = nil
            pane.removeFromSuperview()
            terminalGone()
            if wasFocused { focusEditor() }
        }

        /// ⌘J: show the pane (or take the keyboard to it); from the pane, back to the code.
        @objc func toggleTerminal(_: Any?) {
            guard runPane != nil else { return showRunPicker(nil) }
            if modes.surface == .terminal { return focusEditor() }
            focus(.terminal)
        }

        @objc func closeTerminal(_: Any?) { hideTerminal() }

        func entries() -> [RunEntry] { RunEntries.find(in: workspace) }

        /// What F5 runs: what was run last here, else the default build task's opposite (a launch configuration, a
        /// program), else the first program; nothing found is a picker.
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
    }

#else

    extension FrameWindowController {
        @objc func toggleTerminal(_: Any?) { noTerminal() }
        @objc func closeTerminal(_: Any?) {}
        @objc func showProblems(_: Any?) { noTerminal() }
        @objc func runDefault(_: Any?) { noTerminal() }
        @objc func buildDefault(_: Any?) { noTerminal() }
        @objc func showRunPicker(_: Any?) { noTerminal() }
        private func noTerminal() {
            Task {
                _ = try? await session.channel
                    .lua(
                        "vim.notify('Frame was built without its terminal (GhosttyKit): run `mise run ghostty`', vim.log.levels.WARN)"
                    )
            }
        }
    }

#endif
