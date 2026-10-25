import CryptoKit
import Foundation

/// A context basket's file (`.sill/baskets/<name>.basket.md`): a walkthrough-format notebook of pieces of code
/// collected while browsing or investigating, with notes, sent to the agent with a question; its findings are written
/// back into it. These are its edits, as text, so the file stays the truth and anyone (a person, an agent) can write
/// it.
///
///     ---
///     title: Is tax applied twice?
///     question: Is the tax applied twice on discounted orders?
///     by: you
///     status: open
///     ---
///     ## Collected
///     Discount comes after tax here.
///     @code src/Pricing.cs:3-9 #a1b2c3d
///
///     ## Findings
///     Tax is applied once…
public enum BasketFile {
    public static let suffix = ".basket.md"
    public static let defaultSection = "Collected"
    public static let findings = "Findings"

    /// A new basket's source.
    /// `worktree` and `commit`: where it was made, as the code is read where sill is open.
    public static func new(
        title: String, question: String? = nil, by: String = "you", worktree: String? = nil, commit: String? = nil
    ) -> String {
        var front = ["---", "title: \(oneLine(title))"]
        if let question, !question.isEmpty { front.append("question: \(oneLine(question))") }
        front.append("by: \(oneLine(by))")
        if let worktree { front.append("worktree: \(oneLine(worktree))") }
        if let commit { front.append("commit: \(oneLine(commit))") }
        front += ["status: open", "---", ""]
        return front.joined(separator: "\n")
    }

    /// A file name for a basket titled `title`: lower case words joined by dashes.
    public static func fileName(for title: String) -> String {
        let words = title.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return (words.prefix(8).joined(separator: "-").nilIfEmpty ?? "basket") + suffix
    }

    /// What lines were, as a fingerprint: the first seven hex digits of their SHA-256.
    public static func fingerprint(_ lines: [String]) -> String {
        SHA256.hash(data: Data(lines.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
            .prefix(7).description
    }

    /// The source with a piece added under `section` (made when missing, before the findings): its note as prose, then
    /// `@code <anchor> #<fingerprint>`. A file range touching or overlapping one already in the basket joins it (that
    /// anchor's line takes the joined range and fingerprint `joined` gives for it); the note goes with it.
    public static func adding(
        _ source: String,
        anchor: String,
        fingerprint: String?,
        note: String? = nil,
        section: String? = nil,
        joined: ((_ path: String, _ range: ClosedRange<Int>) -> String?)? = nil
    ) -> String {
        var lines = source.components(separatedBy: "\n")
        let code = "@code \(anchor)" + (fingerprint.map { " #\($0)" } ?? "")
        // A file range joining one already here.
        if let (path, range) = fileRange(anchor) {
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("@code ") else { continue }
                let words = trimmed.dropFirst(6).split(separator: " ").map(String.init)
                guard let first = words.first, let (otherPath, other) = fileRange(first), otherPath == path,
                      other.lowerBound <= range.upperBound + 1, other.upperBound >= range.lowerBound - 1
                else { continue }
                let union = min(range.lowerBound, other.lowerBound) ... max(range.upperBound, other.upperBound)
                let print = joined?(path, union)
                lines[index] = "@code \(path):\(union.lowerBound)-\(union.upperBound)" + (print.map { " #\($0)" } ?? "")
                if let note, !note.isEmpty { lines.insert(oneLine(note), at: index) }
                return lines.joined(separator: "\n")
            }
        }
        let added = (note.flatMap { $0.isEmpty ? nil : [oneLine($0)] } ?? []) + [code]
        return inserting(added, under: section ?? defaultSection, in: lines).joined(separator: "\n")
    }

    /// The source with prose added under `section`.
    public static func noting(_ source: String, _ text: String, section: String? = nil) -> String {
        inserting(
            text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n"),
            under: section ?? defaultSection,
            in: source.components(separatedBy: "\n")
        ).joined(separator: "\n")
    }

    /// The source with the findings section holding `text` (replacing what it held), last, and the status
    /// `concluded`.
    public static func concluding(_ source: String, _ text: String) -> String {
        var lines = source.components(separatedBy: "\n")
        if let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "## \(findings)" }) {
            let end = lines[(start + 1)...].firstIndex { $0.hasPrefix("## ") } ?? lines.count
            lines.removeSubrange(start ..< end)
        }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeLast()
        }
        lines += ["", "## \(findings)", text.trimmingCharacters(in: .whitespacesAndNewlines), ""]
        return setting(lines.joined(separator: "\n"), "status", to: "concluded")
    }

    /// The source without the anchor on `line` (1-based), and the prose right above it that was its note.
    public static func removing(_ source: String, anchorAt line: Int) -> String {
        var lines = source.components(separatedBy: "\n")
        guard line >= 1, line <= lines.count, lines[line - 1].trimmingCharacters(in: .whitespaces).hasPrefix("@")
        else { return source }
        var start = line - 1
        while start > 0, isProse(lines[start - 1]) {
            start -= 1
        }
        lines.removeSubrange(start ..< line)
        return lines.joined(separator: "\n")
    }

    /// The source with a front matter field set (added when missing).
    public static func setting(_ source: String, _ field: String, to value: String) -> String {
        var lines = source.components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else {
            return (["---", "\(field): \(oneLine(value))", "---"] + lines).joined(separator: "\n")
        }
        if let index = lines[1 ..< end].firstIndex(where: { $0.hasPrefix("\(field):") }) {
            lines[index] = "\(field): \(oneLine(value))"
        } else {
            lines.insert("\(field): \(oneLine(value))", at: end)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Helpers

    /// `src/Pricing.cs:3-9` as a path and range; nil for a symbol or a whole file.
    static func fileRange(_ anchor: String) -> (String, ClosedRange<Int>)? {
        guard case let .file(path, lines?)? = Walkthrough.anchor(anchor) else { return nil }
        return (path, lines)
    }

    private static func isProse(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && !trimmed.hasPrefix("@") && !trimmed.hasPrefix("#") && !trimmed.hasPrefix(">")
    }

    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// `added` at the end of section `name` (its trailing blank lines kept after), the section made before the
    /// findings when missing.
    private static func inserting(_ added: [String], under name: String, in lines: [String]) -> [String] {
        var lines = lines
        if let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "## \(name)" }) {
            var end = lines[(start + 1)...].firstIndex { $0.hasPrefix("## ") } ?? lines.count
            while end > start + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                end -= 1
            }
            lines.insert(contentsOf: added, at: end)
            return lines
        }
        let findings = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "## \(Self.findings)" }
        var at = findings ?? lines.count
        while at > 0, lines[at - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            at -= 1
        }
        let block = ["", "## \(name)"] + added + (findings != nil ? [""] : [])
        lines.insert(contentsOf: block, at: at)
        if findings == nil, lines.last?.isEmpty == false { lines.append("") }
        return lines
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
