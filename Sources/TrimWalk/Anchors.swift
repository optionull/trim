import Foundation

/// Where an anchor is in the code now: a file and the lines to show.
public struct ResolvedAnchor: Equatable, Sendable {
    public var path: String
    public var lines: ClosedRange<Int>
    /// How it was found: `path` (a file as written), `text` (a declaration found by git grep), or a server's name.
    public var by: String
    /// Those lines of the file as they are now.
    public var text: [String]
}

/// Finds a walkthrough's anchors in the code. A file is read as written; a symbol is asked of `symbols` first (the
/// language servers, when the host has them) and otherwise found by its declaration in what git knows, with the extent
/// of
/// the declaration worked out from its braces or indentation. Never blocks on a server: without an answer it reads
/// text.
public struct AnchorResolver: Sendable {
    /// The worktree's root (what a relative path is read from when it is not found beside the walkthrough).
    public var root: String
    /// The walkthrough's own folder.
    public var folder: String
    /// An answer from the language servers for a symbol: its file and first line (1-based), and who said so.
    public var symbols: (@Sendable (String) -> (path: String, line: Int, by: String)?)?
    /// How many lines a symbol or a bare file shows at most.
    public static let symbolLines = 60, fileLines = 40

    public init(
        root: String, folder: String? = nil,
        symbols: (@Sendable (String) -> (path: String, line: Int, by: String)?)? = nil
    ) {
        self.root = root
        self.folder = folder ?? root
        self.symbols = symbols
    }

    public enum Result: Equatable, Sendable {
        case found(ResolvedAnchor)
        case problem(String)
    }

    public func resolve(_ anchor: Walkthrough.Anchor) -> Result {
        switch anchor {
        case let .file(path, lines): resolveFile(path, lines)
        case let .symbol(name, lines): resolveSymbol(name, lines)
        }
    }

    private func read(_ path: String) -> [String]? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    private func resolveFile(_ name: String, _ range: ClosedRange<Int>?) -> Result {
        var candidates = name.hasPrefix("/") ? [name] : [folder + "/" + name]
        if !name.hasPrefix("/") { candidates.append(root + "/" + name) }
        guard let path = candidates.first(where: { FileManager.default.isReadableFile(atPath: $0) }),
              let lines = read(path) else { return .problem("no file \(name)") }
        guard !lines.isEmpty else { return .problem("\(name) is empty") }
        let from = min(max(range?.lowerBound ?? 1, 1), lines.count)
        let to = min(range?.upperBound ?? from + Self.fileLines - 1, lines.count, from + Self.symbolLines - 1)
        return .found(ResolvedAnchor(
            path: path,
            lines: from ... max(from, to),
            by: "path",
            text: Array(lines[(from - 1) ..< max(from, to)])
        ))
    }

    private func resolveSymbol(_ name: String, _ range: ClosedRange<Int>?) -> Result {
        let found = symbols?(name).map { ($0.path, $0.line, $0.by) } ?? byText(name)
        guard let (path, start, by) = found, let lines = read(path), start >= 1, start <= lines.count else {
            return .problem("no declaration of \(name) found")
        }
        let end = Self.extent(of: lines, from: start)
        var from = start, to = end
        if let range { // lines counted from the symbol's first
            from = start + range.lowerBound - 1
            to = min(start + range.upperBound - 1, end)
        }
        from = min(max(from, 1), lines.count)
        to = max(from, min(to, lines.count))
        return .found(ResolvedAnchor(path: path, lines: from ... to, by: by, text: Array(lines[(from - 1) ..< to])))
    }

    /// The declaration of `Pricing.Total` by text: a line naming `Total` as it is declared (followed by `(`, `<`, `{`,
    /// `:`
    /// or `=`), in a file that also names `Pricing` when there is a container.
    private func byText(_ wanted: String) -> (String, Int, String)? {
        let parts = wanted.split(separator: ".").map(String.init)
        guard let name = parts.last, !name.isEmpty else { return nil }
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = "(class|struct|record|interface|enum|protocol|extension|fn|func|def|function|void|static|public|private|internal|protected|let|var|const)[^=;]*[^A-Za-z0-9_]\(escaped)[[:space:]]*[(<{:=]"
        guard let out = Git.run(["grep", "-n", "-E", pattern], in: root) else { return nil }
        for line in out.split(separator: "\n") {
            let pieces = line.split(separator: ":", maxSplits: 2).map(String.init)
            guard pieces.count == 3, let number = Int(pieces[1]) else { continue }
            let full = root + "/" + pieces[0]
            if parts.count == 1 { return (full, number, "text") }
            if let text = try? String(contentsOfFile: full, encoding: .utf8), text.contains(parts[parts.count - 2]) {
                return (full, number, "text")
            }
        }
        return nil
    }

    /// Where a declaration starting at `line` (1-based) ends: its braces closed, else its indentation back; at most 60.
    public static func extent(of lines: [String], from line: Int) -> Int {
        var depth = 0, opened = false
        let last = min(lines.count, line + symbolLines - 1)
        for index in line ... last {
            let text = strip(lines[index - 1])
            for character in text where character == "{" || character == "}" {
                depth += character == "{" ? 1 : -1
                opened = true
            }
            if opened, depth <= 0 { return index }
            // An arrow body (or a field) ends with its semicolon.
            if !opened, text.trimmingCharacters(in: .whitespaces).hasSuffix(";") { return index }
        }
        if !opened {
            let indent = lines[line - 1].prefix { $0 == " " || $0 == "\t" }.count
            if line + 1 <= last {
                for index in (line + 1) ... last where !lines[index - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                    if lines[index - 1].prefix(while: { $0 == " " || $0 == "\t" }).count <= indent { return index - 1 }
                }
            }
        }
        return last
    }

    /// A line without its comment and its string literals, so their braces are not counted.
    private static func strip(_ line: String) -> String {
        var text = line
        if let comment = text.range(of: "//") { text = String(text[..<comment.lowerBound]) }
        return text.replacingOccurrences(of: "\"[^\"]*\"", with: "", options: .regularExpression)
    }
}

/// Whether the code an anchor points at is what it was when the walkthrough was written.
public enum Freshness: Equatable, Sendable {
    /// The lines hash to the fingerprint written with the anchor.
    case fresh
    /// The anchor is still there, but its lines changed since.
    case changed
    /// The anchor can no longer be found.
    case orphaned
    /// The anchor has no fingerprint (or has not been looked for yet): nothing to compare.
    case unchecked

    public static func of(recorded: String?, now: ResolvedAnchor?, searched: Bool = true) -> Freshness {
        guard searched else { return .unchecked }
        guard let now else { return .orphaned }
        guard let recorded else { return .unchecked }
        return Walkthrough.fingerprint(now.text) == recorded ? .fresh : .changed
    }
}

/// git, run for what it says; nil when it fails or says nothing.
enum Git {
    static func run(_ arguments: [String], in directory: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return text.isEmpty ? nil : text
    }
}
