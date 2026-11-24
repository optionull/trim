import Foundation

/// `trim walk ...` and `trim skill ...`: what an agent runs to write a walkthrough Trim can show. A function of its
/// arguments, so it is tested without a process; the `trim` tool only passes `CommandLine.arguments` to it.
public enum WalkCommands {
    public static let usage = """
    usage: trim walk check <file> [--root <dir>] [--json]   check a walkthrough; exit 1 when it has errors
           trim walk stamp <file> [--root <dir>]            record each anchor's fingerprint and the commit
           trim walk new "<title>" [--for <path>]           make a skeleton in .trim/walkthroughs, print its path
           trim walk list [--json]                          the repository's walkthroughs
           trim walk open <file>                            show it in Trim
           trim walk format                                 print the skill that teaches the format
           trim skill install [--dir <folder>]              install the skill (default ~/.claude/skills)
    """

    /// Runs one command; `out` and `err` take what it prints. The exit code: 0 ok, 1 the walkthrough has errors, 2
    /// misuse.
    public static func run(
        _ arguments: [String], cwd: String, out: (String) -> Void, err: (String) -> Void,
        open: (URL) -> Void = { _ in }
    ) -> Int32 {
        var args = arguments
        func flag(_ name: String) -> Bool {
            guard let index = args.firstIndex(of: name) else { return false }
            args.remove(at: index)
            return true
        }
        func value(_ name: String) -> String? {
            guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
            let found = args[index + 1]
            args.removeSubrange(index ... index + 1)
            return found
        }
        let json = flag("--json")
        let root = value("--root")
        let folder = value("--dir")
        let target = value("--for")
        guard let group = args.first else { err(usage); return 2 }
        func absolute(_ path: String) -> String { path.hasPrefix("/") ? path : cwd + "/" + path }
        func resolver(for file: String) -> AnchorResolver {
            let here = (file as NSString).deletingLastPathComponent
            // A walkthrough in `.trim/` lives at the repository's main worktree, whichever worktree it explains: its
            // anchors are read in the worktree the tool is run in.
            let reads = file.contains("/\(TrimFolder.name)/") ? cwd : here
            return AnchorResolver(root: root.map(absolute) ?? TrimFolder.worktreeRoot(for: reads), folder: here)
        }
        switch (group, args.dropFirst().first) {
        case ("walk", "check"):
            guard args.count == 3 else { err(usage); return 2 }
            let file = absolute(args[2])
            guard let text = try? String(contentsOfFile: file, encoding: .utf8)
            else { err("no file \(args[2])"); return 2 }
            let report = WalkCheck.run(text, resolver: resolver(for: file))
            if json { out(report.json()) } else {
                for problem in report
                    .problems
                {
                    out("\(args[2]):\(problem.line): \(problem.severity): \(problem.message)")
                }
                let errors = report.problems.count(where: { $0.severity == "error" })
                out(report
                    .ok ? "ok: \(report.steps) steps, \(report.anchors) anchors" :
                    "\(errors) error\(errors == 1 ? "" : "s")")
            }
            return report.ok ? 0 : 1
        case ("walk", "stamp"):
            guard args.count == 3 else { err(usage); return 2 }
            let file = absolute(args[2])
            guard let text = try? String(contentsOfFile: file, encoding: .utf8)
            else { err("no file \(args[2])"); return 2 }
            let resolved = resolver(for: file)
            let day = ISO8601DateFormatter().string(from: Date()).prefix(10)
            let stamped = Walkthrough.stamping(
                text,
                resolver: resolved,
                commit: TrimFolder.head(for: resolved.root),
                date: String(day)
            )
            do { try stamped.write(toFile: file, atomically: true, encoding: .utf8) } catch {
                err("cannot write \(args[2])"); return 2
            }
            out(stamped == text ? "nothing to stamp" : "stamped \(args[2])")
            return 0
        case ("walk", "new"):
            guard args.count >= 3 else { err(usage); return 2 }
            let title = args[2...].joined(separator: " ")
            let base = TrimFolder.path(for: root.map(absolute) ?? cwd) + "/" + TrimFolder.walkthroughs
            let slug = slugged(title)
            var path = "\(base)/\(slug).walk.md", number = 2
            while FileManager.default
                .fileExists(atPath: path)
            {
                path = "\(base)/\(slug)-\(number).walk.md"; number += 1
            }
            let by = ProcessInfo.processInfo.environment["TRIM_AGENT"] ?? "agent"
            let skeleton = """
            ---
            title: \(title)
            for: \(target ?? ".")
            by: \(by)
            ---
            One or two sentences on what this explains and why it matters.

            ## First idea
            What happens here, in a few sentences.
            @code <Type.Member or path:lines>
            """
            do { try skeleton.write(toFile: path, atomically: true, encoding: .utf8) } catch {
                err("cannot write \(path)"); return 2
            }
            out(path)
            return 0
        case ("walk", "list"):
            let found = WalkFiles.find(in: root.map(absolute) ?? TrimFolder.worktreeRoot(for: cwd))
            if json {
                let rows = found.map { [
                    "path": $0.path,
                    "title": $0.title,
                    "by": $0.by ?? "",
                    "private": $0.isPrivate ? "true" : "false",
                ] }
                out((try? String(
                    data: JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]),
                    encoding: .utf8
                )) ?? "[]")
            } else {
                for walk in found {
                    out("\(walk.relative)\t\(walk.title)\(walk.by.map { " (by \($0))" } ?? "")")
                }
            }
            return 0
        case ("walk", "open"):
            guard args.count == 3 else { err(usage); return 2 }
            let file = absolute(args[2])
            guard FileManager.default.fileExists(atPath: file) else { err("no file \(args[2])"); return 2 }
            var components = URLComponents()
            components.scheme = "trim"
            components.host = "walkthrough"
            components.queryItems = [URLQueryItem(name: "path", value: file)]
            if let url = components.url { open(url) }
            return 0
        case ("walk", "format"):
            out(WalkSkill.text)
            return 0
        case ("skill", "install"):
            let base = folder.map(absolute) ?? NSHomeDirectory() + "/.claude/skills"
            let directory = "\(base)/\(WalkSkill.name)"
            do {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try WalkSkill.text.write(toFile: directory + "/SKILL.md", atomically: true, encoding: .utf8)
            } catch { err("cannot write \(directory)"); return 2 }
            out("installed \(directory)/SKILL.md")
            return 0
        default:
            err(usage)
            return 2
        }
    }

    /// `How an order reaches the database` as a file name: `how-an-order-reaches-the-database`.
    static func slugged(_ title: String) -> String {
        let words = title.lowercased().split { !$0.isLetter && !$0.isNumber }.prefix(8)
        let slug = words.joined(separator: "-")
        return slug.isEmpty ? "walkthrough" : slug
    }
}
