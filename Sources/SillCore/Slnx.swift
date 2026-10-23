import Foundation

/// A .slnx solution, read lightly (no MSBuild): its solution folders, the projects and files it lists, and how far its
/// folders are from the folders on disk. sill's rule (owner, 2026-10-23): a project sits in the solution folder of the
/// directory its own directory is in (`src/tooling/docs-builder/docs-builder.csproj` in `/src/tooling/`); a listed
/// file in its directory's folder (`config/navigation.yml` in `/config/`); a file at the root in `/root/`. `sync`
/// rewrites the solution to that rule, adding nothing it does not already list, every other element kept as it was.
public struct Slnx: Equatable, Sendable {
    /// One element of the solution, kept whole: its name, attributes in order, and children.
    public struct Element: Equatable, Sendable {
        public var name: String
        public var attributes: [(String, String)]
        public var children: [Node]

        public static func == (lhs: Element, rhs: Element) -> Bool {
            lhs.name == rhs.name && lhs.attributes.map(\.0) == rhs.attributes.map(\.0) &&
                lhs.attributes.map(\.1) == rhs.attributes.map(\.1) && lhs.children == rhs.children
        }

        public func attribute(_ name: String) -> String? { attributes.first { $0.0 == name }?.1 }

        mutating func set(_ name: String, _ value: String) {
            if let index = attributes.firstIndex(where: { $0.0 == name }) {
                attributes[index].1 = value
            } else {
                attributes.append((name, value))
            }
        }
    }

    public enum Node: Equatable, Sendable {
        case element(Element)
        case comment(String)
    }

