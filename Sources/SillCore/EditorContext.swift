import Foundation

/// What the person is looking at in sill, told to an agent with their prompt (Claude Code's UserPromptSubmit hook adds
/// it to the prompt): the file and line, the lines they selected last, the basket open. Only what changed since the
/// session's last prompt is told again, so a conversation is not filled with the same lines.
public struct EditorContext: Equatable, Sendable {
    public struct Selection: Equatable, Sendable {
        public var path: String
        public var from: Int
        public var to: Int
        public var text: String

        public init(path: String, from: Int, to: Int, text: String) {
            self.path = path
            self.from = from
            self.to = to
            self.text = text
        }
    }

    /// The file in the editor (relative to the worktree), and the cursor's line in it.
    public var path: String?
    public var line: Int?
    /// The last lines selected, if that was since the session's last prompt.
    public var selection: Selection?
    /// The basket open, by its file's name.
    public var basket: String?
    /// The branch's pull request, when something about it needs attention or is awaited.
    public var pullRequest: String?

    /// The most lines of a selection given in full; more are cut, with how many.
    public static let selectionLines = 60

    public init(
        path: String? = nil,
        line: Int? = nil,
        selection: Selection? = nil,
        basket: String? = nil,
        pullRequest: String? = nil
    ) {
        self.path = path
        self.line = line
        self.selection = selection
        self.basket = basket
        self.pullRequest = pullRequest
    }

    /// The context as the agent reads it, with what `last` (the context told before) already said left out; nil when
    /// there is nothing new.
    public func text(after last: EditorContext? = nil) -> String? {
        var lines: [String] = []
        if let path, path != last?.path || line != last?.line {
            lines.append("Open in the editor: \(path)" + (line.map { ":\($0)" } ?? ""))
        }
        if let selection, selection != last?.selection {
            let all = selection.text.components(separatedBy: "\n")
            let shown = all.prefix(Self.selectionLines).joined(separator: "\n")
            let cut = all.count > Self.selectionLines ? "\n… (\(all.count - Self.selectionLines) more lines)" : ""
            let span = selection.from == selection.to ? "\(selection.from)" : "\(selection.from)-\(selection.to)"
            lines.append("Selected, \(selection.path):\(span):\n```\n\(shown)\(cut)\n```")
        }
        if let basket, basket != last?.basket {
            lines.append("Open basket: .sill/baskets/\(basket)")
        }
        if let pullRequest, pullRequest != last?.pullRequest {
            lines.append("The branch's pull request \(pullRequest) (sill's pull_request tool has its details)")
        }
        guard !lines.isEmpty else { return nil }
        return "In sill, the editor beside this session (the person's view; \"this\" and \"here\" may mean it):\n" +
            lines.joined(separator: "\n")
    }
}
