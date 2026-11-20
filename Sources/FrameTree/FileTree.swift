import Foundation

/// A file or folder in the tree. A class, so the outline view keeps its identity (and what is expanded) across
/// reads: a path is the same node for as long as it exists.
public final class TreeNode: Hashable {
    public let path: String
    public let name: String
    public let isDirectory: Bool
    /// Git ignores it (shown only when asked, then dimmed).
    public internal(set) var ignored = false
    /// What git says of the file itself.
    public internal(set) var status: GitState.Status?
    /// A folder with a changed file somewhere below it.
    public internal(set) var changedBelow = false
    /// A folder's entries once read; nil until then.
    public internal(set) var children: [TreeNode]?
    public internal(set) weak var parent: TreeNode?

    init(path: String, isDirectory: Bool) {
        self.path = path
        name = (path as NSString).lastPathComponent
        self.isDirectory = isDirectory
    }

    public static func == (lhs: TreeNode, rhs: TreeNode) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// The tree of a folder, read lazily: a folder's entries are read when asked for, folders first then files, each in
/// the order Finder sorts names. Git's own folder, and what git ignores unless `showIgnored`, are left out. Not
/// thread-safe: use it from one actor; git is read apart (`GitState.read`) and handed in with `apply`.
public final class FileTree {
    public let root: TreeNode
    /// What git ignores: left out unless shown (then dimmed).
    public private(set) var showIgnored = false
    /// Names that start with a dot: shown unless asked not to be. Git's own folder is never shown.
    public private(set) var showDotfiles = true
    public private(set) var git = GitState()
    private var nodes: [String: TreeNode] = [:]
    /// The folders with a changed file somewhere below them, so a folder read later is marked as well.
    private var changedFolders: Set<String> = []

    public init(root path: String) {
        let real = RealPath.of(path)
        root = TreeNode(path: real, isDirectory: true)
        nodes[real] = root
    }

    public func node(at path: String) -> TreeNode? { nodes[path] }

    /// The entries of a folder, read now if they have not been.
    @discardableResult
    public func children(of node: TreeNode) -> [TreeNode] {
        if let read = node.children { return read }
        return reload(node)
    }

    /// Reads a folder again: nodes that are still there are kept, new ones made, gone ones forgotten (with what was
    /// below them).
    @discardableResult
    public func reload(_ folder: TreeNode) -> [TreeNode] {
        guard folder.isDirectory else { return [] }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0 != ".git" }
        var entries: [TreeNode] = []
        for name in names {
            let path = folder.path + "/" + name
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            let node: TreeNode
            if let known = nodes[path], known.isDirectory == isDirectory.boolValue {
                node = known
            } else {
                node = TreeNode(path: path, isDirectory: isDirectory.boolValue)
                nodes[path] = node
            }
            node.parent = folder
            style(node)
            if node.ignored, !showIgnored { continue }
            if !showDotfiles, name.hasPrefix(".") { continue }
            entries.append(node)
        }
        entries.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        let kept = Set(entries)
        for old in folder.children ?? [] where !kept.contains(old) {
            forget(old)
        }
        folder.children = entries
        return entries
    }

    /// Forgets a node and everything below it.
    private func forget(_ node: TreeNode) {
        for child in node.children ?? [] {
            forget(child)
        }
        // Only when it is this node that is known by the path: a file replaced by a folder is a new node.
        if nodes[node.path] === node { nodes[node.path] = nil }
    }

    /// Opens the way to a path: every folder from the root down is read. The folders to expand, root first, and the
    /// node
    /// at the path, when it is there.
    public func reveal(_ path: String) -> (folders: [TreeNode], node: TreeNode?) {
        // As nvim names it: the links followed, so a path under /tmp finds a root that was given as /private/tmp.
        let path = RealPath.of(path)
        guard path.hasPrefix(root.path + "/") else { return ([], nil) }
        var folders = [root]
        var current = root
        let parts = path.dropFirst(root.path.count + 1).split(separator: "/").map(String.init)
        for (index, part) in parts.enumerated() {
            guard let next = children(of: current).first(where: { $0.name == part }) else { return (folders, nil) }
            if index == parts.count - 1 { return (folders, next) }
            guard next.isDirectory else { return (folders, nil) }
            folders.append(next)
            current = next
        }
        return (folders, nil)
    }

    /// Hands in what git said: files marked, folders marked for a change below, ignored ones flagged (and, unless
    /// shown, dropped from the folders read so far). The folders whose entries changed, to be shown again.
    @discardableResult
    public func apply(_ state: GitState) -> [TreeNode] {
        git = state
        changedFolders = []
        for path in state.status.keys {
            var folder = (path as NSString).deletingLastPathComponent
            while folder.hasPrefix(root.path) {
                changedFolders.insert(folder)
                if folder == root.path { break }
                folder = (folder as NSString).deletingLastPathComponent
            }
        }
        var affected: [TreeNode] = []
        for node in nodes.values {
            style(node)
        }
        // A folder read earlier may now hold (or no longer hold) ignored entries.
        affected = reloadLoaded()
        return affected
    }

    /// Shows or hides what git ignores and the names that start with a dot (nil leaves one as it is). The folders whose
    /// entries changed, to be shown again.
    @discardableResult
    public func setVisibility(ignored: Bool? = nil, dotfiles: Bool? = nil) -> [TreeNode] {
        if let ignored { showIgnored = ignored }
        if let dotfiles { showDotfiles = dotfiles }
        return reloadLoaded()
    }

    /// Every folder read so far, read again (parents first, and one that went with a parent is left alone), and those
    /// whose entries are not what they were.
    private func reloadLoaded() -> [TreeNode] {
        var affected: [TreeNode] = []
        let loaded = nodes.values.filter { $0.isDirectory && $0.children != nil }
            .sorted { $0.path.count < $1.path.count }
        for node in loaded where nodes[node.path] === node {
            let before = node.children ?? []
            let after = reload(node)
            if before != after { affected.append(node) }
        }
        return affected
    }

    /// Ignored when git lists the path or a folder above it.
    private func style(_ node: TreeNode) {
        node.status = git.status[node.path]
        node.changedBelow = node.isDirectory && changedFolders.contains(node.path)
        var path = node.path
        var ignored = false
        while path.hasPrefix(root.path), path != root.path {
            if git.ignored.contains(path) {
                ignored = true
                break
            }
            path = (path as NSString).deletingLastPathComponent
        }
        node.ignored = ignored
    }
}
