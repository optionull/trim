import Foundation

/// A symbol's call hierarchy as it is walked: who calls it (incoming) or what it calls (outgoing), a level at a time,
/// each level asked of the language server when it is opened.
public struct TraceTree: Equatable, Sendable {
    public enum Direction: String, Sendable {
        case incoming, outgoing

        public var label: String { self == .incoming ? "callers" : "callees" }
    }

    /// What the language server answered for one symbol.
    public struct Item: Equatable, Sendable {
        /// The server's item, by the number sill.trace keeps it under.
        public var id: Int
        public var name: String
        public var detail: String
        public var path: String
        public var line: Int
        public var column: Int
        /// The line of the call: in the caller (incoming), in this symbol (outgoing).
        public var at: Int?

        public init(
            id: Int, name: String, detail: String = "", path: String, line: Int, column: Int = 1, at: Int? = nil
        ) {
            self.id = id
            self.name = name
            self.detail = detail
            self.path = path
            self.line = line
            self.column = column
            self.at = at
        }

        /// The same symbol, whichever item the server made for it.
        func same(_ other: Item) -> Bool { name == other.name && path == other.path && line == other.line }
    }

    public struct Node: Equatable, Sendable {
        public var item: Item
        public var depth: Int
        public var parent: Int?
        /// Indexes of its calls; nil until asked.
        public var children: [Int]?
        public var expanded = false
        /// It is one of its own ancestors: opening it would go round.
        public var recursive = false
    }

    public var direction: Direction
    public private(set) var nodes: [Node]

    public init(root: Item, direction: Direction) {
        self.direction = direction
        nodes = [Node(item: root, depth: 0)]
    }

    /// The calls of node `index`, as the server answered, sorted by where they are; it is opened.
    public mutating func setChildren(of index: Int, _ items: [Item]) {
        let ancestors = path(to: index).map { nodes[$0].item }
        var children: [Int] = []
        for item in items.sorted(by: { ($0.path, $0.at ?? $0.line) < ($1.path, $1.at ?? $1.line) }) {
            var node = Node(item: item, depth: nodes[index].depth + 1, parent: index)
            node.recursive = ancestors.contains { $0.same(item) }
            if node.recursive { node.children = [] }
            nodes.append(node)
            children.append(nodes.count - 1)
        }
        nodes[index].children = children
        nodes[index].expanded = true
    }

    public mutating func setExpanded(_ index: Int, _ expanded: Bool) {
        nodes[index].expanded = expanded && nodes[index].children != nil
    }

    /// The nodes shown, in order: each opened node's calls under it.
    public var visible: [Int] {
        var out: [Int] = []
        func walk(_ index: Int) {
            out.append(index)
            guard nodes[index].expanded else { return }
            for child in nodes[index].children ?? [] {
                walk(child)
            }
        }
        walk(0)
        return out
    }

    /// From the root to node `index`.
    public func path(to index: Int) -> [Int] {
        var out = [index]
        while let parent = nodes[out[0]].parent {
            out.insert(parent, at: 0)
        }
        return out
    }

    /// The nodes not asked yet down to `depth` below the root, nearest first: what a deeper trace asks next.
    public func unasked(within depth: Int) -> [Int] {
        visible.filter { nodes[$0].children == nil && nodes[$0].depth < depth }
    }

    /// The tree as text, for an agent: a line per node, indented by depth, paths from `root`.
    public func text(relativeTo root: String = "") -> String {
        let prefix = root.isEmpty ? "" : (root.hasSuffix("/") ? root : root + "/")
        func place(_ path: String, _ line: Int) -> String {
            (path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path) + ":\(line)"
        }
        var lines =
            [
                "\(direction.label.capitalized) of \(nodes[0].item.name) (\(place(nodes[0].item.path, nodes[0].item.line))):",
            ]
        for index in visible.dropFirst() {
            let node = nodes[index]
            var line = String(repeating: "  ", count: node.depth) + node.item.name + "  " +
                place(node.item.path, node.item.line)
            if let at = node.item.at, direction == .incoming { line += ", calls at line \(at)" }
            if node.recursive { line += " (recursive)" }
            lines.append(line)
        }
        if nodes[0].children?.isEmpty == true {
            lines.append(direction == .incoming ? "  (no callers found)" : "  (calls nothing found)")
        }
        return lines.joined(separator: "\n")
    }
}
