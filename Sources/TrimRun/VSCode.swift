import Foundation

/// VS Code's `.vscode/tasks.json` and `launch.json`: the tasks as they are (a shell command, or a program with
/// arguments), and the launch configurations that are a program to run (node, python, a built .NET dll, a native
/// binary), as the command line they stand for. Debugger-only settings are left out: Trim runs, it does not attach.
public enum VSCode {
    /// JSON with comments and trailing commas, as VS Code's files are.
    public static func parse(_ text: String) -> Any? {
        var out = ""
        var inString = false
        var escaped = false
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            let c = chars[index]
            if inString {
                out.append(c)
                switch (escaped, c) {
                case (true, _): escaped = false
                case (false, "\\"): escaped = true
                case (false, "\""): inString = false
                default: break
                }
            } else if c == "\"" {
                inString = true
                out.append(c)
            } else if c == "/", index + 1 < chars.count, chars[index + 1] == "/" {
                while index < chars.count, chars[index] != "\n" {
                    index += 1
                }
                continue
            } else if c == "/", index + 1 < chars.count, chars[index + 1] == "*" {
                index += 2
                while index + 1 < chars.count, !(chars[index] == "*" && chars[index + 1] == "/") {
                    index += 1
                }
                index += 2
                continue
            } else {
                out.append(c)
            }
            index += 1
        }
        // Trailing commas: a comma followed by only whitespace and a closing bracket.
        var cleaned = ""
        let o = Array(out)
        inString = false
        escaped = false
        for (i, c) in o.enumerated() {
            if inString {
                cleaned.append(c)
                switch (escaped, c) {
                case (true, _): escaped = false
                case (false, "\\"): escaped = true
                case (false, "\""): inString = false
                default: break
                }
                continue
            }
            if c == "\"" { inString = true }
            if c == "," {
                var j = i + 1
                while j < o.count, o[j].isWhitespace {
                    j += 1
                }
                if j < o.count, o[j] == "}" || o[j] == "]" { continue }
            }
            cleaned.append(c)
        }
        return try? JSONSerialization.jsonObject(with: Data(cleaned.utf8))
    }

    /// `${workspaceFolder}` and its relatives, for the folder `root`.
    static func expand(_ text: String, root: String) -> String {
        text.replacingOccurrences(of: "${workspaceFolder}", with: root)
            .replacingOccurrences(of: "${workspaceRoot}", with: root)
            .replacingOccurrences(of: "${workspaceFolderBasename}", with: (root as NSString).lastPathComponent)
            .replacingOccurrences(of: "${pathSeparator}", with: "/")
    }

    private static func shellWord(_ word: String) -> String {
        if word.isEmpty { return "''" }
        let safe = word.allSatisfy { $0.isLetter || $0.isNumber || "-_./:=@%+,".contains($0) }
        return safe ? word : "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func read(_ file: String, in root: String) -> [String: Any]? {
        guard let text = try? String(contentsOfFile: root + "/.vscode/" + file, encoding: .utf8) else { return nil }
        return parse(text) as? [String: Any]
    }

    private static func environment(_ value: Any?, root: String) -> [String: String] {
        var result: [String: String] = [:]
        for (key, entry) in (value as? [String: Any]) ?? [:] {
            if let text = entry as? String {
                result[key] = expand(text, root: root)
            } else if let number = entry as? NSNumber {
                result[key] = number.stringValue
            }
        }
        return result
    }

    private static func directory(_ value: Any?, root: String) -> String {
        guard let path = value as? String, !path.isEmpty else { return root }
        let expanded = expand(path, root: root)
        return expanded.hasPrefix("/") ? expanded : root + "/" + expanded
    }

    /// The tasks of `tasks.json` (and a platform's `osx` override of the command), as entries.
    public static func tasks(in root: String) -> [RunEntry] {
        guard let file = read("tasks.json", in: root), let tasks = file["tasks"] as? [[String: Any]] else { return [] }
        var entries: [RunEntry] = []
        let defaults = file["options"] as? [String: Any]
        for task in tasks {
            let platform = task["osx"] as? [String: Any]
            func value(_ key: String) -> Any? { platform?[key] ?? task[key] }
            guard let label = (task["label"] as? String) ?? (task["taskName"] as? String),
                  let command = value("command") as? String else { continue }
            let arguments = (value("args") as? [Any] ?? []).compactMap { argument -> String? in
                if let text = argument as? String { return expand(text, root: root) }
                if let dictionary = argument as? [String: Any],
                   let text = dictionary["value"] as? String
                { return expand(
                    text,
                    root: root
                ) }
                return nil
            }
            let isShell = (value("type") as? String ?? "shell") == "shell"
            let expandedCommand = expand(command, root: root)
            // A shell task's command is a command line; a process task's is a program, its arguments words.
            let line = isShell
                ? ([expandedCommand] + arguments.map(shellWord)).joined(separator: " ")
                : ([shellWord(expandedCommand)] + arguments.map(shellWord)).joined(separator: " ")
            let options = (value("options") as? [String: Any]) ?? [:]
            var env = environment(defaults?["env"], root: root)
            env.merge(environment(options["env"], root: root)) { _, new in new }
            let group = task["group"]
            let groupKind = (group as? String) ?? ((group as? [String: Any])?["kind"] as? String)
            let isDefault = ((group as? [String: Any])?["isDefault"] as? Bool) ?? false
            let kind: RunEntry.Kind = groupKind == "build" ? .build : (groupKind == "test" ? .test : .task)
            entries.append(RunEntry(
                title: label, source: "VS Code", kind: kind, command: line,
                directory: directory(options["cwd"] ?? defaults?["cwd"], root: root), environment: env,
                isDefault: isDefault
            ))
        }
        return entries
    }

    /// The launch configurations that are a program to run.
    public static func launches(in root: String) -> [RunEntry] {
        guard let file = read("launch.json", in: root), let configs = file["configurations"] as? [[String: Any]]
        else { return [] }
        var entries: [RunEntry] = []
        for config in configs {
            guard let name = config["name"] as? String, let type = config["type"] as? String,
                  (config["request"] as? String ?? "launch") == "launch" else { continue }
            let program = (config["program"] as? String).map { expand($0, root: root) }
            let arguments = (config["args"] as? [Any] ?? [])
                .compactMap { ($0 as? String).map { expand($0, root: root) } }
            var words: [String]
            switch type {
            case "node", "pwa-node":
                guard let program else { continue }
                words = ["node", program]
            case "python", "debugpy":
                guard let program else { continue }
                words = ["python3", program]
            case "coreclr":
                guard let program else { continue }
                words = program.hasSuffix(".dll") ? ["dotnet", program] : [program]
            case "lldb", "cppdbg", "cppvsdbg", "go", "swift":
                guard let program else { continue }
                words = [program]
            default:
                continue
            }
            var env = environment(config["env"], root: root)
            if let cwd = config["cwd"] as? String { env["PWD"] = nil; _ = cwd }
            entries.append(RunEntry(
                title: name, source: "VS Code", kind: .run,
                command: (words + arguments).map(shellWord).joined(separator: " "),
                directory: directory(config["cwd"], root: root), environment: env, origin: ".vscode/launch.json"
            ))
        }
        return entries
    }
}
