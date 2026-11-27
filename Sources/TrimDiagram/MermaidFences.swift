import Foundation

/// A ```` ```mermaid ```` block of a Markdown text: the lines of its opening and closing fences (1-based) and the
/// diagram text.
public struct MermaidFence: Equatable, Sendable {
    public var first: Int
    public var last: Int
    public var source: String
}

public enum MermaidFences {
    /// The Mermaid blocks of `text`, wherever they are (other fenced blocks are skipped whole, so a fence shown inside
    /// one is not
    /// taken for the start of another). A block that is never closed is not one.
    public static func find(in text: String) -> [MermaidFence] {
        var found: [MermaidFence] = []
        var open: (language: String, first: Int, body: [String])?
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") else {
                open?.body.append(line)
                continue
            }
            if let current = open {
                if current.language == "mermaid" {
                    found.append(MermaidFence(
                        first: current.first,
                        last: index + 1,
                        source: current.body.joined(separator: "\n")
                    ))
                }
                open = nil
            } else {
                open = (trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased(), index + 1, [])
            }
        }
        return found
    }
}
