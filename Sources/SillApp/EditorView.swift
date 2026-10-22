import AppKit
import SillCore
import SillNvim

/// Draws nvim's grids where multigrid places them and sends it keys and mouse clicks.
///
/// A stand-in until the Metal grid (day 3 of the plan): it draws with CoreText on the main thread, run by run, only
/// when a new screen arrives. It never waits on nvim: screens are handed to it, and input is queued.
@MainActor
final class EditorView: NSView {
    private(set) var screen = Screen()
    private let channel: NvimChannel
    let metrics: CellMetrics
    /// Called with the new size in cells when the view is resized.
    var onResize: ((_ cols: Int, _ rows: Int) -> Void)?
    /// Called when the editor takes the keyboard back (a click on it).
    var onFocus: (() -> Void)?
    /// Grids not to draw: those under a terminal pane.
    var coveredGrids: Set<Int> = []

    init(channel: NvimChannel, metrics: CellMetrics) {
        self.channel = channel
        self.metrics = metrics
        super.init(frame: NSRect(x: 0, y: 0, width: 1100, height: 700))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var gridSize: (cols: Int, rows: Int) {
        (max(Int(bounds.width / metrics.width), 1), max(Int(bounds.height / metrics.height), 1))
    }

    func show(_ screen: Screen) {
        self.screen = screen
        needsDisplay = true
    }

    /// The rectangle of a run of cells on grid 1, in points.
    func rect(row: Int, col: Int, width: Int, height: Int) -> NSRect {
        NSRect(
            x: CGFloat(col) * metrics.width, y: CGFloat(row) * metrics.height,
            width: CGFloat(width) * metrics.width, height: CGFloat(height) * metrics.height
        )
    }

    override func setFrameSize(_ newSize: NSSize) {
        let before = gridSize
        super.setFrameSize(newSize)
        let after = gridSize
        if before != after { onResize?(after.cols, after.rows) }
    }

    // MARK: Drawing

    override func draw(_: NSRect) {
        let background = NSColor(rgb: screen.defaultBackground)
        background.setFill()
        bounds.fill()
        let screenRows = screen.grids[1]?.rows ?? 0
        for (grid, placement) in screen.drawOrder where !coveredGrids.contains(grid) {
            guard let buffer = screen.grids[grid] else { continue }
            // The message grid is as tall as the screen and starts part-way down: only what fits is shown.
            let rows = min(buffer.rows, max(screenRows - placement.row, 0))
            draw(buffer, rows: rows, atRow: placement.row, col: placement.col)
        }
        drawCursor()
    }

    private func draw(_ buffer: GridBuffer, rows: Int, atRow top: Int, col left: Int) {
        for row in 0 ..< rows {
            var col = 0
            while col < buffer.cols {
                // A run: cells with one highlight and plain single-width text, drawn as one string.
                let hl = buffer[row, col].hl
                var end = col
                var text = ""
                while end < buffer.cols, buffer[row, end].hl == hl {
                    let cell = buffer[row, end]
                    let wide = end + 1 < buffer.cols && buffer[row, end + 1].text.isEmpty
                    if wide || !cell.text.allSatisfy(\.isASCII) {
                        if end == col { text = cell.text; end += wide ? 2 : 1 }
                        break
                    }
                    text += cell.text
                    end += 1
                }
                drawRun(text, hl: hl, row: top + row, col: left + col, width: end - col)
                col = end
            }
        }
    }

    private func drawRun(_ text: String, hl: Int, row: Int, col: Int, width: Int) {
        let style = screen.highlights[hl] ?? Highlight()
        var foreground = style.foreground ?? screen.defaultForeground
        var background = style.background ?? screen.defaultBackground
        if style.reverse { swap(&foreground, &background) }
        let cells = rect(row: row, col: col, width: width, height: 1)
        if background != screen.defaultBackground || style.reverse {
            NSColor(rgb: background).setFill()
            cells.fill()
        }
        guard text.contains(where: { $0 != " " }) else { return }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: metrics.font(bold: style.bold, italic: style.italic),
            .foregroundColor: NSColor(rgb: foreground),
        ]
        if style.underline || style.undercurl {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            if let special = style.special { attributes[.underlineColor] = NSColor(rgb: special) }
        }
        if style.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        NSAttributedString(string: text, attributes: attributes)
            .draw(at: NSPoint(x: cells.minX, y: cells.minY + metrics.textOffset))
    }

    private func drawCursor() {
        guard window?.firstResponder === self, !coveredGrids.contains(screen.cursorGrid) else { return }
        let origin: (row: Int, col: Int) = screen.cursorGrid == 1 ? (0, 0) :
            screen.placements[screen.cursorGrid].map { ($0.row, $0.col) } ?? (0, 0)
        var cursor = rect(row: origin.row + screen.cursorRow, col: origin.col + screen.cursorCol, width: 1, height: 1)
        if screen.mode.hasPrefix("insert") || screen.mode.hasPrefix("cmdline") { cursor.size.width = 2 }
        NSColor(rgb: screen.defaultForeground).withAlphaComponent(0.8).setFill()
        cursor.fill()
    }

    // MARK: Input

    override func keyDown(with event: NSEvent) {
        if let keys = KeyNotation.keys(for: event) { channel.send(keys: keys) }
    }

    /// Control chords come here before `keyDown`; they are nvim's, unless the menu took them first.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown,
              event.modifierFlags.contains(.control), !event.modifierFlags.contains(.command)
        else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onFocus?()
        mouse(event, action: "press")
    }

    override func mouseDragged(with event: NSEvent) { mouse(event, action: "drag") }
    override func mouseUp(with event: NSEvent) { mouse(event, action: "release") }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }

    /// A click goes to the grid on top at that cell, in that grid's own coordinates.
    private func mouse(_ event: NSEvent, action: String) {
        let point = convert(event.locationInWindow, from: nil)
        let row = Int(point.y / metrics.height), col = Int(point.x / metrics.width)
        let hit = screen.drawOrder.last { _, placement in
            row >= placement.row && row < placement.row + placement.height &&
                col >= placement.col && col < placement.col + placement.width
        }
        let (grid, placement) = hit ?? (1, Placement(kind: .window, win: 0, row: 0, col: 0, width: 0, height: 0))
        let channel = channel
        Task {
            await channel.inputMouse(
                button: "left", action: action, modifier: "", grid: grid, row: row - placement.row,
                col: col - placement.col
            )
        }
    }
}

/// The cell size and fonts of the grid.
struct CellMetrics {
    let regular: NSFont
    let width: CGFloat
    let height: CGFloat
    /// From the top of a cell to where text is drawn, centring the line in the cell.
    let textOffset: CGFloat

    init(size: CGFloat = 13) {
        regular = NSFont(name: "JetBrains Mono", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        width = ceil(("M" as NSString).size(withAttributes: [.font: regular]).width)
        let line = ceil(regular.ascender - regular.descender + regular.leading)
        height = ceil(line * 1.2)
        textOffset = floor((height - line) / 2)
    }

    func font(bold: Bool, italic: Bool) -> NSFont {
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        guard !traits.isEmpty else { return regular }
        return NSFontManager.shared.convert(regular, toHaveTrait: traits)
    }
}

extension NSColor {
    convenience init(rgb: Int) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255, alpha: 1
        )
    }
}