    /// A difference between the solution and the disk.
    public struct Drift: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// Listed, but not on disk in any case.
            case missing
            /// On disk under another case: `actual` is how the disk names it.
            case caseDiffers(actual: String)
            /// In solution folder `from` (nil at the solution's root) where the rule says `to`.
            case misplaced(from: String?, to: String?)
        }

        public var path: String
        public var kind: Kind

        public var message: String {
            switch kind {
            case .missing: "\(path) is listed but not on disk"
            case let .caseDiffers(actual): "\(path) is \(actual) on disk"
            case let .misplaced(from, to):
                "\(path) is in \(from ?? "the solution's root"), its folder on disk is \(to ?? "the solution's root")"
            }
        }
    }

    public static let rootFolder = "/root/"

    public var root: Element
    var declaration: String?

    // MARK: Reading

    public init(text: String) throws {
        let parser = Reader(text)
        root = try parser.read()
        declaration = parser.declaration
    }

    /// The projects and files it lists, each with the solution folder it is in (nil at the root).
    public var listed: [(path: String, isProject: Bool, folder: String?)] {
        var found: [(String, Bool, String?)] = []
        for case let .element(child) in root.children {
            switch child.name {
            case "Folder":
                let folder = child.attribute("Name")
                for case let .element(item) in child.children {
                    if let entry = Self.entry(item) { found.append((entry.path, entry.isProject, folder)) }
                }
            default:
                if let entry = Self.entry(child) { found.append((entry.path, entry.isProject, nil)) }
            }
        }
        return found
    }

    public var folders: [String] {
        root.children.compactMap { node in
            guard case let .element(element) = node, element.name == "Folder" else { return nil }
            return element.attribute("Name")
        }
    }

    static func entry(_ element: Element) -> (path: String, isProject: Bool)? {
        guard element.name == "Project" || element.name == "File",
              let path = element.attribute("Path") else { return nil }
        return (normalized(path), element.name == "Project")
    }

    static func normalized(_ path: String) -> String { path.replacingOccurrences(of: "\\", with: "/") }

    /// The folder the rule puts a project or a file in: nil for the solution's root.
    public static func folder(for path: String, isProject: Bool) -> String? {
        let directory = (normalized(path) as NSString).deletingLastPathComponent
        if isProject {
            let parent = (directory as NSString).deletingLastPathComponent
            return parent.isEmpty ? nil : "/\(parent)/"
        }
        return directory.isEmpty ? rootFolder : "/\(directory)/"
    }

    // MARK: Drift

    /// How the solution differs from the disk under `directory` (the solution's own folder).
    public func drift(in directory: String) -> [Drift] {
        listed.compactMap { entry in
            let actual = Self.actualCase(entry.path, in: directory)
            guard let actual else { return Drift(path: entry.path, kind: .missing) }
            if actual != entry.path { return Drift(path: entry.path, kind: .caseDiffers(actual: actual)) }
            let wanted = Self.folder(for: entry.path, isProject: entry.isProject)
            guard Self.same(entry.folder, wanted) else {
                return Drift(path: entry.path, kind: .misplaced(from: entry.folder, to: wanted))
            }
            return nil
        }
    }

    private static func same(_ lhs: String?, _ rhs: String?) -> Bool {
        lhs?.lowercased() == rhs?.lowercased()
    }

    /// The path as the disk spells it, component by component; nil when it is not there in any case.
    static func actualCase(_ path: String, in directory: String) -> String? {
        var current = directory
        var parts: [String] = []
        for component in path.split(separator: "/").map(String.init) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: current) else { return nil }
            guard let name = names.first(where: { $0 == component }) ??
                names.first(where: { $0.caseInsensitiveCompare(component) == .orderedSame }) else { return nil }
            parts.append(name)
            current = (current as NSString).appendingPathComponent(name)
        }
        return parts.joined(separator: "/")
    }

    // MARK: Sync

    /// The solution rewritten to the rule, changing as little as it can: paths in the disk's case where they are, a
    /// misplaced project or file moved to the end of its folder, a folder that is needed (or a parent of one) added in
    /// name order, a folder left empty gone. Everything else keeps its place. Missing entries stay. Nothing is added.
    public func synced(in directory: String) -> Slnx {
        var leading: [Node] = [], trailing: [Node] = []
        var folders: [String: (element: Element, items: [Element], others: [Node])] = [:]
        /// The folders in the order the solution has them; new ones are placed among them by name.
        var order: [String] = []
        /// Comments written before a folder, kept before it.
        var before: [String: [Node]] = [:]
        var comments: [Node] = []
        var rootItems: [Element] = []
        var seenFolder = false

        func place(_ item: Element, from folder: String?) {
            var item = item
            guard let entry = Self.entry(item) else { return }
            var target = folder
            if let actual = Self.actualCase(entry.path, in: directory) {
                item.set("Path", actual)
                target = Self.folder(for: actual, isProject: entry.isProject)
            }
            if let target {
                let key = Self.key(target, in: folders)
                if folders[key] == nil {
                    folders[key] = (Element(name: "Folder", attributes: [("Name", target)], children: []), [], [])
                }
                folders[key]?.items.append(item)
            } else {
                rootItems.append(item)
            }
        }

        for node in root.children {
            guard case let .element(child) = node else {
                if seenFolder { comments.append(node) } else { leading.append(node) }
                continue
            }
            switch child.name {
            case "Folder":
                seenFolder = true
                let name = child.attribute("Name") ?? "/"
                let key = Self.key(name, in: folders)
                before[key, default: []] += comments
                comments = []
                var shell = child
                shell.children = []
                if folders[key] == nil { folders[key] = (shell, [], []) }
                order.append(key)
                for grandchild in child.children {
                    if case let .element(item) = grandchild, Self.entry(item) != nil {
                        place(item, from: name)
                    } else {
                        folders[key]?.others.append(grandchild)
                    }
                }
            case "Project", "File":
                seenFolder = true
                trailing += comments
                comments = []
                place(child, from: nil)
            default:
                if seenFolder { trailing += comments + [node] } else { leading.append(node) }
                comments = []
            }
        }
        trailing += comments
        // Every folder's parents declared, as the solution formats expect.
        for name in Array(folders.keys) {
            var parent = (String(name.dropFirst().dropLast()) as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                let folder = "/\(parent)/"
                let key = Self.key(folder, in: folders)
                if folders[key] == nil {
                    folders[key] = (Element(name: "Folder", attributes: [("Name", folder)], children: []), [], [])
                }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        // Empty folders go, unless a folder inside them stays (or they hold something else).
        let kept = folders.filter { key, value in
            !value.items.isEmpty || !value.others.isEmpty || folders.keys.contains { $0 != key && $0.hasPrefix(key) &&
                !(folders[$0]?.items.isEmpty ?? true)
            }
        }
        // The solution's folders in its order. One it lacked goes after its parent and the parent's folders, when the
        // parent is there; else before the first folder that sorts after it.
        var placed = order.filter { kept[$0] != nil }
        for key in kept.keys.sorted() where !placed.contains(key) {
            let parent = (String(key.dropFirst().dropLast()) as NSString).deletingLastPathComponent
            let family = parent.isEmpty ? nil : "/\(parent)/".lowercased()
            if let family, let last = placed.lastIndex(where: { $0.hasPrefix(family) }) {
                placed.insert(key, at: last + 1)
            } else {
                placed.insert(key, at: placed.firstIndex { $0 > key } ?? placed.count)
            }
        }
        var children = leading
        for key in placed {
            guard var folder = kept[key]?.element, let value = kept[key] else { continue }
            folder.children = value.items.map(Node.element) + value.others
            children += before[key] ?? []
            children.append(.element(folder))
        }
        children += rootItems.map(Node.element)
        children += trailing
        var synced = self
        synced.root.children = children
        return synced
    }

    /// Folders are told apart without case: the existing spelling wins.
    private static func key(_ name: String, in folders: [String: some Any]) -> String {
        folders.keys.first { $0.lowercased() == name.lowercased() } ?? name.lowercased()
    }

    // MARK: Writing

    /// The solution as text: two spaces a level, an element with no children closed in itself.
    public var text: String {
        var out = declaration.map { $0 + "\n" } ?? ""
        func write(_ node: Node, _ depth: Int) {
            let indent = String(repeating: "  ", count: depth)
            switch node {
            case let .comment(text):
                out += "\(indent)<!--\(text)-->\n"
            case let .element(element):
                let attributes = element.attributes.map { " \($0.0)=\"\(Self.escaped($0.1))\"" }.joined()
                if element.children.isEmpty {
                    out += "\(indent)<\(element.name)\(attributes) />\n"
                } else {
                    out += "\(indent)<\(element.name)\(attributes)>\n"
                    for child in element.children {
                        write(child, depth + 1)
                    }
                    out += "\(indent)</\(element.name)>\n"
                }
            }
        }
        write(.element(root), 0)
        return out
    }

    private static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
    }

    /// The line of the first element listing `path`, 1-based, in the solution's text: where a drift is shown.
    public static func line(of path: String, in text: String) -> Int? {
        let lines = text.components(separatedBy: "\n")
        let needles = ["\"\(path)\"", "\"\(path.replacingOccurrences(of: "/", with: "\\"))\""]
        return lines.firstIndex { line in needles.contains { line.contains($0) } }.map { $0 + 1 }
    }
}

