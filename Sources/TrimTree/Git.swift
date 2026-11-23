import Foundation

/// What git says about a folder, read in one go off the main thread and handed to the tree: which files changed and
/// which paths it ignores. Paths are absolute. Git's own commands, lifted from sill's explorer (`status`, `ignored`).
public struct GitState: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case modified, added, deleted, renamed, untracked, conflicted

        /// From the two letters `git status --porcelain` starts a line with (index, then working tree).
        public init?(porcelain code: String) {
            let letters = Array(code)
            guard letters.count == 2 else { return nil }
            if code == "??" {
                self = .untracked
            } else if letters.contains("U") || code == "AA" || code == "DD" {
                self = .conflicted
            } else if letters.contains("R") || letters.contains("C") {
                self = .renamed
            } else if letters.contains("D") {
                self = .deleted
            } else if letters.contains("A") {
                self = .added
            } else if letters.contains("M") || letters.contains("T") {
                self = .modified
            } else {
                return nil
            }
        }
    }

    public var branch = ""
    public var status: [String: Status] = [:]
    /// Ignored files and folders, as git lists them (a whole ignored folder as itself).
    public var ignored: Set<String> = []

    public init(branch: String = "", status: [String: Status] = [:], ignored: Set<String> = []) {
        self.branch = branch
        self.status = status
        self.ignored = ignored
    }

    /// Reads `directory`'s repository; empty when it is not in one.
    public static func read(in directory: String) -> GitState {
        let directory = RealPath.of(directory)
        guard let top = run(["rev-parse", "--show-toplevel"], in: directory)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !top.isEmpty
        else { return GitState() }
        let real = RealPath.of(top)
        var state = GitState()
        state.branch = run(["rev-parse", "--abbrev-ref", "HEAD"], in: directory)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        for (relative, code) in porcelain(in: directory) {
            if let status = Status(porcelain: code) { state.status[real + "/" + relative] = status }
        }
        for relative in ignoredPaths(in: directory) {
            let path = directory + "/" + (relative.hasSuffix("/") ? String(relative.dropLast()) : relative)
            state.ignored.insert(path)
        }
        return state
    }

    /// `git status`'s changed files by path relative to the repository's root, with their two-letter code.
    static func porcelain(in directory: String) -> [String: String] {
        guard let output = run(["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: directory) else {
            return [:]
        }
        var result: [String: String] = [:]
        var entries = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        while let entry = entries.popFirst() {
            guard entry.count > 3 else { continue }
            let code = String(entry.prefix(2)), path = String(entry.dropFirst(3))
            result[path] = code
            if code.contains("R") || code.contains("C") { _ = entries.popFirst() } // The rename's old path.
        }
        return result
    }

    /// Ignored files and folders (folders end in /), relative to `directory`.
    static func ignoredPaths(in directory: String) -> Set<String> {
        guard let output = run(
            ["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"], in: directory
        ) else { return [] }
        return Set(output.split(separator: "\0").map(String.init))
    }

    static func run(_ arguments: [String], in directory: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
