import Foundation

/// A run in a terminal, so sill knows how it ended: the command goes into a small POSIX script in the repository's
/// `.sill/runs` (whatever the person's shell is, fish included), which shows the command, runs it where it runs, and
/// writes how it ended beside itself (its exit code, how long it took, when it ended). The Run pane and the summary
/// read that back.
public enum RunScript {
    /// How a run ended.
    public struct Result: Equatable, Sendable {
        public var code: Int32
        public var seconds: Int
        public var at: Date

        public init(code: Int32, seconds: Int, at: Date) {
            self.code = code
            self.seconds = seconds
            self.at = at
        }

        public var passed: Bool { code == 0 }
    }

    /// The script and the result file of a run, by its name and folder, in `runs` (`.sill/runs`).
    public static func paths(name: String, directory: String, in runs: String) -> (script: String, result: String) {
        let base = runs + "/" + BasketFile.fingerprint([name, directory])
        return (base + ".sh", base + ".result")
    }

    /// The script: the command shown as typed, run (from `folder` when it has one), and its end written to `result`.
    public static func script(command: String, folder: String, result: String) -> String {
        let shown = (folder.isEmpty ? "" : "cd \(folder) && ") + command
        return """
        #!/bin/sh
        # Written by sill for one run; it writes how the run ended to the file below. Safe to delete.
        printf '\\033[2m$ %s\\033[0m\\n' \(Runnables.quoted(shown))
        sill_start=$(date +%s)
        \(folder.isEmpty ? "" : "cd \(Runnables.quoted(folder)) || exit\n")\(command)
        sill_code=$?
        sill_end=$(date +%s)
        printf '%s %s %s\\n' "$sill_code" "$((sill_end - sill_start))" "$sill_end" > \(Runnables.quoted(result))
        exit "$sill_code"

        """
    }

    /// The line typed into the terminal: the script, run by sh.
    public static func line(script: String) -> String { "sh " + Runnables.quoted(script) }

    /// How the run ended, from its result file: nil when it has not (or never ran).
    public static func result(_ file: String) -> Result? {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
        let parts = text.split(whereSeparator: \.isWhitespace)
        guard parts.count == 3, let code = Int32(parts[0]), let seconds = Int(parts[1]), let end = Double(parts[2])
        else { return nil }
        return Result(code: code, seconds: seconds, at: Date(timeIntervalSince1970: end))
    }
}
