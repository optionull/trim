import Foundation

/// A run configuration of the person's own: a command line (with the arguments they want), a folder to run it in and
/// environment variables, kept in `.frame/run.json` of the folder. Made from an entry found in the project's files (so
/// it starts as what that did, and `basedOn` says which) or from nothing; run like any entry, listed first.
public struct RunConfig: Codable, Equatable, Sendable {
    public var name: String
    public var command: String
    /// From the folder's root; empty is the root.
    public var directory: String
    public var environment: [String: String]
    /// "run", "build", "test" or "task".
    public var kind: String
    /// Where it was copied from, as an entry's id says it (`make:build`), for the person's own reading.
    public var basedOn: String?

    public init(
        name: String, command: String, directory: String = "", environment: [String: String] = [:],
        kind: String = "run",
        basedOn: String? = nil
    ) {
        self.name = name
        self.command = command
        self.directory = directory
        self.environment = environment
        self.kind = kind
        self.basedOn = basedOn
    }
}

public enum RunConfigs {
    /// What entries of these say they come from.
    public static let source = "Frame"
    public static let relativePath = ".frame/run.json"

    public static func file(in root: String) -> String { root + "/" + relativePath }

    /// The saved configurations of a folder (none when there is no file, or it is not what it should be).
    public static func load(in root: String) -> [RunConfig] {
        guard let data = FileManager.default.contents(atPath: file(in: root)) else { return [] }
        return (try? JSONDecoder().decode([RunConfig].self, from: data)) ?? []
    }

    /// Writes them, creating `.frame/`; none removes the file.
    public static func save(_ configs: [RunConfig], in root: String) throws {
        let path = file(in: root)
        if configs.isEmpty {
            try? FileManager.default.removeItem(atPath: path)
            return
        }
        try FileManager.default.createDirectory(atPath: root + "/.frame", withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(configs).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// The configurations as entries.
    public static func entries(in root: String) -> [RunEntry] {
        load(in: root).map { config in
            RunEntry(
                title: config.name, source: source, kind: RunEntry.Kind(rawValue: config.kind) ?? .run,
                command: config.command, directory: config.directory.isEmpty ? root : root + "/" + config.directory,
                environment: config.environment, origin: relativePath + (config.basedOn.map { " (from \($0))" } ?? "")
            )
        }
    }

    /// An entry as a configuration to start from: what it runs, where, with what environment.
    public static func config(from entry: RunEntry, in root: String) -> RunConfig {
        var directory = ""
        if entry.directory.hasPrefix(root + "/") { directory = String(entry.directory.dropFirst(root.count + 1)) }
        return RunConfig(
            name: entry.title + " (mine)", command: entry.command, directory: directory, environment: entry.environment,
            kind: entry.kind.rawValue, basedOn: entry.isCustom ? nil : entry.id
        )
    }

    /// A name no saved configuration has: `name`, else `name 2`, `name 3`...
    public static func unusedName(_ name: String, among configs: [RunConfig]) -> String {
        let taken = Set(configs.map(\.name))
        if !taken.contains(name) { return name }
        var number = 2
        while taken.contains("\(name) \(number)") {
            number += 1
        }
        return "\(name) \(number)"
    }

    /// Environment as one variable a line (`KEY=value`), for a form; and back (blank lines and comments dropped).
    public static func text(of environment: [String: String]) -> String {
        environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    }

    public static func environment(from text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            if !key
                .isEmpty { result[key] = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces) }
        }
        return result
    }
}
