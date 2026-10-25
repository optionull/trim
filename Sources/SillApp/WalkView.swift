import AppKit
import SillCore
import SillEditor

/// A walkthrough as a notebook: one document that scrolls, its sections in an outline beside it (the one in view
/// marked; a click goes there). Each section's prose, the code its anchors point at now, a review's diffs, and its
/// examples, each with Run and what it wrote under it; questions with their answers, or Ask the agent.
///
/// A basket shows the same way, with its question and where it stands on top, a Remove on each piece, and a second
/// left menu (Tab): the files its pieces are in, as a tree; a click goes to the file's first piece.
final class WalkView: NSView, ToolContent {
    let walker: Walker
    /// A basket's notebook rather than a walkthrough's.
    let basket: Bool
    enum Menu { case outline, files, context }
    private(set) var side: Menu = .outline
    /// For baskets: a piece's anchor removed (its line), the basket sent with a question.
    var onRemove: ((Int) -> Void)?
    var onSend: (() -> Void)?
    var onAskFindings: (() -> Void)?
    /// For baskets: what was collected about a piece (by its anchor): short facts for its heading, and the lines its
    /// details show; and across the basket, for the Context menu.
    var chips: ((String) -> [String])?
    var details: ((String) -> [String])?
    var overview: (() -> [(heading: String, rows: [String])])?
    /// The pieces whose details show (`i`), by anchor line.
    private(set) var expanded: Set<Int> = []
    /// Where each piece of code starts in the document, by its file, in order.
    private(set) var fileTops: [(path: String, top: CGFloat, moved: Bool)] = []
    private var fileFrames: [(String, NSRect)] = []
    private var outlineFrames: [(Int, NSRect)] = []
    private var actionFrames: [(String, String, NSRect)] = []
    /// Where each section starts in the document, as last laid out.
    private(set) var sectionTops: [CGFloat] = []
    private(set) var documentHeight: CGFloat = 0
    private(set) var scroll: CGFloat = 0

