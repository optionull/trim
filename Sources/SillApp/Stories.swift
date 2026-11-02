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
            let (story, walkthroughs, agent) = await Task.detached { () -> (
                Story,
                [CheckoutState.Prepared],
                AgentActivity?
            ) in
                let repository = SillFolder.mainRoot(for: directory) ?? directory
                let checkout = Checkout(
                    path: directory,
                    repository: realPath(repository),
                    isWorktree: realPath(repository) != directory
                )
                return (
                    Story.read(directory, transcripts: HomeModel.transcripts),
                    CheckoutState.prepared(for: checkout),
                    AgentActivity.read(cwd: directory, transcripts: HomeModel.transcripts)
                )
            }.value
            (self.story, self.walkthroughs, self.agent) = (story, walkthroughs, agent)
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
