import Foundation

/// What a folder's git says of it, read from `.git` itself (a few small files, no process): the repository it belongs
/// to and the branch it is on. A worktree's `.git` is a file that points at its own folder inside the repository's, and
/// that folder's `commondir` points back at the repository's.
public enum GitHead {
    public struct Info: Equatable, Sendable {
        /// The repository's main checkout: where the git root is, whichever worktree this is.
        public var root: String
        /// The folder `.git` was found in (the folder itself, or one above it).
        public var checkout: String
        /// The branch; the first characters of the commit when HEAD is detached; empty when there is none yet.
        public var branch: String
        public var isWorktree: Bool { root != checkout }
        public var rootName: String { (root as NSString).lastPathComponent }
    }

    /// The git info of `path`, looking in the folders above it too (at most `levels` up); nil outside a repository.
    public static func info(at path: String, levels: Int = 8) -> Info? {
        var folder = RealPath.of(path)
        for _ in 0 ... levels {
            if let info = read(checkout: folder) { return info }
            let parent = (folder as NSString).deletingLastPathComponent
            if parent == folder || parent.isEmpty { return nil }
            folder = parent
        }
        return nil
    }

    private static func read(checkout: String) -> Info? {
        let dot = checkout + "/.git"
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dot, isDirectory: &isFolder) else { return nil }
        var gitDirectory = dot
        var root = checkout
        if !isFolder.boolValue {
            // A worktree: ".git" says "gitdir: <repository>/.git/worktrees/<name>".
            guard let text = try? String(contentsOfFile: dot, encoding: .utf8),
                  let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") })
            else { return nil }
            let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            gitDirectory = target.hasPrefix("/") ? target : RealPath.of(checkout + "/" + target)
            if let common = try? String(contentsOfFile: gitDirectory + "/commondir", encoding: .utf8) {
                let relative = common.trimmingCharacters(in: .whitespacesAndNewlines)
                let commonDirectory = relative.hasPrefix("/") ? relative : RealPath.of(gitDirectory + "/" + relative)
                // The common directory is <repository>/.git; its parent is the repository.
                root = (commonDirectory as NSString).deletingLastPathComponent
            }
        }
        let head = (try? String(contentsOfFile: gitDirectory + "/HEAD", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let branch = if head.hasPrefix("ref: refs/heads/") {
            String(head.dropFirst("ref: refs/heads/".count))
        } else if head.hasPrefix("ref: ") {
            String(head.dropFirst(5))
        } else {
            String(head.prefix(8))
        }
        return Info(root: root, checkout: checkout, branch: branch)
    }
}