    init(walker: Walker, basket: Bool = false) {
        self.walker = walker
        self.basket = basket
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    private var outline: CGFloat { min(280, bounds.width * 0.24) }

    func changed() { needsDisplay = true }

    /// The section whose heading is nearest above the top of what shows.
    var currentSection: Int {
        let top = scroll + 40
        return max((sectionTops.lastIndex { $0 <= top }) ?? 0, 0)
    }

    /// Scrolls the document to a section, as the outline does.
    func show(section index: Int) {
        guard sectionTops.indices.contains(index) else { return }
        scroll = max(0, min(sectionTops[index] - 20, max(documentHeight - bounds.height, 0)))
        walker.go(to: index)
        needsDisplay = true
    }

    private func text(
        _ string: String,
        _ size: CGFloat = 14,
        _ color: NSColor = Design.text,
        weight: NSFont.Weight = .regular
    ) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: Self.font(size, weight), .foregroundColor: color])
    }

    /// The notebook is in the editor's monospaced font throughout: this size of it, bold from semibold up.
    static func font(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont(descriptor: EditorFont.metrics.regular.fontDescriptor, size: size) ??
            NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        return weight >= .semibold ? NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask) : base
    }

    private func mono(_ string: String, _ color: NSColor = Design.text) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: EditorFont.metrics.regular, .foregroundColor: color])
    }

    /// Prose with `code` spans in the grid's font.
    private func prose(_ string: String, _ color: NSColor = Design.text) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (index, part) in string.components(separatedBy: "`").enumerated() {
            out.append(index % 2 == 1 ? mono(part, Design.insert) : text(part, 14, color))
        }
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 5
        out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: out.length))
        return out
    }

    override func draw(_: NSRect) {
        Design.canvas.setFill()
        bounds.fill()
        outlineFrames = []
        actionFrames = []
        guard let walk = walker.walk else {
            let none = basket ? "No basket open: :SillBasket new <title>, or :SillBasket to pick one." :
                "No walkthrough open: :SillWalk picks one."
            text(
                walker.path == nil ? none : "Reading…",
                14,
                Design.textFaint
            ).draw(at: NSPoint(x: 24, y: 24))
            return
        }
        drawDocument(walk)
        switch side {
        case .files: drawFiles()
        case .context: drawContext()
        case .outline: drawOutline(walk)
        }
    }

    /// The menu's heading: OUTLINE alone for a walkthrough, OUTLINE · FILES (Tab) for a basket.
    private func drawMenuHeading() {
        let outlineLabel = text("OUTLINE", 11, side == .outline ? Design.text : Design.textMuted, weight: .semibold)
        outlineLabel.draw(at: NSPoint(x: 20, y: 20))
        guard basket else { return }
        let files = text("FILES", 11, side == .files ? Design.text : Design.textMuted, weight: .semibold)
        files.draw(at: NSPoint(x: 36 + outlineLabel.size().width, y: 20))
        let context = text("CONTEXT", 11, side == .context ? Design.text : Design.textMuted, weight: .semibold)
        let contextX = 52 + outlineLabel.size().width + files.size().width
        context.draw(at: NSPoint(x: contextX, y: 20))
        fileFrames.append(("menu:outline", NSRect(x: 12, y: 12, width: outlineLabel.size().width + 16, height: 28)))
        fileFrames.append(("menu:files", NSRect(
            x: 28 + outlineLabel.size().width, y: 12, width: files.size().width + 16, height: 28
        )))
        fileFrames.append((
            "menu:context",
            NSRect(x: contextX - 8, y: 12, width: context.size().width + 16, height: 28)
        ))
    }

    // MARK: The context

    /// Across the pieces: the projects they are in, the tests that reach them, who changed them last.
    private func drawContext() {
        Design.chrome.setFill()
        NSRect(x: 0, y: 0, width: outline, height: bounds.height).fill()
        fileFrames = []
        drawMenuHeading()
        var y: CGFloat = 46
        let sections = overview?() ?? []
        for section in sections where !section.rows.isEmpty {
            text(section.heading.uppercased(), 10, Design.textFaint, weight: .semibold).draw(at: NSPoint(
                x: 20,
                y: y + 4
            ))
            y += 22
            for row in section.rows {
                text(row, 12, Design.text).draw(
                    with: NSRect(x: 20, y: y + 3, width: outline - 34, height: 18),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
                )
                y += 22
            }
            y += 8
        }
        if sections.allSatisfy(\.rows.isEmpty) {
            text("Collecting…", 12, Design.textFaint).draw(at: NSPoint(x: 20, y: y + 4))
        }
        text("Tab outline · i a piece's context", 11, Design.textFaint).draw(
            with: NSRect(x: 20, y: bounds.height - 44, width: outline - 32, height: 36),
            options: [.usesLineFragmentOrigin]
        )
    }

    // MARK: The files

    /// The files the pieces are in, as a tree of their folders: how many pieces each, a mark when one changed.
    private func drawFiles() {
        let column = NSRect(x: 0, y: 0, width: outline, height: bounds.height)
        Design.chrome.setFill()
        column.fill()
        drawMenuHeading()
        var pieces: [String: (count: Int, moved: Bool)] = [:]
        for entry in fileTops {
            pieces[entry.path, default: (0, false)].count += 1
            pieces[entry.path]!.moved = pieces[entry.path]!.moved || entry.moved
        }
        var y: CGFloat = 46
        var shownFolders: [String] = []
        for path in pieces.keys.sorted() {
            let relative = relativePath(path)
            let parts = relative.split(separator: "/").map(String.init)
            // Each folder on the way, once, indented by its depth.
            for depth in 0 ..< max(parts.count - 1, 0) {
                let folder = parts[0 ... depth].joined(separator: "/")
                guard !shownFolders.contains(folder) else { continue }
                shownFolders.append(folder)
                text(parts[depth] + "/", 12, Design.textMuted).draw(at: NSPoint(x: 20 + CGFloat(depth) * 14, y: y + 6))
                y += 26
            }
            let depth = CGFloat(max(parts.count - 1, 0))
            let rect = NSRect(x: 0, y: y, width: outline, height: 26)
            let info = pieces[path]!
            let name = text(parts.last ?? relative, 13, Design.text)
            name.draw(
                with: NSRect(x: 20 + depth * 14, y: y + 5, width: outline - 70 - depth * 14, height: 18),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
            )
            let count = text(
                "\(info.count)" + (info.moved ? " ●" : ""),
                11,
                info.moved ? Design.modified : Design.textFaint
            )
            count.draw(at: NSPoint(x: outline - count.size().width - 14, y: y + 6))
            fileFrames.append((path, rect))
            y += 26
        }
        if pieces.isEmpty {
            text("No code in it yet.", 12, Design.textFaint).draw(at: NSPoint(x: 20, y: y + 4))
        }
        text("Tab context · ↵ open · x remove · s send", 11, Design.textFaint).draw(
            with: NSRect(x: 20, y: bounds.height - 44, width: outline - 32, height: 36),
            options: [.usesLineFragmentOrigin]
        )
    }

    private func relativePath(_ path: String) -> String {
        let root = walker.root
        return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
    }

    /// Scrolls the document to a file's first piece, as the files menu does.
    func show(file path: String) {
        guard let top = fileTops.first(where: { $0.path == path })?.top else { return }
        scroll = max(0, min(top - 20, max(documentHeight - bounds.height, 0)))
        walker.go(to: currentSection)
        needsDisplay = true
    }

    // MARK: The outline

    private func drawOutline(_ walk: Walkthrough) {
        let column = NSRect(x: 0, y: 0, width: outline, height: bounds.height)
        Design.chrome.setFill()
        column.fill()
        fileFrames = []
        drawMenuHeading()
        var y: CGFloat = 46
        let current = currentSection
        for (index, step) in walk.steps.enumerated() {
            let rect = NSRect(x: 0, y: y, width: outline, height: 30)
            if index == current {
                Design.selection.setFill()
                rect.fill()
                Design.accent.setFill()
                NSRect(x: 0, y: y, width: 3, height: 30).fill()
            }
            let stale = walker.found[safe: index]?.values.contains { $0.problem != nil } ?? false
            text("\(index + 1)", 12, stale ? Design.error : Design.textFaint).draw(at: NSPoint(x: 20, y: y + 8))
            text(step.title, 13, index == current ? Design.text : Design.textMuted).draw(
                with: NSRect(x: 42, y: y + 7, width: outline - 56, height: 18),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
            )
            outlineFrames.append((index, rect))
            y += 30
        }
        text(
            basket ? "Tab files · i context · j/k scroll · n/p sections · o open · x remove · s send" :
                "j/k scroll · n/p sections · o open · a ask · e run · r read again",
            11,
            Design.textFaint
        ).draw(
            with: NSRect(x: 20, y: bounds.height - 44, width: outline - 32, height: 36),
            options: [.usesLineFragmentOrigin]
        )
    }

    // MARK: The document

    private func drawDocument(_ walk: Walkthrough) {
        let left = outline + 40, width = min(bounds.width - outline - 80, 920)
        var y = 32 - scroll
        var tops: [CGFloat] = []
        var files: [(path: String, top: CGFloat, moved: Bool)] = []
        func write(_ string: NSAttributedString, gap: CGFloat = 14) {
            let height = ceil(string.boundingRect(
                with: NSSize(width: width, height: 100_000),
                options: [.usesLineFragmentOrigin]
            ).height)
            if y + height > 0, y < bounds.height {
                string.draw(
                    with: NSRect(x: left, y: y, width: width, height: height),
                    options: [.usesLineFragmentOrigin]
                )
            }
            y += height + gap
        }
        /// A cell, as a code pane shows code: a header strip (what it is, its facts, its actions on the right), the
        /// lines on the editor's ground with a gutter of line numbers when they have them, and a footer (details, an
        /// example's output) inside the same border.
        func box(
            _ heading: String,
            _ rows: [NSAttributedString],
            firstLine: Int? = nil,
            facts: [String] = [],
            actions: [(title: String, kind: String, key: String)] = [],
            footer: [NSAttributedString] = [],
            footerTint: NSColor = Design.chrome,
            border: NSColor = Design.border,
            rowTints: [NSColor?] = []
        ) {
            let lineHeight = EditorFont.metrics.height, header: CGFloat = 32
            let footerHeight = footer.isEmpty ? 0 : CGFloat(footer.count) * lineHeight + 16
            let frame = NSRect(
                x: left, y: y, width: width,
                height: header + (rows.isEmpty ? 0 : CGFloat(rows.count) * lineHeight + 16) + footerHeight
            )
            let gutter: CGFloat = firstLine.map { first in
                CGFloat(String(first + max(rows.count - 1, 0)).count) * EditorFont.metrics.width + 28
            } ?? 12
            let visible = frame.maxY > 0 && frame.minY < bounds.height
            // The actions, right to left in the header: placed now, drawn over the cell below.
            var x = frame.maxX - 14
            var labels: [(NSAttributedString, NSRect)] = []
            for action in actions.reversed() {
                let label = text(
                    action.title,
                    12,
                    action.kind == "remove" ? Design.textMuted : Design.accent,
                    weight: .semibold
                )
                let rect = NSRect(
                    x: x - label.size().width - 14,
                    y: frame.minY + 5,
                    width: label.size().width + 14,
                    height: 22
                )
                labels.append((label, rect))
                actionFrames.append((action.kind, action.key, rect))
                x = rect.minX - 6
            }
            if visible {
                let shape = NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8)
                NSGraphicsContext.saveGraphicsState()
                shape.addClip()
                Design.editor.setFill()
                frame.fill()
                Design.chrome.setFill()
                NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: header).fill()
                if !footer.isEmpty {
                    footerTint.setFill()
                    NSRect(x: frame.minX, y: frame.maxY - footerHeight, width: frame.width, height: footerHeight).fill()
                }
                border.setFill()
                NSRect(x: frame.minX, y: frame.minY + header - 1, width: frame.width, height: 1).fill()
                if !footer.isEmpty {
                    NSRect(x: frame.minX, y: frame.maxY - footerHeight, width: frame.width, height: 1).fill()
                }
                if firstLine != nil, !rows.isEmpty {
                    Design.border.setFill()
                    NSRect(
                        x: frame.minX + gutter - 10,
                        y: frame.minY + header,
                        width: 1,
                        height: frame.height - header - footerHeight
                    ).fill()
                }
                NSGraphicsContext.restoreGraphicsState()
                border.setStroke()
                shape.lineWidth = 1
                shape.stroke()
                // Room for the actions drawn above.
                let title = NSMutableAttributedString(attributedString: text(
                    heading,
                    12,
                    Design.text,
                    weight: .semibold
                ))
                if !facts
                    .isEmpty { title.append(text("    " + facts.joined(separator: "  ·  "), 11, Design.textMuted)) }
                title.draw(
                    with: NSRect(x: frame.minX + 14, y: frame.minY + 8, width: x - frame.minX - 20, height: 18),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
                )
                var lineY = frame.minY + header + 8
                // A diff's added and removed lines, across the row.
                NSGraphicsContext.saveGraphicsState()
                shape.addClip()
                for (offset, tint) in rowTints.enumerated() {
                    guard let tint else { continue }
                    tint.setFill()
                    NSRect(
                        x: frame.minX,
                        y: lineY + CGFloat(offset) * lineHeight,
                        width: frame.width,
                        height: lineHeight
                    ).fill()
                }
                NSGraphicsContext.restoreGraphicsState()
                for (offset, row) in rows.enumerated() {
                    if let first = firstLine {
                        let number = mono(String(first + offset), Design.textFaint)
                        number.draw(at: NSPoint(x: frame.minX + gutter - 18 - number.size().width, y: lineY))
                    }
                    row.draw(
                        with: NSRect(
                            x: frame.minX + gutter,
                            y: lineY,
                            width: frame.width - gutter - 12,
                            height: lineHeight
                        ),
                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
                    )
                    lineY += lineHeight
                }
                for (label, rect) in labels {
                    label.draw(at: NSPoint(x: rect.minX + 7, y: rect.minY + 3))
                }
                lineY = frame.maxY - footerHeight + 8
                for row in footer {
                    row.draw(
                        with: NSRect(x: frame.minX + 14, y: lineY, width: frame.width - 28, height: lineHeight),
                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
                    )
                    lineY += lineHeight
                }
            }
            y = frame.maxY + 18
        }

        write(text(walk.title, 26, weight: .semibold), gap: 8)
        if basket {
            let status = walk.status ?? "open"
            let line = NSMutableAttributedString(attributedString: text(
                status.uppercased(),
                11,
                status == "concluded" ? Design.accent : status == "sent" ? Design.modified :
                    status == "stopped" ? Design.warm : Design.textMuted,
                weight: .semibold
            ))
            line.append(text("  by \(walk.by ?? "you")", 12, Design.textFaint))
            write(line, gap: 10)
            if let question = walk.question { write(prose(question, Design.insert), gap: 20) }
        }
        if let base = walk.base { write(text("Changes since \(base.prefix(10))", 12, Design.textFaint), gap: 18) }
        if !walk.intro.isEmpty { write(prose(walk.intro), gap: 24) }
        for (index, step) in walk.steps.enumerated() {
            tops.append(y + scroll)
            write(text("\(index + 1). \(step.title)", 20, weight: .semibold), gap: 14)
            for (blockIndex, block) in step.blocks.enumerated() {
                switch block {
                case let .prose(string):
                    write(prose(string))
                case let .code(anchor, line):
                    let name = switch anchor {
                    case let .symbol(name, _): name
                    case let .file(name, _): name
                    }
                    let place = walker.found[safe: index]?[blockIndex]
                    if let place, let file = place.path {
                        let moved = walker.moved.contains(line)
                        files.append((file, y + scroll, moved))
                        let facts = (moved ? ["changed since it was added"] : []) +
                            (place.by == "text" ? ["found by its text"] : []) +
                            (basket ? (chips?(anchor.text) ?? []) : [])
                        let details = basket && expanded.contains(line) ? (details?(anchor.text) ?? []) : []
                        box(
                            "\(relativePath(file)):\(place.from)–\(place.to)",
                            place.lines.prefix(40).map { mono($0) },
                            firstLine: place.from,
                            facts: facts,
                            actions: (basket ? [("Remove", "remove", "\(line)")] : []) +
                                [("Open", "open", "\(index):\(blockIndex)")],
                            footer: basket && expanded.contains(line) ?
                                (details.isEmpty ? ["Collecting…"] : details)
                                .map { text($0, 12, Design.textMuted) } : [],
                            border: moved ? Design.modified.withAlphaComponent(0.7) : Design.border
                        )
                    } else {
                        write(text(
                            "⚠︎ \(name): \(place?.problem ?? (walker.resolving ? "finding it…" : "not found"))",
                            13,
                            walker.resolving ? Design.textFaint : Design.error
                        ))
                    }
                case let .diff(file, _):
                    guard let diff = walker.diffs[file], !diff.hunks.isEmpty else {
                        write(text("\(file): no change since the base", 13, Design.textFaint))
                        continue
                    }
                    var rows: [NSAttributedString] = [], tints: [NSColor?] = []
                    for hunk in diff.hunks {
                        rows.append(mono(hunk.header, Design.textFaint))
                        tints.append(Design.chrome)
                        for line in hunk.lines.prefix(60) {
                            rows.append(mono(
                                line,
                                line.hasPrefix("+") ? Design.accent :
                                    line.hasPrefix("-") ? Design.error : Design.textMuted
                            ))
                            tints.append(line.hasPrefix("+") ? Design.accent.withAlphaComponent(0.08) :
                                line.hasPrefix("-") ? Design.error.withAlphaComponent(0.08) : nil)
                        }
                    }
                    box(file, rows, facts: ["the change"], rowTints: tints)
                case let .example(file, _):
                    let path = examplePath(file)
                    let run = walker.runs[path]
                    let rows = (walker.examples[path] ?? "").components(separatedBy: "\n").prefix(60).map { mono($0) }
                    // Its output, when it has run, in the same cell.
                    var output: [NSAttributedString] = []
                    if let run, !run.running {
                        let status = run.status == 0 ? "ran in \(String(format: "%.1f", run.seconds)) s" :
                            "exited \(run.status) after \(String(format: "%.1f", run.seconds)) s"
                        output = [text(status, 11, run.status == 0 ? Design.accent : Design.error, weight: .semibold)] +
                            run.output.trimmingCharacters(in: .newlines).components(separatedBy: "\n").suffix(40).map {
                                mono($0, run.status == 0 ? Design.text : Design.error)
                            }
                    }
                    box(
                        file,
                        rows,
                        firstLine: 1,
                        facts: ["\(ScriptRunner.language(of: path)) example"],
                        actions: [(run?.running == true ? "Running…" : "Run", "run", path)],
                        footer: output,
                        footerTint: run?.status ?? 0 == 0 ? Design.accent.withAlphaComponent(0.06) :
                            Design.error.withAlphaComponent(0.08)
                    )
                case let .trace(symbol, callers, _, _):
                    let tree = walker.traces[symbol + (
                        callers ? " callers" : " callees"
                    )] ?? "Asking the language server…"
                    box(
                        symbol,
                        tree.components(separatedBy: "\n").dropFirst().prefix(60).map { mono($0) },
                        facts: [callers ? "who calls it" : "what it calls"]
                    )
                case let .ask(question, answer, line):
                    write(text(question, 15, Design.insert, weight: .semibold), gap: 6)
                    if let answer {
                        let top = y
                        write(prose(answer, Design.textMuted))
                        Design.border.setFill()
                        NSRect(x: left - 14, y: top, width: 3, height: max(y - top - 14, 0)).fill()
                    } else {
                        let ask = text("Ask the agent", 12, Design.onAccent, weight: .semibold)
                        let rect = NSRect(x: left, y: y, width: ask.size().width + 24, height: 26)
                        if rect.maxY > 0, rect.minY < bounds.height {
                            Design.accent.setFill()
                            NSBezierPath(roundedRect: rect, xRadius: 13, yRadius: 13).fill()
                            ask.draw(at: NSPoint(x: rect.minX + 12, y: rect.midY - ask.size().height / 2))
                        }
                        actionFrames.append(("ask", "\(index):\(line)", rect))
                        y = rect.maxY + 16
                    }
                }
            }
            y += 20
        }
        sectionTops = tops
        fileTops = files
        // Room past the end, so the last section can come to the top as the outline asks.
        documentHeight = y + scroll + max(bounds.height - 160, 40)
    }

    /// An example's path: beside the walkthrough unless it is absolute.
    func examplePath(_ file: String) -> String {
        file.hasPrefix("/") ? file : ((walker.path ?? "") as NSString).deletingLastPathComponent + "/" + file
    }

    // MARK: Input

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let (key, _) = fileFrames.first(where: { $0.1.contains(point) }) {
            switch key {
            case "menu:outline": side = .outline
            case "menu:files": side = .files
            case "menu:context": side = .context
            default: show(file: key)
            }
            needsDisplay = true
            return
        }
        if let (index, _) = outlineFrames.first(where: { $0.1.contains(point) }) { return show(section: index) }
        guard let (kind, key, _) = actionFrames.first(where: { $0.2.contains(point) }) else { return }
        perform(kind, key)
    }

    func perform(_ kind: String, _ key: String) {
        let parts = key.split(separator: ":").compactMap { Int($0) }
        switch kind {
        case "run": Task { await walker.run(example: key) }
        case "remove": if let line = Int(key) { onRemove?(line) }
        case "open":
            if parts.count == 2 {
                walker.go(to: parts[0])
                walker.openCode(block: parts[1])
            }
        case "ask":
            if parts.count == 2 {
                walker.go(to: parts[0])
                walker.ask(line: parts[1])
            }
        default: break
        }
    }

    override func scrollWheel(with event: NSEvent) {
        scroll = max(0, min(
            scroll - event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 10),
            max(documentHeight - bounds.height, 0)
        ))
        walker.go(to: currentSection)
        needsDisplay = true
    }

    /// Asks a question of its own about the section in view.
    private func askAboutSection() {
        let alert = NSAlert()
        alert.messageText = "Ask about this section"
        alert.informativeText = "The agent gets the section and its code; the answer is written into the walkthrough."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Ask")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty {
            walker.go(to: currentSection)
            walker.ask(line: nil, question: field.stringValue)
        }
    }

    /// The anchor line of the first piece of code showing.
    private func pieceInView() -> Int? {
        actionFrames.filter { $0.0 == "remove" && $0.2.minY >= 0 }.min { $0.2.minY < $1.2.minY }.flatMap { Int($0.1) }
    }

    func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { return false }
        let step = EditorFont.metrics.height * 3
        if basket {
            switch event.characters ?? "" {
            case "\t":
                side = switch side {
                case .outline: .files
                case .files: .context
                case .context: .outline
                }
                needsDisplay = true
                return true
            case "i":
                // The details of the first piece in view.
                if let line = pieceInView() {
                    if expanded.contains(line) { expanded.remove(line) } else { expanded.insert(line) }
                }
                needsDisplay = true
                return true
            case "s":
                onSend?()
                return true
            case "f":
                onAskFindings?()
                return true
            case "x":
                // The first piece in view.
                if let line = pieceInView() { onRemove?(line) }
                return true
            case "a", "e": return false
            default: break
            }
        }
        switch event.characters ?? "" {
        case "j", String(UnicodeScalar(NSDownArrowFunctionKey)!):
            scroll = min(scroll + step, max(documentHeight - bounds.height, 0))
        case "k", String(UnicodeScalar(NSUpArrowFunctionKey)!): scroll = max(scroll - step, 0)
        case "n": show(section: currentSection + 1)
        case "p": show(section: max(currentSection - 1, 0))
        case "o", "\r":
            walker.go(to: currentSection)
            walker.openCode()
        case "a": askAboutSection()
        case "e":
            // The examples of the section in view.
            for case let .example(file, _) in walker.walk?.steps[safe: currentSection]?.blocks ?? [] {
                let path = examplePath(file)
                Task { await walker.run(example: path) }
            }
        case "r": Task { await walker.read() }
        default: return false
        }
        needsDisplay = true
        return true
    }
}
