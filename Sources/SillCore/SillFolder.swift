import Foundation

/// `.sill/` at a repository's root: what sill keeps for it (baskets, review walkthroughs, the code map's summary and
/// tour), private to this machine. Like `.git`, there is one for the repository, at the main worktree's root, whichever
/// worktree sill is open on; what is in it resolves against the worktree sill is open on. sill adds it to the
/// repository's `.git/info/exclude`, which is never committed and covers every worktree, so git, reviews and the
/// agents' diffs never see it.
public enum SillFolder {
    public static let name = ".sill"

    private static func git(_ arguments: [String], _ directory: String) -> String? {
        Review.git(arguments, in: directory)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// The root of the worktree `directory` is in; nil outside a repository.
    public static func worktreeRoot(for directory: String) -> String? {
        git(["rev-parse", "--show-toplevel"], directory)
    }

    /// The main worktree's root: the folder around the common `.git` (a bare repository's worktrees have none: their
    /// own root then).
    public static func mainRoot(for directory: String) -> String? {
        guard let common = git(["rev-parse", "--path-format=absolute", "--git-common-dir"], directory) else {
            return nil
        }
        return (common as NSString).lastPathComponent == ".git" ? (common as NSString).deletingLastPathComponent :
            worktreeRoot(for: directory)
    }

    /// The `.sill` folder for `directory`: at its repository's main worktree (made, and kept out of git; a
    /// worktree's own, from before, merged in), else in the folder itself outside a repository.
    public static func path(for directory: String) -> String {
        let main = mainRoot(for: directory)
        let folder = ((main ?? directory) as NSString).appendingPathComponent(name)
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        guard main != nil, let common = git(["rev-parse", "--path-format=absolute", "--git-common-dir"], directory)
        else { return folder }
        exclude(in: common)
        moveOld(from: (git(["rev-parse", "--absolute-git-dir"], directory) ?? "") + "/sill", to: folder)
        if let own = worktreeRoot(for: directory), own != main {
            moveOld(from: (own as NSString).appendingPathComponent(name), to: folder)
        }
        return folder
    }

    /// `path` from the root of the worktree it is in, when that is a worktree of `directory`'s repository (the one
    /// sill is open on first); else as it is.
    public static func relative(_ path: String, in directory: String) -> String {
        relative(path, roots: roots(for: directory))
    }

    /// The roots `relative` measures from: `directory`'s worktree and every worktree of its repository. Asks git,
    /// twice: find them once where that matters (a hook's answer), and use `relative(_:roots:)`.
    public static func roots(for directory: String) -> [String] {
        var roots = worktreeRoot(for: directory).map { [$0] } ?? []
        let listed = git(["worktree", "list", "--porcelain"], directory) ?? ""
        roots += listed.split(separator: "\n").filter { $0.hasPrefix("worktree ") }.map { String($0.dropFirst(9)) }
        return roots
    }

    /// `path` from the deepest of `roots` it is in; else as it is. No git: strings only.
    public static func relative(_ path: String, roots: [String]) -> String {
        for root in roots.sorted(by: { $0.count > $1.count }) where path.hasPrefix(root + "/") {
            return String(path.dropFirst(root.count + 1))
        }
        return path
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

    /// What sill kept elsewhere before (`.git/sill`, a worktree's own `.sill`), merged in: a folder's entries one by
    /// one (baskets with baskets), nothing that is already there overwritten; the old place removed once empty.
    static func moveOld(from old: String, to folder: String) {
        guard old != folder, old != "/sill" else { return }
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(atPath: old) else { return }
        for entry in entries {
            let source = (old as NSString).appendingPathComponent(entry)
            let target = (folder as NSString).appendingPathComponent(entry)
            var sourceIsFolder: ObjCBool = false, targetIsFolder: ObjCBool = false
            _ = manager.fileExists(atPath: source, isDirectory: &sourceIsFolder)
            if !manager.fileExists(atPath: target, isDirectory: &targetIsFolder) {
                try? manager.moveItem(atPath: source, toPath: target)
            } else if sourceIsFolder.boolValue, targetIsFolder.boolValue {
                moveOld(from: source, to: target)
            }
        }
        if (try? manager.contentsOfDirectory(atPath: old))?.isEmpty == true { try? manager.removeItem(atPath: old) }
    }

    /// The repository a file inside `.sill` belongs to: the folder around `.sill`; nil for a file outside one.
    public static func repository(containing path: String) -> String? {
        path.range(of: "/\(name)/").map { String(path[..<$0.lowerBound]) }
    }
}
