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
    private(set) var reading = false
    private var again = false
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
        let directory = directory
        Task {
            let (story, walkthroughs, agent, runs) = await Task.detached {
                let repository = SillFolder.mainRoot(for: directory) ?? directory
                let checkout = Checkout(
                    path: directory, repository: realPath(repository), isWorktree: realPath(repository) != directory
                )
                let walkthroughs = CheckoutState.prepared(for: checkout)
                let runs = walkthroughs.first { $0.kind == "handoff" }
                    .flatMap { try? String(contentsOfFile: $0.path, encoding: .utf8) }
                    .map { HandoffFile.runs(in: Walkthrough($0)) } ?? []
                return (
                    Story.read(directory, transcripts: HomeModel.transcripts), walkthroughs,
                    AgentActivity.read(cwd: directory, transcripts: HomeModel.transcripts), runs
                )
            }.value
            (self.story, self.walkthroughs, self.agent, handoffRuns) = (story, walkthroughs, agent, runs)
            reading = false
            onChange?()
            if again {
                again = false
                refresh()
            }
        }
    }

    /// The newest walkthrough not seen yet.
    var unseen: CheckoutState.Prepared? { walkthroughs.first { !$0.seen } }

    func show() {
        Nvim.lua(channel, "require'sill'.show_pane('summary')")
        refresh()
    }
}
