import AppKit
import MessagePack
import SillCore
import SillEditor
import SillInput
import TrimModes
import TrimRun
import TrimTree
import TrimWalk

/// The walkthrough open in the pane: its own nvim, the text as that nvim has it, and what the editor beside it was last
/// told
/// to show.
@MainActor
final class WalkState {
    let session: WalkSession
    let path: String
    var lines: [String] = []
    var doc = WalkDoc()
    var cursorLine = 1
    var renderTask: Task<Void, Never>?
    var eventTask: Task<Void, Never>?
    var lastJump: WalkJump?
    var highlighted: [String: NSAttributedString] = [:]
    var watcher: FileEvents?
    /// Parsed again from `lines`: the walkthrough as of the last render.
    var parsed: Walkthrough?

    init(session: WalkSession, path: String) {
        self.session = session
        self.path = path
    }
}

extension TrimWindowController {
    // MARK: Opening

    /// The walkthrough pane, made when first wanted.
    func ensureWalkPane() -> WalkPaneView {
        if let pane = walkPane { return pane }
        let pane = WalkPaneView(look: tree.look)
        pane.onFocus = { [weak self] in self?.walkFocused() }
        pane.onClose = { [weak self] in self?.hideWalkPane() }
        pane.document.onKey = { [weak self] event in self?.walkKey(event) }
        pane.document.onClick = { [weak self] line in
            guard let session = self?.walk?.session else { return }
            Task { await session.moveCursor(to: line) }
        }
        pane.document.onToggle = { [weak self] line in self?.walkAct("toggle", line: line) }
        pane.document.onRun = { [weak self] line in self?.walkAct("run", line: line) }
        pane.document.onActive = { [weak self] _ in self?.followWalk() }
        pane.isHidden = true
        view.walkView = pane
        walkPane = pane
        return pane
    }

    /// The pane gives the slot to the build or Run pane.
    func hideWalkForSlot() {
        guard let pane = walkPane, !pane.isHidden else { return }
        pane.isHidden = true
        if modes.surface == .walk { walkGone() }
        view.needsLayout = true
    }

    /// View ▸ Walkthroughs…, `<leader>W`, `:TrimWalk`: the repository's walkthroughs to choose from.
    @objc func showWalkthroughs(_: Any?) {
        let root = workspace
        Task { [weak self] in
            let found = await Task.detached { WalkFiles.find(in: root) }.value
            guard let self, listPicker == nil else { return }
            let items = found.map { walk in
                PickerItem(
                    id: walk.path, title: walk.title.isEmpty ? walk.relative : walk.title,
                    detail: (walk.by.map { "by " + $0 + " · " } ?? "") +
                        (walk.isPrivate ? "private" : "in the repository"),
                    subtitle: walk.relative
                )
            }
            showList(
                title: "Walkthroughs", items: items, current: items.first?.id,
                onChoose: { [weak self] item in self?.openWalkthrough(item.id) }
            )
        }
    }

    /// Shows a walkthrough in the pane, the keyboard in it.
    func openWalkthrough(_ path: String) {
        guard view != nil, FileManager.default.fileExists(atPath: path) else { return }
        if let known = walk, known.path == path, walkPane?.isHidden == false { return focus(.walk) }
        let pane = ensureWalkPane()
        // The build and Run panes step aside; the walkthrough is in their slot.
        runPane?.isHidden = true
        runListPane?.isHidden = true
        if modes.surface == .terminal { terminalGone() }
        if modes.surface == .run { runGone() }
        pane.isHidden = false
        view.needsLayout = true
        let old = walk
        let session = WalkSession()
        let state = WalkState(session: session, path: path)
        walk = state
        Task { [weak self] in
            await old?.session.stop()
            old?.eventTask?.cancel()
            do { try await session.start(file: path, runtime: TrimRuntime.directory) } catch {
                self?.walkFailed("the walkthrough's nvim did not start: \(error)")
                return
            }
            guard let self, walk === state else { return }
            state.eventTask = Task { [weak self] in
                for await event in session.events {
                    await self?.walkEvent(event, from: state)
                }
            }
            // An agent still writing the file: read it again as it changes.
            let events = FileEvents(root: (path as NSString).deletingLastPathComponent, raw: true)
            events.onChange = { [weak self] changed in
                guard changed.contains(where: { RealPath.of($0) == RealPath.of(path) }) else { return }
                Task { await self?.walkFileChanged(state) }
            }
            events.start()
            state.watcher = events
            focus(.walk)
        }
    }

