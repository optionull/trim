import Foundation

/// How a checkout stands, for Home: its branch, its changes not committed and when they were last edited, the last
/// commit, what an agent is doing in it, and the walkthroughs agents prepared for it (seen or not). Read only, off the
/// main thread; a few git calls and stats a checkout.
public struct CheckoutState: Equatable, Sendable, Codable {
    public var branch: String
    /// Files changed and not committed (staged or not, new ones included).
    public var touched: Int
    public var lastCommit: Date?
    /// When a changed file was last written.
    public var lastEdit: Date?
    public var agent: AgentActivity?
    public var walkthroughs: [Prepared]

    public init(
        branch: String,
        touched: Int = 0,
        lastCommit: Date? = nil,
        lastEdit: Date? = nil,
        agent: AgentActivity? = nil,
        walkthroughs: [Prepared] = []
    ) {
        self.branch = branch
        self.touched = touched
        self.lastCommit = lastCommit
        self.lastEdit = lastEdit
        self.agent = agent
        self.walkthroughs = walkthroughs
    }

    /// When anything last happened in it: Home's order.
    public var active: Date {
        ([lastCommit, lastEdit, agent?.last] + walkthroughs.map(\.at)).compactMap { $0 }.max() ?? .distantPast
    }

    public var unseen: [Prepared] { walkthroughs.filter { !$0.seen } }

    /// A notebook an agent prepared (a handoff, a review walkthrough, a plan): what it says first, and whether it was
    /// opened in sill since it was last written.
    public struct Prepared: Equatable, Sendable, Codable {
        public var path: String
        public var title: String
        public var summary: String
        public var at: Date
        public var seen: Bool
        public var kind: String
    }

    /// Reads it. `seen` is the `.sill/seen.json` of its repository; `transcripts` where Claude Code keeps its
    /// sessions (`~/.claude/projects`).
    public static func read(_ checkout: Checkout, transcripts: String, now: Date = Date()) -> CheckoutState {
        let path = checkout.path
        func git(_ arguments: [String]) -> String? { Review.git(arguments, in: path) }
        var state = CheckoutState(branch: git(["branch", "--show-current"])?.trimmed ?? "")
        if state.branch.isEmpty { state.branch = git(["rev-parse", "--short", "HEAD"])?.trimmed ?? "" }
        if let seconds = git(["log", "-1", "--format=%ct"])?.trimmed, let value = Double(seconds) {
            state.lastCommit = Date(timeIntervalSince1970: value)
        }
        // The changed files and when they were last written (at most 200 looked at: enough to say when).
        // Without the index's lock: an agent working in it must never find git busy because sill looked.
        let changed = (git(["--no-optional-locks", "status", "--porcelain", "--untracked-files=normal"]) ?? "")
            .split(separator: "\n")
            // sill's own folder is no change of the checkout's (where git was not told to ignore it).
            .filter { !$0.dropFirst(3).hasPrefix(SillFolder.name + "/") }
        state.touched = changed.count
        for line in changed.prefix(200) where line.count > 3 {
            var file = String(line.dropFirst(3))
            if let arrow = file.range(of: " -> ") { file = String(file[arrow.upperBound...]) }
            let attributes = try? FileManager.default.attributesOfItem(atPath: path + "/" + file.unquoted)
            if let date = attributes?[.modificationDate] as? Date, date > (state.lastEdit ?? .distantPast) {
                state.lastEdit = date
            }
        }
        state.agent = AgentActivity.read(cwd: path, transcripts: transcripts, now: now)
        state.walkthroughs = prepared(for: checkout)
        return state
    }

    /// Every checkout's state, read on every core at once, in the checkouts' order.
    public static func readAll(_ checkouts: [Checkout], transcripts: String, now: Date = Date()) -> [CheckoutState] {
        Parallel.map(checkouts) { read($0, transcripts: transcripts, now: now) }
    }

    /// The notebooks agents prepared for this checkout, newest first: those in its repository's `.sill` that name it
    /// (`worktree:`), and, for the main checkout, those that name none.
    public static func prepared(for checkout: Checkout) -> [Prepared] {
        guard let folder = Checkouts.sillFolder(of: checkout) else { return [] }
        let seen = Seen.read(folder)
        var found: [Prepared] = []
        let walker = FileManager.default.enumerator(atPath: folder)
        while let relative = walker?.nextObject() as? String {
            let kind = relative.hasPrefix("handoffs/") ? "handoff" : relative.hasPrefix("reviews/") ? "review" :
                relative.hasPrefix("plans/") ? "plan" : relative.hasSuffix(".walk.md") ? "walkthrough" : nil
            guard let kind, relative.hasSuffix(".walk.md") || relative.hasSuffix(".plan.md") else { continue }
            let file = folder + "/" + relative
            guard let text = try? String(contentsOfFile: file, encoding: .utf8),
                  let at = (try? FileManager.default.attributesOfItem(atPath: file))?[.modificationDate] as? Date
            else { continue }
            let walk = Walkthrough(text)
            let target = walk.worktree.map { realPath($0) }
            guard target == checkout.path || (target == nil && !checkout.isWorktree) else { continue }
            let summary = walk.intro.split(separator: "\n\n").first.map(String.init) ?? ""
            found.append(Prepared(
                path: file, title: walk.title.isEmpty ? relative : walk.title,
                summary: summary.replacingOccurrences(of: "\n", with: " "), at: at,
                seen: (seen[relative] ?? .distantPast) >= at, kind: kind
            ))
        }
        return found.sorted { $0.at > $1.at }
    }
}

