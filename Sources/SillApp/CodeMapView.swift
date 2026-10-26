import AppKit
import SillCore
import SillEditor

/// The code map pane: the agent's summary on top, then the projects in rows, each above what it references, joined
/// by lines. A card says what a project is, where it starts and which of its files change most; those open on a click.
final class CodeMapView: NSView, ToolContent {
    let mapper: CodeMapper
    /// The card selected, as an index into the map's projects.
    private(set) var selected: Int?
    private var scroll: CGFloat = 0
    private(set) var cards: [Int: NSRect] = [:]
    /// What a click opens: a file (from the root) and a line.
    private(set) var links: [(NSRect, String, Int)] = []

    init(mapper: CodeMapper) {
        self.mapper = mapper
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    private static let bar = PaneBar.height, line: CGFloat = 18, cardWidth: CGFloat = 260, gap: CGFloat = 16

    func changed() { needsDisplay = true }

    private func text(
        _ string: String, _ size: CGFloat = 12, _ color: NSColor = Design.text, weight: NSFont.Weight = .regular
    ) -> NSAttributedString {
        NSAttributedString(
            string: string,
            attributes: [.font: Design.ui(size, weight: weight), .foregroundColor: color]
        )
    }

    /// The agent's prose: `code spans` in the editor's font.
    static func prose(_ summary: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (index, part) in summary.components(separatedBy: "`").enumerated() {
            let code = index % 2 == 1
            out.append(NSAttributedString(string: part, attributes: [
                .font: code ? EditorFont.metrics.regular : Design.ui(13),
                .foregroundColor: code ? Design.accent : Design.text,
            ]))
        }
        return out
    }

    private func draw(_ string: NSAttributedString, in rect: NSRect) {
        string.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// A card's height: its name, what it is, its size, then a line per entry point and hot file.
    private static func height(_ project: CodeMap.Project) -> CGFloat {
        let lines = min(project.entryPoints.count, 2) + project.hot.count
        return 70 + CGFloat(lines) * line + (project.hot.isEmpty ? 0 : 6)
    }

    override func draw(_: NSRect) {
        Design.editor.setFill()
        bounds.fill()
        // The whole visible part each time (what a click opens is noted as it is drawn), and nothing below it.
        let shown = visibleRect
        cards = [:]
        links = []
        guard let map = mapper.map else {
            text(mapper.building ? "Reading the repository…" : "No map yet: :SillMap builds one", 13, Design.textMuted)
                .draw(at: NSPoint(x: 20, y: Self.bar + 20))
            drawBar(nil)
            return
        }
        var y = Self.bar + 16 - scroll
        if let summary = mapper.summary, !summary.isEmpty {
            let body = Self.prose(summary)
            let width = min(bounds.width - 40, 900)
            let size = body.boundingRect(
                with: NSSize(width: width - 32, height: 10000),
                options: .usesLineFragmentOrigin
            )
            let box = NSRect(x: 20, y: y, width: width, height: ceil(size.height) + 24)
            Design.chrome.setFill()
            NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
            body.draw(with: box.insetBy(dx: 16, dy: 12), options: .usesLineFragmentOrigin)
            y = box.maxY + 20
        }
        // The rows, a row wrapping when its cards do not fit.
        let perRow = max(Int((bounds.width - 40 + Self.gap) / (Self.cardWidth + Self.gap)), 1)
        var placed: [(Int, NSRect)] = []
        for row in map.layers {
            if map.projects[row[0]].kind == .test {
                y = drawTests(row, map, at: y)
                continue
            }
            for start in stride(from: 0, to: row.count, by: perRow) {
                let slice = row[start ..< min(start + perRow, row.count)]
                let height = slice.map { Self.height(map.projects[$0]) }.max() ?? 0
                for (offset, index) in slice.enumerated() {
                    let rect = NSRect(
                        x: 20 + CGFloat(offset) * (Self.cardWidth + Self.gap),
                        y: y,
                        width: Self.cardWidth,
                        height: height
                    )
                    placed.append((index, rect))
                }
                // Room for the lines between layers; a row that only wraps needs less.
                y += height + (start + perRow < row.count ? Self.gap : Self.gap * 2.5)
            }
        }
        for (index, rect) in placed {
            cards[index] = rect
        }
        // Only what shows: a large solution's cards and lines run far below the pane.
        drawEdges(map, in: shown)
        for (index, rect) in placed where rect.intersects(shown) {
            drawCard(map.projects[index], index, in: rect)
        }
        drawBar(map)
    }

    /// The tests, last and small: a chip each, its name and size, opening its project file.
    private func drawTests(_ row: [Int], _ map: CodeMap, at top: CGFloat) -> CGFloat {
        text("TESTS", 10, Design.textFaint, weight: .semibold).draw(at: NSPoint(x: 20, y: top))
        var x: CGFloat = 20, y = top + 18
        for index in row {
            let project = map.projects[index]
            let label = NSMutableAttributedString(attributedString: text(project.name, 11))
            label.append(text("  " + CodeMap.count(project.files, "file"), 11, Design.textMuted))
            let width = min(label.size().width + 20, bounds.width - 40)
            if x + width > bounds.width - 20, x > 20 {
                x = 20
                y += 30
            }
            let chip = NSRect(x: x, y: y, width: width, height: 24)
            Design.chrome.setFill()
            NSBezierPath(roundedRect: chip, xRadius: 6, yRadius: 6).fill()
            if selected == index {
                Design.accent.setStroke()
                NSBezierPath(roundedRect: chip, xRadius: 6, yRadius: 6).stroke()
            }
            draw(label, in: chip.insetBy(dx: 10, dy: 4))
            cards[index] = chip
            links.append((chip, project.file, 1))
            x += width + 8
        }
        return y + 40
    }

    private func drawBar(_ map: CodeMap?) {
        let files = map.map { $0.projects.reduce($0.otherFiles) { $0 + $1.files } } ?? 0
        let detail = map.map { "\($0.name) · \($0.projects.count) projects · \(files) files" } ?? ""
        PaneBar.draw(title: "Code map", detail: detail + (mapper.building ? " · reading…" : ""), in: bounds)
        PaneBar.drawKeys("j/k projects · ↵ open · s summary · w walkthrough · r read again", in: bounds)
    }

    /// A line from each project down to each it references: the selected one's in the accent.
    private func drawEdges(_ map: CodeMap, in dirty: NSRect) {
        let byName = Dictionary(map.projects.enumerated().map { ($1.name, $0) }) { first, _ in first }
        for (index, project) in map.projects.enumerated() {
            guard let from = cards[index] else { continue }
            for reference in project.references {
                guard let target = byName[reference], let to = cards[target], from.union(to).intersects(dirty) else {
                    continue
                }
                let lit = selected == index || selected == target
                // Tests reference nearly everything: their lines only for the selected.
                if project.kind == .test, !lit { continue }
                let path = NSBezierPath()
                // Down to what it builds on; a test, below, reaches up.
                let up = to.maxY <= from.minY
                let start = NSPoint(x: from.midX, y: up ? from.minY : from.maxY)
                let end = NSPoint(x: to.midX, y: up ? to.maxY : to.minY)
                path.move(to: start)
                let bend = max(abs(end.y - start.y) / 2, 20) * (up ? -1 : 1)
                path.curve(
                    to: end,
                    controlPoint1: NSPoint(x: start.x, y: start.y + bend),
                    controlPoint2: NSPoint(x: end.x, y: end.y - bend)
                )
                (lit ? Design.accent : Design.textFaint.withAlphaComponent(0.5)).setStroke()
                path.lineWidth = lit ? 2 : 1
                path.stroke()
            }
        }
    }

    private func drawCard(_ project: CodeMap.Project, _ index: Int, in rect: NSRect) {
        let card = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        Design.chrome.setFill()
        card.fill()
        if selected == index {
            Design.accent.setStroke()
            card.lineWidth = 2
            card.stroke()
        }
        let left = rect.minX + 14, width = rect.width - 28
        draw(
            text(project.name, 13, weight: .semibold),
            in: NSRect(x: left, y: rect.minY + 12, width: width, height: 18)
        )
        links.append((NSRect(x: rect.minX, y: rect.minY + 8, width: rect.width, height: 22), project.file, 1))
        let kindColor: NSColor = switch project.kind {
        case .app, .web: Design.accent
        case .test: Design.modified
        case .library: Design.textMuted
        }
        let kind = text(project.kind.rawValue.uppercased(), 10, kindColor, weight: .semibold)
        kind.draw(at: NSPoint(x: left, y: rect.minY + 33))
        text(
            "\(project.language) · " + CodeMap.count(project.files, "file") + " · " +
                CodeMap.count(project.lines, "line"),
            11,
            Design.textMuted
        ).draw(at: NSPoint(x: left + kind.size().width + 8, y: rect.minY + 32))
        var y = rect.minY + 56
        for place in project.entryPoints.prefix(2) {
            let name = (place.path as NSString).lastPathComponent
            draw(text("▸ \(name):\(place.line)  \(place.label)", 11, Design.text), in: NSRect(
                x: left,
                y: y,
                width: width,
                height: Self.line
            ))
            links.append((NSRect(x: rect.minX, y: y - 2, width: rect.width, height: Self.line), place.path, place.line))
            y += Self.line
        }
        if !project.hot.isEmpty { y += 6 }
        for hot in project.hot {
            let name = (hot.path as NSString).lastPathComponent
            draw(text("● \(name)  " + CodeMap.count(hot.changes, "change"), 11, Design.hot), in: NSRect(
                x: left,
                y: y,
                width: width,
                height: Self.line
            ))
            links.append((NSRect(x: rect.minX, y: y - 2, width: rect.width, height: Self.line), hot.path, 1))
            y += Self.line
        }
    }

    // MARK: Input

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let (_, path, line) = links.first(where: { $0.0.contains(point) }) {
            selected = cards.first { $0.value.contains(point) }?.key
            needsDisplay = true
            return mapper.open(path, line: line)
        }
        selected = cards.first { $0.value.contains(point) }?.key
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        scroll = max(scroll - event.scrollingDeltaY, 0)
        needsDisplay = true
    }

    /// The projects in the order drawn: row by row.
    private var order: [Int] { mapper.map?.layers.flatMap(\.self) ?? [] }

    func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { return false }
        let order = order
        switch event.characters ?? "" {
        case "j":
            selected = order.first.map { first in
                selected.flatMap { order.firstIndex(of: $0) }.map { order[min($0 + 1, order.count - 1)] } ?? first
            }
        case "k":
            selected = selected.flatMap { order.firstIndex(of: $0) }.map { order[max($0 - 1, 0)] }
        case "\r":
            guard let selected, let project = mapper.map?.projects[safe: selected] else { return false }
            if let place = project.entryPoints.first {
                mapper.open(place.path, line: place.line)
            } else {
                mapper.open(project.file)
            }
        case "s": mapper.askForSummary()
        case "w": mapper.askForTour()
        case "r": mapper.rebuild()
        default: return false
        }
        needsDisplay = true
        return true
    }
}
