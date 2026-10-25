import AppKit
import MessagePack
import SillCore
import SillNvim

/// Tracing a symbol: `:SillTrace` (or `trace_symbol`) asks the language server for its call hierarchy through
/// sill.trace, the trace pane shows it as a tree opened a level at a time, and a path through it can go to the agent to
/// be explained.
@MainActor
final class Tracer {
    private weak var app: AppDelegate?
    private let channel: NvimChannel
    let directory: String
    private(set) var tree: TraceTree?
    /// What the last trace could not do.
    private(set) var problem: String?
    private(set) var busy = false
    private var handled = 0
    var onChange: (() -> Void)?

    init(app: AppDelegate, channel: NvimChannel, directory: String) {
        self.app = app
        self.channel = channel
        self.directory = directory
    }

    /// nvim's asks: `:SillTrace [callers|callees]` at the cursor.
    func update(_ screen: Screen) {
        guard screen.traceAsks.count > handled else { return }
        let asks = screen.traceAsks[handled...]
        handled = screen.traceAsks.count
        if let ask = asks.last {
            Task {
                await trace(
                    path: ask.path,
                    line: ask.line,
                    column: ask.column,
                    direction: TraceTree.Direction(rawValue: ask.direction) ?? .incoming
                )
            }
        }
    }

    // MARK: Asking sill.trace

    private struct Answer {
        var items: [TraceTree.Item]
        var problem: String?
    }