/// What an agent does in a folder, from its own record of the session (Claude Code's transcripts): working while its
/// turn has not ended, and the person's last prompt.
public struct AgentActivity: Equatable, Sendable, Codable {
    public var working: Bool
    public var last: Date
    public var prompt: String?

    /// A turn not ended but not written to for this long is no longer worked on (the session was closed).
    static let stale: TimeInterval = 600

    /// Claude Code's folder for the sessions in `cwd`: its path with every character not a letter or digit as `-`.
    public static func folder(for cwd: String, in transcripts: String) -> String {
        transcripts + "/" + String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    public static func read(cwd: String, transcripts: String, now: Date = Date()) -> AgentActivity? {
        let folder = folder(for: cwd, in: transcripts)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return nil }
        let newest = names.filter { $0.hasSuffix(".jsonl") }.compactMap { name -> (String, Date)? in
            let path = folder + "/" + name
            return ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date).map {
                (path, $0)
            }
        }.max { $0.1 < $1.1 }
        guard let (path, last) = newest else { return nil }
        let (ended, prompt) = turn(in: tail(of: path))
        return AgentActivity(working: !ended && now.timeIntervalSince(last) < stale, last: last, prompt: prompt)
    }

    /// The end of a transcript, as lines (the last 256 KB: a turn's end and its prompt are there).
    static func tail(of path: String) -> [String] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
    }

    /// Whether the last turn ended (the assistant's last message ended it, nothing after), and the last prompt.
    static func turn(in lines: [String]) -> (ended: Bool, prompt: String?) {
        var ended: Bool?, prompt: String?
        for line in lines.reversed() where !line.isEmpty {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = entry["type"] as? String
            else { continue }
            // Claude Code notes the prompt as it goes: found near the end, however long the turn's tools ran.
            if type == "last-prompt", prompt == nil, let text = entry["lastPrompt"] as? String {
                prompt = text
            }
            guard type == "user" || type == "assistant", let message = entry["message"] as? [String: Any] else {
                continue
            }
            if ended == nil {
                ended = type == "assistant" && message["stop_reason"] as? String == "end_turn"
            }
            // The person's prompt: a user message of text, not a tool's result.
            if type == "user", prompt == nil {
                if let text = message["content"] as? String {
                    prompt = text
                } else if let parts = message["content"] as? [[String: Any]],
                          !parts.contains(where: { $0["type"] as? String == "tool_result" }),
                          let text = parts.compactMap({ $0["text"] as? String }).first
                {
                    prompt = text
                }
            }
            if ended != nil, prompt != nil { break }
        }
        let cleaned = prompt.map { $0.replacingOccurrences(of: "\n", with: " ").trimmed }
        return (ended ?? true, cleaned.map { $0.count > 200 ? String($0.prefix(199)) + "…" : $0 })
    }
}

/// The notebooks opened in sill, by path within `.sill`, and when: Home's seen and unseen.
public enum Seen {
    public static func file(_ sillFolder: String) -> String { sillFolder + "/seen.json" }

    public static func read(_ sillFolder: String) -> [String: Date] {
        guard let data = FileManager.default.contents(atPath: file(sillFolder)),
              let entries = try? JSONDecoder().decode([String: Date].self, from: data)
        else { return [:] }
        return entries
    }

    /// Marks `path` (a notebook in `sillFolder`) seen now.
    public static func mark(_ path: String, in sillFolder: String, at date: Date = Date()) {
        guard path.hasPrefix(sillFolder + "/") else { return }
        var entries = read(sillFolder)
        entries[String(path.dropFirst(sillFolder.count + 1))] = date
        try? JSONEncoder().encode(entries).write(to: URL(fileURLWithPath: file(sillFolder)), options: .atomic)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    /// A path as git quotes it when it has spaces or such: without the quotes.
    var unquoted: String { hasPrefix("\"") && hasSuffix("\"") ? String(dropFirst().dropLast()) : self }
}
