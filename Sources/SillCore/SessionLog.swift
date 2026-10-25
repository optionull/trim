import Foundation

/// An agent session as sill's hooks logged it (`.sill/sessions/<session>.jsonl`, a JSON object a line), read back as
/// turns: each prompt, what the agent's tools did for it, how the turn ended, and the worktree's tree at its start and
/// end (git trees, as review baselines are), between which its changes are.
public struct SessionLog: Equatable, Sendable {
    public struct Step: Equatable, Sendable {
        /// The tool, `Edit`, `Bash`, …, or `plan` (presented) and `approved`.
        public var tool: String
        /// A file it worked on, a command it ran, a pattern it looked for: what says most about it.
        public var detail: String
        public var at: Date?

        public init(tool: String, detail: String, at: Date? = nil) {
            self.tool = tool
            self.detail = detail
            self.at = at
        }
    }

    public struct Turn: Equatable, Sendable {
        public var prompt: String
        public var mode: String?
        public var at: Date?
        public var ended: Date?
        public var steps: [Step] = []
        /// The worktree's tree when the prompt was given, and when the turn ended.
        public var before: String?
        public var after: String?

        public init(prompt: String, mode: String? = nil, at: Date? = nil) {
            self.prompt = prompt
            self.mode = mode
            self.at = at
        }

        /// The files the turn's tools wrote, in the order they were first written.
        public var written: [String] {
            var seen: Set<String> = []
            return steps.filter { Self.writes.contains($0.tool) }.map(\.detail).filter { seen.insert($0).inserted }
        }

        static let writes: Set = ["Edit", "Write", "MultiEdit", "NotebookEdit"]
    }

    public var turns: [Turn]

    public init(turns: [Turn]) {
        self.turns = turns
    }

    /// Reads the log's lines; what is before the first prompt (a resumed session's tools) is a turn without one.
    /// Paths under `root` are made relative to it.
    public init(_ text: String, root: String? = nil) {
        let dates = ISO8601DateFormatter()
        var turns: [Turn] = []
        func current() -> Int {
            if turns.isEmpty { turns.append(Turn(prompt: "")) }
            return turns.count - 1
        }
        func relative(_ path: String) -> String {
            guard let root, path.hasPrefix(root + "/") else { return path }
            return String(path.dropFirst(root.count + 1))
        }
        for line in text.split(separator: "\n") {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                continue
            }
            let at = (event["at"] as? String).flatMap(dates.date(from:))
            // A tree logged once its snapshot was taken: the start of the turn its prompt began, or the end of one.
            if let tree = event["tree"] as? String {
                let index = current()
                if event["of"] as? String == "Stop" { turns[index].after = tree } else { turns[index].before = tree }
                continue
            }
            switch event["hook_event_name"] as? String {
            case "UserPromptSubmit":
                turns.append(Turn(
                    prompt: event["prompt"] as? String ?? "",
                    mode: event["permission_mode"] as? String,
                    at: at
                ))
            case "PreToolUse" where event["tool_name"] as? String == "ExitPlanMode":
                turns[current()].steps.append(Step(tool: "plan", detail: "presented for approval", at: at))
            case "PostToolUse":
                let tool = event["tool_name"] as? String ?? "tool"
                if tool == "ExitPlanMode" {
                    turns[current()].steps.append(Step(tool: "approved", detail: "the plan", at: at))
                    continue
                }
                let detail = (event["file_path"] ?? event["notebook_path"]).flatMap { $0 as? String }.map(relative)
                    ?? event["command"] as? String ?? event["pattern"] as? String
                    ?? event["description"] as? String ?? ""
                turns[current()].steps.append(Step(tool: tool, detail: detail, at: at))
            case "Stop":
                turns[current()].ended = at
            default:
                break
            }
        }
        self.turns = turns
    }

    /// The session's title: its first prompt, on one line.
    public var title: String {
        let first = turns.first { !$0.prompt.isEmpty }?.prompt ?? "A session"
        let line = first.replacingOccurrences(of: "\n", with: " ")
        return line.count > 80 ? line.prefix(79) + "…" : line
    }
}
