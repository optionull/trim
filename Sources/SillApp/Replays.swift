import AppKit
import SillCore
import SillNvim

/// A session replayed from its log (`.sill/sessions`, written by sill's hooks): its prompts in order, what the agent's
/// tools did for each, and each turn's changes, between the worktree's trees at its prompt and its end. Read only:
/// the code is not put back as it was.
@MainActor
final class Replays {
    private weak var app: Workspace?
    private let channel: NvimChannel
    private let directory: String
    private var handled = 0

    /// The session open, by its id, and its log.
    private(set) var session: String?
    private(set) var log: SessionLog?
    private(set) var selected = 0
    /// The selected turn's changes: its files and their diffs, read off the main thread.
    private(set) var files: [Review.File] = []
    private(set) var diffs: [String: Review.Diff] = [:]
    private(set) var reading = false
    /// Why the turn's changes cannot be shown, when they cannot.
    private(set) var missing: String?
    var onChange: (() -> Void)?

    init(app: Workspace, channel: NvimChannel, directory: String) {
        self.app = app
        self.channel = channel
        self.directory = directory
    }

    private var root: String { SillFolder.worktreeRoot(for: directory) ?? directory }
    private var folder: String { SillFolder.path(for: directory) + "/sessions" }

    /// nvim's asks: `:SillReplay` picks a session, `:SillReplay <session>` opens it.
    func update(_ screen: Screen) {
        guard screen.replayAsks.count > handled else { return }
        let asks = screen.replayAsks[handled...]
        handled = screen.replayAsks.count
        for ask in asks {
            if ask.isEmpty { pick() } else { open(ask) }
        }
    }

    /// The sessions logged here, newest first: the id, the title, when it was last written to.
    func sessions() -> [(id: String, title: String, at: Date)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names.filter { $0.hasSuffix(".jsonl") }.compactMap { name in
            let path = folder + "/" + name
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            let at = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ??
                .distantPast
            return (String(name.dropLast(6)), SessionLog(text, root: root).title, at)
        }.sorted { $0.at > $1.at }
    }

    func pick() {
        let sessions = sessions()
        guard !sessions.isEmpty else {
            return Nvim.lua(channel, "vim.notify(...)", [
                .string("No sessions yet: sill's hooks log them (:SillHooks install, or an agent sill starts)"),
                .int(2),
            ])
        }
        Nvim.lua(channel, "require'sill'.pick_replay(...)", [.array(sessions.map { session in
            let when = session.at.formatted(.dateTime.month(.abbreviated).day().hour().minute())
            return .array([.string(session.id), .string("\(session.title)  [\(when)]")])
        })])
    }

    /// Opens session `id`'s replay at its last turn.
    func open(_ id: String) {
        guard let text = try? String(contentsOfFile: folder + "/" + id + ".jsonl", encoding: .utf8) else {
            return Nvim.lua(channel, "vim.notify(...)", [.string("No session \(id) in .sill/sessions"), .int(3)])
        }
        session = id
        log = SessionLog(text, root: root)
        Nvim.lua(channel, "require'sill'.show_pane('replay')")
        select(max((log?.turns.count ?? 1) - 1, 0))
    }

    /// Turn `index`, and its changes read.
    func select(_ index: Int) {
        guard let log, log.turns.indices.contains(index) else { return }
        selected = index
        files = []
        diffs = [:]
        missing = nil
        let turn = log.turns[index]
        // A turn not ended yet (or before trees were logged) ends where the next began, or at the worktree now.
        let next = log.turns.indices.contains(index + 1) ? log.turns[index + 1].before : nil
        guard let before = turn.before else {
            missing = "Its start was not recorded: the session was logged before sill kept trees."
            return onChange?() ?? ()
        }
        reading = true
        onChange?()
        let directory = directory, after = turn.after ?? next
        Task {
            let read = await Task.detached { () -> ([Review.File], [String: Review.Diff], String?) in
                guard let end = after ?? Review.snapshot(in: directory)
                else { return ([], [:], "No worktree to read.") }
                // Trees git has pruned (two weeks unreferenced) are gone.
                guard Review.git(["cat-file", "-e", before], in: directory) != nil,
                      Review.git(["cat-file", "-e", end], in: directory) != nil
                else { return ([], [:], "Its changes are gone: git has pruned the trees.") }
                let files = Review.files(from: before, to: end, in: directory)
                var diffs: [String: Review.Diff] = [:]
                for file in files {
                    diffs[file.path] = Review.diff(file, from: before, to: end, in: directory)
                }
                return (files, diffs, nil)
            }.value
            guard self.selected == index else { return }
            (files, diffs, missing) = read
            reading = false
            onChange?()
        }
    }

    /// Opens a file the turn changed, at its first change, beside the replay.
    func reveal(_ path: String) {
        let line = diffs[path]?.hunks.first?.firstChange ?? 1
        Nvim.lua(channel, "require'sill'.open_beside(...)", [.string(root + "/" + path), .int(Int64(line))])
    }
}
