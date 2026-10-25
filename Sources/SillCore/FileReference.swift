import Foundation

/// A place in a file named in terminal output, as agents, compilers and stack traces print them: `src/Foo.cs:42`,
/// `Foo.swift:42:7`, `Foo.cs(42,7)`, `Foo.cs#L42`, `in /src/Foo.cs:line 42`, `File "foo.py", line 42`, or a bare path.
public struct FileReference: Equatable, Sendable {
    /// Absolute.
    public var path: String
    public var line: Int?
    public var column: Int?

    public init(path: String, line: Int? = nil, column: Int? = nil) {
        self.path = path
        self.line = line
        self.column = column
    }

    // A path (no spaces), then where in it. `(?<![\w.~/@+-])` keeps a match from starting inside a word.
    private static let pattern = try? NSRegularExpression(pattern: #"""
    (?<![\w.~/@+-])((?:~|\.{1,2})?/?[\w.@+-]+(?:/[\w.@+-]+)*)(?::(\d+)(?:[:,](\d+))?(?:-\d+)?|\((\d+)(?:,(\d+))?\)|#L(\d+)(?:-L?\d+)?|:line (\d+))?
    """#)
    private static let python = try? NSRegularExpression(pattern: #"File "([^"]+)", line (\d+)"#)

    /// The reference in `line` around `column` (counted in characters from 0), if what it names is a file that
    /// exists: absolute, from the home folder, or relative to `directory` (where the terminal is) and then `root`
    /// (the project).
    public static func find(
        in line: String, at column: Int, directory: String, root: String,
        exists: (String) -> Bool = { path in
            var folder: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &folder) && !folder.boolValue
        }
    ) -> FileReference? {
        guard let pattern, let python else { return nil }
        let text = line as NSString
        // The click's offset in UTF-16, which NSRegularExpression counts in.
        let characters = Array(line)
        guard column >= 0, column < characters.count else { return nil }
        let offset = String(characters[..<column]).utf16.count
        let range = NSRange(location: 0, length: text.length)
        for match in python.matches(in: line, range: range) where NSLocationInRange(offset, match.range) {
            if let path = resolve(text.substring(with: match.range(at: 1)), directory, root, exists) {
                return FileReference(path: path, line: Int(text.substring(with: match.range(at: 2))))
            }
        }
        for match in pattern.matches(in: line, range: range) where NSLocationInRange(offset, match.range) {
            var name = text.substring(with: match.range(at: 1))
            // Prose around a path: `see Foo.cs.` or `(Foo.cs)`.
            while name.hasSuffix(".") {
                name.removeLast()
            }
            guard let path = resolve(name, directory, root, exists) else { continue }
            func number(_ group: Int) -> Int? {
                let range = match.range(at: group)
                return range.location == NSNotFound ? nil : Int(text.substring(with: range))
            }
            return FileReference(
                path: path,
                line: number(2) ?? number(4) ?? number(6) ?? number(7),
                column: number(3) ?? number(5)
            )
        }
        return nil
    }

    /// A place another app asks sill to open: `sill://open?path=/abs/Foo.cs&line=42&column=7`, or a file URL.
    public init?(url: URL) {
        if url.isFileURL {
            self.init(path: url.standardizedFileURL.path)
            return
        }
        guard url.scheme == "sill", url.host == "open",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let path = items.first(where: { $0.name == "path" })?.value, path.hasPrefix("/") || path.hasPrefix("~")
        else { return nil }
        func number(_ name: String) -> Int? { items.first { $0.name == name }?.value.flatMap { Int($0) } }
        self.init(
            path: ((path as NSString).expandingTildeInPath as NSString).standardizingPath,
            line: number("line"),
            column: number("column")
        )
    }

    private static func resolve(
        _ name: String, _ directory: String, _ root: String, _ exists: (String) -> Bool
    ) -> String? {
        guard !name.isEmpty, name != "/", name != "." else { return nil }
        let candidates: [String] = if name.hasPrefix("/") {
            [name]
        } else if name.hasPrefix("~") {
            [(name as NSString).expandingTildeInPath]
        } else {
            [directory, root].map { ($0 as NSString).appendingPathComponent(name) }
        }
        return candidates.map { ($0 as NSString).standardizingPath }.first(where: exists)
    }
}
