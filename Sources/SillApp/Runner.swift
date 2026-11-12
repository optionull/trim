import AppKit
import SillCore
import SillNvim

/// Running what a checkout has: its runnables (found from its project files off the main thread), and the
/// configurations the person ran, their command lines as altered, kept in the repository's `.sill/run.json`. ⌘R runs
/// the last again; ⇧⌘R picks one and lets its command line be changed first; the Run pane lists them, those the
/// branch touched first, with Debug and Profile where sill has them (.NET; Profile for Cargo and Swift too).
@MainActor
final class Runner {
    private weak var app: Workspace?
    private let channel: NvimChannel
    let directory: String
    private var handled = 0
    private(set) var runnables: [Runnable] = []
    private(set) var configurations = RunConfigurations()
    private(set) var reading = false
    var onChange: (() -> Void)?

    init(app: Workspace, channel: NvimChannel, directory: String) {
        self.app = app
        self.channel = channel
        self.directory = directory
    }

    /// The repository's `.sill/run.json`, found off the main thread (git says where) when they are first read.
    private var file: String?

    /// Finds them again, and the configurations.
    func refresh() {
        guard !reading else { return }
        reading = true
        let directory = directory
        Task {
            let (found, saved, file) = await Task.detached {
                let file = SillFolder.path(for: directory) + "/run.json"
                return (Runnables.find(in: directory), RunConfigurations.load(file), file)
            }.value
            // A run started while the file was read is newer than the file: kept.
            (runnables, configurations, self.file) = (found, saved.merged(with: configurations), file)
            reading = false
            onChange?()
            readResults()
        }
    }

    /// What the newest handoff offers to run.
    var fromAgent: [HandoffFile.Run] { app?.stories?.handoffRuns ?? [] }

    /// The title of the newest handoff, whose runs those are.
    var handoffTitle: String? { app?.stories?.walkthroughs.first { $0.kind == "handoff" }?.title }

    /// The runnables the branch's touched files are in.
    var touched: [Runnable] {
        let files = app?.stories.story?.touched.map(\.path) ?? []
        guard !files.isEmpty else { return [] }
        return runnables.filter { $0.directory.isEmpty && $0.project == nil ? false : $0.touched(by: files) }
    }

    // MARK: Running

    /// Runs a configuration in a terminal at the bottom, and keeps it as the last run. It runs through a script in
    /// `.sill/runs` that writes how it ended (`RunScript`), which the Run pane and the summary show.
    func run(name: String, command: String, directory folder: String) {
        configurations.ran(.init(name: name, command: command, directory: folder))
        let saved = configurations, directory = directory, known = file
        running[Self.key(name, folder)] = (name, folder)
        results[Self.key(name, folder)] = nil
        onChange?()
        Task {
            let line = await Task.detached { () -> String in
                let file = known ?? SillFolder.path(for: directory) + "/run.json"
                saved.save(file)
                let runs = (file as NSString).deletingLastPathComponent + "/runs"
                try? FileManager.default.createDirectory(atPath: runs, withIntermediateDirectories: true)
                let (script, result) = RunScript.paths(name: name, directory: folder, in: runs)
                try? FileManager.default.removeItem(atPath: result)
                let text = RunScript.script(command: command, folder: folder, result: result)
                guard (try? text.write(toFile: script, atomically: true, encoding: .utf8)) != nil else {
                    return folder.isEmpty ? command : "cd \(Runnables.quoted(folder)) && \(command)"
                }
                return RunScript.line(script: script)
            }.value
            app?.run(command: line)
            watch()
        }
    }

    // MARK: How runs ended

    /// How each run last ended, by name and folder.
    private(set) var results: [String: RunScript.Result] = [:]
    /// The runs started and not ended yet, by key: their name and folder.
    private(set) var running: [String: (name: String, folder: String)] = [:]
    private var watching: Task<Void, Never>?

    nonisolated static func key(_ name: String, _ folder: String) -> String { name + "|" + folder }

    /// How a run of this name and folder last ended, if sill saw it end.
    func result(_ name: String, _ folder: String = "") -> RunScript.Result? { results[Self.key(name, folder)] }

    func isRunning(_ name: String, _ folder: String = "") -> Bool { running[Self.key(name, folder)] != nil }

