import Foundation

/// The files of a workspace, and finding among them: what the finder lists and ranks. No UI. Git's own list when the
/// folder is a
/// repository (tracked and untracked files, the ignored left out), else a walk that skips the folders nothing is
/// searched in.
public enum FileIndex {
    /// Folders a walk does not go into.
    static let skipped: Set<String> = [
        ".git", ".build", "node_modules", "target", "obj", "bin", "artifacts", ".sill", ".DS_Store", "build", "dist",
        ".venv",
        "__pycache__",
    ]

    /// The files under `root`, as paths relative to it, in a stable order.
    public static func files(in root: String, limit: Int = 200_000) async -> [String] {
        await Task.detached {
            if let listed = git(["ls-files", "-z", "--cached", "--others", "--exclude-standard"], in: root) {
                return Array(listed.split(separator: "\0").map(String.init).sorted().prefix(limit))
            }
            return walk(root, limit: limit)
        }.value
    }

    private static func walk(_ root: String, limit: Int) -> [String] {
        var found: [String] = []
        // The enumerator reports real paths (/private/var, where Foundation's own resolving says /var).
        let real = realpath(root, nil).map { pointer -> String in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? root
        let base = URL(fileURLWithPath: real)
        guard let walker = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [
                .skipsHiddenFiles,
                .skipsPackageDescendants,
            ]
        ) else { return [] }
        for case let url as URL in walker {
            if skipped.contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { continue }
            found.append(String(url.path.dropFirst(base.path.count + 1)))
            if found.count >= limit { break }
        }
        return found.sorted()
    }

    /// Runs git in `root`: what it printed, or nil when it is not a repository (or git is not there).
    static func git(_ arguments: [String], in root: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root] + arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    /// Whether the characters of `query` appear in `text` in order, ignoring case: the cheap test that comes before the
    /// scoring, so most files are never scored.
    static func isSubsequence(_ query: [UInt8], of text: String) -> Bool {
        var next = 0
        for byte in text.utf8 {
            let lower = byte >= 65 && byte <= 90 ? byte + 32 : byte
            if next < query.count, lower == query[next] { next += 1 }
        }
        return next == query.count
    }

    /// The files that match `query`, best first, at most `limit`. A match in the file's name counts for more than one
    /// in
    /// its folders, and a shorter path wins a tie. No query: the first `limit` files.
    public static func rank(_ query: String, in files: [String], limit: Int = 200) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return Array(files.prefix(limit)) }
        let needle = Array(trimmed.lowercased().utf8)
        var scored: [(score: Int, path: String)] = []
        for path in files where isSubsequence(needle, of: path) {
            guard let whole = Fuzzy.match(trimmed, in: path) else { continue }
            let name = (path as NSString).lastPathComponent
            let inName = Fuzzy.match(trimmed, in: name).map { $0.score + 30 } ?? 0
            scored.append((max(whole.score, inName) * 10 - path.count, path))
        }
        scored.sort { ($0.score, $1.path) > ($1.score, $0.path) }
        return scored.prefix(limit).map(\.path)
    }

    public struct Hit: Equatable, Sendable {
        public var path: String
        public var line: Int
        public var text: String
    }

    /// Lines under `root` that contain `query` (as text, not a pattern), by git for a repository (so ignored files are
    /// not
    /// searched) and by grep otherwise; at most `limit`.
    public static func grep(_ query: String, in root: String, limit: Int = 200) async -> [Hit] {
        guard !query.isEmpty else { return [] }
        return await Task.detached {
            var out = git(["grep", "-n", "-I", "-F", "-i", "--no-color", "--untracked", "-e", query], in: root)
            if out == nil {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
                process.arguments = [
                    "-rnIFi",
                    "--exclude-dir=.git",
                    "--exclude-dir=node_modules",
                    "--exclude-dir=.build",
                    "-e",
                    query,
                    ".",
                ]
                process.currentDirectoryURL = URL(fileURLWithPath: root)
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                if (try? process.run()) != nil {
                    out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    process.waitUntilExit()
                }
            }
            return parse(out ?? "", limit: limit)
        }.value
    }

    /// `path:line:text` lines as hits.
    static func parse(_ output: String, limit: Int) -> [Hit] {
        var hits: [Hit] = []
        for row in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = row.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let line = Int(parts[1]) else { continue }
            var path = String(parts[0])
            if path.hasPrefix("./") { path.removeFirst(2) }
            hits.append(Hit(path: path, line: line, text: parts[2].trimmingCharacters(in: .whitespaces)))
            if hits.count >= limit { break }
        }
        return hits
    }
}
