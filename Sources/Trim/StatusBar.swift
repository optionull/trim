import AppKit
import SillEditor
import TrimModes
import TrimTree

/// What the bar says, as one value: it draws again when this changes.
struct StatusState: Equatable {
    /// The mode as a word: nvim's, or Trim's own while the keyboard is in the tree or the switcher.
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
    /// The build that is running, by its title; empty when none is.
    var building = ""
    /// How the last build ended, as the bar says it ("✓ Build succeeded"); empty when there is nothing to say.
    var buildResult = ""
    var buildFailed = false
    var filetype = ""
    var line = 0, col = 0, lines = 0, top = 0, bottom = 0
    /// With the tabs in the status bar and more than one file open: how many, the file's name being the way to them.
    var picker = 0

    /// Where the window is in the buffer: Top, Bot, All or a percentage.
    var scroll: String { StatusLine.percent(line: line, lines: lines, firstVisible: top, lastVisible: bottom) }
}

/// The bar under the grid: the mode, the branch, the file and its state on the left; the diagnostics, language
/// servers, file type and position on the right. Drawn natively in the editor's font and the sidebar's colours.
final class StatusBarView: NSView {
    var look = TreeLook() {
        didSet { needsDisplay = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    var state = StatusState() {
        didSet {
            if state != oldValue { needsDisplay = true }
        }
    }

    /// A click on the problems' counts: the build pane on its Problems tab. A click on the build: its output.
    var onProblemsClick: (() -> Void)?
    var onBuildClick: (() -> Void)?
    /// A click on the language servers: the panel of what each is doing.
    var onLspClick: (() -> Void)?
    private var lspRect = NSRect.zero {
        didSet { if lspRect != oldValue { window?.invalidateCursorRects(for: self) } }
    }

    private var problemsRect = NSRect.zero {
        didSet { if problemsRect != oldValue { window?.invalidateCursorRects(for: self) } }
    }

    private var buildRect = NSRect.zero {
        didSet { if buildRect != oldValue { window?.invalidateCursorRects(for: self) } }
    }

    /// Which clickable section the pointer is over (it has a ground of its own then).
    private var hoveringTarget: Piece.Target?

    /// The loader while a build runs: a turning arc that Core Animation moves, in a view of its own, so the bar is not
    /// drawn again for it.
    private let spinner = LoaderView(.spinner)
    var spinnerFrame: NSRect { spinner.isHidden ? .zero : spinner.frame }
    var isSpinning: Bool { !spinner.isHidden && spinner.isGoing }

    private func placeSpinner(_ rect: NSRect?) {
        if let rect {
            if spinner.superview == nil { addSubview(spinner) }
            if spinner.frame != rect { spinner.frame = rect }
            spinner.isHidden = false
        } else {
            spinner.isHidden = true
        }
    }

    /// A click on the workspace segment: the switcher.
    var onWorkspaceClick: (() -> Void)?
    private var workspaceRect = NSRect.zero {
        didSet { if workspaceRect != oldValue { window?.invalidateCursorRects(for: self) } }
    }

    private(set) var hoveringWorkspace = false
    /// A click on the file's name, when the tabs are in the status bar: the list of open files.
    var onFileClick: (() -> Void)?
    private var fileRect = NSRect.zero {
        didSet { if fileRect != oldValue { window?.invalidateCursorRects(for: self) } }
    }

    private(set) var hoveringFile = false

    /// The file's name as a button, in this view's coordinates (empty when it is not one).
    var fileButton: NSRect { state.picker > 0 ? fileRect : .zero }

    /// Where the pointer is a hand: the workspace segment, when it is there.
    func pointerRects() -> [NSRect] {
        var rects: [NSRect] = []
        if state.showsWorkspace, !workspaceRect.isEmpty { rects.append(workspaceRect) }
        if state.picker > 0, !fileRect.isEmpty { rects.append(fileRect) }
        if !problemsRect.isEmpty { rects.append(problemsRect) }
        if !buildRect.isEmpty { rects.append(buildRect) }
        if !lspRect.isEmpty { rects.append(lspRect) }
        return rects
    }

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
        let point = convert(event.locationInWindow, from: nil)
        setHoveringWorkspace(state.showsWorkspace && workspaceRect.contains(point))
        setHoveringFile(state.picker > 0 && fileRect.contains(point))
        setHovering(
            problemsRect.contains(point) ? .problems
                : (buildRect.contains(point) ? .build : (lspRect.contains(point) ? .lsp : nil))
        )
    }

    private func setHovering(_ target: Piece.Target?) {
        guard target != hoveringTarget else { return }
        hoveringTarget = target
        needsDisplay = true
    }

    override func mouseExited(with _: NSEvent) {
        setHoveringWorkspace(false)
        setHoveringFile(false)
        setHovering(nil)
    }

    func setHoveringFile(_ hovering: Bool) {
        guard hovering != hoveringFile else { return }
        hoveringFile = hovering
        needsDisplay = true
    }

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
        let point = convert(event.locationInWindow, from: nil)
        if state.showsWorkspace, workspaceRect.contains(point) {
            onWorkspaceClick?()
        } else if state.picker > 0, fileRect.contains(point) {
            onFileClick?()
        } else if !problemsRect.isEmpty, problemsRect.contains(point) {
            onProblemsClick?()
        } else if !buildRect.isEmpty, buildRect.contains(point) {
            onBuildClick?()
        } else if !lspRect.isEmpty, lspRect.contains(point) {
            onLspClick?()
        }
    }

