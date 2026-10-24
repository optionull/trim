import Foundation

/// A walkthrough: a Markdown file (`*.walk.md`, anywhere) an agent writes, or a person, to walk someone through code.
///
///     ---
///     title: How an order reaches the database
///     for: Orders.slnx
///     ---
///     What this walkthrough covers.
///
///     ## The request comes in
///     Kestrel hands the POST to `Create`.
///     @code OrdersController.Create
///     @code src/Orders/Pricing.cs:12-30
///     @ask Why is the total not cached?
///     > Because prices change per request.
///
/// A step is a `##` heading and what follows it: prose, `@code` anchors (a symbol, which the language server finds and
/// so survives edits, optionally `lines 3-9` of it; or a path with a line or lines) and `@ask` questions, each with its
/// answer, when it has one, as the quote right after it. sill shows the anchors as live code and writes answers back.
public struct Walkthrough: Equatable, Sendable {
    public enum Anchor: Equatable, Sendable {
        /// A symbol (`Pricing.Total`), and lines of it counted from its first (1-based), if given.
        case symbol(String, lines: ClosedRange<Int>?)
        /// A file relative to the walkthrough's folder or absolute, and lines of it.
        case file(String, lines: ClosedRange<Int>?)
    }

    public enum Block: Equatable, Sendable {
        case prose(String)
        case code(Anchor, line: Int)
        /// A question, its answer if one was written, and the line the question is on (1-based).
        case ask(String, answer: String?, line: Int)
        /// A file's change against the walkthrough's `base` (a review's).
        case diff(String, line: Int)
        /// An example: an isolated script (a .NET 10 file-based app, a TypeScript, Python, Swift or Rust script)
        /// beside the walkthrough, shown and run in place.
        case example(String, line: Int)
    }

    public struct Step: Equatable, Sendable {
        public var title: String
        public var blocks: [Block]
        /// The line of its heading (1-based).
        public var line: Int
    }

    public var title: String
    /// What it walks through: a solution, a folder.
    public var target: String?
    /// What a review's changes are against: a git tree or commit (its `@diff`s compare it with the worktree).
    public var base: String?
    public var intro: String
    public var steps: [Step]

    public init(_ source: String) {
        var lines = source.components(separatedBy: "\n")
        var title = "", target: String?, base: String?, offset = 0
        // Front matter.
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        {
            for line in lines[1 ..< end] {
                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "title": title = parts[1]
                case "for": target = parts[1]
                case "base": base = parts[1]
                default: break
                }
            }
            offset = end + 1
            lines = Array(lines[(end + 1)...])
        }
        var intro: [String] = [], steps: [Step] = []
        var prose: [String] = []
        func flush() {
            let text = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            prose = []
            guard !text.isEmpty, !steps.isEmpty else { return }
            steps[steps.count - 1].blocks.append(.prose(text))
        }
        var index = 0
        while index < lines.count {
            let line = lines[index], number = offset + index + 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                flush()
                steps.append(Step(title: String(trimmed.dropFirst(3)), blocks: [], line: number))
            } else if trimmed.hasPrefix("# "), steps.isEmpty, title.isEmpty {
                title = String(trimmed.dropFirst(2))
            } else if steps.isEmpty {
                intro.append(line)
            } else if trimmed.hasPrefix("@code ") {
                flush()
                if let anchor = Self.anchor(String(trimmed.dropFirst(6))) {
                    steps[steps.count - 1].blocks.append(.code(anchor, line: number))
                }
            } else if trimmed.hasPrefix("@diff ") {
                flush()
                steps[steps.count - 1].blocks.append(.diff(
                    String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces),
                    line: number
                ))
            } else if trimmed.hasPrefix("@example ") {
                flush()
                steps[steps.count - 1].blocks.append(.example(
                    String(trimmed.dropFirst(9)).trimmingCharacters(in: .whitespaces),
                    line: number
                ))
            } else if trimmed.hasPrefix("@ask ") {
                flush()
                var question = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if question.hasPrefix("\""), question.hasSuffix("\""), question.count >= 2 {
                    question = String(question.dropFirst().dropLast())
                }
                // The answer: the quote right after the question.
                var answer: [String] = []
                while index + 1 < lines.count, lines[index + 1].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    index += 1
                    let quoted = lines[index].trimmingCharacters(in: .whitespaces).dropFirst()
                    answer.append(quoted.hasPrefix(" ") ? String(quoted.dropFirst()) : String(quoted))
                }
                steps[steps.count - 1].blocks.append(.ask(
                    question, answer: answer.isEmpty ? nil : answer.joined(separator: "\n"), line: number
                ))
            } else {
                prose.append(line)
            }
            index += 1
        }
        flush()
        self.title = title.isEmpty ? (steps.first?.title ?? "Walkthrough") : title
        self.target = target
        self.base = base
        self.intro = intro.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        self.steps = steps
    }

    /// `Pricing.Total`, `Pricing.Total lines 3-9`, `src/Pricing.cs:12`, `src/Pricing.cs:12-30`.
    static func anchor(_ text: String) -> Anchor? {
        let words = text.split(separator: " ").map(String.init)
        guard let first = words.first else { return nil }
        func range(_ text: String) -> ClosedRange<Int>? {
            let parts = text.split(separator: "-").compactMap { Int($0) }
            guard let start = parts.first, start > 0 else { return nil }
            let end = parts.count > 1 ? parts[1] : start
            return start ... max(start, end)
        }
        // A path: a slash or a file extension, with or without :lines.
        let pathPart = first.split(separator: ":", maxSplits: 1).map(String.init)
        let ext = (pathPart[0] as NSString).pathExtension.lowercased()
        if pathPart[0].contains("/") || pathPart.count == 2 || Self.codeExtensions.contains(ext) {
            return .file(pathPart[0], lines: pathPart.count == 2 ? range(pathPart[1]) : nil)
        }
        if words.count >= 3, words[1] == "lines" { return .symbol(first, lines: range(words[2])) }
        return .symbol(first, lines: nil)
    }

    /// What a file name ends in, so `Program.cs` alone is a file and `Pricing.Total` a symbol.
    static let codeExtensions: Set = [
        "cs", "razor", "cshtml", "fs", "swift", "rs", "ts", "tsx", "js", "jsx", "json", "md", "py", "go", "java",
        "kt", "c", "h", "cpp", "hpp", "lua", "toml", "yml", "yaml", "xml", "csproj", "slnx", "html", "css", "sh",
    ]

    /// The source with `answer` under the question on `line` (1-based) as a quote, an answer already there replaced.
    public static func answering(_ source: String, questionAt line: Int, with answer: String) -> String {
        var lines = source.components(separatedBy: "\n")
        guard line >= 1, line <= lines.count else { return source }
        var end = line
        while end < lines.count, lines[end].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
            end += 1
        }
        let quoted = answer.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
            .map { $0.isEmpty ? ">" : "> " + $0 }
        lines.replaceSubrange(line ..< end, with: quoted)
        return lines.joined(separator: "\n")
    }
}
