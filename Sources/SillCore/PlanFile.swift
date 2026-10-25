import Foundation

/// An agent's plan, as it presents it for approval, made a notebook: its own Markdown, titled by its first heading,
/// with the files it names (that exist) as code at the end, so the plan is read against the code it means to change.
public enum PlanFile {
    /// The notebook's source; `status` is presented or approved.
    public static func notebook(
        _ plan: String, root: String, status: String = "presented",
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String {
        let lines = plan.components(separatedBy: "\n")
        let heading = lines.first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) }
        let title = heading ?? lines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespaces)) ?? "Plan"
        // The plan's own title is the notebook's; its sections stay sections.
        var body = lines.filter { $0 != "# \(title)" }.joined(separator: "\n").trimmingCharacters(in: .newlines)
        let references = FileReference.all(in: plan, directory: root, root: root, exists: exists)
        if !references.isEmpty {
            // The root as given and as references spell it (/private/tmp is /tmp to them).
            let prefixes = [root, (root as NSString).standardizingPath].map { $0.hasSuffix("/") ? $0 : $0 + "/" }
            body += "\n\n## Code it names\n" + references.map { reference in
                let path = prefixes.first { reference.path.hasPrefix($0) }
                    .map { String(reference.path.dropFirst($0.count)) } ?? reference.path
                // A line names a place in the file: a few lines around it; a bare file, the file.
                guard let line = reference.line else { return "@code \(path)" }
                return "@code \(path):\(max(line - 2, 1))-\(line + 6)"
            }.joined(separator: "\n")
        }
        return "---\ntitle: \(title.replacingOccurrences(of: "\n", with: " "))\nby: agent\nstatus: \(status)\n---\n\n" +
            body + "\n"
    }

    /// A file name for a plan: the moment and its title.
    public static func fileName(title: String, at date: Date) -> String {
        let stamp = date.formatted(.iso8601.year().month().day().dateSeparator(.omitted)
            .time(includingFractionalSeconds: false).timeSeparator(.omitted))
            .replacingOccurrences(of: "T", with: "-").replacingOccurrences(of: "Z", with: "")
        let slug = BasketFile.fileName(for: title).replacingOccurrences(of: BasketFile.suffix, with: "")
        return "\(stamp)-\(slug).plan.md"
    }
}

/// sill's hooks in a Claude Code settings file (`.claude/settings.local.json`, or the one sill passes with
/// `--settings`): added beside whatever else is there, and taken out again, recognised by their command.
public enum HookSettings {
    /// The events sill listens to; tool events for every tool.
    public static let events = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"]
    static let toolEvents: Set = ["PreToolUse", "PostToolUse"]

    /// `settings` (a settings file's JSON object) with sill's hooks running `command` (replacing sill's earlier).
    public static func installing(_ command: String, marker: String, in settings: [String: Any]) -> [String: Any] {
        var settings = removing(marker: marker, from: settings)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var entries = hooks[event] as? [[String: Any]] ?? []
            var entry: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": 5]]]
            if toolEvents.contains(event) { entry["matcher"] = "*" }
            entries.append(entry)
            hooks[event] = entries
        }
        settings["hooks"] = hooks
        return settings
    }

    /// `settings` without sill's hooks (those whose command has `marker`); events left empty, gone.
    public static func removing(marker: String, from settings: [String: Any]) -> [String: Any] {
        var settings = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            let kept = entries.compactMap { entry -> [String: Any]? in
                var entry = entry
                let handlers = (entry["hooks"] as? [[String: Any]] ?? []).filter {
                    !(($0["command"] as? String)?.contains(marker) ?? false)
                }
                guard !handlers.isEmpty else { return nil }
                entry["hooks"] = handlers
                return entry
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        return settings
    }

    /// Whether sill's hooks are in `settings`.
    public static func installed(marker: String, in settings: [String: Any]) -> Bool {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        return events.allSatisfy { event in
            (hooks[event] as? [[String: Any]] ?? []).contains { entry in
                (entry["hooks"] as? [[String: Any]] ?? [])
                    .contains { ($0["command"] as? String)?.contains(marker) == true }
            }
        }
    }
}
