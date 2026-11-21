import Foundation

/// What the status bar says, and how it is said: the parts that are not drawing.
public enum StatusLine {
    /// Where the window is in the buffer, as vim says it: Top, Bot, All, or a percentage.
    public static func percent(line: Int, lines: Int, firstVisible: Int? = nil, lastVisible: Int? = nil) -> String {
        guard lines > 0 else { return "All" }
        let first = firstVisible ?? line, last = lastVisible ?? line
        if first <= 1, last >= lines { return "All" }
        if first <= 1 { return "Top" }
        if last >= lines { return "Bot" }
        return "\(min(max(Int((Double(line) / Double(lines) * 100).rounded()), 1), 99))%"
    }

    /// A file's path as the bar shows it: relative to the workspace when it is inside it, else with the home folder
    /// as `~`.
    public static func displayPath(_ path: String, root: String?, home: String = NSHomeDirectory()) -> String {
        guard !path.isEmpty else { return "" }
        if let root, !root.isEmpty, path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// A path cut to fit `width` (as `measure` says how wide a text is) by dropping folders from the front, `…/` in
    /// their
    /// place; the file's name is kept whole (whatever is left of the room, it is not cut).
    public static func fitted(_ path: String, width: CGFloat, measure: (String) -> CGFloat) -> String {
        guard measure(path) > width else { return path }
        var parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count > 1 else { return path }
        while parts.count > 1 {
            parts.removeFirst()
            let candidate = "…/" + parts.joined(separator: "/")
            if measure(candidate) <= width || parts.count == 1 { return candidate }
        }
        return "…/" + (parts.first ?? path)
    }

    /// Diagnostic counts as the short form: nothing for none.
    public static func counts(errors: Int, warnings: Int, infos: Int, hints: Int) -> [(kind: String, count: Int)] {
        [("error", errors), ("warning", warnings), ("info", infos), ("hint", hints)].filter { $0.1 > 0 }
    }
}