    private func walkFailed(_ message: String) {
        hideWalkPane()
        setBuild(result: message, failed: true)
    }

    func hideWalkPane() {
        guard let pane = walkPane, !pane.isHidden else { return }
        let wasFocused = modes.surface == .walk
        pane.isHidden = true
        view.needsLayout = true
        walkGone()
        Task { _ = try? await session.channel.lua("require('trim.walk').clear()") }
        if wasFocused { focusEditor() }
    }

    private func walkFileChanged(_ state: WalkState) async {
        guard walk === state else { return }
        await state.session.reload()
    }

    // MARK: Events from the document's nvim

    private func walkEvent(_ event: WalkSession.Event, from state: WalkState) async {
        guard walk === state else { return }
        switch event {
        case let .cursor(line, _, mode):
            state.cursorLine = line
            setWalkMode(mode)
            walkPane?.setCursor(line: line)
        case let .text(lines):
            state.lines = lines
            renderWalk(state)
        case .saved:
            break
        case let .action(name, line):
            walkAct(name, line: line)
        }
    }

    /// A key typed in the pane, which is nvim's, Escape excepted (it leaves in normal mode).
    private func walkKey(_ event: NSEvent) {
        guard let state = walk else { return }
        if event.keyCode == 53 {
            if walkEscape() == .pass { state.session.send(keys: "<Esc>") }
            return
        }
        if let keys = KeyNotation.keys(for: event) { state.session.send(keys: keys) }
    }

    /// What Trim's keys in the document do (`<CR>`, `x`, `gr`, `gs`, `q`...), and the pane's buttons.
    func walkAct(_ name: String, line: Int) {
        guard let state = walk else { return }
        switch name {
        case "jump":
            if let jump = walkJump(at: line, in: state) {
                show(jump)
                focusEditor()
            }
        case "toggle":
            guard let item = state.doc.items.first(where: { $0.span.lowerBound == line }),
                  case .task = item.kind else { return }
            let toggled = Walkthrough.toggling(state.lines.joined(separator: "\n"), taskAt: line)
                .components(separatedBy: "\n")
            Task { await state.session.replace(lines: toggled) }
        case "run":
            guard let item = state.doc.items.first(where: { $0.span.contains(line) }),
                  case let .run(name, command) = item.kind else { return }
            let entry = RunEntry(
                title: name, source: "walkthrough", kind: .task, command: command, directory: workspace,
                origin: (state.path as NSString).lastPathComponent
            )
            runInRunPane(entry)
        case "source":
            open(file: state.path, toEditor: true, line: line)
        case "close":
            hideWalkPane()
        default:
            // Asking and the slides are not here yet.
            setBuild(result: "\(name) is not in this version of walkthroughs yet", failed: false)
        }
    }

    // MARK: The editor follows the step

    private func walkJump(at line: Int, in state: WalkState) -> WalkJump? {
        guard let index = state.doc.items.lastIndex(where: { $0.span.lowerBound <= line }) else { return nil }
        let item = state.doc.items[index]
        if let jump = item.jump { return jump }
        return state.doc.items.first { $0.step == item.step && $0.jump != nil }?.jump
    }

    private func show(_ jump: WalkJump) {
        Task { [weak self] in
            guard let self else { return }
            _ = try? await session.channel.lua(
                "return require('trim.walk').show(...)", args: [
                    .string(jump.path),
                    .int(Int64(jump.from)),
                    .int(Int64(jump.to)),
                ]
            )
        }
    }

    /// The active item changed: the editor shows its code (or its step's first), without taking the keyboard.
    func followWalk() {
        guard let state = walk, let jump = walkJump(at: state.cursorLine, in: state),
              jump != state.lastJump else { return }
        state.lastJump = jump
        show(jump)
    }

    // MARK: Drawing the document

