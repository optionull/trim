import Foundation

/// What an agent changed, for a person to review: the worktree as it was at a moment (a baseline) against the worktree
/// now, file by file and hunk by hunk, and a hunk taken back. A baseline is a git tree of every file in the worktree,
/// untracked ones included and ignored ones not, written through a temporary index, so neither the repository's index
/// nor its history changes. Runs git: call it off the main thread.
public enum Review {
    public struct File: Equatable, Sendable {
        public enum Status: String, Sendable { case added = "A", modified = "M", deleted = "D" }

        public var path: String
        public var status: Status
        public var added: Int
        public var removed: Int
    }

    public struct Hunk: Equatable, Sendable {
        /// `@@ -oldStart,oldCount +newStart,newCount @@` and what follows on that line.
        public var header: String
        public var oldStart: Int
        public var oldCount: Int
        public var newStart: Int
        public var newCount: Int
        /// The hunk's lines, each with its ` `, `-` or `+`.
        public var lines: [String]

        /// The first changed line, in the file as it is now: past the context the hunk starts with.
        public var firstChange: Int { newStart + lines.prefix { $0.hasPrefix(" ") }.count }
    }

    /// A file's diff: the lines before its first hunk (`diff --git`, `---`, `+++`, …), and its hunks.
    public struct Diff: Equatable, Sendable {
        public var header: [String]
        public var hunks: [Hunk]
    }

    /// The worktree now, as a tree (its id); nil outside a git repository.
    public static func snapshot(in directory: String) -> String? {
        guard let gitDir = git(["rev-parse", "--absolute-git-dir"], in: directory)?.trimmed else { return nil }
        let index = NSTemporaryDirectory() + "sill-review-\(UUID().uuidString).index"
        defer { try? FileManager.default.removeItem(atPath: index) }
        // From the repository's own index: what it knows is not hashed again.
        try? FileManager.default.copyItem(atPath: gitDir + "/index", toPath: index)
        let environment = ["GIT_INDEX_FILE": index]
        guard git(["add", "-A", "."], in: directory, environment: environment) != nil else { return nil }
        return git(["write-tree"], in: directory, environment: environment)?.trimmed
    }

    /// The files that differ between two trees, by path.
    public static func files(from base: String, to current: String, in directory: String) -> [File] {
        guard let numbers = git(["diff", "--numstat", "--no-renames", base, current], in: directory),
              let statuses = git(["diff", "--name-status", "--no-renames", base, current], in: directory)
        else { return [] }
        var status: [String: File.Status] = [:]
        for line in statuses.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            if parts.count == 2 { status[String(parts[1])] = File.Status(rawValue: String(parts[0].prefix(1))) }
        }
        return numbers.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2)
            guard parts.count == 3 else { return nil }
            let path = String(parts[2])
            return File(
                path: path,
                status: status[path] ?? .modified,
                added: Int(parts[0]) ?? 0,
                removed: Int(parts[1]) ?? 0
            )
        }.sorted { $0.path < $1.path }
    }

    /// A file's diff between two trees.
    public static func diff(_ path: String, from base: String, to current: String, in directory: String) -> Diff {
        parse(git(["diff", "--no-renames", "-U3", base, current, "--", path], in: directory) ?? "")
    }

    public static func parse(_ text: String) -> Diff {
        var header: [String] = [], hunks: [Hunk] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("@@"), let hunk = Self.hunk(line) {
                hunks.append(hunk)
            } else if line.isEmpty {
                continue
            } else if hunks.isEmpty {
                header.append(line)
            } else {
                // ` `, `-`, `+`, and `\ No newline at end of file`.
                hunks[hunks.count - 1].lines.append(line)
            }
        }
        return Diff(header: header, hunks: hunks)
    }

    private static func hunk(_ line: String) -> Hunk? {
        // @@ -a,b +c,d @@ rest
        let scanner = line.dropFirst(3).split(separator: " ", maxSplits: 2)
        guard scanner.count >= 2 else { return nil }
        func range(_ text: Substring) -> (Int, Int)? {
            let parts = text.dropFirst().split(separator: ",")
            guard let start = Int(parts.first ?? "") else { return nil }
            return (start, parts.count > 1 ? Int(parts[1]) ?? 1 : 1)
        }
        guard let old = range(scanner[0]), let new = range(scanner[1]) else { return nil }
        return Hunk(header: line, oldStart: old.0, oldCount: old.1, newStart: new.0, newCount: new.1, lines: [])
    }

    /// Takes a hunk back in the worktree: the file as the baseline had it there. False when the file changed since
    /// (the hunk no longer applies).
    @discardableResult
    public static func reject(_ hunk: Hunk, of diff: Diff, in directory: String) -> Bool {
        let patch = (diff.header + [hunk.header] + hunk.lines).joined(separator: "\n") + "\n"
        let file = NSTemporaryDirectory() + "sill-review-\(UUID().uuidString).patch"
        defer { try? FileManager.default.removeItem(atPath: file) }
        guard (try? patch.write(toFile: file, atomically: true, encoding: .utf8)) != nil else { return false }
        return git(["apply", "-R", "--recount", "--whitespace=nowarn", file], in: directory) != nil
    }

    /// The baseline's text of a file (empty for one it did not have): for the side by side diff.
    public static func text(of path: String, in tree: String, directory: String) -> String {
        git(["show", "\(tree):\(path)"], in: directory) ?? ""
    }

    /// git's output, or nil when it failed.
    static func git(_ arguments: [String], in directory: String, environment: [String: String] = [:]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
