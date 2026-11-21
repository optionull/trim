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

/// The checkouts found last time: the first thing the switcher shows, before anything is looked for.
enum WorkspaceCache {
    private static let key = "FrameKnownWorkspaces"

    static var checkouts: [Checkout] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Checkout].self, from: data)) ?? []
    }

    static func remember(_ checkouts: [Checkout]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(checkouts), forKey: key)
    }
}

/// Where the switcher's workspaces come from: the roots to look in, and heed, which is optional: without it (not
/// installed, not running, slow) the list is the same, named by branches.
struct WorkspaceSources: Sendable {
    var roots: @Sendable () -> [String]
    var heed: @Sendable () async -> [HeedSession]
    /// When Frame last opened each workspace: the order of the list.
    var opened: @Sendable () -> [String: Date] = { WorkspaceHistory.opened }
    /// The checkouts found last time, shown at once; and where to keep what is found now.
    var cached: @Sendable () -> [Checkout] = { WorkspaceCache.checkouts }
    var remember: @Sendable ([Checkout]) -> Void = { WorkspaceCache.remember($0) }
    /// Whether to read each checkout's git state (changes, last activity) once they are found.
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

/// What is known of the workspaces so far, as each part arrives; every change gives the list as it now is, in an order
/// that does not depend on which parts are in (`WorkspaceIndex.build`).
private actor Gathered {
    private var checkouts: [Checkout]
    private var sessions: [HeedSession]
    private var states: [String: CheckoutState] = [:]
    private let opened: [String: Date], open: Set<String>, current: String?
    private var version = 0

    init(checkouts: [Checkout], sessions: [HeedSession], opened: [String: Date], open: Set<String>, current: String?) {
        self.checkouts = checkouts
        self.sessions = sessions
        self.opened = opened
        self.open = open
        self.current = current
    }

    private func built() -> (version: Int, workspaces: [Workspace]) {
        version += 1
        return (version, WorkspaceIndex.build(
            checkouts: checkouts, states: states, sessions: sessions, opened: opened, open: open, current: current
        ))
    }

    func snapshot() -> (version: Int, workspaces: [Workspace]) { built() }

    func set(checkouts found: [Checkout]) -> (version: Int, workspaces: [Workspace]) {
        checkouts = found
        return built()
    }

    func set(sessions found: [HeedSession]) -> (version: Int, workspaces: [Workspace]) {
        sessions = found
        return built()
    }

    func set(states found: [String: CheckoutState]) -> (version: Int, workspaces: [Workspace]) {
        states = found
        return built()
    }
}

/// The newest list handed over so far: a slower part finishing late must not put an older list over a newer one.
@MainActor
private final class Newest {
    var version = 0
}

extension FrameApp {
    /// The workspaces to switch to, handed to `update` as they become known, and the order is always the same: the
    /// last opened first. At once, the ones known from last time and from the windows; then, each as it arrives and on
    /// its own, what is found under the roots, what heed calls the work in them, and what git says of each. `done` is
    /// true with the last.
    func loadWorkspaces(update: @escaping @MainActor @Sendable (_ workspaces: [Workspace], _ done: Bool) -> Void) {
        let sources = sources, roots = sources.roots()
        let open = Set(controllers.map { $0.tree?.rootPath ?? $0.workspace })
        let current = active?.tree?.rootPath ?? active?.workspace
        let opened = sources.opened()
        // A folder with a window is a workspace, whether or not it is under the roots.
        let withWindows: @Sendable ([Checkout]) -> [Checkout] = { checkouts in
            var all = checkouts
            for path in open where !all.contains(where: { $0.path == path }) {
                all.append(Checkout(path: path, repository: path, isWorktree: false))
            }
            return all
        }
        let known = withWindows(sources.cached())
        let remembered = lastSessions
        update(
            WorkspaceIndex.build(checkouts: known, sessions: remembered, opened: opened, open: open, current: current),
            false
        )
        let gathered = Gathered(checkouts: known, sessions: remembered, opened: opened, open: open, current: current)
        let newest = Newest()
        let reading = sources.readsStates
        Task { @MainActor [weak self] in
            @MainActor func push(_ result: (version: Int, workspaces: [Workspace]), done: Bool = false) {
                guard result.version > newest.version else { return }
                newest.version = result.version
                update(result.workspaces, done)
            }
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    let found = withWindows(Checkouts.find(roots: roots))
                    sources.remember(found)
                    await push(gathered.set(checkouts: found))
                    guard reading else { return }
                    let transcripts = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")
                    let read = CheckoutState.readAll(found, transcripts: transcripts)
                    await push(gathered.set(states: Dictionary(zip(found.map(\.path), read)) { first, _ in first }))
                }
                group.addTask {
                    let found = await sources.heed()
                    await MainActor.run { self?.lastSessions = found }
                    await push(gathered.set(sessions: found))
                }
            }
            // Nothing is left to arrive: the same list again, to say so.
            await push(gathered.snapshot(), done: true)
        }
    }
}