    /// Starts a request in sill.trace and collects its answer: nvim does not wait on the server.
    private func ask(_ start: String, _ args: [MessagePackValue], timeout: Duration = .seconds(60)) async -> Answer {
        guard let token = try? await channel.lua("return require'sill.trace'.\(start)(...)", args: args).integerValue
        else { return Answer(items: [], problem: "sill.trace did not start the request") }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let answer = try? await channel.lua("return require'sill.trace'.take(...)", args: [.int(token)]),
               let map = answer.dictionaryValue
            {
                if let problem = map[.string("problem")]?.stringValue { return Answer(items: [], problem: problem) }
                return Answer(items: (map[.string("items")]?.arrayValue ?? []).compactMap(Self.item), problem: nil)
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return Answer(items: [], problem: "The language server did not answer in time")
    }

    private static func item(_ value: MessagePackValue) -> TraceTree.Item? {
        guard let map = value.dictionaryValue, let id = map[.string("id")]?.integerValue,
              let path = map[.string("path")]?.stringValue
        else { return nil }
        return TraceTree.Item(
            id: Int(id),
            name: map[.string("name")]?.stringValue ?? "?",
            detail: map[.string("detail")]?.stringValue ?? "",
            path: path,
            line: Int(map[.string("line")]?.integerValue ?? 1),
            column: Int(map[.string("col")]?.integerValue ?? 1),
            at: map[.string("at")]?.integerValue.map(Int.init)
        )
    }

    // MARK: Tracing

    /// Traces the symbol at a place: its root, and its first level of calls. A language server still starting is
    /// waited for.
    @discardableResult
    func trace(path: String, line: Int, column: Int, direction: TraceTree.Direction, show: Bool = true) async -> Bool {
        busy = true
        problem = nil
        if show { showPane() }
        onChange?()
        defer {
            busy = false
            onChange?()
        }
        var answer = Answer(items: [], problem: nil)
        for _ in 0 ..< 60 {
            answer = await ask("prepare", [.string(path), .int(Int64(line)), .int(Int64(column))])
            guard answer.problem?.hasPrefix("No language server") == true else { break }
            try? await Task.sleep(for: .seconds(1))
        }
        guard let root = answer.items.first else {
            problem = answer.problem ?? "Nothing to trace there"
            tree = nil
            return false
        }
        tree = TraceTree(root: root, direction: direction)
        await open(0)
        return problem == nil
    }

    /// The same root the other way: callers to callees and back.
    func turn() async {
        guard let tree else { return }
        let root = tree.nodes[0].item
        await trace(
            path: root.path,
            line: root.line,
            column: root.column,
            direction: tree.direction == .incoming ? .outgoing : .incoming
        )
    }

    /// Opens node `index`: its calls, asked the first time.
    func open(_ index: Int) async {
        guard var tree, tree.nodes.indices.contains(index) else { return }
        if tree.nodes[index].children == nil {
            let answer = await ask("calls", [
                .int(Int64(tree.nodes[index].item.id)), .string(tree.direction.rawValue),
            ])
            // The tree may have been replaced while the server answered.
            guard self.tree?.nodes.first?.item == tree.nodes[0].item, self.tree?.direction == tree.direction
            else { return }
            tree = self.tree ?? tree
            if let problem = answer.problem {
                self.problem = problem
                onChange?()
                return
            }
            tree.setChildren(of: index, answer.items)
        } else {
            tree.setExpanded(index, true)
        }
        self.tree = tree
        onChange?()
    }

    func close(_ index: Int) {
        tree?.setExpanded(index, false)
        onChange?()
    }

    /// Asks every level down to `depth` below the root: what `trace_symbol` answers with.
    func load(depth: Int, limit: Int = 200) async {
        while let tree, tree.nodes.count < limit, let next = tree.unasked(within: depth).first {
            await open(next)
            if problem != nil { return }
        }
    }

    /// Where a symbol (`Tax.Of`) is declared, found as walkthroughs find their anchors (the language servers, else
    /// its declaration's text), with the column of its name.
    func place(of symbol: String) async -> (path: String, line: Int, column: Int)? {
        let found = try? await channel.lua(
            "return require'sill.walk'.resolve({ { kind = 'symbol', name = ... } }, select(2, ...))[1]",
            args: [.string(symbol), .string(directory)]
        )
        guard let map = found?.dictionaryValue, let path = map[.string("path")]?.stringValue,
              let line = map[.string("from")]?.integerValue.map(Int.init)
        else { return nil }
        let name = symbol.split(separator: ".").last.map(String.init) ?? symbol
        let text = (try? String(contentsOfFile: path, encoding: .utf8))?.components(separatedBy: "\n")
        let row = text?[safe: line - 1] ?? ""
        let column = row.range(of: name).map { row.distance(from: row.startIndex, to: $0.lowerBound) + 1 } ?? 1
        return (path, line, column)
    }

    /// A symbol's call tree as text, `depth` levels deep, built apart from the pane's: a notebook's `@trace`.
    func text(of symbol: String, direction: TraceTree.Direction, depth: Int) async -> String {
        guard let place = await place(of: symbol) else { return "No symbol \(symbol) found" }
        var answer = Answer(items: [], problem: nil)
        for _ in 0 ..< 60 {
            answer = await ask("prepare", [.string(place.path), .int(Int64(place.line)), .int(Int64(place.column))])
            guard answer.problem?.hasPrefix("No language server") == true else { break }
            try? await Task.sleep(for: .seconds(1))
        }
        guard let root = answer.items.first else { return answer.problem ?? "Nothing to trace at \(symbol)" }
        var tree = TraceTree(root: root, direction: direction)
        while tree.nodes.count < 100, let next = tree.unasked(within: depth).first {
            let calls = await ask("calls", [.int(Int64(tree.nodes[next].item.id)), .string(direction.rawValue)])
            if let problem = calls.problem { return problem }
            tree.setChildren(of: next, calls.items)
        }
        return tree.text(relativeTo: directory)
    }

    func showPane() {
        Nvim.lua(channel, "require'sill'.show_pane('trace')")
    }

    /// A node's place, in the editor.
    func reveal(_ index: Int) {
        guard let node = tree?.nodes[safe: index] else { return }
        // A caller opens where it makes the call.
        let line = tree?.direction == .incoming ? node.item.at ?? node.item.line : node.item.line
        Nvim.lua(channel, "vim.cmd('tabprevious'); require'sill'.open(...)", [
            .string(node.item.path), .int(Int64(line)),
        ])
    }

    // MARK: The agent

    /// Asks the agent to explain the path from the root to node `index`, with each step's code.
    func explain(_ index: Int) {
        guard let tree, let agents = app?.agents else { return }
        let path = tree.path(to: index)
        // The chain read in call order: callers top down, callees as they are called.
        let chain = tree.direction == .incoming ? Array(path.reversed()) : path
        var steps: [String] = []
        for (number, node) in chain.map({ tree.nodes[$0] }).enumerated() {
            let place = relative(node.item.path) + ":\(node.item.line)"
            steps.append("\(number + 1). \(node.item.name) at \(place)")
            steps.append(contentsOf: Self.excerpt(node.item.path, from: node.item.line).map { "    " + $0 })
        }
        let first = tree.nodes[chain.first ?? 0].item.name, last = tree.nodes[chain.last ?? 0].item.name
        agents.send(headline: "Explain how \(first) reaches \(last)", """
        Explain this call path in \(directory): what each step does with what it is given, what it passes on, and \
        what in it is worth knowing (state, side effects, where it can fail). A few sentences per step.

        \(steps.joined(separator: "\n"))
        """)
    }

    /// Node `index`'s code, into the current basket.
    func addToBasket(_ index: Int) {
        guard let tree, let node = tree.nodes[safe: index], let baskets = app?.baskets else { return }
        let lines = Self.excerpt(node.item.path, from: node.item.line).count
        let note = index == 0 ? nil : tree.direction == .incoming ?
            "\(node.item.name) calls \(tree.nodes[node.parent ?? 0].item.name)" +
            (node.item.at.map { " at line \($0)" } ?? "") :
            "\(tree.nodes[node.parent ?? 0].item.name) calls \(node.item.name)"
        baskets.add(path: node.item.path, lines: node.item.line ... node.item.line + max(lines - 1, 0), note: note)
    }

    private func relative(_ path: String) -> String {
        path.hasPrefix(directory + "/") ? String(path.dropFirst(directory.count + 1)) : path
    }

    /// A symbol's first lines from its declaration: to where its braces close, at most 25.
    static func excerpt(_ path: String, from line: Int) -> [String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        let lines = text.components(separatedBy: "\n")
        guard line >= 1, line <= lines.count else { return [] }
        var out: [String] = [], depth = 0, opened = false
        for number in line ... min(lines.count, line + 24) {
            let current = lines[number - 1]
            out.append("\(number)\t\(current)")
            for character in current where character == "{" || character == "}" {
                depth += character == "{" ? 1 : -1
                opened = true
            }
            if opened, depth <= 0 { break }
            if !opened, current.trimmingCharacters(in: .whitespaces).hasSuffix(";") { break }
        }
        return out
    }
}
