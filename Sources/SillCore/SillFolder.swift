import Foundation

/// `.sill/` at a repository's root: what sill keeps for it (baskets, review walkthroughs, the code map's summary and
/// tour), private to this machine. sill adds it to the repository's `.git/info/exclude`, which is never committed
/// and covers every worktree, so git, reviews and the agents' diffs never see it.
public enum SillFolder {
    public static let name = ".sill"

    /// The `.sill` folder for `directory`: at its repository's root (made, and kept out of git), else in the folder
    /// itself outside a repository.
    public static func path(for directory: String) -> String {
        let root = Review.git(["rev-parse", "--show-toplevel"], in: directory)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = ((root ?? directory) as NSString).appendingPathComponent(name)
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        if root != nil, let common = Review.git(
            ["rev-parse", "--path-format=absolute", "--git-common-dir"], in: directory
        )?.trimmingCharacters(in: .whitespacesAndNewlines) {
            exclude(in: common)
            moveOld(
                from: (Review.git(["rev-parse", "--absolute-git-dir"], in: directory) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                to: folder
            )
        }
        return folder
    }

    /// The line that keeps `.sill/` out of git.
    static let excludeLine = "/\(name)/"

    /// Adds `/.sill/` to `<git common dir>/info/exclude` unless it is there.
    public static func exclude(in commonDir: String) {
        let info = (commonDir as NSString).appendingPathComponent("info")
        let file = (info as NSString).appendingPathComponent("exclude")
        let text = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        guard !text.components(separatedBy: "\n").contains(where: {
            $0.trimmingCharacters(in: .whitespaces) == excludeLine
        }) else { return }
        try? FileManager.default.createDirectory(atPath: info, withIntermediateDirectories: true)
        let added = (text.isEmpty || text.hasSuffix("\n") ? text : text + "\n") +
            "# sill's own folder: baskets, review walkthroughs (never committed)\n\(excludeLine)\n"
        try? added.write(toFile: file, atomically: true, encoding: .utf8)
    }

    /// What sill kept in `.git/sill` before `.sill` (reviews, the map's summary and tour), moved over once.
    static func moveOld(from gitDir: String, to folder: String) {
        guard !gitDir.isEmpty else { return }
        let old = (gitDir as NSString).appendingPathComponent("sill")
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(atPath: old) else { return }
        for entry in entries {
            let target = (folder as NSString).appendingPathComponent(entry)
            if !manager.fileExists(atPath: target) {
                try? manager.moveItem(atPath: (old as NSString).appendingPathComponent(entry), toPath: target)
            }
        }
        if (try? manager.contentsOfDirectory(atPath: old))?.isEmpty == true { try? manager.removeItem(atPath: old) }
    }

    /// The repository a file inside `.sill` belongs to: the folder around `.sill`; nil for a file outside one.
    public static func repository(containing path: String) -> String? {
        path.range(of: "/\(name)/").map { String(path[..<$0.lowerBound]) }
    }
}
