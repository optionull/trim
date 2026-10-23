import Foundation

/// A build's output as diagnostics, one shape whatever the toolchain (plan §7): dotnet/MSBuild, Swift, Cargo, tsc.
public enum BuildCapture {
    /// The command that builds what is in `directory`, by what it holds.
    public static func command(in directory: String) -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        if names.contains(where: { $0.hasSuffix(".sln") || $0.hasSuffix(".slnx") || $0.hasSuffix(".csproj") ||
                $0.hasSuffix(".fsproj")
        }) {
            return "dotnet build -nologo -consoleLoggerParameters:NoSummary"
        }
        if names.contains("Package.swift") { return "swift build" }
        if names.contains("Cargo.toml") { return "cargo build --message-format=short" }
        if names.contains("tsconfig.json") { return "npx tsc --noEmit --pretty false" }
        return nil
    }

    /// The diagnostics in a build's output. Relative paths are taken from `directory`. A diagnostic reported twice
    /// (MSBuild repeats errors per project and in its summary) is kept once.
    public static func diagnostics(in output: String, directory: String) -> [Diagnostic] {
        var seen = Set<String>(), result: [Diagnostic] = []
        for line in output.split(whereSeparator: \.isNewline) {
            guard let diagnostic = parse(String(line), directory: directory) else { continue }
            let key = "\(diagnostic.path):\(diagnostic.line):\(diagnostic.col):\(diagnostic.code):\(diagnostic.message)"
            if seen.insert(key).inserted { result.append(diagnostic) }
        }
        return result
    }

    /// One line: `file(line,col): error CODE: message [project]` (MSBuild, tsc) or `file:line:col: error[: or
    /// [CODE]:] message` (Swift, Cargo, clang).
    static func parse(_ line: String, directory: String) -> Diagnostic? {
        let line = line.trimmingCharacters(in: .whitespaces)
        if let match = line.firstMatch(of: msbuild) {
            var message = String(match.output.message)
            // MSBuild ends with the project in brackets; it is not part of the message.
            if let bracket = message.range(of: " [", options: .backwards), message.hasSuffix("]") {
                message = String(message[..<bracket.lowerBound])
            }
            return diagnostic(
                path: String(match.output.path), line: Int(match.output.line) ?? 1, col: Int(match.output.col) ?? 1,
                severity: String(match.output.severity), code: String(match.output.code), message: message,
                directory: directory, source: String(match.output.code).hasPrefix("TS") ? "tsc" : "dotnet"
            )
        }
        if let match = line.firstMatch(of: compiler) {
            return diagnostic(
                path: String(match.output.path), line: Int(match.output.line) ?? 1, col: Int(match.output.col) ?? 1,
                severity: String(match.output.severity), code: String(match.output.code ?? ""),
                message: String(match.output.message), directory: directory, source: "build"
            )
        }
        return nil
    }

    private nonisolated(unsafe) static let msbuild =
        /^(?<path>[^(:\s][^(]*)\((?<line>\d+),(?<col>\d+)(?:,\d+,\d+)?\): (?<severity>error|warning) (?<code>[A-Z]+\d+): (?<message>.+)$/

    private nonisolated(unsafe) static let compiler =
        /^(?<path>[^:\s][^:]*):(?<line>\d+):(?<col>\d+): (?<severity>error|warning)(?:\[(?<code>[A-Z]+\d+)\])?: (?<message>.+)$/

    private static func diagnostic(
        path: String, line: Int, col: Int, severity: String, code: String, message: String, directory: String,
        source: String
    ) -> Diagnostic {
        let absolute = path.hasPrefix("/") ? path : (directory as NSString).appendingPathComponent(path)
        return Diagnostic(
            severity: severity == "error" ? 1 : 2, message: message, source: source, code: code,
            path: (absolute as NSString).standardizingPath, buffer: 0, line: line, col: col
        )
    }
}
