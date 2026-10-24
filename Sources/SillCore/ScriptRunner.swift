import Foundation

/// How an example script runs, by its language: a .NET 10 file-based app (`dotnet run file.cs`, `#:project` and
/// `#:package` in it), TypeScript and JavaScript on node (which strips types itself), Python with uv (its PEP 723
/// inline metadata) or python3, Swift as a script, Rust as cargo's script format (a `---cargo` manifest at its top)
/// run on stable through a scratch package, shell with bash. Each runs in its own folder.
public enum ScriptRunner {
    public struct Command: Equatable, Sendable {
        public var executable: String
        public var arguments: [String]
        public var directory: String
        /// Files to write first (a scratch package's), by path.
        public var files: [String: String]
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unknownLanguage(String)
        public var description: String {
            switch self {
            case let .unknownLanguage(ext): "no runner for .\(ext) scripts (C#, TypeScript, JavaScript, Python, Swift, Rust, shell)"
            }
        }
    }

    /// The language a script is written in, as the notebook labels it.
    public static func language(of path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "cs": "C#"
        case "ts", "mts": "TypeScript"
        case "js", "mjs": "JavaScript"
        case "py": "Python"
        case "swift": "Swift"
        case "rs": "Rust"
        case "sh": "shell"
        default: (path as NSString).pathExtension
        }
    }

    /// The command that runs `path` (absolute); `scratch` is where a Rust script's package is made; `has` says whether
    /// a tool is on the PATH.
    public static func command(for path: String, scratch: String, has: (String) -> Bool) throws -> Command {
        let folder = (path as NSString).deletingLastPathComponent
        let ext = (path as NSString).pathExtension.lowercased()
        func env(_ arguments: [String]) -> Command {
            Command(executable: "/usr/bin/env", arguments: arguments, directory: folder, files: [:])
        }
        switch ext {
        case "cs": return env(["dotnet", "run", path])
        case "ts", "mts", "js", "mjs": return env(["node", path])
        case "py": return has("uv") ? env(["uv", "run", "--quiet", path]) : env(["python3", path])
        case "swift": return env(["swift", path])
        case "sh": return env(["bash", path])
        case "rs":
            let source = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            let (manifest, code) = cargoScript(source)
            let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                .replacingOccurrences(of: "-", with: "_").lowercased()
            // Paths in the manifest are the script's; the package is elsewhere.
            let absolute = manifest.replacingOccurrences(of: "path = \"", with: "path = \"\(folder)/")
                .replacingOccurrences(of: "path=\"", with: "path=\"\(folder)/")
            let toml =
                "[package]\nname = \"\(name.isEmpty ? "example" : name)\"\nversion = \"0.0.0\"\nedition = \"2021\"\n\n" +
                absolute + (absolute.contains("[dependencies]") ? "" : "\n[dependencies]\n")
            return Command(
                executable: "/usr/bin/env",
                arguments: ["cargo", "run", "--quiet"],
                directory: scratch,
                files: [scratch + "/Cargo.toml": toml, scratch + "/src/main.rs": code]
            )
        default:
            throw Failure.unknownLanguage(ext)
        }
    }

    /// cargo's script format: an optional `---cargo` … `---` manifest at the top (after a `#!` line), then the code.
    public static func cargoScript(_ source: String) -> (manifest: String, code: String) {
        var lines = source.components(separatedBy: "\n")
        if lines.first?.hasPrefix("#!") == true { lines.removeFirst() }
        guard let start = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              lines[start].trimmingCharacters(in: .whitespaces).hasPrefix("---"),
              let end = lines[(start + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return ("", lines.joined(separator: "\n")) }
        return (lines[(start + 1) ..< end].joined(separator: "\n") + "\n", lines[(end + 1)...].joined(separator: "\n"))
    }
}
