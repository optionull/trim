import AppKit
import MessagePack
import SillCore
import SillNvim

/// Context baskets: notebooks of code collected while browsing (`:SillBasket add`, `b` in the trace pane) or by an
/// agent investigating, kept in `.sill/baskets/` as `*.basket.md`, sent to the agent with a question; its answer is
/// written back as the basket's findings. One basket is current: what is added goes there. Sending one closes it, and
/// the next piece starts a new one.
@MainActor
final class Baskets {
    private weak var app: AppDelegate?
    private let channel: NvimChannel
    let directory: String
    /// The baskets' notebook.
    let walker: Walker
    private var handled = 0

    init(app: AppDelegate, channel: NvimChannel, directory: String) {
        self.app = app
        self.channel = channel
        self.directory = directory
        walker = Walker(app: app, channel: channel, directory: directory, pane: "basket")
    }

    /// `.sill/baskets`, made when first asked for.
    var folder: String {
        let folder = SillFolder.path(for: directory) + "/baskets"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        return folder
    }

    private var currentFile: String { folder + "/.current" }

    /// The basket pieces go to: the last made or opened, until it is sent.
    var current: String? {
        get {
            guard let name = try? String(contentsOfFile: currentFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
            else { return nil }
            let path = folder + "/" + name
            return FileManager.default.fileExists(atPath: path) ? path : nil
        }
        set {
            try? ((newValue as NSString?)?.lastPathComponent ?? "").write(
                toFile: currentFile, atomically: true, encoding: .utf8
            )
        }
    }

    /// Every basket, the newest first, with what it says of itself.
    func list() -> [(path: String, basket: Walkthrough)] {
        let folder = folder
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names.filter { $0.hasSuffix(BasketFile.suffix) }.map { folder + "/" + $0 }.compactMap { path in
            (try? String(contentsOfFile: path, encoding: .utf8)).map { (path, Walkthrough($0)) }
        }.sorted { modified($0.path) > modified($1.path) }
    }

    private func modified(_ path: String) -> Date {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date) ?? .distantPast
    }

    // MARK: Asks from nvim

    func update(_ screen: Screen) {
        guard screen.basketAsks.count > handled else { return }
        let asks = screen.basketAsks[handled...]
        handled = screen.basketAsks.count
        for ask in asks {
            switch ask.action {
            case "new": create(title: ask.argument.isEmpty ? "Basket" : ask.argument)
            case "add":
                guard let path = ask.path else { continue }
                add(
                    path: path,
                    lines: ask.from.flatMap { from in ask.to.map { from ... max($0, from) } },
                    now: ask.lines,
                    note: ask.argument.isEmpty ? nil : ask.argument
                )
            case "send": send(question: ask.argument)
            case "investigate": investigate(ask.argument)
            case "skill": walker.installSkill("sill-investigate")
            case "open":
                if let found = list().first(where: {
                    ($0.path as NSString).lastPathComponent.hasPrefix(ask.argument) || $0.basket.title == ask.argument
                }) {
                    open(found.path)
                } else {
                    Nvim.lua(channel, "vim.notify(...)", [.string("No basket \(ask.argument)"), .int(3)])
                }
            default: pick()
            }
        }
    }

    /// The baskets to choose from, in nvim's picker.
    func pick() {
        let baskets = list()
        guard !baskets.isEmpty else {
            return Nvim.lua(channel, "vim.notify(...)", [
                .string("No baskets yet: :SillBasket new <title>, or :SillBasket add on some code"), .int(2),
            ])
        }
        Nvim.lua(channel, "require'sill'.pick_basket(...)", [.array(baskets.map { entry in
            let status = entry.basket.status ?? "open"
            let by = entry.basket.by.map { " · by \($0)" } ?? ""
            return .array([
                .string((entry.path as NSString).lastPathComponent),
                .string("\(entry.basket.title)  [\(status)\(by)]"),
            ])
        })])
    }

    // MARK: Changing a basket

