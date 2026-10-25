import Foundation

/// What sill collects about each piece of a basket as it goes in: its project, the symbol around it (signature, the
/// first sentence of its documentation), the tests that reach it, the history of its lines and the problems in it.
/// Kept beside the basket (`<name>.basket.context.json`) so the basket stays prose a person reads; shown on demand in
/// the notebook and given to agents with the code.
public struct BasketContext: Codable, Equatable, Sendable {
    public struct Test: Codable, Equatable, Sendable {
        public var name: String
        public var path: String
        public var line: Int

        public init(name: String, path: String, line: Int) {
            self.name = name
            self.path = path
            self.line = line
        }
    }

    public struct Change: Codable, Equatable, Sendable {
        public var commit: String
        public var author: String
        public var date: String
        public var subject: String

        public init(commit: String, author: String, date: String, subject: String) {
            self.commit = commit
            self.author = author
            self.date = date
            self.subject = subject
        }
    }

    public struct Piece: Codable, Equatable, Sendable {
        public var project: String?
        public var projectKind: String?
        public var symbol: String?
        public var signature: String?
        public var summary: String?
        public var tests: [Test] = []
        /// How many commits changed these lines, and the last of them.
        public var changes = 0
        public var last: Change?
        public var problems: [String] = []

        public init() {}
    }

    /// By anchor, as the basket writes it (`Pricing.cs:3-7`, `Tax.Of`).
    public var pieces: [String: Piece] = [:]

    public init(pieces: [String: Piece] = [:]) {
        self.pieces = pieces
    }

    // MARK: The file

    /// `report.basket.md` → `report.basket.context.json`.
    public static func file(for basket: String) -> String {
        (basket.hasSuffix(".md") ? String(basket.dropLast(3)) : basket) + ".context.json"
    }

    public static func load(for basket: String) -> BasketContext {
        guard let data = FileManager.default.contents(atPath: file(for: basket)),
              let context = try? JSONDecoder().decode(BasketContext.self, from: data)
        else { return BasketContext() }
        return context
    }

    public func save(for basket: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: URL(fileURLWithPath: Self.file(for: basket)))
    }

    // MARK: Reading what was collected

    /// `git log -L … -s --format=%h%x09%an%x09%as%x09%s`: how many commits, and the newest.
    public static func history(_ log: String) -> (changes: Int, last: Change?) {
        let commits = log.split(separator: "\n").map { $0.split(separator: "\t", maxSplits: 3).map(String.init) }
            .filter { $0.count == 4 }
        return (commits.count, commits.first.map { Change(commit: $0[0], author: $0[1], date: $0[2], subject: $0[3]) })
    }

    /// A hover's Markdown: the first code block's first line as the signature, the first sentence after it as the
    /// summary.
    public static func hover(_ markdown: String) -> (signature: String?, summary: String?) {
        var signature: String?, prose: [String] = [], inCode = false
        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inCode.toggle()
                continue
            }
            if inCode {
                if signature == nil, !trimmed.isEmpty { signature = trimmed }
            } else if !trimmed.isEmpty, !trimmed.hasPrefix("---") {
                prose.append(trimmed)
            }
        }
        let text = prose.joined(separator: " ")
        let sentence = text.range(of: ". ").map { String(text[..<$0.lowerBound]) + "." } ?? text
        return (signature, sentence.isEmpty ? nil : sentence)
    }

    // MARK: Showing it

    /// The short facts under a piece's heading: project, symbol, tests, history, problems.
    public func chips(_ anchor: String, today: Date = Date()) -> [String] {
        guard let piece = pieces[anchor] else { return [] }
        var chips: [String] = []
        if let project = piece.project { chips.append(project) }
        if let symbol = piece.symbol { chips.append(symbol) }
        if !piece.tests.isEmpty { chips.append(piece.tests.count == 1 ? "1 test" : "\(piece.tests.count) tests") }
        if let last = piece.last {
            chips.append((piece.changes == 1 ? "1 change" : "\(piece.changes) changes") + ", last " +
                Self.age(last.date, today: today))
        }
        if !piece.problems.isEmpty {
            chips.append(piece.problems.count == 1 ? "1 problem" : "\(piece.problems.count) problems")
        }
        return chips
    }

    /// `2026-10-22` from `today`: "3 days ago", "today", "in 2026-01".
    static func age(_ date: String, today: Date) -> String {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd"
        format.timeZone = TimeZone(identifier: "UTC")
        guard let day = format.date(from: date) else { return date }
        let days = Int((format.date(from: format.string(from: today)) ?? today).timeIntervalSince(day) / 86400)
        switch days {
        case ..<1: return "today"
        case 1: return "yesterday"
        case ..<60: return "\(days) days ago"
        default: return "in " + String(date.prefix(7))
        }
    }

    /// A piece's context, as lines for an agent.
    public func text(_ anchor: String) -> [String] {
        guard let piece = pieces[anchor] else { return [] }
        var out: [String] = []
        let around = [
            piece.project.map { "in \($0)" + (piece.projectKind.map { " (\($0))" } ?? "") },
            piece.signature ?? piece.symbol,
        ].compactMap(\.self)
        if !around.isEmpty { out.append("Context: " + around.joined(separator: ", ")) }
        if let summary = piece.summary { out.append("Documented as: \(summary)") }
        if !piece.tests.isEmpty {
            out.append("Tests reaching it: " + piece.tests.map { "\($0.name) (\($0.path):\($0.line))" }
                .joined(separator: ", "))
        }
        if let last = piece.last {
            out.append("History: \(piece.changes) commit\(piece.changes == 1 ? "" : "s"), last \(last.commit) " +
                "\"\(last.subject)\" by \(last.author) on \(last.date)")
        }
        if !piece.problems.isEmpty { out.append("Problems: " + piece.problems.joined(separator: "; ")) }
        return out
    }

    /// Across the pieces: the projects (and how many pieces in each), the tests, the people who last changed them.
    public var overview: (projects: [(String, Int)], tests: [Test], authors: [(String, Int)]) {
        var projects: [String: Int] = [:], authors: [String: Int] = [:], tests: [Test] = []
        for piece in pieces.values {
            if let project = piece.project { projects[project, default: 0] += 1 }
            if let author = piece.last?.author { authors[author, default: 0] += 1 }
            for test in piece.tests where !tests.contains(test) {
                tests.append(test)
            }
        }
        func sorted(_ counts: [String: Int]) -> [(String, Int)] {
            counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { ($0.key, $0.value) }
        }
        return (sorted(projects), tests.sorted { ($0.path, $0.line) < ($1.path, $1.line) }, sorted(authors))
    }
}
