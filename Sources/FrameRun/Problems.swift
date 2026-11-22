import Foundation

/// An error or warning a build printed: where, how bad, what it says.
public struct Problem: Equatable, Sendable {
    public enum Severity: String, Sendable { case error, warning }

    public var path: String
    public var line: Int
    public var column: Int
    public var severity: Severity
    public var code: String
    public var message: String
}

/// Reads the problems out of a build's output (what the terminal pane shows, escapes and all): MSBuild and tsc's
/// `file(12,5): error CS1002: text`, the compilers' `file:12:5: error: text` (swiftc, clang, gcc, rustc's `-->` form
/// too). Each problem once (MSBuild prints them twice), the file made absolute against `directory`, the ones whose file
/// does not exist left out (a path in a stack trace, a message that only looks like one).
public enum Problems {
    public static func parse(_ output: String, directory: String) -> [Problem] {
        var found: [Problem] = []
        var seen = Set<String>()
        func add(_ path: String, _ line: Int, _ column: Int, _ severity: String, _ code: String, _ message: String) {
            guard let level = Problem.Severity(rawValue: severity == "fatal error" ? "error" : severity) else { return }
            let full = path.hasPrefix("/") ? path : directory + "/" + path
            let clean = URL(fileURLWithPath: full).standardized.path
            guard FileManager.default.fileExists(atPath: clean) else { return }
            let text = message.trimmingCharacters(in: .whitespaces)
            guard seen.insert("\(clean):\(line):\(column):\(code):\(text)").inserted else { return }
            found.append(Problem(path: clean, line: line, column: column, severity: level, code: code, message: text))
        }
        let lines = strip(output).split(whereSeparator: \.isNewline).map(String.init)
        var pendingRust: (severity: String, code: String, message: String)?
        for line in lines {
            if let m = match(msbuild, line) {
                add(m[1], Int(m[2]) ?? 1, Int(m[3]) ?? 1, m[4], m[5], m[6])
                pendingRust = nil
            } else if let m = match(compiler, line) {
                add(m[1], Int(m[2]) ?? 1, Int(m[3]) ?? 1, m[4], "", m[5])
                pendingRust = nil
            } else if let m = match(rustHeader, line) {
                pendingRust = (m[1], m[2], m[3])
            } else if let rust = pendingRust, let m = match(rustLocation, line) {
                add(m[1], Int(m[2]) ?? 1, Int(m[3]) ?? 1, rust.severity, rust.code, rust.message)
                pendingRust = nil
            }
        }
        return found
    }

    /// Terminal escapes: colours, cursor moves, and OSC titles and links.
    static func strip(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\u{1B}\\][^\u{7}\u{1B}]*(\u{7}|\u{1B}\\\\)|\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "",
            options: .regularExpression
        )
    }

    private static let msbuild = regex(
        #"^\s*(.+?)\((\d+),(\d+)(?:,\d+,\d+)?\):\s*(error|warning)\s+([A-Za-z]+\d+)?:?\s*(.*?)(?:\s+\[[^\]]+\])?$"#
    )
    private static let compiler = regex(
        #"^\s*(.+?):(\d+):(\d+):\s*(fatal error|error|warning):\s*(.*)$"#
    )
    private static let rustHeader = regex(#"^(error|warning)(?:\[(\w+)\])?:\s*(.*)$"#)
    private static let rustLocation = regex(#"^\s*-->\s*(.+?):(\d+):(\d+)\s*$"#)

    /// A pattern known to be valid (they are all literals here).
    private static func regex(_ pattern: String) -> NSRegularExpression {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { preconditionFailure(pattern) }
        return expression
    }

    private static func match(_ expression: NSRegularExpression, _ line: String) -> [String]? {
        let range = NSRange(line.startIndex..., in: line)
        guard let result = expression.firstMatch(in: line, range: range) else { return nil }
        return (0 ..< result.numberOfRanges).map { index in
            Range(result.range(at: index), in: line).map { String(line[$0]) } ?? ""
        }
    }
}
