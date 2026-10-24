import Foundation

/// The conflicts git leaves in a file: `<<<<<<<`, an optional `|||||||` base (diff3, zdiff3), `=======` and `>>>>>>>`,
/// each at the start of a line and the first, base and last followed by a space or nothing (so a line of eight `=` in
/// Markdown is no separator). Lines may end in CRLF. The same rules as `sill.merge`'s in Lua.
public enum MergeConflicts {
    public static func count(in text: String) -> Int {
        var count = 0, open = false, separated = false
        // Split on any line end: in Swift a CRLF is one character, so splitting on "\n" would not split it.
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if marker(line, "<") {
                open = true
                separated = false
            } else if open, line == "=======" {
                separated = true
            } else if open, separated, marker(line, ">") {
                count += 1
                open = false
            }
        }
        return count
    }

    public static func count(inFile path: String) -> Int {
        (try? String(contentsOfFile: path, encoding: .utf8)).map(count(in:)) ?? 0
    }

    private static func marker(_ line: Substring, _ character: Character) -> Bool {
        let prefix = String(repeating: character, count: 7)
        guard line.hasPrefix(prefix) else { return false }
        let rest = line.dropFirst(7)
        return rest.isEmpty || rest.first == " "
    }
}
