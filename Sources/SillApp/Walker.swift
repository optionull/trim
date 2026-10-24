import AppKit
import MessagePack
import SillCore
import SillNvim

/// Walkthroughs (after M9): a `*.walk.md` opened in its pane, step by step, each anchor shown as the code it points at
/// now; a step asked about (its `@ask`, or the step itself) goes to the agent, whose answer `walkthrough_answer` writes
/// back under the question. An agent writes walkthroughs with the sill-walkthrough skill and drives them through MCP.
@MainActor
final class Walker {
    /// An anchor as found: the file and lines it shows now, or why it was not found.
    struct Found: Equatable {
        var path: String?
        var from = 0
        var to = 0
        var by = ""
        var lines: [String] = []
        var problem: String?
    }

    private weak var app: AppDelegate?
    private let channel: NvimChannel
    private let directory: String
    private(set) var path: String?
    private(set) var walk: Walkthrough?
    /// Each code block's anchor as found, by step and block.
    private(set) var found: [[Int: Found]] = []
    private(set) var step = 0
    private(set) var resolving = false
    var onChange: (() -> Void)?
    private var handled = 0

    init(app: AppDelegate, channel: NvimChannel, directory: String) {
        self.app = app
        self.channel = channel
        self.directory = directory
    }

    /// nvim's asks: `open <path>`, `skill`.
    func update(_ screen: Screen) {
        guard screen.walkAsks.count > handled else { return }
        for ask in screen.walkAsks[handled...] {
            switch ask.action {
            case "open": open(ask.argument)
            case "skill": installSkill()
            default: break
            }
        }
        handled = screen.walkAsks.count
    }

    // MARK: Reading

    /// Opens a walkthrough in its pane at `step`, its anchors found.
    func open(_ path: String, step: Int = 0) {
        self.path = path
        self.step = step
        Nvim.lua(channel, "require'sill'.show_pane('walk')")
        Task { await read() }
    }

    /// Reads the file again and finds its anchors: what changed (an answer written, an edit) shows.
    @discardableResult
    func read() async -> [String] {
        guard let path, let source = try? String(contentsOfFile: path, encoding: .utf8) else {
            walk = nil
            changed()
            return ["no walkthrough at \(path ?? "")"]
        }
        let walk = Walkthrough(source)
        self.walk = walk
        step = min(step, max(walk.steps.count - 1, 0))
        resolving = true
        changed()
        // Every anchor, in order, to Lua in one call.
        var anchors: [MessagePackValue] = [], places: [(Int, Int)] = []
        for (s, step) in walk.steps.enumerated() {
            for (b, block) in step.blocks.enumerated() {
                guard case let .code(anchor, _) = block else { continue }
                var fields: [MessagePackValue: MessagePackValue] = [:]
                switch anchor {
                case let .symbol(name, lines):
                    fields = [.string("kind"): .string("symbol"), .string("name"): .string(name)]
                    if let lines {
                        fields[.string("from")] = .int(Int64(lines.lowerBound)); fields[.string("to")] =
                            .int(Int64(lines.upperBound))
                    }
                case let .file(name, lines):
                    fields = [.string("kind"): .string("file"), .string("name"): .string(name)]
                    if let lines {
                        fields[.string("from")] = .int(Int64(lines.lowerBound)); fields[.string("to")] =
                            .int(Int64(lines.upperBound))
                    }
                }
                anchors.append(.map(fields))
                places.append((s, b))
            }
        }
        let folder = (path as NSString).deletingLastPathComponent
        let answers = await (try? channel.lua(
            "return require'sill.walk'.resolve(...)",
            args: [.array(anchors), .string(folder)]
        ))?.arrayValue ?? []
        var found = Array(repeating: [Int: Found](), count: walk.steps.count)
        var problems: [String] = []
        for (index, (s, b)) in places.enumerated() {
            let answer = index < answers.count ? (answers[index].dictionaryValue ?? [:]) : [:]
            if let problem = answer[.string("problem")]?.stringValue {
                found[s][b] = Found(problem: problem)
                problems.append("step \(s + 1) (\(walk.steps[s].title)): \(problem)")
                continue
            }
            guard let file = answer[.string("path")]?.stringValue else {
                found[s][b] = Found(problem: "not found")
                problems.append("step \(s + 1): not found")
                continue
            }
            let from = Int(answer[.string("from")]?.integerValue ?? 1),
                to = Int(answer[.string("to")]?.integerValue ?? 1)
            let all = (try? String(contentsOfFile: file, encoding: .utf8))?.components(separatedBy: "\n") ?? []
            let lines = from >= 1 && from <= all.count ? Array(all[(from - 1) ..< min(to, all.count)]) : []
            found[s][b] = Found(
                path: file,
                from: from,
                to: to,
                by: answer[.string("by")]?.stringValue ?? "",
                lines: lines
            )
        }
        self.found = found
        resolving = false
        changed()
        return problems
    }