    /// Reads every kept configuration's result, off the main thread.
    func readResults() {
        // The kept ones, and those running (a run is looked for whatever the configurations say).
        var seen: Set<String> = []
        let names = (configurations.configurations.map { ($0.name, $0.directory) } + running.values.map { (
            $0.name,
            $0.folder
        ) })
        .filter {
            seen
                .insert(Self
                    .key(
                        $0.0,
                        $0.1
                    )).inserted
        }
        let directory = directory, known = file
        Task {
            let read = await Task.detached { () -> [String: RunScript.Result] in
                let runs = ((known ?? SillFolder.path(for: directory) + "/run.json") as NSString)
                    .deletingLastPathComponent + "/runs"
                var read: [String: RunScript.Result] = [:]
                for (name, folder) in names {
                    if let result = RunScript.result(RunScript.paths(name: name, directory: folder, in: runs).result) {
                        read[Self.key(name, folder)] = result
                    }
                }
                return read
            }.value
            var changed = false
            for (key, result) in read where results[key] != result {
                results[key] = result
                running[key] = nil
                changed = true
            }
            if changed { onChange?() }
        }
    }

    /// While something runs: its result looked for every two seconds (a small file each), until none is left, or for
    /// two hours (a run stopped with ⌃C writes nothing; it is then no longer shown as running).
    private func watch() {
        guard watching == nil else { return }
        watching = Task { [weak self] in
            for _ in 0 ..< 3600 {
                guard let self, !self.running.isEmpty, !Task.isCancelled else { break }
                try? await Task.sleep(for: .seconds(2))
                readResults()
            }
            self?.running = [:]
            self?.watching = nil
            self?.onChange?()
        }
    }

    func run(_ runnable: Runnable) { run(name: runnable.name, command: runnable.command, directory: runnable.directory)
    }

    /// ⌘R: the last run again; none yet, a choice.
    func rerun() {
        guard let last = configurations.last else { return pick() }
        run(name: last.name, command: last.command, directory: last.directory)
    }

    /// ⇧⌘R: a choice of what was run (the last first) and everything else (what the branch touched first), then its
    /// command line, to change before it runs.
    func pick() {
        let configured = Set(configurations.configurations.map { "\($0.name)|\($0.directory)" })
        let others = (touched + runnables).filter { !configured.contains("\($0.name)|\($0.directory)") }
        var seen: Set<String> = []
        let items: [(String, String, String, String)] = fromAgent.map {
            ($0.name, "", $0.command, "★ " + $0.name + "  ·  from the agent")
        } + configurations.configurations.map {
            ($0.name, $0.directory, $0.command, "↻ " + $0.name)
        } + others.filter { seen.insert("\($0.name)|\($0.directory)").inserted }.map {
            ($0.name, $0.directory, $0.command, $0.name + (touched.contains($0) ? "  ·  touched" : ""))
        }
        guard !items.isEmpty else {
            return Nvim.lua(channel, "vim.notify(...)", [.string("Nothing to run here that sill found."), .int(2)])
        }
        Nvim.lua(channel, "require'sill'.pick_run(...)", [.array(items.map { item in
            .array([.string(item.0), .string(item.1), .string(item.2), .string(item.3 + "    " + item.2)])
        })])
    }

    /// One to change first: its command line asked for, then run.
    func alter(_ runnable: Runnable) {
        Nvim.lua(channel, "require'sill'.alter_run(...)", [
            .string(runnable.name), .string(runnable.directory), .string(runnable.command),
        ])
    }

    /// nvim's asks: `:SillRun` (a choice), and a choice made with its command line.
    func update(_ screen: Screen) {
        guard screen.runAsks.count > handled else { return }
        let asks = screen.runAsks[handled...]
        handled = screen.runAsks.count
        for ask in asks {
            if let name = ask.name, let command = ask.command {
                run(name: name, command: command, directory: ask.directory ?? "")
            } else {
                pick()
            }
        }
    }

    func debug(_ runnable: Runnable) {
        guard runnable.debuggable, let project = runnable.project else { return }
        app?.debugger.debug(project: directory + "/" + project)
    }

    func profile(_ runnable: Runnable) {
        guard runnable.profilable else { return }
        app?.profiler.start(project: runnable.project.map { directory + "/" + $0 })
    }

    func show() {
        Nvim.lua(channel, "require'sill'.show_pane('run')")
        refresh()
    }
}