    /// A line of the grid, with room above and below.
    static func height(for look: TreeLook) -> CGFloat { look.rowHeight + 12 }

    /// The mode's colour: nvim's modes as is usual, and Trim's own modes each a colour of their own.
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

    @MainActor private struct Piece {
        enum Target { case problems, build, lsp }

        var text: NSAttributedString
        var target: Target?
        var gap: CGFloat = 12
        /// Measured once (shaping text in a ligature font is the slow part of drawing the bar).
        let width: CGFloat

        init(text: NSAttributedString, target: Target? = nil, gap: CGFloat = 12) {
            self.text = text
            self.target = target
            self.gap = gap
            width = TextWidths.of(text)
        }
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
            right.append(Piece(text: text, target: .lsp))
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
        if diagnostics.length > 0 { right.append(Piece(text: diagnostics, target: .problems)) }
        // A build: a loader while it runs, then how it went for a while.
        var spinnerAt: NSRect?
        if !state.building.isEmpty {
            right.append(Piece(text: attributed("     Building " + state.building, Design.accent), target: .build))
        } else if !state.buildResult.isEmpty {
            let color: NSColor = state.buildFailed ? .systemRed : .systemGreen
            right.append(Piece(text: attributed(state.buildResult, color), target: .build))
        }
        let midY = bounds.height / 2
        var edge = bounds.width - 12
        var newProblemsRect = NSRect.zero, newBuildRect = NSRect.zero, newLspRect = NSRect.zero
        for piece in right {
            let size = piece.text.size()
            let box = NSRect(x: edge - piece.width - 4, y: 0, width: piece.width + 8, height: bounds.height)
            if let target = piece.target, target == hoveringTarget {
                look.selection.setFill()
                NSBezierPath(roundedRect: box.insetBy(dx: -2, dy: 5), xRadius: 6, yRadius: 6).fill()
            }
            piece.text.draw(at: NSPoint(x: edge - piece.width, y: midY - size.height / 2))
            if piece.target == .problems { newProblemsRect = box }
            if piece.target == .lsp { newLspRect = box }
            if piece.target == .build {
                newBuildRect = box
                if !state.building.isEmpty { spinnerAt = NSRect(
                    x: edge - piece.width,
                    y: midY - 7,
                    width: 14,
                    height: 14
                ) }
            }
            edge -= piece.width + piece.gap
        }
        problemsRect = newProblemsRect
        buildRect = newBuildRect
        lspRect = newLspRect
        placeSpinner(spinnerAt)
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
        fileRect = .zero
        guard !state.path.isEmpty else { return }
        let file = NSMutableAttributedString()
        if !state.name.isEmpty {
            let glyph = String(FileIcons.icon(name: state.name, isDirectory: false).glyph)
            file.append(icon(glyph, look.muted))
            file.append(attributed(" ", look.muted))
        }
        // The name is what matters: a path too long for the room loses its front folders, not its end.
        let pathFont = look.font.withSize(look.smallFont.pointSize + 1)
        let room = max(0, edge - x - 96)
        let shownPath = StatusLine.fitted(state.path, width: room) { text in
            TextWidths.of(NSAttributedString(string: text, attributes: [.font: pathFont]))
        }
        file.append(attributed(shownPath, look.text, font: pathFont))
        if state.readonly { file.append(icon("  \u{F023}", look.muted)) }
        if state.modified { file.append(attributed("  ●", NSColor(frameRGB: 0xE5C07B))) }
        // With the tabs here, the name is the way to the other files: how many there are, and a mark that it opens.
        let picker = state.picker > 0
            ? attributed("  ▾ \(state.picker)", look.muted, font: look.smallFont) : NSAttributedString()
        let width = max(0, edge - x - ceil(picker.size().width))
        let shown = min(ceil(file.size().width), width)
        if picker.length > 0 {
            let button = NSRect(
                x: x - 6,
                y: 5,
                width: shown + ceil(picker.size().width) + 12,
                height: bounds.height - 10
            )
            fileRect = button
            look.text.withAlphaComponent(hoveringFile ? 0.14 : 0.0).setFill()
            NSBezierPath(roundedRect: button, xRadius: 5, yRadius: 5).fill()
        }
        file.draw(
            with: NSRect(x: x, y: midY - file.size().height / 2, width: width, height: file.size().height),
            options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin]
        )
        picker.draw(at: NSPoint(x: x + shown, y: midY - picker.size().height / 2))
    }
}

/// How wide text is, remembered: the status bar draws again and again (a loader turns in it) and the same strings are
/// measured each time.
@MainActor
enum TextWidths {
    private static var known: [NSAttributedString: CGFloat] = [:]

    static func of(_ text: NSAttributedString) -> CGFloat {
        if let width = known[text] { return width }
        if known.count > 400 { known.removeAll() }
        let width = ceil(text.size().width)
        known[text] = width
        return width
    }
}
