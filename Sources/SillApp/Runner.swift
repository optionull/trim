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
            (runnables, configurations, self.file) = (found, saved, file)
            reading = false
            onChange?()
        }
    }

    /// The runnables the branch's touched files are in.
    var touched: [Runnable] {
        let files = app?.stories.story?.touched.map(\.path) ?? []
        guard !files.isEmpty else { return [] }
        return runnables.filter { $0.directory.isEmpty && $0.project == nil ? false : $0.touched(by: files) }
    }

    // MARK: Running

    /// Runs a configuration in a terminal at the bottom, and keeps it as the last run.
    func run(name: String, command: String, directory folder: String) {
        configurations.ran(.init(name: name, command: command, directory: folder))
        let saved = configurations, directory = directory, known = file
        Task.detached { saved.save(known ?? SillFolder.path(for: directory) + "/run.json") }
        onChange?()
        let line = folder.isEmpty ? command : "cd \(Runnables.quoted(folder)) && \(command)"
        app?.run(command: line)
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
        let items: [(String, String, String, String)] = configurations.configurations.map {
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