    /// A new basket, current and open.
    @discardableResult
    func create(title: String, question: String? = nil, by: String = "you", show: Bool = true) -> String {
        var path = folder + "/" + BasketFile.fileName(for: title)
        var number = 2
        while FileManager.default.fileExists(atPath: path) {
            path = folder + "/" + BasketFile.fileName(for: title).replacingOccurrences(
                of: BasketFile.suffix, with: "-\(number)\(BasketFile.suffix)"
            )
            number += 1
        }
        let commit = Review.git(["rev-parse", "--short", "HEAD"], in: directory)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let source = BasketFile.new(
            title: title, question: question, by: by, worktree: walker.root,
            commit: commit?.isEmpty == false ? commit : nil
        )
        try? source.write(toFile: path, atomically: true, encoding: .utf8)
        current = path
        if show { open(path) }
        return path
    }

    /// Shows a basket; picked by the person (not shown by sill after a change) it becomes the current one.
    func open(_ path: String, current makeCurrent: Bool = true) {
        if makeCurrent { current = path }
        walker.open(path)
    }

    /// Edits basket `path` (the current one when nil) and shows it again.
    private func edit(_ path: String?, _ change: (String) -> String) {
        guard let path = path ?? current,
              let source = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        try? change(source).write(toFile: path, atomically: true, encoding: .utf8)
        // What shows is read again; a basket not showing is not brought up (adding keeps you where you are).
        if walker.path == path { Task { await walker.read() } } else { walker.open(path, show: false) }
    }

    /// The anchor for a file's lines: from the repository's root, the whole file when no lines.
    private func anchor(_ path: String, _ lines: ClosedRange<Int>?) -> String {
        // From the worktree's root, whichever worktree of the repository the path is in.
        let relative = SillFolder.relative(path, in: directory)
        guard let lines else { return relative }
        return "\(relative):\(lines.lowerBound)-\(lines.upperBound)"
    }

    private static func lines(of path: String, _ range: ClosedRange<Int>) -> [String] {
        let all = (try? String(contentsOfFile: path, encoding: .utf8))?.components(separatedBy: "\n") ?? []
        guard range.lowerBound >= 1, range.lowerBound <= all.count else { return [] }
        return Array(all[(range.lowerBound - 1) ..< min(range.upperBound, all.count)])
    }

    /// Adds a file's lines (or the whole file) to the current basket, a new one when there is none. `now` is what the
    /// lines are in the editor, unsaved edits and all; else they are read from disk. Named baskets are an agent's:
    /// it is not announced.
    func add(
        path: String,
        lines: ClosedRange<Int>?,
        now: [String]? = nil,
        note: String? = nil,
        section: String? = nil,
        basket: String? = nil
    ) {
        let target = basket ?? current ?? create(
            title: "Collected " + Date().formatted(.dateTime.month(.abbreviated).day().hour().minute()),
            show: false
        )
        let print = lines.map { BasketFile.fingerprint(now ?? Self.lines(of: path, $0)) }
        let root = walker.root
        // A joined range's fingerprint: its lines on disk.
        let joined: (String, ClosedRange<Int>) -> String? = { relative, range in
            BasketFile.fingerprint(Self.lines(of: relative.hasPrefix("/") ? relative : root + "/" + relative, range))
        }
        let anchor = anchor(path, lines)
        edit(target) { source in
            BasketFile.adding(
                source, anchor: anchor, fingerprint: print, note: note, section: section, joined: joined
            )
        }
        guard basket == nil else { return }
        let title = (try? String(contentsOfFile: target, encoding: .utf8)).map { Walkthrough($0).title } ?? "the basket"
        Nvim.lua(channel, "vim.notify(...)", [.string("Added \(anchor) to \(title)"), .int(2)])
    }

    /// Adds a symbol (`Pricing.Total`), its fingerprint from where it is found now.
    func add(symbol: String, note: String? = nil, section: String? = nil, basket: String? = nil) async -> String? {
        let found = try? await channel.lua(
            "return require'sill.walk'.resolve({ { kind = 'symbol', name = ... } }, select(2, ...))[1]",
            args: [.string(symbol), .string(directory)]
        )
        guard let map = found?.dictionaryValue, let path = map[.string("path")]?.stringValue,
              let from = map[.string("from")]?.integerValue, let to = map[.string("to")]?.integerValue
        else { return "No symbol \(symbol) found" }
        let print = BasketFile.fingerprint(Self.lines(of: path, Int(from) ... Int(max(to, from))))
        guard let target = basket ?? current else { return "No basket to add to" }
        edit(target) { BasketFile.adding($0, anchor: symbol, fingerprint: print, note: note, section: section) }
        return nil
    }

