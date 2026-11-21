import Foundation
import FrameTree
import SillAgent
import SillCore

/// One place to work: a repository or a worktree, with what is known of it. The name people know it by is rarely the
/// folder's, so heed's title for the session working in it comes first when there is one.
public struct Workspace: Equatable, Sendable, Identifiable {
    public var path: String
    /// The repository's name (its main checkout's folder).
    public var repository: String
    public var isWorktree: Bool
    public var branch: String
    /// What heed calls the session in it: what the work is about.
    public var title: String?
    /// heed's state of that session (working, idle, blocked, done...), and whether it needs the person.
    public var heedState: String?
    public var needsYou = false
    public var changes = 0
    public var activeAt: Date = .distantPast
    /// A window of Frame is on it, and it is the one the person is in.
    public var isOpen = false
    public var isCurrent = false

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }

    public init(
        path: String, repository: String, isWorktree: Bool = false, branch: String = "", title: String? = nil
    ) {
        self.path = path
        self.repository = repository
        self.isWorktree = isWorktree
        self.branch = branch
        self.title = title
    }

    /// The line that says what it is: heed's title; else the branch of a worktree (the folder's name says little);
    /// else, for a main checkout, the repository.
    public var primary: String {
        if let title, !title.isEmpty { return title }
        if isWorktree { return branch.isEmpty ? name : branch }
        return repository
    }

    /// Under it: the repository and where in it, unless the first line says that already.
    public var secondary: String {
        let hasTitle = title.map { !$0.isEmpty } ?? false
        if hasTitle { return [repository, branch.isEmpty ? name : branch].joined(separator: " · ") }
        if isWorktree { return repository + " · " + name }
        return branch.isEmpty ? "" : branch
    }
}

/// What a query found: the workspace, how well, and which characters of its two lines to highlight.
public struct WorkspaceMatch: Equatable, Sendable {
    public var workspace: Workspace
    public var score: Int
    public var primaryHits: [Int]
    public var secondaryHits: [Int]
}

public enum WorkspaceIndex {
    /// The workspaces from the checkouts found, what is read of each (by path), heed's sessions, when Frame last
    /// opened each, and which have a window. Needs-you first, then whatever happened last.
    public static func build(
        checkouts: [Checkout], states: [String: CheckoutState] = [:], sessions: [HeedSession] = [],
        opened: [String: Date] = [:], open: Set<String> = [], current: String? = nil
    ) -> [Workspace] {
        // Of the sessions in a folder, the one that was last active names it.
        var byPath: [String: HeedSession] = [:]
        for session in sessions {
            guard let directory = session.directory, session.repo != nil || session.branch != nil,
                  FileManager.default.fileExists(atPath: directory) else { continue }
            let path = RealPath.of(directory)
            if let known = byPath[path],
               (known.lastActivity ?? .distantPast) >= (session.lastActivity ?? .distantPast)
            {
                continue
            }
            byPath[path] = session
        }
        var workspaces: [Workspace] = []
        var seen: Set<String> = []
        for checkout in checkouts where seen.insert(checkout.path).inserted {
            var workspace = Workspace(
                path: checkout.path, repository: checkout.repositoryName, isWorktree: checkout.isWorktree
            )
            if let state = states[checkout.path] {
                workspace.branch = state.branch
                workspace.changes = state.touched
                workspace.activeAt = state.active
            }
            workspaces.append(workspace)
        }
        // A folder heed knows that is not under the roots is still a place to go.
        for (path, session) in byPath where seen.insert(path).inserted {
            let repository = session.repo.map { ($0 as NSString).lastPathComponent } ?? (path as NSString)
                .lastPathComponent
            workspaces.append(Workspace(path: path, repository: repository, branch: session.branch ?? ""))
        }
        for index in workspaces.indices {
            let path = workspaces[index].path
            if let session = byPath[path] {
                workspaces[index].title = session.title
                workspaces[index].heedState = session.state
                workspaces[index].needsYou = session.needsYou
                if workspaces[index].branch.isEmpty { workspaces[index].branch = session.branch ?? "" }
                workspaces[index].activeAt = max(workspaces[index].activeAt, session.lastActivity ?? .distantPast)
            }
            // The branch is in .git, so every row has it at once, without waiting on git.
            if workspaces[index].branch.isEmpty, let info = GitHead.info(at: path, levels: 0) {
                workspaces[index].branch = info.branch
            }
            workspaces[index].activeAt = max(workspaces[index].activeAt, opened[path] ?? .distantPast)
            workspaces[index].isOpen = open.contains(path)
            workspaces[index].isCurrent = path == current
        }
        return workspaces.sorted {
            ($0.needsYou ? 1 : 0, $0.activeAt, $1.path) > ($1.needsYou ? 1 : 0, $1.activeAt, $0.path)
        }
    }

    /// The workspaces a query finds, best first: every word of it must be found, in the lines shown, the branch, the
    /// folder or the path. No query is every workspace, in the order given.
    public static func search(_ query: String, in workspaces: [Workspace]) -> [WorkspaceMatch] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else {
            return workspaces.map { WorkspaceMatch(workspace: $0, score: 0, primaryHits: [], secondaryHits: []) }
        }
        var found: [(index: Int, match: WorkspaceMatch)] = []
        for (index, workspace) in workspaces.enumerated() {
            var score = 0
            var primaryHits: Set<Int> = [], secondaryHits: Set<Int> = []
            var matchedAll = true
            for word in words {
                let candidates: [(Int, FuzzyMatch?, Int)] = [
                    (3, Fuzzy.match(word, in: workspace.primary), 0),
                    (2, Fuzzy.match(word, in: workspace.secondary), 1),
                    (2, Fuzzy.match(word, in: workspace.branch), 2),
                    (2, Fuzzy.match(word, in: workspace.name), 2),
                    (1, Fuzzy.match(word, in: workspace.path), 2),
                ]
                guard let best = candidates
                    .compactMap({ weight, match, line in match.map { ($0.score * weight, $0, line) } })
                    .max(by: { $0.0 < $1.0 })
                else { matchedAll = false; break }
                score += best.0
                if best.2 == 0 { primaryHits.formUnion(best.1.positions) }
                if best.2 == 1 { secondaryHits.formUnion(best.1.positions) }
            }
            guard matchedAll else { continue }
            found.append((index, WorkspaceMatch(
                workspace: workspace, score: score, primaryHits: primaryHits.sorted(),
                secondaryHits: secondaryHits.sorted()
            )))
        }
        return found.sorted { ($0.match.score, $1.index) > ($1.match.score, $0.index) }.map(\.match)
    }
}
