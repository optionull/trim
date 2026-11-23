import Foundation

/// How bad a diagnostic is, as nvim and LSP number them (1 error ... 4 hint). Comparable: the worse one is greater.
public enum DiagnosticLevel: Int, Comparable, Sendable, CaseIterable {
    case hint = 4, info = 3, warning = 2, error = 1

    public static func < (lhs: DiagnosticLevel, rhs: DiagnosticLevel) -> Bool { lhs.rawValue > rhs.rawValue }
}

/// The worst diagnostic of each file, and of each folder from the worst below it, up to the tree's root. Pure and
/// built off the main thread: a tree only ever looks marks up.
public struct DiagnosticMarks: Equatable, Sendable {
    public private(set) var levels: [String: DiagnosticLevel]

    public static let none = DiagnosticMarks(levels: [:])

    /// `files` (absolute paths with their worst level) folded up through the folders under `root`.
    public static func fold(_ files: [String: DiagnosticLevel], under root: String) -> DiagnosticMarks {
        var levels: [String: DiagnosticLevel] = [:]
        let prefix = root + "/"
        for (path, level) in files where path.hasPrefix(prefix) {
            var current = path
            while current.hasPrefix(prefix) || current == root {
                if let known = levels[current], known >= level { break }
                levels[current] = level
                if current == root { break }
                current = (current as NSString).deletingLastPathComponent
            }
        }
        return DiagnosticMarks(levels: levels)
    }

    public func level(of path: String) -> DiagnosticLevel? { levels[path] }

    /// The paths whose mark is not the same in `other`: the rows to draw again.
    public func changed(from other: DiagnosticMarks) -> Set<String> {
        var paths = Set<String>()
        for (path, level) in levels where other.levels[path] != level {
            paths.insert(path)
        }
        for path in other.levels.keys where levels[path] == nil {
            paths.insert(path)
        }
        return paths
    }
}
