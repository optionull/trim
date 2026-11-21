import Foundation
import FrameTree
import FrameWorkspaces
import SillAgent
import SillCore

/// When Frame last opened each workspace: one of the things that order the switcher (with git, edits and heed).
enum WorkspaceHistory {
    private static let key = "FrameWorkspaceOpened"

    static var opened: [String: Date] {
        let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        return stored.mapValues { Date(timeIntervalSince1970: $0) }
    }

    static func touch(_ path: String, now: Date = Date()) {
        var stored = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        stored[path] = now.timeIntervalSince1970
        // The newest two hundred are plenty.
        if stored.count > 200 {
            for (old, _) in stored.sorted(by: { $0.value < $1.value }).prefix(stored.count - 200) {
                stored[old] = nil
            }
        }
        UserDefaults.standard.set(stored, forKey: key)
    }
}

/// Where the switcher's workspaces come from: the roots to look in, and heed, which is optional: without it (not
/// installed, not running, slow) the list is the same, named by branches.
struct WorkspaceSources: Sendable {
    var roots: @Sendable () -> [String]
    var heed: @Sendable () async -> [HeedSession]
    /// Whether to read each checkout's git state (commit times, changes) after the first list.
    var readsStates = true

    /// `home.roots` of sill's settings (`SILL_ROOTS`), else ~/Projects.
    static let live = WorkspaceSources(
        roots: {
            let configured = Settings.shared.current.roots
            let roots = configured.isEmpty ? ["~/Projects"] : configured
            return roots.map { ($0 as NSString).expandingTildeInPath }
                .filter { FileManager.default.fileExists(atPath: $0) }
        },
        heed: {
            let heed = Heed()
            // Not installed or not running: no socket, nothing to wait for.
            guard FileManager.default.fileExists(atPath: heed.path) else { return [] }
            return await (try? heed.call(HeedRequest(method: "sessions"), timeout: 1.5))?.sessions ?? []
        }
    )
}

extension FrameApp {
    /// The workspaces to switch to, handed to `update` twice: first as soon as the checkouts and heed are known, then
    /// again with what git says of each (the order of recent work). `done` is true on the last.
    func loadWorkspaces(update: @escaping @MainActor @Sendable (_ workspaces: [Workspace], _ done: Bool) -> Void) {
        let sources = sources, roots = sources.roots()
        let open = Set(controllers.map { $0.tree?.rootPath ?? $0.workspace })
        let current = (active?.tree?.rootPath ?? active?.workspace)
        let opened = WorkspaceHistory.opened
        Task.detached {
            var checkouts = Checkouts.find(roots: roots)
            // A folder with a window is a workspace, whether or not it is under the roots.
            for path in open where !checkouts.contains(where: { $0.path == path }) {
                checkouts.append(Checkout(path: path, repository: path, isWorktree: false))
            }
            let sessions = await sources.heed()
            let first = WorkspaceIndex.build(
                checkouts: checkouts, sessions: sessions, opened: opened, open: open, current: current
            )
            await update(first, !sources.readsStates)
            guard sources.readsStates else { return }
            let transcripts = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")
            let read = CheckoutState.readAll(checkouts, transcripts: transcripts)
            let states = Dictionary(zip(checkouts.map(\.path), read)) { first, _ in first }
            let full = WorkspaceIndex.build(
                checkouts: checkouts, states: states, sessions: sessions, opened: opened, open: open, current: current
            )
            await update(full, true)
        }
    }
}
