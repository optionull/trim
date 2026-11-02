import AppKit
import MessagePack
import SillCore
import SillEditor
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
        /// Kept first and never dropped for newer ones: where a pull request's branch left its base.
        var pinned = false
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
    /// `joining`: a moment that matters even when nothing changed (a plan approved) joins the last baseline's name
    /// then, rather than being dropped.
    /// `then` gets the worktree's tree, a new baseline or not: a session's log keeps it for its replay.
    func mark(_ name: String, joining: Bool = false, then: (@MainActor (String) -> Void)? = nil) {
        let directory = directory
        // In the order asked: a slow snapshot must not take a later moment's worktree under its own name.
        let previous = marking
        marking = Task {
            await previous?.value
            guard let tree = await Task.detached(operation: { Review.snapshot(in: directory) }).value else { return }
            then?(tree)
            // The same worktree as the last baseline is not a new one.
            if baselines.last?.tree == tree {
                if joining, let last = baselines.last, !last.name.contains(name) {
                    baselines[baselines.count - 1].name = last.name + " · " + name
                    changed()
                }
                return
            }
            baselines.append(Baseline(name: name, tree: tree, at: Date()))
            // The oldest go, a pinned one stays.
            while baselines.count > 12, let oldest = baselines.firstIndex(where: { !$0.pinned }) {
                baselines.remove(at: oldest)
                if selectedBaseline > oldest { selectedBaseline -= 1 }
            }
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

    /// A baseline that stays (a pull request's base), first and selected: it replaces the one pinned before.
    func pin(_ name: String, tree: String) {
        baselines.removeAll { $0.pinned }
        baselines.insert(Baseline(name: name, tree: tree, at: Date(), pinned: true), at: 0)
        selectedBaseline = 0
        refresh()
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

    // MARK: A walkthrough of the changes

    /// The last walkthrough asked for: where the agent is to write it.
    private(set) var walkthroughAsked: String?

    /// Asks the agent for a walkthrough of the changes since the baseline: a throwaway notebook (inside the
    /// repository's .sill, never committed) that goes through them at a high level, their diffs, and examples of what
    /// changed as isolated scripts it can run.
    func askForWalkthrough() {
        guard let base = baseline, let agents = app?.agents else { return }
        let directory = directory
        Task {
            // .sill first: kept out of git before the snapshot, so the walkthrough is never part of a change.
            let (sill, now, files) = await Task.detached { () -> (String, String?, [Review.File]) in
                let sill = SillFolder.path(for: directory)
                let now = Review.snapshot(in: directory)
                return (sill, now, now.map { Review.files(from: base.tree, to: $0, in: directory) } ?? [])
            }.value
            guard let now else { return }
            let stamp = Date()
                .formatted(.iso8601.year().month().day().dateSeparator(.omitted).time(includingFractionalSeconds: false)
                    .timeSeparator(.omitted)).replacingOccurrences(of: "T", with: "-").replacingOccurrences(
                    of: "Z",
                    with: ""
                )
            let folder = sill + "/reviews/" + stamp
            try? FileManager.default.createDirectory(atPath: folder + "/examples", withIntermediateDirectories: true)
            let path = folder + "/review.walk.md"
            walkthroughAsked = path
            let list = Review.outline(files) + (files.count > 60 ? "\n(`git diff --stat` for every file)" : "")
            let worktree = SillFolder.worktreeRoot(for: directory) ?? directory
            agents.send(headline: "Write a review walkthrough of the changes since \(base.name)", """
            Write a walkthrough of the changes made since \(base
                .name), for the person to review them: what changed and \
            why it matters, at a high level, in the order a reviewer should read it, one section per idea (not per file).

            The changes are `git diff \(base.tree) \(now)` in \(directory) (git trees of the worktree then and now):
            \(list)

            Follow the sill-walkthrough skill's review form. Write \(path) with `base: \(base.tree)` and \
            `worktree: \(worktree)` in its front \
            matter; show the part of a change a section is about with `@diff <path from the repository's root>`, code \
            it relates to with `@code Symbol`, and usage examples of what changed as isolated scripts in \
            \(folder)/examples, each printing what it shows, referenced with `@example examples/<file>`: for C# a .NET \
            10 file-based app (`#:project <the .csproj's absolute path>` at its top, run with `dotnet run file.cs`); \
            TypeScript a .ts file node runs; Python a script with PEP 723 metadata; Rust cargo's script format (a \
            `---cargo` manifest at its top); Swift a script. Reach the code under review by absolute paths in \
            \(worktree): the folder the walkthrough is in is shared by every worktree of the repository. It is a \
            throwaway for this review: keep it short.

            Then call sill's walkthrough_check with its path (it runs the examples), fix what it reports, and call \
            walkthrough_open.
            """)
        }
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
