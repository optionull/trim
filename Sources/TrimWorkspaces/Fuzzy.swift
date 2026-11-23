import Foundation

/// A fuzzy match of a query in a text: the characters of the query in order, and where they were found.
public struct FuzzyMatch: Equatable, Sendable {
    public var score: Int
    /// Offsets (in characters) of the text's characters that matched.
    public var positions: [Int]
}

public enum Fuzzy {
    /// The best way the characters of `query` appear in order in `text`, ignoring case, or nil. Starts of words and
    /// runs of neighbours score higher; a gap costs a little.
    public static func match(_ query: String, in text: String) -> FuzzyMatch? {
        let needle = Array(query.lowercased()), hay = Array(text.lowercased()), original = Array(text)
        guard !needle.isEmpty else { return FuzzyMatch(score: 0, positions: []) }
        guard hay.count == original.count, needle.count <= hay.count else { return nil }
        func boundary(_ index: Int) -> Bool {
            guard index > 0 else { return true }
            let before = original[index - 1], here = original[index]
            return !before.isLetter && !before.isNumber || before.isLowercase && here.isUppercase
        }
        // best[q][t]: the best score with needle[q] matched at hay[t], and the t before it.
        var best = Array(repeating: Array(repeating: Int.min, count: hay.count), count: needle.count)
        var from = Array(repeating: Array(repeating: -1, count: hay.count), count: needle.count)
        for q in 0 ..< needle.count {
            for t in q ..< hay.count where hay[t] == needle[q] {
                let bonus = (boundary(t) ? 10 : 0) + (t == 0 ? 4 : 0)
                if q == 0 {
                    best[0][t] = 1 + bonus - min(t, 6)
                    continue
                }
                var top = Int.min, previous = -1
                for p in (q - 1) ..< t where best[q - 1][p] != Int.min {
                    let value = best[q - 1][p] + (p == t - 1 ? 8 : -min(t - p - 1, 4))
                    if value > top { top = value; previous = p }
                }
                if previous >= 0 {
                    best[q][t] = top + 1 + bonus
                    from[q][t] = previous
                }
            }
        }
        let last = needle.count - 1
        guard let end = best[last].indices.max(by: { best[last][$0] < best[last][$1] }),
              best[last][end] != Int.min else { return nil }
        var positions = [end], at = end
        for q in stride(from: last, to: 0, by: -1) {
            at = from[q][at]
            positions.append(at)
        }
        return FuzzyMatch(score: best[last][end], positions: positions.reversed())
    }
}
