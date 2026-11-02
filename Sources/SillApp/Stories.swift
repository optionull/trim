import AppKit
import SillCore
import SillNvim

/// What happened in the checkout a workspace has open, for its summary and its touched files: the story (the branch's
/// base, the files touched since, the commits, the prompts) and the walkthroughs agents prepared for it, seen or not.
/// Read off the main thread when the workspace opens, when its window comes to the front, and after an agent's turn.
@MainActor
final class Stories {
    private let channel: NvimChannel
    let directory: String
    private(set) var story: Story?
    private(set) var walkthroughs: [CheckoutState.Prepared] = []
    private(set) var agent: AgentActivity?
    /// What the newest handoff offers to run.
    private(set) var handoffRuns: [HandoffFile.Run] = []
    /// What is new since the person last looked here (Looked's point).
    private(set) var since: Since?
    private(set) var reading = false
    private var again = false
    private var returning = false

    struct Since {
        var point: Looked.Point
        /// Changed since, the worktree as it is.
        var files: [Review.File]
        var prompts: Int
        var commits: Int
    }

    var onChange: (() -> Void)?

    init(channel: NvimChannel, directory: String) {
        self.channel = channel
        self.directory = directory
    }

    /// Reads it again; asked while reading, once more after.
    func refresh() {
        guard !reading else {
            again = true
            return
        }
        reading = true
        let directory = directory, returning = returning
        self.returning = false
        Task {
            let (story, walkthroughs, agent, runs, since) = await Task.detached {
                let repository = SillFolder.mainRoot(for: directory) ?? directory
                let checkout = Checkout(
                    path: directory, repository: realPath(repository), isWorktree: realPath(repository) != directory
                )
                let walkthroughs = CheckoutState.prepared(for: checkout)
                let runs = walkthroughs.first { $0.kind == "handoff" }
                    .flatMap { try? String(contentsOfFile: $0.path, encoding: .utf8) }
                    .map { HandoffFile.runs(in: Walkthrough($0)) } ?? []
                let story = Story.read(directory, transcripts: HomeModel.transcripts)
                return (
                    story, walkthroughs, AgentActivity.read(cwd: directory, transcripts: HomeModel.transcripts), runs,
                    Self.since(directory, story: story, returning: returning)
                )
            }.value
            (self.story, self.walkthroughs, self.agent, handoffRuns, self.since) = (
                story,
                walkthroughs,
                agent,
                runs,
                since
            )
            reading = false
            onChange?()
            if again {
                again = false
                refresh()
            }
        }
    }

    /// Back at it (the workspace opened, sill in front again): the last leaving may become the point.
    func returned() {
        returning = true
        refresh()
    }

    /// What changed since the point: the files (the worktree now against the tree then), the prompts and commits
    /// after it. Nil before a first leaving, or when git no longer has that tree.
    private nonisolated static func since(_ directory: String, story: Story, returning: Bool) -> Since? {
        let checkout = SillFolder.worktreeRoot(for: directory) ?? directory
        let sill = SillFolder.path(for: directory)
        let point = returning ? Looked.returned(sill, checkout: checkout) : Looked.point(sill, checkout: checkout)
        guard let point, Review.git(["cat-file", "-e", point.tree + "^{tree}"], in: directory) != nil,
              let now = Review.snapshot(in: directory) else { return nil }
        return Since(
            point: point,
            files: Review.files(from: point.tree, to: now, in: directory),
            prompts: story.prompts.count { ($0.at ?? .distantPast) > point.at },
            commits: story.commits.count { $0.at > point.at }
        )
    }

    /// Left it (sill no longer in front, the window closed): the worktree now noted, off the main thread.
    nonisolated static func left(_ directory: String) {
        let checkout = SillFolder.worktreeRoot(for: directory) ?? directory
        guard let tree = Review.snapshot(in: directory) else { return }
        Looked.left(SillFolder.path(for: directory), checkout: checkout, tree: tree)
    }

    /// The newest walkthrough not seen yet.
    var unseen: CheckoutState.Prepared? { walkthroughs.first { !$0.seen } }

    func show() {
        Nvim.lua(channel, "require'sill'.show_pane('summary')")
        refresh()
    }
}
