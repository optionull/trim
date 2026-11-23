import Foundation

/// What a filter found: the files whose path holds the text, and the folders above them, as absolute paths.
public struct FilterResult: Equatable, Sendable {
    public var paths: Set<String>
    /// The walk stopped at its limit, so there may be more than is listed.
    public var truncated: Bool

    public init(paths: Set<String> = [], truncated: Bool = false) {
        self.paths = paths
        self.truncated = truncated
    }
}

public extension FileTree {
    /// Walks a folder for the files whose path (from `root`, so a folder's name counts) holds `text`, without regard to
    /// case. What the tree would leave out (git's own folder, ignored files and dotfiles, as asked) is not walked, an
    /// ignored folder not at all. Pure and `Sendable`: for off the main thread, then handed to `setFilter`.
    static func scan(
        root: String,
        text: String,
        showDotfiles: Bool,
        showIgnored: Bool,
        ignored: Set<String>,
        limit: Int = 50000
    ) -> FilterResult {
        let needle = text.lowercased()
        guard !needle.isEmpty else { return FilterResult() }
        let manager = FileManager.default
        var result = FilterResult()
        var visited = 0
        // Folders with a match somewhere below, as the walk comes back up: the stack holds (folder, found one yet).
        var found: Set<String> = []
        var pending = [root]
        var folders: [String] = []
        while let folder = pending.popLast() {
            folders.append(folder)
            for name in (try? manager.contentsOfDirectory(atPath: folder)) ?? [] {
                visited += 1
                if visited > limit {
                    result.truncated = true
                    break
                }
                if name == ".git" || (!showDotfiles && name.hasPrefix(".")) { continue }
                let path = folder + "/" + name
                if !showIgnored, ignored.contains(path) { continue }
                var isDirectory: ObjCBool = false
                guard manager.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
                if isDirectory.boolValue {
                    pending.append(path)
                } else if String(path.dropFirst(root.count + 1)).lowercased().contains(needle) {
                    found.insert(path)
                }
            }
            if result.truncated { break }
        }
        // The folders above each file found.
        for file in found {
            result.paths.insert(file)
            var folder = (file as NSString).deletingLastPathComponent
            while folder.hasPrefix(root), result.paths.insert(folder).inserted {
                if folder == root { break }
                folder = (folder as NSString).deletingLastPathComponent
            }
        }
        return result
    }
}
