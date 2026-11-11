import AppKit
import SillCore
import SillNvim

/// Home: the git checkouts under the folders sill watches, most recently active first, what an agent is doing in each
/// (working or idle) and the walkthroughs agents prepared that are not seen yet. sill left running in the background is
/// this; a checkout opens in a sill of its own. Shown from the cache at once, read again off the main thread, and kept
/// up to date by the file system's events, re-reading only the checkouts they are in.
@MainActor
final class HomeModel {
    private(set) var roots: [String]
    private(set) var rows: [(checkout: Checkout, state: CheckoutState)] = []
    private(set) var reading = false
    private(set) var readAt: Date?
    var onChange: (() -> Void)?

    private var watchers: [FileEvents] = []
    private var dirty: Set<String> = []
    private var debounce: Task<Void, Never>?
    private var tick: Timer?

    /// Where Claude Code keeps its sessions: what an agent does in a checkout is read from there.
    nonisolated static let transcripts = realPath(ProcessInfo.processInfo.environment["SILL_TRANSCRIPTS"] ??
        NSHomeDirectory() + "/.claude/projects")

    init(roots: [String]) {
        self.roots = roots.map { realPath(($0 as NSString).expandingTildeInPath) }
    }

    /// The rows as sill last saw them, then the checkouts read again, then the watching.
    func start() {
        if let cached = Self.cached(), Set(cached.roots) == Set(roots) {
            rows = cached.rows.map { ($0.checkout, $0.state) }
            onChange?()
        }
        refresh()
        // A turn that went quiet is no longer working: looked at again now and then.
        tick = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reread(Set(self?.rows.filter { $0.state.agent?.working == true }
                    .map(\.checkout.path) ?? [])) }
        }
    }

    func set(roots: [String]) {
        self.roots = roots.map { realPath(($0 as NSString).expandingTildeInPath) }
        refresh()
    }

    /// Every checkout found and read again.
    func refresh() {
        guard !reading else { return }
        reading = true
        onChange?()
        let roots = roots
        Task {
            let (checkouts, states) = await Task.detached {
                let checkouts = Checkouts.find(roots: roots)
                return (checkouts, CheckoutState.readAll(checkouts, transcripts: Self.transcripts))
            }.value
            rows = Self.ordered(Array(zip(checkouts, states)))
            reading = false
            readAt = Date()
            watch()
            save()
            onChange?()
        }
    }

    static func ordered(_ rows: [(checkout: Checkout, state: CheckoutState)]) -> [(
        checkout: Checkout,
        state: CheckoutState
    )] {
        rows.sorted { ($0.state.active, $1.checkout.path) > ($1.state.active, $0.checkout.path) }
    }

    /// The checkouts at `paths` read again (the rest as they are).
    private func reread(_ paths: Set<String>) {
        let checkouts = rows.map(\.checkout).filter { paths.contains($0.path) }
        guard !checkouts.isEmpty else { return }
        Task {
            let states = await Task.detached { CheckoutState.readAll(checkouts, transcripts: Self.transcripts) }.value
            var byPath = Dictionary(rows.map { ($0.checkout.path, $0) }) { first, _ in first }
            for (checkout, state) in zip(checkouts, states) {
                byPath[checkout.path] = (checkout, state)
            }
            rows = Self.ordered(Array(byPath.values))
            save()
            onChange?()
        }
    }

    // MARK: Watching

    /// The roots, the worktrees outside them and the agents' transcripts, watched: an event re-reads the checkout it
    /// is in, a second after the last of a burst.
    private func watch() {
        watchers.forEach { $0.stop() }
        let outside = rows.map(\.checkout.path).filter { path in !roots.contains { path.hasPrefix($0 + "/") } }
        watchers = (roots + outside + [Self.transcripts]).map { folder in
            let events = FileEvents(root: folder, raw: true)
            events.onChange = { [weak self] paths in self?.changed(paths) }
            events.start()
            return events
        }
    }

    private func changed(_ paths: [String]) {
        let checkouts = rows.map(\.checkout.path).sorted { $0.count > $1.count }
        // A transcript's folder names the checkout its session is in.
        let byTranscript = Dictionary(
            checkouts.map { (AgentActivity.folder(for: $0, in: Self.transcripts), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for path in paths {
            // A repository's .sill (walkthroughs, what was seen) is every worktree's of it.
            if let range = path.range(of: "/" + SillFolder.name + "/") {
                let repository = String(path[..<range.lowerBound])
                dirty.formUnion(rows.filter { $0.checkout.repository == repository }.map(\.checkout.path))
            }
            if path.hasPrefix(Self.transcripts + "/") {
                let folder = (path as NSString).deletingLastPathComponent
                if let checkout = byTranscript[folder] { dirty.insert(checkout) }
            } else if let checkout = checkouts.first(where: { path.hasPrefix($0 + "/") || path == $0 }) {
                dirty.insert(checkout)
            }
        }
        guard !dirty.isEmpty else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            let paths = dirty
            dirty = []
            reread(paths)
        }
    }

    // MARK: The cache

    private struct Cache: Codable {
        struct Row: Codable {
            var checkout: Checkout
            var state: CheckoutState
        }

        var roots: [String]
        var rows: [Row]
    }

    private nonisolated static var cacheFile: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sill")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("home.json")
    }

    private static func cached() -> Cache? {
        (try? Data(contentsOf: cacheFile)).flatMap { try? JSONDecoder().decode(Cache.self, from: $0) }
    }

    private func save() {
        let cache = Cache(roots: roots, rows: rows.map { Cache.Row(checkout: $0.checkout, state: $0.state) })
        Task.detached { try? JSONEncoder().encode(cache).write(to: Self.cacheFile, options: .atomic) }
    }

    // MARK: What it says

    /// The agents working now.
    var working: Int { rows.count(where: { $0.state.agent?.working == true }) }

    /// The summary of summaries: every walkthrough not seen yet, newest first, with its checkout.
    var unseen: [(checkout: Checkout, prepared: CheckoutState.Prepared)] {
        rows.flatMap { row in row.state.unseen.map { (row.checkout, $0) } }.sorted { $0.prepared.at > $1.prepared.at }
    }

    /// Asked to open a checkout (and a walkthrough in it): the app opens it in a window of its own.
    var onOpen: ((String, String?) -> Void)?

    /// Every walkthrough of a checkout not read yet, marked read (nothing in it opened).
    func markSeen(_ checkout: Checkout) {
        guard let folder = Checkouts.sillFolder(of: checkout),
              let row = rows.first(where: { $0.checkout == checkout }), !row.state.unseen.isEmpty else { return }
        for prepared in row.state.unseen {
            Seen.mark(prepared.path, in: folder)
        }
        reread([checkout.path])
    }

    func open(_ checkout: Checkout, walkthrough: String? = nil) {
        onOpen?(checkout.path, walkthrough)
        if let walkthrough, let folder = Checkouts.sillFolder(of: checkout) {
            Seen.mark(walkthrough, in: folder)
            reread([checkout.path])
        }
    }
}
