import AppKit
import SillCore
import SillEditor

/// JetBrains' islands look (a setting, on by default): the explorer, each editor window, the panel and the panes as
/// rounded panels on a darker canvas, the title, activity and status bars on the canvas too. Drawn over the editor
/// rather than by nvim or the renderer: the canvas everywhere, then each window's rounded rectangle cleared, so
/// nvim's separator columns and rule rows become the gaps whatever colour scheme the person uses. Floats are cleared
/// as they are, unrounded. It takes no clicks: dragging a separator still resizes.
final class IslandsView: NSView {
    private var windows: [NSRect] = []
    private var floats: [NSRect] = []

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_: NSPoint) -> NSView? { nil }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    /// The windows as the screen places them, in the editor's points.
    func update(_ screen: Screen, editor: EditorView) {
        var windows: [NSRect] = [], floats: [NSRect] = []
        for placement in screen.placements.values where !placement.hidden {
            let rect = editor.rect(
                row: placement.row,
                col: placement.col,
                width: placement.width,
                height: placement.height
            )
            if placement.kind == .window { windows.append(rect) } else { floats.append(rect) }
        }
        // nvim's root grid, when no window is placed (before the first layout), is one island.
        if windows.isEmpty, let grid = screen.grids[1] {
            windows.append(editor.rect(row: 0, col: 0, width: grid.cols, height: grid.rows))
        }
        guard windows != self.windows || floats != self.floats else { return }
        self.windows = windows
        self.floats = floats
        needsDisplay = true
    }

    override func draw(_: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        Design.canvas.setFill()
        bounds.fill()
        context.setBlendMode(.clear)
        for window in windows {
            NSBezierPath(roundedRect: window, xRadius: Design.islandRadius, yRadius: Design.islandRadius).fill()
        }
        for float in floats {
            float.fill()
        }
        context.setBlendMode(.normal)
    }
}