    // MARK: Moving

    func go(to index: Int) {
        guard let walk, walk.steps.indices.contains(index) else { return }
        step = index
        changed()
    }

    /// The step's first piece of code, in the editor.
    func openCode(block: Int? = nil) {
        guard let found = found[safe: step] else { return }
        let place = block.flatMap { found[$0] } ?? found.keys.sorted().compactMap { found[$0] }.first { $0.path != nil }
        guard let place, let file = place.path else { return }
        Nvim.lua(channel, "vim.cmd('tabprevious'); require'sill'.open(...)", [.string(file), .int(Int64(place.from))])
    }

    // MARK: Asking

    /// Asks the agent about the step: its `@ask` on `line`, or the step itself with `question`. The answer comes back
    /// through `walkthrough_answer` and is written under the question.
    func ask(line: Int?, question: String? = nil) {
        guard let walk, let path, let current = walk.steps[safe: step] else { return }
        var asked = question ?? ""
        var answerLine = line
        if let line, case let .ask(text, _, _)? = current.blocks.first(where: {
            if case let .ask(_, _, at) = $0 { return at == line }
            return false
        }) {
            asked = text
        }
        if answerLine == nil {
            // A new question: written into the step first, so the answer has its place.
            guard !asked.isEmpty, let source = try? String(contentsOfFile: path, encoding: .utf8) else { return }
            var lines = source.components(separatedBy: "\n")
            let next = walk.steps[safe: step + 1]?.line ?? (lines.count + 1)
            var at = next - 1
            while at > current.line, lines[at - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                at -= 1
            }
            lines.insert("@ask " + asked, at: at)
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            answerLine = at + 1
        }
        var context: [String] = [current.title]
        for (index, block) in current.blocks.enumerated() {
            switch block {
            case let .prose(text): context.append(text)
            case .code:
                if let place = found[safe: step]?[index], let file = place.path {
                    context.append("\(file):\(place.from)-\(place.to)")
                    context.append(contentsOf: place.lines.prefix(40).map { "    " + $0 })
                }
            case .ask: break
            }
        }
        let prompt = """
        A question on the walkthrough \(path), step \(step + 1), "\(current.title)": \(asked)

        The step:
        \(context.joined(separator: "\n"))

        Answer in a few sentences, then call sill's walkthrough_answer tool with path "\(path)", line \(answerLine ??
            0) \
        and your answer, so it is written under the question in the walkthrough.
        """
        app?.agents.send(headline: "Walkthrough: \(asked)", prompt)
        Task { await read() }
    }

    /// The agent's answer written under the question on `line`.
    func answer(path: String, line: Int, _ text: String) async -> Bool {
        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        try? Walkthrough.answering(source, questionAt: line, with: text).write(
            toFile: path,
            atomically: true,
            encoding: .utf8
        )
        _ = try? await channel.lua("vim.cmd('silent! checktime')")
        if path == self.path { await read() }
        return true
    }

    // MARK: The skill

    /// The skill that teaches an agent to write walkthroughs, from the app's runtime into ~/.claude/skills.
    func installSkill() {
        let source = Runtime.directory.appendingPathComponent("skills/sill-walkthrough/SKILL.md")
        let target = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/skills/sill-walkthrough/SKILL.md")
        do {
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.copyItem(at: source, to: target)
            Nvim.lua(channel, "vim.notify(...)", [.string("The sill-walkthrough skill is in \(target.path)"), .int(2)])
        } catch {
            Nvim.lua(channel, "vim.notify(...)", [.string("The skill could not be installed: \(error)"), .int(3)])
        }
    }

    private func changed() { onChange?() }
}
