import AppKit
import FrameModes
import FrameTree
import SillEditor

/// What the bar says, as one value: it draws again when this changes.
struct StatusState: Equatable {
    /// The mode as a word: nvim's, or Frame's own while the keyboard is in the tree or the switcher.
    var mode = "NORMAL"
    /// The branch, empty while the sidebar shows it.
    var branch = ""
    /// With the bar across the window the workspace is its first segment (the chip, which is its own island otherwise).
    var workspace = ""
    var workspaceIsWorktree = false
    var showsWorkspace = false
    /// The file as it is shown (relative to the workspace), and its name for the icon.
    var path = ""
    var name = ""
    var modified = false
    var readonly = false
    var recording = ""
    var errors = 0, warnings = 0, infos = 0, hints = 0
    var lsp: [String] = []
    var filetype = ""
    var line = 0, col = 0, lines = 0, top = 0, bottom = 0

    /// Where the window is in the buffer: Top, Bot, All or a percentage.
    var scroll: String { StatusLine.percent(line: line, lines: lines, firstVisible: top, lastVisible: bottom) }
}

/// The bar under the grid: the mode, the branch, the file and its state on the left; the diagnostics, language
/// servers, file type and position on the right. Drawn natively in the editor's font and the sidebar's colours.
final class StatusBarView: NSView {
    var look = TreeLook() {
        didSet { needsDisplay = true }
    }

    var state = StatusState() {
        didSet { if state != oldValue { needsDisplay = true } }
    }

    /// A click on the workspace segment: the switcher.
    var onWorkspaceClick: (() -> Void)?
    private var workspaceRect = NSRect.zero {
        didSet { if workspaceRect != oldValue { window?.invalidateCursorRects(for: self) } }
    }

    private(set) var hoveringWorkspace = false

    /// Where the pointer is a hand: the workspace segment, when it is there.
    func pointerRects() -> [NSRect] { state.showsWorkspace && !workspaceRect.isEmpty ? [workspaceRect] : [] }

