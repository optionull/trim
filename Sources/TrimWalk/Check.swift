import Foundation

/// What `trim walk check` says of a walkthrough: problems an author (an agent) can fix before a person opens it.
public struct WalkReport: Codable, Equatable, Sendable {
    public struct Problem: Codable, Equatable, Sendable {
        public var line: Int
        public var severity: String // "error" or "warning"
        public var message: String
    }

    public var ok: Bool
    public var title: String
    public var steps: Int
    public var anchors: Int
    public var problems: [Problem]

    /// The report as JSON, for a program to read.
    public func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? String(data: encoder.encode(self), encoding: .utf8)) ?? "{}"
    }
}

public enum WalkCheck {
    /// The first words of a Mermaid diagram.
    static let diagramKinds: Set = [
        "graph", "flowchart", "sequenceDiagram", "classDiagram", "stateDiagram", "stateDiagram-v2", "erDiagram",
        "journey",
        "gantt", "pie", "mindmap", "timeline", "gitGraph", "quadrantChart", "requirementDiagram", "sankey-beta",
        "xychart-beta",
        "block-beta", "packet-beta", "kanban", "architecture-beta", "C4Context", "C4Container", "C4Component",
        "C4Dynamic",
    ]

    /// Checks `source`: its structure, and that every anchor is found in the code `resolver` reads.
    public static func run(_ source: String, resolver: AnchorResolver) -> WalkReport {
        let walk = Walkthrough(source)
        var problems: [WalkReport.Problem] = []
        func add(_ line: Int, _ severity: String, _ message: String) {
            problems.append(.init(line: line, severity: severity, message: message))
        }
        var anchors = 0
        if walk.steps.isEmpty { add(1, "error", "no steps: a step is a line starting with `## `") }
        if walk.steps.count > 12 { add(walk.steps[12].line, "warning", "\(walk.steps.count) steps: 4 to 10 read best") }
        if walk.intro.isEmpty { add(1, "warning", "no introduction: a sentence or two on what this explains and why") }
        for step in walk.steps {
            var showsCode = false
            var lastFence: (text: String, line: Int)?
            for block in step.blocks {
                switch block {
                case let .code(anchor, line):
                    anchors += 1
                    showsCode = true
                    switch resolver.resolve(anchor) {
                    case let .problem(message): add(line, "error", message)
                    case let .found(found):
                        if let recorded = walk.fingerprints[line], Walkthrough.fingerprint(found.text) != recorded {
                            add(line, "warning", "\(anchor.text) changed since the walkthrough was written")
                        }
                    }
                case let .link(node, anchor, line):
                    anchors += 1
                    if case let .problem(message) = resolver.resolve(anchor) { add(line, "error", message) }
                    if let fence = lastFence, !fence.text.contains(node) {
                        add(line, "warning", "the diagram above has no node `\(node)`")
                    }
                    if lastFence == nil { add(line, "warning", "@link has no diagram above it in this step") }
                case let .fence(language, text, line):
                    lastFence = (text, line)
                    if language == "mermaid" {
                        let first = text.split(separator: "\n").first
                            .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
                        let word = first.split(separator: " ").first.map(String.init) ?? ""
                        if !diagramKinds.contains(word) { add(line, "error", "unknown diagram type `\(word)`") }
                    }
                case let .run(_, command, line):
                    showsCode = true
                    if command.trimmingCharacters(in: .whitespaces)
                        .isEmpty { add(line, "error", "@run has no command") }
                case let .diff(path, line):
                    showsCode = true
                    let url = path.hasPrefix("/") ? path : resolver.root + "/" + path
                    if !FileManager.default.fileExists(atPath: url), Git.run(
                        ["ls-files", "--", path],
                        in: resolver.root
                    ) == nil {
                        add(line, "warning", "@diff \(path): no such file in the worktree")
                    }
                case .example, .trace:
                    showsCode = true
                default: break
                }
            }
            if !showsCode, step.blocks.contains(where: { if case .prose = $0 { true } else { false } }) {
                add(step.line, "warning", "step \"\(step.title)\" shows no code: anchor it with @code")
            }
        }
        return WalkReport(
            ok: !problems.contains { $0.severity == "error" }, title: walk.title, steps: walk.steps.count,
            anchors: anchors, problems: problems
        )
    }
}
