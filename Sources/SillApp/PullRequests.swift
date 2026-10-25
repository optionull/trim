import AppKit
import SillCore
import SillNvim

/// The pull requests of the worktree's branch, read with `gh` (never written to): what the status bar says, what the
/// PR pane shows, and what an agent is told. Read when sill starts, when its window comes to the front, every two
/// minutes while it is, and after an agent's turn (it may have pushed).
@MainActor
final class PullRequests {
    private weak var app: AppDelegate?
    private let channel: NvimChannel
    private let directory: String
    private var handled = 0
    private var timer: Timer?

    /// The branch's pull requests, newest first, and the worktree beside them.
    private(set) var all: [PullRequest] = []
    private(set) var branch: PullRequest.Branch?
    /// Why there are none to show: no gh, not signed in, no branch.
    private(set) var problem: String?
    private(set) var reading = false
    private(set) var readAt: Date?
    var onChange: (() -> Void)?

    /// The one that matters: the newest open one, else the newest.
    var current: PullRequest? { all.first { $0.state == "OPEN" } ?? all.first }

    init(app: AppDelegate, channel: NvimChannel, directory: String) {
        self.app = app
        self.channel = channel
        self.directory = directory
    }

    func start() {
        refresh()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if NSApp.isActive { self?.refresh() } }
        }
    }

    /// `:SillPR`: the pane, read again.
    func update(_ screen: Screen) {
        guard screen.pullRequestAsks > handled else { return }
        handled = screen.pullRequestAsks
        show()
    }

    func show() {
        Nvim.lua(channel, "require'sill'.show_pane('pr')")
        refresh()
    }

    /// Reads them again, off the main thread; one read at a time.
    func refresh() {
        guard !reading else { return }
        reading = true
        onChange?()
        let directory = directory
        Task {
            let (prs, branch, problem) = await Task.detached { Self.read(in: directory) }.value
            (all, self.branch, self.problem) = (prs, branch, problem)
            reading = false
            readAt = Date()
            onChange?()
        }
    }

    /// Read now, for an agent that asks: the text, once read.
    func readNow() async -> String {
        let directory = directory
        let (prs, branch, problem) = await Task.detached { Self.read(in: directory) }.value
        (all, self.branch, self.problem) = (prs, branch, problem)
        readAt = Date()
        onChange?()
        return text
    }

    /// The pull request in a line or two for a prompt: what needs attention and what it waits for; nil without one
    /// or when all is fine.
    var summary: String? {
        guard let current, current.state == "OPEN" else { return nil }
        let pressing = current.insights(branch).filter { $0.level != .fine }.map(\.text)
        guard !pressing.isEmpty else { return nil }
        return "#\(current.number) (\(current.url)): " + pressing.joined(separator: "; ")
    }

    /// The branch, its pull requests by gh, and how the worktree stands beside them.
    nonisolated static func read(in directory: String) -> ([PullRequest], PullRequest.Branch?, String?) {
        func git(_ arguments: [String]) -> String? {
            Review.git(arguments, in: directory)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let name = git(["rev-parse", "--abbrev-ref", "HEAD"]), name != "HEAD" else {
            return ([], nil, "Not on a branch.")
        }
        var branch = PullRequest.Branch(name: name)
        branch.uncommitted = (git(["status", "--porcelain"]) ?? "").split(separator: "\n").count
        branch.unpushed = Int(git(["rev-list", "--count", "@{upstream}..HEAD"]) ?? "") ?? 0
        let (status, output) = gh([
            "pr", "list", "--head", name, "--state", "all", "--limit", "5", "--json",
            "number,title,url,state,isDraft,baseRefName,mergeable,reviewDecision,statusCheckRollup,latestReviews," +
                "comments,updatedAt",
        ], in: directory)
        guard status == 0 else {
            return (
                [],
                branch,
                status == 127 ? "gh is not installed: brew install gh" :
                    "gh could not read the pull requests: \(String(decoding: output, as: UTF8.self).prefix(200))"
            )
        }
        let prs = PullRequest.parse(output)
        if let base = (prs.first { $0.state == "OPEN" } ?? prs.first)?.base, !base.isEmpty {
            branch.behind = Int(git(["rev-list", "--count", "HEAD..origin/\(base)"]) ?? "") ?? 0
        }
        return (prs, branch, nil)
    }

    /// gh as the person's shell finds it (`SILL_GH` for the checks): its status and output.
    nonisolated static func gh(_ arguments: [String], in directory: String) -> (Int32, Data) {
        let process = Process()
        let environment = NvimProcess.cachedEnv.merging(ProcessInfo.processInfo.environment) { shell, _ in shell }
        if let stub = ProcessInfo.processInfo.environment["SILL_GH"] {
            process.executableURL = URL(fileURLWithPath: stub)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["gh"] + arguments
        }
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = environment.merging(["GH_PROMPT_DISABLED": "1", "NO_COLOR": "1"]) { _, new in new }
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        guard (try? process.run()) != nil else { return (127, Data()) }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let failure = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, process.terminationStatus == 0 ? data : failure)
    }

    /// The status bar's word on it: the number and the most pressing thing, and how pressing.
    var label: (text: String, level: PullRequest.Insight.Level)? {
        guard let current else { return nil }
        return (current.label(branch), current.insights(branch).first?.level ?? .fine)
    }

    /// For an agent: the pull request, or why there is none.
    var text: String {
        if let current { return current.text(branch) }
        return problem ?? "No pull request for the branch \(branch?.name ?? "") yet."
    }

    /// Hands what needs doing to the agent: the failing checks, the reviews, the branch.
    func sendToAgent() {
        guard let current else { return }
        app?.agents.send(
            headline: "Pull request #\(current.number): see to what it needs",
            text + "\n\nLook into what needs attention above (the failing checks' logs: gh run view --log-failed), " +
                "fix it here, and push."
        )
    }

    /// The pull request's changes in the Review pane: the worktree against where its branch left its base (as of the
    /// last fetch), pinned as a baseline. Comments go to the agent, as any review's do.
    func review() {
        pinBase { [weak self] in
            guard let self else { return }
            Nvim.lua(channel, "require'sill'.show_pane('review')")
        }
    }

    /// A walkthrough of the pull request's changes, from the agent: the review walkthrough, from its base.
    func walkthrough() {
        pinBase { [weak self] in self?.app?.reviewer?.askForWalkthrough() }
    }

    /// Where the branch left the pull request's base: `git merge-base` with origin's base (the local one if origin's
    /// is not fetched), as a tree.
    private func pinBase(then: @escaping @MainActor () -> Void) {
        guard let current, let reviewer = app?.reviewer else { return }
        let directory = directory, base = current.base
        Task {
            let tree = await Task.detached { () -> String? in
                func git(_ arguments: [String]) -> String? {
                    Review.git(arguments, in: directory)?.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard let fork = git(["merge-base", "HEAD", "origin/\(base)"]) ?? git(["merge-base", "HEAD", base])
                else { return nil }
                return git(["rev-parse", fork + "^{tree}"])
            }.value
            guard let tree else {
                return Nvim.lua(channel, "vim.notify(...)", [
                    .string("No \(base) here to compare pull request #\(current.number) with: git fetch first"),
                    .int(3),
                ])
            }
            reviewer.pin("the base of pull request #\(current.number) (\(base))", tree: tree)
            then()
        }
    }

    func openInBrowser() {
        guard let url = current.flatMap({ URL(string: $0.url) }) else { return }
        NSWorkspace.shared.open(url)
    }
}
