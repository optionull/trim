import Foundation

/// Something a checkout can run, as its project files say (read, never built or asked of a tool, so it is quick): a
/// .NET program (a run per launch profile) or test project, a Swift executable or test target, a Cargo binary or its
/// tests, a package.json script, a mise task, a just recipe. What the person runs is a configuration of one: its
/// command
/// line as they altered it, kept in the repository's `.sill/run.json`.
public struct Runnable: Equatable, Sendable, Codable, Hashable {
    public enum Kind: String, Sendable, Codable { case app, test, script }

    public var name: String
    public var kind: Kind
    /// dotnet, swift, cargo, node, mise, just.
    public var tool: String
    public var command: String
    /// Where it runs, from the checkout's root ("" for the root).
    public var directory: String
    /// The project file (from the root), for the debugger and the profiler (.NET).
    public var project: String?

    public init(
        name: String,
        kind: Kind,
        tool: String,
        command: String,
        directory: String = "",
        project: String? = nil
    ) {
        self.name = name
        self.kind = kind
        self.tool = tool
        self.command = command
        self.directory = directory
        self.project = project
    }

    /// Under the debugger: a .NET program (a test project is run by `dotnet test`, not debugged here).
    public var debuggable: Bool { tool == "dotnet" && kind == .app }
    /// Under the profiler: a .NET program, a Cargo binary, a Swift executable.
    public var profilable: Bool { kind == .app && ["dotnet", "cargo", "swift"].contains(tool) }

    /// Whether `files` (from the root) touch it: one of them is in its folder (the root's runs are touched by any).
    public func touched(by files: [String]) -> Bool {
        let folder = project.map { ($0 as NSString).deletingLastPathComponent } ?? directory
        return files.contains { folder.isEmpty || $0.hasPrefix(folder + "/") }
    }
}

public enum Runnables {
    /// Every runnable in the checkout at `root`, from the files git knows (and new ones): .NET, Swift, Cargo, Node,
    /// mise, just. Ordered programs, tests, then scripts, each by name.
    public static func find(in root: String) -> [Runnable] {
        let files = (Review.git(["ls-files", "--cached", "--others", "--exclude-standard"], in: root) ?? "")
            .split(separator: "\n").map(String.init)
        var found: [Runnable] = []
        for file in files {
            let name = (file as NSString).lastPathComponent
            let folder = (file as NSString).deletingLastPathComponent
            func read() -> String { (try? String(contentsOfFile: root + "/" + file, encoding: .utf8)) ?? "" }
            if name.hasSuffix(".csproj") || name.hasSuffix(".fsproj") {
                found += dotnet(file, text: read(), launchSettings: (try? String(
                    contentsOfFile: root + "/" + (folder.isEmpty ? "" : folder + "/") +
                        "Properties/launchSettings.json",
                    encoding: .utf8
                )))
            } else if name == "Package.swift" {
                found += swift(read(), folder: folder)
            } else if name == "Cargo.toml" {
                found += cargo(read(), folder: folder, root: root)
            } else if name == "package.json", !file.contains("node_modules/") {
                found += node(read(), folder: folder, lockfiles: Set(files.filter {
                    ($0 as NSString).deletingLastPathComponent == folder
                }.map { ($0 as NSString).lastPathComponent }))
            } else if name == "mise.toml" || name == ".mise.toml" {
                found += mise(read(), folder: folder)
            } else if name == "justfile" || name == "Justfile" {
                found += just(read(), folder: folder)
            }
        }
        let order: [Runnable.Kind] = [.app, .test, .script]
        return found.sorted {
            (order.firstIndex(of: $0.kind) ?? 0, $0.name) < (order.firstIndex(of: $1.kind) ?? 0, $1.name)
        }
    }

    // MARK: Each ecosystem

    /// A .NET project: a program (a run per launch profile when it has them) or a test project; a library none.
    static func dotnet(_ file: String, text: String, launchSettings: String?) -> [Runnable] {
        let project = ProjectFile(path: file, text: text)
        switch project.kind {
        case .test:
            return [Runnable(
                name: project.name,
                kind: .test,
                tool: "dotnet",
                command: "dotnet test \(quoted(file))",
                project: file
            )]
        case .app, .web:
            let profiles = launchSettings.flatMap { text -> [String]? in
                guard let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                      let profiles = root["profiles"] as? [String: [String: Any]] else { return nil }
                // The profiles dotnet run can start (a project's), not IIS Express's.
                return profiles.filter { ($0.value["commandName"] as? String) == "Project" }.keys.sorted()
            } ?? []
            let run = "dotnet run --project \(quoted(file))"
            if profiles.count < 2 {
                return [Runnable(name: project.name, kind: .app, tool: "dotnet", command: run, project: file)]
            }
            return profiles.map {
                Runnable(
                    name: "\(project.name) (\($0))",
                    kind: .app,
                    tool: "dotnet",
                    command: "\(run) --launch-profile \(quoted($0))",
                    project: file
                )
            }
        case .library:
            return []
        }
    }

