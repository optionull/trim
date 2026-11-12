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

        /// As it is written after `@code`: `Pricing.Total`, `Pricing.Total lines 3-9`, `src/Pricing.cs:12-30`.
        public var text: String {
            switch self {
            case let .symbol(name, lines): name + (lines.map { " lines \($0.lowerBound)-\($0.upperBound)" } ?? "")
            case let .file(path, lines): path + (lines.map { ":\($0.lowerBound)-\($0.upperBound)" } ?? "")
            }
        }
    }

    public enum Block: Equatable, Sendable {
        case prose(String)
        case code(Anchor, line: Int)
        /// A question, its answer if one was written, and the line the question is on (1-based).
        case ask(String, answer: String?, line: Int)
        /// A file's change against the walkthrough's `base` (a review's).
        case diff(String, line: Int)
        /// An example: an isolated script (a .NET file-based app, a TypeScript, Python, Swift or Rust script)
        /// beside the walkthrough, shown and run in place.
        case example(String, line: Int)
        /// A symbol's call tree (`@trace Tax.Of callers 3`): who calls it, or what it calls, so many levels deep.
        case trace(String, callers: Bool, depth: Int, line: Int)
        /// Something to run to see it work (`@run Tests: dotnet test`), from the checkout's root: a handoff's.
        case run(name: String, command: String, line: Int)
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
    /// A basket's question, who made it (you, or an agent) and where it stands (open, sent, concluded).
    public var question: String?
    public var by: String?
    public var status: String?
    /// The checkout it is about, when an agent wrote it for one (a handoff): its root.
    public var worktree: String?
    /// The fingerprint written after an anchor (`@code Pricing.Total #a1b2c3d`), by the anchor's line: what its code
    /// was when it was added, to say when it moved on.
    public var fingerprints: [Int: String] = [:]

    public init(_ source: String) {
        var lines = source.components(separatedBy: "\n")
        var title = "", target: String?, base: String?, offset = 0
        var question: String?, by: String?, status: String?, worktree: String?
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
                case "question": question = parts[1]
                case "by": by = parts[1]
                case "status": status = parts[1]
                case "worktree": worktree = parts[1]
                default: break
                }
            }
            offset = end + 1
            lines = Array(lines[(end + 1)...])
        }
        var intro: [String] = [], steps: [Step] = [], fingerprints: [Int: String] = [:]
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
                var words = String(trimmed.dropFirst(6)).split(separator: " ").map(String.init)
                if let last = words.last, Self.isFingerprint(last) {
                    fingerprints[number] = String(last.dropFirst())
                    words.removeLast()
                }
                if let anchor = Self.anchor(words.joined(separator: " ")) {
                    steps[steps.count - 1].blocks.append(.code(anchor, line: number))
                }
            } else if trimmed.hasPrefix("@trace ") {
                flush()
                let words = trimmed.dropFirst(7).split(separator: " ").map(String.init)
                if let symbol = words.first {
                    steps[steps.count - 1].blocks.append(.trace(
                        symbol,
                        callers: !words.contains("callees"),
                        depth: words.compactMap { Int($0) }.first.map { min(max($0, 1), 6) } ?? 2,
                        line: number
                    ))
                }
            } else if trimmed.hasPrefix("@diff ") {
                flush()
                steps[steps.count - 1].blocks.append(.diff(
                    String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces),
                    line: number
                ))
            } else if trimmed.hasPrefix("@run ") {
                flush()
                // `@run Name: command`, or just the command (its name then).
                let rest = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                let parts = rest.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                // A name: short, before the first colon, not a path or a chain of commands.
                let named = parts.count == 2 && !parts[0].isEmpty && parts[0].count <= 40 &&
                    !parts[0].contains("/") && !parts[0].contains("&")
                steps[steps.count - 1].blocks.append(.run(
                    name: named ? parts[0] : rest, command: named ? parts[1] : rest, line: number
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
        self.question = question
        self.by = by
        self.status = status
        self.worktree = worktree
        self.fingerprints = fingerprints
    }

    /// `#a1b2c3d`: seven or more hex digits after a `#`.
    static func isFingerprint(_ word: String) -> Bool {
        word.hasPrefix("#") && word.count >= 8 && word.dropFirst().allSatisfy(\.isHexDigit)
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
