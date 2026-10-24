import AppKit
import MessagePack
import SillCore
import SillNvim

/// Reviewing what an agent changed (after M9): the worktree against a baseline, file by file and hunk by hunk; a
/// hunk kept, taken back, or commented on, and the comments sent to the agent as one review. Baselines are taken when
/// sill opens, when work is sent to an agent, when an agent's turn ends (its heed session stops working) and on
/// `:SillReview mark`.
@MainActor
final class Reviewer {
    struct Baseline: Equatable {
        var name: String
        var tree: String
        var at: Date
    }

    struct Comment: Equatable {
        var path: String
        var line: Int
        var text: String
        /// The hunk's lines, for the agent to see what the comment is about.
        var excerpt: [String]
    }

    private weak var app: AppDelegate?
    private let channel: NvimChannel
    let directory: String
    private(set) var baselines: [Baseline] = []
    /// The baseline compared against.
    private(set) var selectedBaseline = 0
    private(set) var current: String?
    private(set) var files: [Review.File] = []
    private(set) var selectedFile = 0
    private(set) var diff: Review.Diff?
    /// Hunks kept, by file and hunk header.
    private(set) var kept: Set<String> = []
    private(set) var comments: [Comment] = []
    private(set) var reading = false
    var onChange: (() -> Void)?
    private var handled = 0
    private var working = false

    init(app: AppDelegate, channel: NvimChannel, directory: String) {
        self.app = app
        self.channel = channel
        self.directory = directory
        mark("when sill opened")
    }

    // MARK: Baselines

    /// A baseline now, named for why it was taken.
    func mark(_ name: String) {
        let directory = directory
        // In the order asked: a slow snapshot must not take a later moment's worktree under its own name.
        let previous = marking
        marking = Task {
            await previous?.value
            guard let tree = await Task.detached(operation: { Review.snapshot(in: directory) }).value else { return }
            // The same worktree as the last baseline is not a new one.
            if baselines.last?.tree == tree { return }
            baselines.append(Baseline(name: name, tree: tree, at: Date()))
            if baselines.count > 12 { baselines.removeFirst(baselines.count - 12) }
            changed()
        }
    }

    /// The last baseline being taken: the next waits for it.
    private var marking: Task<Void, Never>?

    /// heed's session here: a turn ends when it stops working.
    func follow(_ session: (state: String, title: String)?) {
        let now = session?.state == "working"
        if working, !now { mark("after the agent's turn") }
        working = now
    }

    /// nvim's asks (`:SillReview`, `:SillReview mark`).
    func update(_ screen: Screen) {
        guard screen.reviewAsks.count > handled else { return }
        for ask in screen.reviewAsks[handled...] {
            if ask == "mark" { mark("marked") } else { refresh() }
        }
        handled = screen.reviewAsks.count
    }

    func select(baseline index: Int) {
        guard baselines.indices.contains(index) else { return }
        selectedBaseline = index
        refresh()
    }

    // MARK: Reading

    /// The worktree now against the selected baseline.
    func refresh() {
        guard !reading else { return }
        let directory = directory
        let base = baselines.indices.contains(selectedBaseline) ? baselines[selectedBaseline].tree : nil
        reading = true
        changed()
        Task {
            let (tree, files) = await Task.detached { () -> (String?, [Review.File]) in
                guard let tree = Review.snapshot(in: directory) else { return (nil, []) }
                return (tree, base.map { Review.files(from: $0, to: tree, in: directory) } ?? [])
            }.value
            current = tree
            self.files = files
            selectedFile = min(selectedFile, max(files.count - 1, 0))
            reading = false
            await readDiff()
        }
    }

    func select(file index: Int) {
        guard files.indices.contains(index) else { return }
        selectedFile = index
        Task { await readDiff() }
    }

    private func readDiff() async {
        guard let base = baseline?.tree, let current, files.indices.contains(selectedFile) else {
            diff = nil
            return changed()
        }
        let path = files[selectedFile].path, directory = directory
        diff = await Task.detached { Review.diff(path, from: base, to: current, in: directory) }.value
        changed()
    }

    var baseline: Baseline? { baselines.indices.contains(selectedBaseline) ? baselines[selectedBaseline] : nil }
    var file: Review.File? { files.indices.contains(selectedFile) ? files[selectedFile] : nil }

    // MARK: Hunks

    func key(_ hunk: Review.Hunk) -> String { (file?.path ?? "") + hunk.header }

    func keep(_ hunk: Review.Hunk) {
        kept.insert(key(hunk))
        changed()
    }

    /// Takes the hunk back in the file, then reads again; open buffers read the file again.
    func reject(_ hunk: Review.Hunk) {
        guard let diff else { return }
        let directory = directory
        Task {
            let done = await Task.detached { Review.reject(hunk, of: diff, in: directory) }.value
            if !done {
                Nvim.lua(channel, "vim.notify(...)", [
                    .string("That change no longer applies: the file changed since. Refresh shows it as it is."),
                    .int(3),
                ])
            }
            _ = try? await channel.lua("vim.cmd('silent! checktime')")
            refresh()
        }
    }

    /// A comment on a hunk, for the review sent to the agent.
    func comment(_ hunk: Review.Hunk, _ text: String) {
        guard let file, !text.isEmpty else { return }
        comments.append(Comment(path: file.path, line: hunk.firstChange, text: text, excerpt: hunk.lines))
        changed()
    }

    /// Asks the person for a comment on the hunk.
    func askComment(_ hunk: Review.Hunk) {
        let alert = NSAlert()
        alert.messageText = "Comment on \(file?.path ?? ""):\(hunk.firstChange)"
        alert.informativeText = "Goes to the agent with the other comments when you send the review."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn { comment(hunk, field.stringValue) }
    }

    /// The review as an agent reads it: each comment with where it is and the change it is about.
    func reviewText() -> String {
        var lines = ["Review of your changes since \(baseline?.name ?? "the baseline"): \(comments.count) comment" +
            (comments.count == 1 ? "" : "s") + ". Address each, then say what you changed."]
        for comment in comments {
            lines.append("")
            lines.append("\(comment.path):\(comment.line): \(comment.text)")
            lines.append(contentsOf: comment.excerpt.prefix(12).map { "    " + $0 })
        }
        return lines.joined(separator: "\n")
    }

    /// The comments to the agent working here (through heed, or a new agent in a pane), and cleared.
    func sendReview() {
        guard !comments.isEmpty, let agents = app?.agents else { return }
        agents.send(headline: "Review: \(comments.count) comment\(comments.count == 1 ? "" : "s")", reviewText())
        sentReviews += 1
        // Sending marks a baseline (as all work sent to an agent does): what it does about the review is reviewed next.
        comments = []
        changed()
    }

    /// Reviews sent, for the self-check.
    private(set) var sentReviews = 0

    /// The baseline's file beside the current one in nvim's diff mode, to read it whole and edit.
    func openSideBySide() {
        guard let file, let base = baseline?.tree else { return }
        let directory = directory
        Task {
            let text = await Task.detached { Review.text(of: file.path, in: base, directory: directory) }.value
            let copy = NSTemporaryDirectory() + "sill-review-\(UUID().uuidString)-" + (file.path as NSString)
                .lastPathComponent
            try? text.write(toFile: copy, atomically: true, encoding: .utf8)
            let path = (directory as NSString).appendingPathComponent(file.path)
            Nvim.lua(channel, "vim.cmd('tabnew'); require('sill.merge').diff(...)", [.string(copy), .string(path)])
        }
    }

    private func changed() { onChange?() }
}
