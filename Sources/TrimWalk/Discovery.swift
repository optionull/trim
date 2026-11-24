import Foundation

/// `.trim/` at a repository's main worktree: what Trim keeps for it, private to this machine (agent-written
/// walkthroughs
/// are made here). Like `.git`, one for the repository whichever worktree Trim is open on; added to the repository's
/// `.git/info/exclude`, which is never committed, so git and the agents' diffs never see it.
public enum TrimFolder {
    public static let name = ".trim"
    public static let walkthroughs = "walkthroughs"

    /// The root of the worktree `directory` is in (the folder itself outside a repository).
    public static func worktreeRoot(for directory: String) -> String {
        Git.run(["rev-parse", "--show-toplevel"], in: directory)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? directory
    }

    /// The short commit `directory`'s repository is at; nil outside one.
    public static func head(for directory: String) -> String? {
        Git.run(["rev-parse", "--short", "HEAD"], in: directory)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The main worktree's root: the folder around the common `.git` (the folder itself outside a repository).
    public static func mainRoot(for directory: String) -> String {
        guard let common = Git.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: directory)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return directory }
        return (common as NSString).lastPathComponent == ".git" ? (common as NSString)
            .deletingLastPathComponent : directory
    }

    /// The folder for `directory`'s repository: `<main root>/.trim`. Made, with `walkthroughs` in it, and kept out of
    /// git
    /// (nothing is written outside the folder but that one line of `.git/info/exclude`).
    @discardableResult
    public static func path(for directory: String, create: Bool = true) -> String {
        let folder = (mainRoot(for: directory) as NSString).appendingPathComponent(name)
        guard create else { return folder }
        try? FileManager.default.createDirectory(
            atPath: (folder as NSString).appendingPathComponent(walkthroughs), withIntermediateDirectories: true
        )
        if let common = Git.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: directory)?
            .trimmingCharacters(in: .whitespacesAndNewlines) { exclude(in: common) }
        return folder
    }

    static let excludeLine = "/\(name)/"

    /// Adds `/.trim/` to `<git common dir>/info/exclude` unless it is there.
    public static func exclude(in commonDir: String) {
        let info = (commonDir as NSString).appendingPathComponent("info")
        let file = (info as NSString).appendingPathComponent("exclude")
        let text = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        guard !text.components(separatedBy: "\n")
            .contains(where: { $0.trimmingCharacters(in: .whitespaces) == excludeLine })
        else { return }
        try? FileManager.default.createDirectory(atPath: info, withIntermediateDirectories: true)
        let added = (text.isEmpty || text.hasSuffix("\n") ? text : text + "\n") +
            "# Trim's own folder: walkthroughs agents write for you (never committed)\n\(excludeLine)\n"
        try? added.write(toFile: file, atomically: true, encoding: .utf8)
    }
}

/// A walkthrough file Trim found.
public struct FoundWalkthrough: Equatable, Sendable {
    public var path: String
    /// From the root it was found under (`.trim/walkthroughs/x.walk.md`, `docs/tour.walk.md`).
    public var relative: String
    public var title: String
    public var by: String?
    public var modified: Date
    /// In `.trim/` (written for this machine) rather than tracked by git (written for the repository).
    public var isPrivate: Bool
}

public enum WalkFiles {
    /// Every walkthrough of the repository `root` is in: those in `.trim/walkthroughs` (of the main worktree) and any
    /// `*.walk.md` git tracks or has not ignored, newest first.
    public static func find(in root: String) -> [FoundWalkthrough] {
        var found: [FoundWalkthrough] = []
        var seen = Set<String>()
        func add(_ path: String, relative: String, isPrivate: Bool) {
            let real = (path as NSString).resolvingSymlinksInPath
            guard seen.insert(real).inserted, let text = try? String(contentsOfFile: path, encoding: .utf8),
                  let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            else { return }
            let walk = Walkthrough(text)
            found.append(FoundWalkthrough(
                path: path, relative: relative, title: walk.title, by: walk.by, modified: modified, isPrivate: isPrivate
            ))
        }
        let folder = (TrimFolder.path(for: root, create: false) as NSString)
            .appendingPathComponent(TrimFolder.walkthroughs)
        if let walker = FileManager.default.enumerator(atPath: folder) {
            for case let relative as String in walker where relative.hasSuffix(".walk.md") {
                add(folder + "/" + relative, relative: ".trim/walkthroughs/" + relative, isPrivate: true)
            }
        }
        let listed = Git
            .run(["ls-files", "--cached", "--others", "--exclude-standard", "--", "*.walk.md"], in: root) ?? ""
        for relative in listed.split(separator: "\n").map(String.init) {
            add(root + "/" + relative, relative: relative, isPrivate: false)
        }
        return found.sorted { $0.modified > $1.modified }
    }
}