    override func resetCursorRects() {
        pointerRects().forEach { addCursorRect($0, cursor: .pointingHand) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        setHoveringWorkspace(state.showsWorkspace && workspaceRect.contains(convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with _: NSEvent) { setHoveringWorkspace(false) }

    func setHoveringWorkspace(_ hovering: Bool) {
        guard hovering != hoveringWorkspace else { return }
        hoveringWorkspace = hovering
        needsDisplay = true
    }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if state.showsWorkspace, workspaceRect.contains(convert(event.locationInWindow, from: nil)) {
            onWorkspaceClick?()
        }
    }

    /// A line of the grid, with room above and below.
    static func height(for look: TreeLook) -> CGFloat { look.rowHeight + 12 }

    /// The mode's colour: nvim's modes as is usual, and Frame's own modes each a colour of their own.
    static func color(forMode mode: String) -> NSColor {
        let rgb = switch mode {
        case "INSERT": 0x98C379
        case "VISUAL", "SELECT": 0xC678DD
        case "REPLACE": 0xE06C75
        case "COMMAND": 0xE5C07B
        case "TERMINAL": 0x56B6C2
        case "TREE": 0x2AC3DE
        case "FILTER": 0xFF9E64
        case "SWITCH": 0xBB9AF7
        default: 0x61AFEF
        }
        return NSColor(frameRGB: rgb)
    }

    private struct Piece {
        var text: NSAttributedString
        var gap: CGFloat = 12
        var width: CGFloat { ceil(text.size().width) }
    }

    private func attributed(
        _ text: String, _ color: NSColor, font: NSFont? = nil
    ) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font ?? look.smallFont, .foregroundColor: color])
    }

    private func icon(_ glyph: String, _ color: NSColor) -> NSAttributedString {
        attributed(glyph, color, font: NerdFont.font(size: look.iconSize - 1) ?? look.smallFont)
    }

    override func draw(_: NSRect) {
        look.island.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Design.islandRadius, yRadius: Design.islandRadius).fill()
        let state = state
        // The right side, from the right edge in: position, file type, language servers, diagnostics.
        var right: [Piece] = []
        right.append(Piece(text: attributed("\(max(state.line, 1)):\(max(state.col, 1))  \(state.scroll)", look.muted)))
        if !state.filetype.isEmpty { right.append(Piece(text: attributed(state.filetype, look.muted))) }
        if !state.lsp.isEmpty {
            let names = state.lsp.joined(separator: " ")
            let text = NSMutableAttributedString(attributedString: icon("\u{F013}", look.muted))
            text.append(attributed(" " + names, look.muted))
            right.append(Piece(text: text))
        }
        let marks: [(String, NSColor, Int)] = [
            ("\u{F057}", .systemRed, state.errors), ("\u{F071}", .systemYellow, state.warnings),
            ("\u{F05A}", .systemBlue, state.infos), ("\u{F0EB}", .systemTeal, state.hints),
        ]
        let diagnostics = NSMutableAttributedString()
        for (glyph, color, count) in marks where count > 0 {
            if diagnostics.length > 0 { diagnostics.append(attributed("  ", look.muted)) }
            diagnostics.append(icon(glyph, color))
            diagnostics.append(attributed(" \(count)", color))
        }
        if diagnostics.length > 0 { right.append(Piece(text: diagnostics)) }
        let midY = bounds.height / 2
        var edge = bounds.width - 12
        for piece in right {
            let size = piece.text.size()
            piece.text.draw(at: NSPoint(x: edge - piece.width, y: midY - size.height / 2))
            edge -= piece.width + piece.gap
        }
        // The left side: the mode, the branch, then the file, which gives way when there is no room.
        var x: CGFloat = 8
        workspaceRect = .zero
        if state.showsWorkspace, !state.workspace.isEmpty {
            let text = NSMutableAttributedString(attributedString: icon(
                state.workspaceIsWorktree ? "\u{E0A0}" : "\u{F401}",
                look.muted
            ))
            text.append(attributed(
                "  " + state.workspace,
                look.text,
                font: look.boldFont.withSize(look.smallFont.pointSize + 1)
            ))
            let width = min(ceil(text.size().width), max(0, (edge - x) * 0.3))
            let pill = NSRect(x: x, y: 6, width: width + 20, height: bounds.height - 12)
            look.text.withAlphaComponent(hoveringWorkspace ? 0.18 : 0.08).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 5, yRadius: 5).fill()
            text.draw(
                with: NSRect(
                    x: pill.minX + 10,
                    y: midY - text.size().height / 2,
                    width: width,
                    height: text.size().height
                ),
                options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin]
            )
            workspaceRect = pill
            x = pill.maxX + 8
        }
        let label = attributed(
            state.mode, NSColor(frameRGB: look.palette.background),
            font: look.boldFont.withSize(look.smallFont.pointSize)
        )
        let pillWidth = ceil(label.size().width) + 14, pillHeight = bounds.height - 12
        let pill = NSRect(x: x, y: (bounds.height - pillHeight) / 2, width: pillWidth, height: pillHeight)
        Self.color(forMode: state.mode).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 5, yRadius: 5).fill()
        label.draw(at: NSPoint(x: pill.minX + 7, y: midY - label.size().height / 2))
        x = pill.maxX + 12
        if !state.branch.isEmpty {
            let text = NSMutableAttributedString(attributedString: icon("\u{E0A0}", look.muted))
            text.append(attributed(" " + state.branch, look.muted))
            let width = min(ceil(text.size().width), max(0, (edge - x) * 0.35))
            text.draw(
                with: NSRect(x: x, y: midY - text.size().height / 2, width: width, height: text.size().height),
                options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin]
            )
            x += width + 12
        }
        if !state.recording.isEmpty {
            let text = attributed("● recording @\(state.recording)", .systemRed)
            text.draw(at: NSPoint(x: x, y: midY - text.size().height / 2))
            x += ceil(text.size().width) + 12
        }
        guard !state.path.isEmpty else { return }
        let file = NSMutableAttributedString()
        if !state.name.isEmpty {
            let glyph = String(FileIcons.icon(name: state.name, isDirectory: false).glyph)
            file.append(icon(glyph, look.muted))
            file.append(attributed(" ", look.muted))
        }
        file.append(attributed(state.path, look.text, font: look.font.withSize(look.smallFont.pointSize + 1)))
        if state.readonly { file.append(icon("  \u{F023}", look.muted)) }
        if state.modified { file.append(attributed("  ●", NSColor(frameRGB: 0xE5C07B))) }
        let width = max(0, edge - x)
        file.draw(
            with: NSRect(x: x, y: midY - file.size().height / 2, width: width, height: file.size().height),
            options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin]
        )
    }
}
