import Foundation

/// What happened in a checkout, as sill tells it before the code: the branch's base, the files touched since it left
/// it (committed or not, new ones too), its commits since, and what the person asked the agent there. The workspace's
/// summary and its touched files are read from it. Read only, off the main thread.
public struct Story: Equatable, Sendable {
    /// The branch it is compared with (`origin/main`), and where this branch left it.
    public var base: String?
    public var fork: String?
    /// Files touched since the fork, the worktree as it is: committed, not committed, and new.
    public var touched: [Review.File]
    public var commits: [Commit]
    /// The person's prompts to the agent here, newest first.
    public var prompts: [Prompt]

    public struct Commit: Equatable, Sendable {
        public var hash: String
        public var subject: String
        public var at: Date
    }

    public struct Prompt: Equatable, Sendable {
        public var text: String
        public var at: Date?
    }

    public init(
        base: String? = nil,
        fork: String? = nil,
        touched: [Review.File] = [],
        commits: [Commit] = [],
        prompts: [Prompt] = []
    ) {
        self.base = base
        self.fork = fork
        self.touched = touched
        self.commits = commits
        self.prompts = prompts
    }

    public static func read(_ path: String, transcripts: String) -> Story {
        func git(_ arguments: [String]) -> String? {
            Review.git(["--no-optional-locks"] + arguments, in: path)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var story = Story()
        // The base: where origin's HEAD points, else a main or master branch.
        let candidates = [git(["rev-parse", "--abbrev-ref", "origin/HEAD"])] +
            ["origin/main", "origin/master", "main", "master"].map(Optional.some)
        story.base = candidates.compactMap { $0 }.first { git(["rev-parse", "--verify", "--quiet", $0]) != nil }
        let branch = git(["branch", "--show-current"]) ?? ""
        if let base = story.base, (base as NSString).lastPathComponent != branch {
            story.fork = git(["merge-base", "HEAD", base])
        } else {
            // On the base branch itself: what is not pushed, else nothing committed counts.
            story.fork = git(["rev-parse", "--verify", "--quiet", "@{upstream}"]) ?? git(["rev-parse", "HEAD"])
        }
        if let fork = story.fork {
            story.touched = touched(since: fork, in: path)
            let log = git(["log", "--format=%H%x09%ct%x09%s", "-n", "30", "\(fork)..HEAD"]) ?? ""
            story.commits = log.split(separator: "\n").compactMap { line in
                let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
                guard parts.count == 3, let seconds = Double(parts[1]) else { return nil }
                return Commit(
                    hash: String(parts[0].prefix(9)),
                    subject: parts[2],
                    at: Date(timeIntervalSince1970: seconds)
                )
            }
        }
        story.prompts = prompts(cwd: path, transcripts: transcripts)
        return story
    }

    /// The worktree against `fork`, file by file (renames followed), and the files git does not know yet, with their
    /// lines as added; sill's own folder left out. Most changed first.
    static func touched(since fork: String, in path: String) -> [Review.File] {
        func git(_ arguments: [String]) -> String {
            Review.git(["--no-optional-locks"] + arguments, in: path) ?? ""
        }
        var statuses: [String: Review.File.Status] = [:]
        for line in git(["diff", "--name-status", "-M", fork]).split(separator: "\n") {
            let parts = line.split(separator: "\t").map(String.init)
            guard let code = parts.first?.first, let file = parts.last else { continue }
            statuses[file] = code == "A" ? .added : code == "D" ? .deleted : .modified
        }
        var files: [Review.File] = git(["diff", "--numstat", "-M", fork]).split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { return nil }
            // A rename is `old => new` or `dir/{old => new}/file`: the new path.
            var file = parts[2]
            if let braces = file.range(of: #"\{[^}]* => ([^}]*)\}"#, options: .regularExpression) {
                let inner = String(file[braces]).dropFirst().dropLast().components(separatedBy: " => ").last ?? ""
                file.replaceSubrange(braces, with: inner)
                file = file.replacingOccurrences(of: "//", with: "/")
            } else if let arrow = file.range(of: " => ") {
                file = String(file[arrow.upperBound...])
            }
            return Review.File(
                path: file, status: statuses[file] ?? .modified, added: Int(parts[0]) ?? 0, removed: Int(parts[1]) ?? 0
            )
        }
        for file in git(["ls-files", "--others", "--exclude-standard"]).split(separator: "\n").map(String.init) {
            // Its lines: the newlines, and a last line without one.
            let text = (try? String(contentsOfFile: path + "/" + file, encoding: .utf8)) ?? ""
            let lines = text.count(where: { $0 == "\n" }) + (text.isEmpty || text.hasSuffix("\n") ? 0 : 1)
            files.append(Review.File(path: file, status: .added, added: lines, removed: 0))
        }
        return files.filter { !$0.path.hasPrefix(SillFolder.name + "/") }
            .sorted { ($0.added + $0.removed, $1.path) > ($1.added + $1.removed, $0.path) }
    }

    /// The person's prompts in Claude Code's newest session here, newest first: its user messages of text (not tools'
    /// results), at most five, from its last megabyte.
    static func prompts(cwd: String, transcripts: String) -> [Prompt] {
        let folder = AgentActivity.folder(for: cwd, in: transcripts)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        let newest = names.filter { $0.hasSuffix(".jsonl") }.max { a, b in
            let date = { (name: String) in
                ((try? FileManager.default.attributesOfItem(atPath: folder + "/" + name))?[.modificationDate] as? Date)
                    ?? .distantPast
            }
            return date(a) < date(b)
        }
        guard let newest, let handle = FileHandle(forReadingAtPath: folder + "/" + newest) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 1_048_576 ? size - 1_048_576 : 0)
        let lines = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self).components(separatedBy: "\n")
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var prompts: [Prompt] = []
        for line in lines.reversed() where line.contains(#""type":"user""#) {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let message = entry["message"] as? [String: Any]
            else { continue }
            var text = message["content"] as? String
            if text == nil, let parts = message["content"] as? [[String: Any]],
               !parts.contains(where: { $0["type"] as? String == "tool_result" })
            {
                text = parts.compactMap { $0["text"] as? String }.first
            }
            guard let text, !text.hasPrefix("<") else { continue }
            let at = (entry["timestamp"] as? String).flatMap(dates.date(from:))
            let line = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            if prompts.last?.text != line { prompts.append(Prompt(text: line, at: at)) }
            if prompts.count == 5 { break }
        }
        return prompts
    }
}
