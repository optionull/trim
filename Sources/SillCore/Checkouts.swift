import Foundation

/// The git checkouts under the folders sill watches (its roots): every repository found there and every worktree of
/// them, wherever it is. Home lists them, most recently active first. Everything here only reads: watching a
/// repository changes nothing in it (no `.sill` made, no exclude written).
public struct Checkout: Equatable, Sendable, Hashable, Codable {
    /// The checkout's root, as the file system names it.
    public var path: String
    /// The main worktree's root: the repository's name, and where its `.sill` is.
    public var repository: String
    public var isWorktree: Bool

    public init(path: String, repository: String, isWorktree: Bool) {
        self.path = path
        self.repository = repository
        self.isWorktree = isWorktree
    }

    public var name: String { (path as NSString).lastPathComponent }
    public var repositoryName: String { (repository as NSString).lastPathComponent }
}

public enum Checkouts {
    /// Folders never looked into: dependencies and build output hold no checkouts of one's own.
    static let skipped: Set = ["node_modules", "bin", "obj", "target", "dist", "build", "vendor", "Pods", "DerivedData"]

    /// The repositories under `roots` (a folder with `.git`, not looked into further, `depth` levels down at most),
    /// and their worktrees as git lists them. Paths are real ones; each checkout once.
    public static func find(roots: [String], depth: Int = 4) -> [Checkout] {
        var repositories: [String] = []
        func walk(_ folder: String, _ level: Int) {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: folder + "/.git") {
                repositories.append(folder)
                return
            }
            guard level < depth, let names = try? fileManager.contentsOfDirectory(atPath: folder) else { return }
            for name in names where !name.hasPrefix(".") && !skipped.contains(name) {
                var isFolder: ObjCBool = false
                let path = folder + "/" + name
                if fileManager.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue {
                    walk(path, level + 1)
                }
            }
        }
        for root in roots {
            walk(realPath(root), 0)
        }
        // Each repository's worktrees, asked in parallel: the main one first, the rest where git keeps them.
        let found = Parallel.map(repositories) { worktrees(of: $0) }
        var seen: Set<String> = [], checkouts: [Checkout] = []
        for checkout in found.flatMap({ $0 }) where seen.insert(checkout.path).inserted {
            checkouts.append(checkout)
        }
        return checkouts
    }

    /// A repository's checkouts from `git worktree list --porcelain`; a worktree whose folder is gone is left out.
    static func worktrees(of folder: String) -> [Checkout] {
        guard let listed = Review.git(["worktree", "list", "--porcelain"], in: folder) else {
            return [Checkout(path: realPath(folder), repository: realPath(folder), isWorktree: false)]
        }
        let paths = listed.split(separator: "\n").filter { $0.hasPrefix("worktree ") }.map { String($0.dropFirst(9)) }
        guard let main = paths.first else { return [] }
        return paths.enumerated().compactMap { index, path in
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return Checkout(path: realPath(path), repository: realPath(main), isWorktree: index > 0)
        }
    }

    /// The `.sill` folder of a checkout's repository, if there is one (never made here).
    public static func sillFolder(of checkout: Checkout) -> String? {
        let folder = checkout.repository + "/" + SillFolder.name
        return FileManager.default.fileExists(atPath: folder) ? folder : nil
    }
}

/// Work done on every core at once, the results in the order of the input.
enum Parallel {
    static func map<T: Sendable, R: Sendable>(_ items: [T], _ transform: @Sendable (T) -> R) -> [R] {
        let results = Results<R>(count: items.count)
        DispatchQueue.concurrentPerform(iterations: items.count) { index in
            results.set(index, transform(items[index]))
        }
        return results.values
    }

    private final class Results<R>: @unchecked Sendable {
        private let lock = NSLock()
        private var slots: [R?]
        init(count: Int) { slots = Array(repeating: nil, count: count) }
        func set(_ index: Int, _ value: R) { lock.withLock { slots[index] = value } }
        var values: [R] { lock.withLock { slots.compactMap { $0 } } }
    }
}
