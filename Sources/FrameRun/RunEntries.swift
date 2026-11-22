import Foundation
import SillCore

/// Something Frame can run in its terminal pane: a program, a build, a test run or a task, from whatever the folder
/// says (the project files, a Makefile, mise, npm scripts, VS Code's `tasks.json` and `launch.json`). Read, never
/// built or asked of a tool, so it is quick.
public struct RunEntry: Equatable, Sendable, Hashable {
    public enum Kind: String, Sendable { case run, build, test, task }

    /// Stable across runs, to remember what was run last: `source:name`.
    public var id: String { source + ":" + title }
    public var title: String
    /// Where it comes from, as people say it: dotnet, swift, cargo, make, mise, npm, VS Code.
    public var source: String
    public var kind: Kind
    /// A shell command line.
    public var command: String
    /// Where it runs, absolute.
    public var directory: String
    public var environment: [String: String]
    /// What the person marked as the default (a task in the default build group).
    public var isDefault: Bool
    /// The file it is read from, from the folder's root, with the line when there is one (`Makefile:12`): shown, so it
    /// is
    /// clear where an entry comes from and where to change it.
    public var origin: String
    /// A configuration of the person's own (saved in `.frame/run.json`), not one found in the project's files.
    public var isCustom: Bool { source == RunConfigs.source }

    public init(
        title: String, source: String, kind: Kind, command: String, directory: String,
        environment: [String: String] = [:], isDefault: Bool = false, origin: String = ""
    ) {
        self.origin = origin
        self.title = title
        self.source = source
        self.kind = kind
        self.command = command
        self.directory = directory
        self.environment = environment
        self.isDefault = isDefault
    }
}

public enum RunEntries {
    /// Every entry for the folder `root`: what the project files run and build, Makefile targets, VS Code's tasks and
    /// launch configurations. Builds first, then runs, tests and the rest, each in the order found.
    public static func find(in root: String) -> [RunEntry] {
        var found = RunConfigs.entries(in: root)
        found += builds(in: root)
        found += SillCore.Runnables.find(in: root).map { runnable in
            let manifest = [
                "dotnet": runnable.project ?? "", "swift": "Package.swift", "cargo": "Cargo.toml",
                "node": "package.json",
                "mise": "mise.toml", "just": "justfile",
            ][runnable.tool] ?? ""
            let folder = runnable.directory.isEmpty ? "" : runnable.directory + "/"
            return RunEntry(
                title: runnable.name,
                source: runnable.tool == "node" ? "npm" : runnable.tool,
                kind: runnable.kind == .app ? .run : (runnable.kind == .test ? .test : .task),
                command: runnable.command,
                directory: runnable.directory.isEmpty ? root : root + "/" + runnable.directory,
                origin: runnable.project != nil ? manifest : folder + manifest
            )
        }
        found += make(in: root)
        found += VSCode.tasks(in: root)
        found += VSCode.launches(in: root)
        var seen = Set<String>()
        let unique = found.filter { seen.insert($0.id + "\u{0}" + $0.command + "\u{0}" + $0.directory).inserted }
        let order: [RunEntry.Kind] = [.build, .run, .test, .task]
        return unique.enumerated().sorted {
            (order.firstIndex(of: $0.element.kind) ?? 0, $0.offset) < (
                order.firstIndex(of: $1.element.kind) ?? 0,
                $1.offset
            )
        }.map(\.element)
    }

    /// The build of the folder: what its top-level project files say, in the order people expect (a solution before a
    /// project, a Swift package, Cargo, TypeScript's compiler).
    public static func builds(in root: String) -> [RunEntry] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: root)) ?? []
        func entry(_ title: String, _ source: String, _ command: String, from file: String) -> RunEntry {
            RunEntry(title: title, source: source, kind: .build, command: command, directory: root, origin: file)
        }
        var found: [RunEntry] = []
        let solutions = names.filter { $0.hasSuffix(".slnx") || $0.hasSuffix(".sln") }.sorted()
        let projects = names.filter { $0.hasSuffix(".csproj") || $0.hasSuffix(".fsproj") }.sorted()
        for name in solutions.prefix(1) + (solutions.isEmpty ? projects.prefix(1) : []) {
            found.append(entry(
                "Build " + name,
                "dotnet",
                "dotnet build \(SillCore.Runnables.quoted(name))",
                from: name
            ))
        }
        if names
            .contains("Package.swift") { found.append(entry("Build", "swift", "swift build", from: "Package.swift")) }
        if names.contains("Cargo.toml") { found.append(entry("Build", "cargo", "cargo build", from: "Cargo.toml")) }
        if names.contains("tsconfig.json"), !names.contains("package.json") {
            found.append(entry("Build", "tsc", "npx tsc -p .", from: "tsconfig.json"))
        }
        return found
    }

    /// Makefile targets (not pattern rules, variables or the special `.NAME` ones).
    public static func make(in root: String) -> [RunEntry] {
        guard let name = ["Makefile", "makefile", "GNUmakefile"].first(where: {
            FileManager.default.fileExists(atPath: root + "/" + $0)
        }), let text = try? String(contentsOfFile: root + "/" + name, encoding: .utf8) else { return [] }
        var targets: [(name: String, line: Int)] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            guard let first = line.first, first.isLetter || first == "_" else { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let after = line[line.index(after: colon)...]
            if after.hasPrefix("=") || after.hasPrefix(":=") || after.hasPrefix("::=") { continue }
            for target in line[..<colon].split(separator: " ") {
                let word = String(target)
                if word.contains("%") || word.contains("$") || word.contains("=") || targets
                    .contains(where: { $0.name == word })
                {
                    continue
                }
                targets.append((word, index + 1))
            }
        }
        return targets.map { target in
            RunEntry(
                title: target.name, source: "make",
                kind: ["build", "all"].contains(target.name) ? .build : (target.name.hasPrefix("test") ? .test : .task),
                command: "make \(SillCore.Runnables.quoted(target.name))", directory: root,
                origin: "\(name):\(target.line)"
            )
        }
    }
}