public enum SlnxError: Error, Equatable, CustomStringConvertible {
    case unreadable(String)

    public var description: String {
        switch self {
        case let .unreadable(why): "the .slnx does not read: \(why)"
        }
    }
}

/// XMLParser to the element tree, comments kept.
private final class Reader: NSObject, XMLParserDelegate {
    private let text: String
    private var stack: [Slnx.Element] = []
    private var root: Slnx.Element?
    private var failure: String?
    var declaration: String?

    init(_ text: String) {
        self.text = text
        if let start = text.range(of: "<?xml"), let end = text.range(
            of: "?>",
            range: start.upperBound ..< text.endIndex
        ),
            text[text.startIndex ..< start.lowerBound].allSatisfy(\.isWhitespace)
        {
            declaration = String(text[start.lowerBound ..< end.upperBound])
        }
    }

    func read() throws -> Slnx.Element {
        let parser = XMLParser(data: Data(text.utf8))
        parser.delegate = self
        parser.shouldReportNamespacePrefixes = false
        guard parser.parse(), let root else {
            throw SlnxError.unreadable(failure ?? parser.parserError?.localizedDescription ?? "no root element")
        }
        return root
    }

    func parser(
        _: XMLParser, didStartElement name: String, namespaceURI _: String?, qualifiedName _: String?,
        attributes: [String: String]
    ) {
        stack.append(Slnx.Element(name: name, attributes: Self.ordered(attributes), children: []))
    }

    func parser(_: XMLParser, didEndElement _: String, namespaceURI _: String?, qualifiedName _: String?) {
        guard let element = stack.popLast() else { return }
        if stack.isEmpty {
            root = element
        } else {
            stack[stack.count - 1].children.append(.element(element))
        }
    }

    func parser(_: XMLParser, foundComment comment: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].children.append(.comment(comment))
    }

    func parser(_: XMLParser, parseErrorOccurred error: Error) { failure = error.localizedDescription }

    /// XMLParser gives attributes unordered: the solution format's own come in its usual order (Name, Path, ...), the
    /// rest by name.
    private static func ordered(_ attributes: [String: String]) -> [(String, String)] {
        let preferred = ["Name", "Path", "Id", "Type", "Solution", "Project", "Value"]
        return attributes.sorted { lhs, rhs in
            let left = preferred.firstIndex(of: lhs.key) ?? preferred.count
            let right = preferred.firstIndex(of: rhs.key) ?? preferred.count
            return left != right ? left < right : lhs.key < rhs.key
        }
    }
}
