import Foundation

/// When the person last looked at a checkout in sill, and its worktree then (a tree, as a review baseline): what is new
/// since. Leaving (sill no longer in front, or the checkout's window closed) notes the moment; coming back after a
/// real absence makes it the point, so a glance at a terminal does not move it under a review. Kept in the
/// repository's `.sill/looked.json`, by checkout.
public enum Looked {
    public struct Point: Codable, Equatable, Sendable {
        public var at: Date
        public var tree: String

        public init(at: Date, tree: String) {
            self.at = at
            self.tree = tree
        }
    }

    struct Entry: Codable, Equatable {
        /// What is new is since this.
        var point: Point?
        /// The last leaving, not yet a point.
        var left: Point?
    }

    /// Away for less than this is not having left.
    public static let absence: TimeInterval = 300

    public static func file(_ sillFolder: String) -> String { sillFolder + "/looked.json" }

    static func read(_ sillFolder: String) -> [String: Entry] {
        guard let data = FileManager.default.contents(atPath: file(sillFolder)),
              let entries = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return entries
    }

    private static func write(_ entries: [String: Entry], _ sillFolder: String) {
        try? JSONEncoder().encode(entries).write(to: URL(fileURLWithPath: file(sillFolder)), options: .atomic)
    }

    /// The point for `checkout` (its path): what is new is since then.
    public static func point(_ sillFolder: String, checkout: String) -> Point? { read(sillFolder)[checkout]?.point }

    /// Left it: the worktree now (`tree`) noted.
    public static func left(_ sillFolder: String, checkout: String, tree: String, at date: Date = Date()) {
        var entries = read(sillFolder)
        entries[checkout, default: Entry()].left = Point(at: date, tree: tree)
        write(entries, sillFolder)
    }

    /// Back at it: the last leaving becomes the point when it was a real absence (else the point stays); the point.
    @discardableResult
    public static func returned(_ sillFolder: String, checkout: String, now: Date = Date()) -> Point? {
        var entries = read(sillFolder)
        guard var entry = entries[checkout] else { return nil }
        guard let left = entry.left else { return entry.point }
        if now.timeIntervalSince(left.at) >= absence { entry.point = left }
        entry.left = nil
        entries[checkout] = entry
        write(entries, sillFolder)
        return entry.point
    }
}

/// The changed files the person marked seen in a review, by checkout: each with its content then (its blob), so a
/// file changed again is not seen. Kept in the repository's `.sill/seen-files.json`.
public enum SeenFiles {
    /// A deleted file's content.
    public static let deleted = "deleted"

    public static func file(_ sillFolder: String) -> String { sillFolder + "/seen-files.json" }

    static func all(_ sillFolder: String) -> [String: [String: String]] {
        guard let data = FileManager.default.contents(atPath: file(sillFolder)),
              let entries = try? JSONDecoder().decode([String: [String: String]].self, from: data)
        else { return [:] }
        return entries
    }

    /// Path to its content when it was marked seen.
    public static func read(_ sillFolder: String, checkout: String) -> [String: String] {
        all(sillFolder)[checkout] ?? [:]
    }

    /// Marks these seen (path to content), or not seen (content nil).
    public static func mark(_ files: [String: String?], in sillFolder: String, checkout: String) {
        var entries = all(sillFolder)
        for (path, blob) in files {
            entries[checkout, default: [:]][path] = blob
        }
        try? JSONEncoder().encode(entries).write(to: URL(fileURLWithPath: file(sillFolder)), options: .atomic)
    }

    /// The contents (blobs) of `paths` in `tree`; a path it does not have is `deleted`.
    public static func contents(of paths: [String], in tree: String, directory: String) -> [String: String] {
        guard !paths.isEmpty else { return [:] }
        var found: [String: String] = [:]
        // `<mode> blob <id>\t<path>`, a line each.
        for line in (Review.git(["ls-tree", "-r", "-z", tree, "--"] + paths, in: directory) ?? "")
            .split(separator: "\0")
        {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, let id = parts[0].split(separator: " ").last else { continue }
            found[String(parts[1])] = String(id)
        }
        return Dictionary(uniqueKeysWithValues: paths.map { ($0, found[$0] ?? deleted) })
    }
}