    private func renderWalk(_ state: WalkState) {
        state.renderTask?.cancel()
        let text = state.lines.joined(separator: "\n")
        let path = state.path, root = workspace
        state.renderTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let parsed = Walkthrough(text)
            let folder = (path as NSString).deletingLastPathComponent
            let resolved = await Task.detached { Self.resolveAnchors(parsed, root: root, folder: folder) }.value
            guard !Task.isCancelled, let self, walk === state else { return }
            let doc = await buildWalkDoc(parsed, resolved: resolved, root: root, state: state)
            guard !Task.isCancelled, walk === state else { return }
            state.parsed = parsed
            state.doc = doc
            walkPane?.show(doc)
            walkPane?.setCursor(line: state.cursorLine)
            followWalk()
        }
    }

    nonisolated static func resolveAnchors(
        _ walk: Walkthrough,
        root: String,
        folder: String
    ) -> [Int: AnchorResolver.Result] {
        let resolver = AnchorResolver(root: root, folder: folder)
        var found: [Int: AnchorResolver.Result] = [:]
        for step in walk.steps {
            for block in step.blocks {
                switch block {
                case let .code(anchor, line), let .link(_, anchor, line): found[line] = resolver.resolve(anchor)
                default: break
                }
            }
        }
        return found
    }

    /// Code as the highlighted text the pane draws, in the editor's colour scheme (its own nvim does the colouring).
    private func highlighted(_ text: String, path: String, state: WalkState) async -> NSAttributedString {
        let key = path + "\u{0}" + String(text.hashValue)
        if let known = state.highlighted[key] { return known }
        let json = await (try? session.channel.lua(
            "return require('trim.walk').code(...)",
            args: [.string(path), .string(text)]
        ))?.stringValue
        let look = tree.look
        let styled = DocContent.attributed(
            json ?? text, regular: EditorFont.font(12), text: look.text, code: look.text, faint: look.muted,
            rule: look.muted
        )
        state.highlighted[key] = styled
        return styled
    }

    private func buildWalkDoc(
        _ walk: Walkthrough,
        resolved: [Int: AnchorResolver.Result],
        root: String,
        state: WalkState
    ) async -> WalkDoc {
        let look = tree.look
        let style = WalkMarkdown.Style(look: look)
        var doc = WalkDoc(title: walk.title)
        var meta: [String] = []
        if let by = walk.by { meta.append("by " + by) }
        if let model = walk.model { meta.append(model) }
        if let commit = walk.commit { meta.append("at " + commit) }
        if let created = walk.created { meta.append(created) }
        meta.append("\(walk.steps.count) steps")
        let good = NSColor(red: 0.18, green: 0.9, blue: 0.77, alpha: 1), warn = NSColor(
            red: 1,
            green: 0.69,
            blue: 0.24,
            alpha: 1
        )
        let bad = NSColor(red: 1, green: 0.4, blue: 0.4, alpha: 1)
        if !walk.intro.isEmpty { doc.intro = WalkMarkdown.attributed(walk.intro, style: style) }
        var stale = 0
        for (number, step) in walk.steps.enumerated() {
            let end = (number + 1 < walk.steps.count ? walk.steps[number + 1].line - 1 : state.lines.count)
            doc.items.append(WalkItem(
                kind: .step(number: number + 1, title: step.title),
                span: step.line ... step.line,
                jump: nil,
                step: number
            ))
            var cursor = step.line + 1
            for (index, block) in step.blocks.enumerated() {
                func start(_ block: Walkthrough.Block) -> Int? {
                    switch block {
                    case let .code(_, line), let .link(_, _, line), let .diff(_, line), let .example(_, line),
                         let .trace(
                             _,
                             _,
                             _,
                             line
                         ),
                         let .run(_, _, line), let .fence(_, _, line), let .task(_, _, line), let .ask(_, _, line): line
                    case .prose: nil
                    }
                }
                func finish(_ block: Walkthrough.Block, _ line: Int) -> Int {
                    switch block {
                    case let .ask(_, answer, _): line + (answer?.components(separatedBy: "\n").count ?? 0)
                    case let .fence(_, text, _): line + (text.isEmpty ? 0 : text.components(separatedBy: "\n").count) +
                        1
                    default: line
                    }
                }
                let begin = start(block) ?? cursor
                var last = start(block).map { finish(block, $0) } ?? begin
                if case .prose = block {
                    let next = step.blocks.dropFirst(index + 1).lazy.compactMap { start($0) }.first
                    last = max(begin, (next ?? (end + 1)) - 1)
                }
                cursor = last + 1
                let span = begin ... max(begin, last)
                switch block {
                case let .prose(text):
                    doc.items.append(WalkItem(
                        kind: .prose(WalkMarkdown.attributed(text, style: style)),
                        span: span,
                        jump: nil,
                        step: number
                    ))
                case let .code(anchor, line):
                    var jump: WalkJump?
                    var card = WalkCard(heading: anchor.text, badge: nil, body: NSAttributedString(string: ""))
                    switch resolved[line] {
                    case let .found(found):
                        jump = WalkJump(path: found.path, from: found.lines.lowerBound, to: found.lines.upperBound)
                        card.heading = anchor
                            .text + "   " +
                            (found.path.hasPrefix(root + "/") ? String(found.path.dropFirst(root.count + 1)) : found
                                .path)
                            + ":\(found.lines.lowerBound)-\(found.lines.upperBound)"
                        card.body = await highlighted(
                            found.text.joined(separator: "\n"),
                            path: found.path,
                            state: state
                        )
                        switch Freshness.of(recorded: walk.fingerprints[line], now: found) {
                        case .fresh: card.badge = ("as written", good)
                        case .changed: card.badge = ("changed since written", warn); stale += 1
                        case .unchecked, .orphaned: break
                        }
                    case let .problem(message):
                        card.badge = ("not found", bad)
                        card.body = NSAttributedString(
                            string: message,
                            attributes: [.font: EditorFont.font(12), .foregroundColor: bad]
                        )
                        stale += 1
                    case nil: break
                    }
                    doc.items.append(WalkItem(kind: .card(card), span: span, jump: jump, step: number))
                case let .fence(language, text, _):
                    let label = language.isEmpty ? "text" : language
                    let body: NSAttributedString = language == "mermaid"
                        ? NSAttributedString(
                            string: text,
                            attributes: [.font: EditorFont.font(12), .foregroundColor: look.muted]
                        )
                        : await highlighted(text, path: "x." + (language == "swift" ? "swift" : language), state: state)
                    let heading = language == "mermaid" ? "diagram (mermaid)" : label
                    doc.items.append(WalkItem(
                        kind: .card(WalkCard(heading: heading, badge: nil, body: body)),
                        span: span,
                        jump: nil,
                        step: number
                    ))
                case let .task(text, done, _):
                    doc.items.append(WalkItem(kind: .task(text: text, done: done), span: span, jump: nil, step: number))
                case let .ask(question, answer, _):
                    doc.items.append(WalkItem(
                        kind: .ask(question: question, answer: answer),
                        span: span,
                        jump: nil,
                        step: number
                    ))
                case let .run(name, command, _):
                    doc.items.append(WalkItem(
                        kind: .run(name: name, command: command),
                        span: span,
                        jump: nil,
                        step: number
                    ))
                case let .diff(path, _):
                    let text = WalkGit.diff(path, base: walk.base, in: root) ?? "no change in \(path)"
                    let body = diffText(text)
                    doc.items.append(WalkItem(
                        kind: .card(WalkCard(heading: "diff  " + path, badge: nil, body: body)),
                        span: span,
                        jump: nil,
                        step: number
                    ))
                case .link:
                    break
                case let .example(path, _):
                    doc.items.append(WalkItem(
                        kind: .card(WalkCard(heading: "example", badge: nil, body: plainText(path))),
                        span: span,
                        jump: nil,
                        step: number
                    ))
                case let .trace(symbol, callers, depth, _):
                    let text = "\(callers ? "callers" : "callees") of \(symbol), \(depth) deep"
                    doc.items.append(WalkItem(
                        kind: .card(WalkCard(heading: "trace", badge: nil, body: plainText(text))),
                        span: span,
                        jump: nil,
                        step: number
                    ))
                }
            }
        }
        if stale > 0 { meta.append("\(stale) need a look") }
        doc.meta = meta.joined(separator: "  ·  ")
        doc.stale = stale
        return doc
    }

    private func plainText(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: EditorFont.font(12), .foregroundColor: tree.look.muted])
    }

    /// A unified diff in colour: added lines green, removed red, the rest quiet.
    private func diffText(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = EditorFont.font(12)
        for line in text.components(separatedBy: "\n")
            where !line.hasPrefix("diff --git") && !line.hasPrefix("index ")
        {
            let colour: NSColor = line.hasPrefix("+") && !line.hasPrefix("+++") ? NSColor(
                red: 0.45,
                green: 0.85,
                blue: 0.5,
                alpha: 1
            )
                : line.hasPrefix("-") && !line.hasPrefix("---") ? NSColor(red: 1, green: 0.5, blue: 0.5, alpha: 1)
                : line.hasPrefix("@@") ? NSColor(red: 0.56, green: 0.48, blue: 1, alpha: 1) : tree.look.muted
            result.append(NSAttributedString(string: line + "\n", attributes: [.font: font, .foregroundColor: colour]))
        }
        return result
    }
}
