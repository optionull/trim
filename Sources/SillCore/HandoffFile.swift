import Foundation

/// An agent's handoff: what it did, for the person to read in sill and run, written when it finishes a task. A
/// walkthrough in the repository's `.sill/handoffs/`, for the checkout it worked in (`worktree:`): a summary, the
/// files to read in order (each after a sentence on why), and what to run to see it work (`@run`, which the notebook
/// and the Run pane both offer).
public enum HandoffFile {
    public struct Read: Equatable, Sendable {
        public var path: String
        public var lines: ClosedRange<Int>?
        public var why: String?

        public init(path: String, lines: ClosedRange<Int>? = nil, why: String? = nil) {
            self.path = path
            self.lines = lines
            self.why = why
        }
    }

    public struct Run: Equatable, Sendable {
        public var name: String
        public var command: String

        public init(name: String, command: String) {
            self.name = name
            self.command = command
        }
    }

    /// The notebook's text.
    public static func text(
        title: String,
        summary: String,
        worktree: String,
        by: String,
        read: [Read],
        run: [Run]
    ) -> String {
        var lines = [
            "---",
            "title: \(oneLine(title))",
            "worktree: \(worktree)",
            "by: \(oneLine(by))",
            "status: handoff",
            "---",
            summary.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        if !read.isEmpty {
            lines += ["", "## Read in this order"]
            for file in read {
                if let why = file.why?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !why.isEmpty { lines += ["", why] }
                lines.append("@code " + file.path + (file.lines.map { ":\($0.lowerBound)-\($0.upperBound)" } ?? ""))
            }
        }
        if !run.isEmpty {
            lines += ["", "## Run it"]
            lines += run
                .map { "@run \(oneLine($0.name).replacingOccurrences(of: ":", with: " ")): \(oneLine($0.command))" }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Its file's name: when, and the title as a slug.
    public static func fileName(title: String, at date: Date = Date()) -> String {
        let stamp = date.formatted(.iso8601.year().month().day().dateSeparator(.omitted)
            .time(includingFractionalSeconds: false).timeSeparator(.omitted))
            .replacingOccurrences(of: "T", with: "-").replacingOccurrences(of: "Z", with: "")
        let slug = BasketFile.fileName(for: title).replacingOccurrences(of: BasketFile.suffix, with: "")
        return "\(stamp)-\(slug).walk.md"
    }

    /// What a walkthrough offers to run (its `@run`s), in order.
    public static func runs(in walkthrough: Walkthrough) -> [Run] {
        walkthrough.steps.flatMap(\.blocks).compactMap {
            if case let .run(name, command, _) = $0 { Run(name: name, command: command) } else { nil }
        }
    }

    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// What an agent is told on a session's first prompt (where sill's hooks reach it): to hand off when it finishes,
    /// with sill's tool if it has it, else by writing the file itself into `folder` (the repository's
    /// `.sill/handoffs`).
    public static func instruction(folder: String, worktree: String) -> String {
        """
        sill (the person's editor) shows them what you did. When you finish a task here, hand it off: call sill's \
        sill_handoff tool if you have it; else write \(folder)/<yyyyMMdd-HHmmss>-<slug>.walk.md:
        ---
        title: <what you did, as a title>
        worktree: \(worktree)
        by: <you>
        ---
        <a short paragraph: what changed and why>

        ## Read in this order
        <a sentence on why this file matters>
        @code <path from the checkout's root>:<from>-<to>

        ## Run it
        @run <Name>: <a command, from the checkout's root, that shows it working: the tests you touched, the program>
        """
    }
}
