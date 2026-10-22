import AppKit
import SillCore
import SillNvim
import SillRender

/// Shows nvim's grids where multigrid places them, and sends nvim keys and mouse clicks.
///
/// The view is backed by a `CAMetalLayer` that a render thread draws into (`RenderLoop`); the main thread only hands
/// it frames. Nothing here waits on nvim: screens are handed in, and input is queued.
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
    var coveredGrids: Set<Int> = [] {
        didSet { if coveredGrids != oldValue { submit() } }
    }

    private let metalLayer = CAMetalLayer()
    private(set) var loop: RenderLoop?
    /// Tags the frames handed to the render loop, so a measurement can tell which screen reached the display.
    private(set) var frameTag: UInt64 = 0

    init(channel: NvimChannel, metrics: CellMetrics) {
        self.channel = channel
        self.metrics = metrics
        super.init(frame: NSRect(x: 0, y: 0, width: 1100, height: 700))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        metalLayer.isOpaque = true
        startRenderer(scale: NSScreen.main?.backingScaleFactor ?? 2)
    }

    override func makeBackingLayer() -> CALayer { metalLayer }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var gridSize: (cols: Int, rows: Int) {
        (max(Int(bounds.width / metrics.width), 1), max(Int(bounds.height / metrics.height), 1))
    }

    func show(_ screen: Screen) {
        self.screen = screen
        submit()
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
        updateDrawableSize()
        let after = gridSize
        if before != after { onResize?(after.cols, after.rows) }
    }

    // MARK: Drawing

    /// The glyph atlas is rasterised for one backing scale; a window moving to a display with another starts over.
    private func startRenderer(scale: CGFloat) {
        loop?.stop()
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = try? GridRenderer(
                  device: device, font: metrics.regular, cellSize: metrics.cellSize, scale: scale,
                  pixelFormat: .bgra8Unorm
              )
        else {
            NSLog("sill: no Metal renderer")
            return
        }
        metalLayer.contentsScale = scale
        loop = RenderLoop(layer: metalLayer, renderer: renderer) { target, selector in
            self.displayLink(target: target, selector: selector)
        }
        rendererScale = scale
        updateDrawableSize()
        submit()
    }

    private var rendererScale: CGFloat = 0

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let scale = window?.backingScaleFactor else { return }
        if scale != rendererScale {
            startRenderer(scale: scale)
        } else {
            updateDrawableSize()
        }
    }

    private func updateDrawableSize() {
        let size = CGSize(
            width: bounds.width * metalLayer.contentsScale,
            height: bounds.height * metalLayer.contentsScale
        )
        guard size.width > 0, size.height > 0, metalLayer.drawableSize != size else { return }
        metalLayer.drawableSize = size
        loop?.redraw()
    }

    /// What the render thread is drawing now.
    var currentFrame: Frame { Frame(screen: screen, covered: coveredGrids, cursor: cursor) }

    /// Hands the current screen to the render thread.
    private func submit() {
        frameTag += 1
        loop?.submit(currentFrame, tag: frameTag)
    }

    /// The cursor, while the editor has the keyboard; its shape follows the mode.
    private var cursor: Frame.Cursor? {
        guard window?.firstResponder === self else { return nil }
        if screen.mode.hasPrefix("insert") || screen.mode.hasPrefix("cmdline") { return .init(shape: .bar) }
        if screen.mode.hasPrefix("replace") { return .init(shape: .underline) }
        return .init(shape: .block)
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
        let accepted = super.becomeFirstResponder()
        submit()
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        DispatchQueue.main.async { [weak self] in self?.submit() }
        return resigned
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