    func remove(anchorAt line: Int) {
        edit(walker.path) { BasketFile.removing($0, anchorAt: line) }
    }

    func note(_ text: String, section: String? = nil, basket: String? = nil) {
        edit(basket) { BasketFile.noting($0, text, section: section) }
    }

    func conclude(_ text: String, basket: String) {
        edit(basket) { BasketFile.concluding($0, text) }
    }

    // MARK: Investigations

    /// Asks the agent to investigate `question` through sill: a basket it fills as it goes, then its findings. The
    /// skill's steps travel with the ask, so it works before the skill is installed.
    func investigate(_ question: String) {
        guard !question.isEmpty, let agents = app?.agents else { return }
        agents.send(headline: "Investigate: \(question)", """
        Investigate this through sill, following the sill-investigate skill if you have it: \(question)

        Work read-only: do not change code or configuration. Call sill's basket_create with a short title and the \
        question; it opens a basket I watch fill. Orient with code_map and trace_symbol; add every place that matters \
        with basket_add and a note on why (group them with section; add what you ruled out, briefly). Use sill's \
        debugger, profiler and telemetry tools when reading is not enough (they ask me first). Reproduce it in a \
        script when you can. Finish with basket_conclude: the answer first, why you are sure, what is still open, \
        and the next steps you suggest.
        """)
    }

    // MARK: Sending

    /// The basket as the agent reads it: the question, then each section's notes and its code as it is now, marked
    /// when it changed since it was added.
    func text(of path: String) async -> String? {
        if walker.path != path {
            walker.open(path)
        }
        await walker.read()
        guard let basket = walker.walk else { return nil }
        let root = walker.root
        var out: [String] = []
        for (s, step) in basket.steps.enumerated() {
            out += ["", "## \(step.title)"]
            for (b, block) in step.blocks.enumerated() {
                switch block {
                case let .prose(text): out.append(text)
                case let .code(_, line):
                    guard let place = walker.found[safe: s]?[b] else { continue }
                    guard let file = place.path else {
                        out.append("(not found: \(place.problem ?? "?"))")
                        continue
                    }
                    let relative = file.hasPrefix(root + "/") ? String(file.dropFirst(root.count + 1)) : file
                    out.append("\(relative):\(place.from)-\(place.to)" +
                        (walker.moved.contains(line) ? " (changed since it was added)" : ""))
                    out.append("```")
                    out += place.lines.prefix(120).enumerated().map { "\(place.from + $0.offset)\t\($0.element)" }
                    out.append("```")
                case let .trace(symbol, callers, _, _):
                    out
                        .append(walker
                            .traces[symbol + (callers ? " callers" : " callees")] ?? "(the calls of \(symbol))")
                case let .ask(question, answer, _):
                    out.append("Q: \(question)" + (answer.map { "\nA: \($0)" } ?? ""))
                case let .diff(file, _): out.append("(the change to \(file))")
                case let .example(file, _): out.append("(example \(file))")
                }
            }
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sends the basket open (else the current one) to the agent with a question; it is marked sent, and the next
    /// piece added starts a new basket.
    func send(question: String) {
        guard let path = walker.path ?? current, let agents = app?.agents else { return }
        Task {
            guard let body = await text(of: path) else { return }
            let asked = question.isEmpty ? (walker.walk?.question ?? "What do you make of these?") : question
            edit(path) { source in
                var source = BasketFile.setting(source, "status", to: "sent")
                if !question.isEmpty { source = BasketFile.setting(source, "question", to: question) }
                return source
            }
            if current == path { current = nil }
            let name = (path as NSString).lastPathComponent
            agents.send(headline: asked, """
            I collected this code in sill's basket \(name) (\(path)), to ask: \(asked)

            \(body)

            Answer from the code (read more of it as you need), then call sill's basket_conclude tool with basket \
            "\(name)" and your answer, so it is written into the basket as its findings.
            """)
        }
    }
}