    /// A Swift package: its executable targets (and products), and its test targets as one `swift test` each.
    static func swift(_ text: String, folder: String) -> [Runnable] {
        func names(_ call: String) -> [String] {
            matches(of: #"\."# + call + #"\(\s*name:\s*"([^"]+)""#, in: text)
        }
        let executables = Array(Set(names("executableTarget") + names("executable"))).sorted()
        let tests = names("testTarget")
        return executables.map {
            Runnable(name: $0, kind: .app, tool: "swift", command: "swift run \(quoted($0))", directory: folder)
        } + tests.map {
            Runnable(
                name: $0,
                kind: .test,
                tool: "swift",
                command: "swift test --filter \(quoted($0))",
                directory: folder
            )
        }
    }

    /// A Cargo package: its binaries (`[[bin]]`s, else the package when it has `src/main.rs`) and its tests.
    static func cargo(_ text: String, folder: String, root: String) -> [Runnable] {
        let bins = matches(of: #"(?s)\[\[bin\]\][^\[]*?name\s*=\s*"([^"]+)""#, in: text)
        let package = matches(of: #"(?s)\[package\][^\[]*?name\s*=\s*"([^"]+)""#, in: text).first
        let main = FileManager.default
            .fileExists(atPath: root + "/" + (folder.isEmpty ? "" : folder + "/") + "src/main.rs")
        let programs = bins.isEmpty ? (main ? package.map { [$0] } ?? [] : []) : bins
        guard package != nil || !bins.isEmpty else { return [] }
        return programs.map {
            Runnable(name: $0, kind: .app, tool: "cargo", command: "cargo run --bin \(quoted($0))", directory: folder)
        } + [Runnable(
            name: (package ?? "tests") + " tests",
            kind: .test,
            tool: "cargo",
            command: "cargo test",
            directory: folder
        )]
    }

    /// A package.json's scripts, run with the package manager its lockfile names; `test` a test.
    static func node(_ text: String, folder: String, lockfiles: Set<String>) -> [Runnable] {
        guard let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let scripts = root["scripts"] as? [String: Any] else { return [] }
        let manager = lockfiles.contains("pnpm-lock.yaml") ? "pnpm" : lockfiles.contains("yarn.lock") ? "yarn" :
            lockfiles.contains("bun.lockb") || lockfiles.contains("bun.lock") ? "bun" : "npm"
        return scripts.keys.sorted().map { script in
            Runnable(
                name: script,
                kind: script == "test" ? .test : .script,
                tool: "node",
                command: "\(manager) run \(script)",
                directory: folder
            )
        }
    }

    /// mise's tasks (`[tasks.name]`).
    static func mise(_ text: String, folder: String) -> [Runnable] {
        matches(of: #"(?m)^\[tasks\.("?)([A-Za-z0-9_:\-]+)\1\]"#, in: text, group: 2).map { task in
            Runnable(
                name: task,
                kind: task == "test" ? .test : .script,
                tool: "mise",
                command: "mise run \(task)",
                directory: folder
            )
        }
    }

    /// A justfile's recipes (a line starting with a name and a colon, not a setting or an assignment).
    static func just(_ text: String, folder: String) -> [Runnable] {
        // A recipe: a name, parameters (defaults may hold `=`), a colon; not an assignment (`name :=`, `name =`).
        matches(of: #"(?m)^@?([A-Za-z_][A-Za-z0-9_\-]*)(?!\s*:?=)[^:\n]*:(?!=)"#, in: text).filter { $0 != "set" }.map {
            Runnable(
                name: $0,
                kind: $0 == "test" ? .test : .script,
                tool: "just",
                command: "just \($0)",
                directory: folder
            )
        }
    }

    // MARK: Helpers

    static func matches(of pattern: String, in text: String, group: Int = 1) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: group), in: text).map { String(text[$0]) }
        }
    }

    /// A word as a shell takes it: as it is when it is plain, else in single quotes.
    public static func quoted(_ word: String) -> String {
        word.allSatisfy { $0.isLetter || $0.isNumber || "-_./:@".contains($0) } ? word :
            "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// What the person ran here and how: configurations of runnables, their command lines as altered, the last run
/// first. Kept in the repository's `.sill/run.json` (never committed).
public struct RunConfigurations: Codable, Equatable, Sendable {
    public struct Configuration: Codable, Equatable, Sendable {
        public var name: String
        public var command: String
        public var directory: String
        public var lastRun: Date

        public init(name: String, command: String, directory: String, lastRun: Date = Date()) {
            self.name = name
            self.command = command
            self.directory = directory
            self.lastRun = lastRun
        }
    }

    public var configurations: [Configuration] = []

    public init(configurations: [Configuration] = []) {
        self.configurations = configurations
    }

    /// The last run.
    public var last: Configuration? { configurations.max { $0.lastRun < $1.lastRun } }

    /// Ran now: kept (one per name and folder, its command as last run), the newest first.
    public mutating func ran(_ configuration: Configuration) {
        configurations.removeAll { $0.name == configuration.name && $0.directory == configuration.directory }
        configurations.insert(configuration, at: 0)
    }

    public static func load(_ file: String) -> RunConfigurations {
        guard let data = FileManager.default.contents(atPath: file) else { return RunConfigurations() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(RunConfigurations.self, from: data)) ?? RunConfigurations()
    }

    public func save(_ file: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(
            atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        try? encoder.encode(self).write(to: URL(fileURLWithPath: file), options: .atomic)
    }
}
