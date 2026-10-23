import AppKit
import SillCore
import SillInput
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
    /// Called for every key the editor gets, before nvim does.
    var onKey: (() -> Void)?
    /// Sees keys before nvim, after `onKey`; true when it took the key (a tool view whose window is current).
    var keyInterceptor: ((NSEvent) -> Bool)?
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
        startScrolls(from: self.screen, to: screen)
        self.screen = screen
        submit()
    }

    // MARK: Smooth scrolling

    /// How long a slide takes. nvim has already moved; this only shows the move.
    static let scrollDuration: CFTimeInterval = 0.12
    private struct Slide {
        var previous: GridBuffer
        var lines: Int
        var start: CFTimeInterval
    }

    private var slides: [Int: Slide] = [:]
    private var seenScrolls: [Int: Int] = [:]
    private var slideLink: CADisplayLink?
    /// Off with SILL_SMOOTH_SCROLL=0.
    private let smoothScrolling = ProcessInfo.processInfo.environment["SILL_SMOOTH_SCROLL"] != "0"

    /// A window that scrolled less than its height slides there from where it was.
    private func startScrolls(from old: Screen, to new: Screen) {
        let now = CACurrentMediaTime()
        for (grid, scroll) in new.scrolls where scroll.serial > (seenScrolls[grid] ?? 0) {
            seenScrolls[grid] = scroll.serial
            guard smoothScrolling, let previous = old.grids[grid], let placement = new.placements[grid],
                  placement.kind == .window, abs(scroll.lines) < placement.height, previous.rows == placement.height
            else { continue }
            slides[grid] = Slide(previous: previous, lines: scroll.lines, start: now)
        }
        if !slides.isEmpty, slideLink == nil {
            let link = displayLink(target: self, selector: #selector(slideTick))
            link.add(to: .main, forMode: .common)
            slideLink = link
        }
    }

    @objc private func slideTick() {
        submit()
    }

    /// Where each slide is now; finished ones end, and the link stops with the last.
    private func currentScrolls() -> [Int: Frame.ScrollAnimation] {
        let now = CACurrentMediaTime()
        var result: [Int: Frame.ScrollAnimation] = [:]
        for (grid, slide) in slides {
            let t = min(Float((now - slide.start) / Self.scrollDuration), 1)
            if t >= 1 || screen.placements[grid] == nil {
                slides[grid] = nil
                continue
            }
            let eased = 1 - pow(1 - t, 3) // Ease out: fast, then settling.
            result[grid] = Frame.ScrollAnimation(previous: slide.previous, lines: slide.lines, progress: eased)
        }
        if slides.isEmpty {
            slideLink?.invalidate()
            slideLink = nil
        }
        return result
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
    var currentFrame: Frame {
        var frame = Frame(screen: screen, covered: coveredGrids, cursor: cursor)
        frame.scrolls = currentScrolls()
        return frame
    }

    /// Whether a window is sliding now.
    var isSliding: Bool { !slides.isEmpty }

    /// Hands the current screen to the render thread.
    private func submit() {
        frameTag += 1
        loop?.submit(currentFrame, tag: frameTag)
    }

    /// The cursor, while the editor has the keyboard, as nvim describes it for the current mode.
    private var cursor: Frame.Cursor? {
        guard window?.firstResponder === self, let style = screen.cursorStyle else { return nil }
        let shape: Frame.Cursor.Shape = switch style.cursorShape {
        case .block: .block
        case .vertical: .vertical
        case .horizontal: .horizontal
        }
        return Frame.Cursor(shape: shape, percentage: style.cellPercentage, highlight: style.attrId)
    }

    // MARK: Keys and input methods

    /// Text an input method is composing, shown at the cursor until it is committed.
    private var markedText = ""
    private lazy var markedView = MarkedTextView(metrics: metrics)
    /// Set while `interpretKeyEvents` runs, so a key the input method did not take is sent as it is.
    private var handledByInputMethod = false

    override func keyDown(with event: NSEvent) {
        onKey?()
        if markedText.isEmpty, keyInterceptor?(event) == true { return }
        // While composing, every key is the input method's: Backspace shortens, Return commits, Escape cancels.
        if !markedText.isEmpty {
            inputContext?.handleEvent(event)
            return
        }
        // Control and Command chords, and named keys (Escape, Return, arrows...), go straight to nvim. Option goes
        // through the input method, which makes the layout's characters and dead keys of it.
        let modifiers = event.modifierFlags.intersection([.control, .command])
        let scalar = event.characters?.unicodeScalars.first?.value ?? 0
        let named = scalar < 0x20 || scalar == 0x7F || (0xF700 ... 0xF8FF).contains(scalar)
        if !modifiers.isEmpty || named {
            if let keys = KeyNotation.keys(for: event) { channel.send(keys: keys) }
            return
        }
        handledByInputMethod = false
        inputContext?.handleEvent(event)
        if !handledByInputMethod, markedText.isEmpty, let keys = KeyNotation.keys(for: event) {
            channel.send(keys: keys)
        }
    }

    /// Control chords come here before `keyDown`; they are nvim's, unless the menu took them first.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown,
              event.modifierFlags.contains(.control), !event.modifierFlags.contains(.command)
        else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    /// The cursor's cell, in this view's coordinates: where marked text is shown and input methods put candidates.
    var cursorRect: NSRect {
        let origin = screen.cursorGrid == 1 ? (row: 0, col: 0) :
            screen.placements[screen.cursorGrid].map { (row: $0.row, col: $0.col) } ?? (row: 0, col: 0)
        return rect(row: origin.row + screen.cursorRow, col: origin.col + screen.cursorCol, width: 1, height: 1)
    }

    private func showMarkedText() {
        if markedText.isEmpty {
            markedView.removeFromSuperview()
            return
        }
        markedView.text = markedText
        markedView.frame = NSRect(origin: cursorRect.origin, size: markedView.fittingSize)
        if markedView.superview == nil { addSubview(markedView) }
    }

    // MARK: Edit menu

    /// ⌘V: the pasteboard's text through `nvim_paste`, which works in every mode.
    @objc func paste(_: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        channel.send(.paste(text))
    }

    /// ⌘C and ⌘X: in Visual mode, yank or delete into the `+` register, which nvim keeps in the system clipboard.
    @objc func copy(_: Any?) {
        if isVisual { channel.send(keys: "\"+y") }
    }

    @objc func cut(_: Any?) {
        if isVisual { channel.send(keys: "\"+d") }
    }

    private var isVisual: Bool { screen.mode.hasPrefix("visual") || screen.mode.hasPrefix("select") }

    // MARK: Mouse

    private lazy var scroll = ScrollAccumulator(lineHeight: metrics.height, columnWidth: metrics.width)
    /// The grid a button was pressed in: drags and the release go to it, in its coordinates, wherever the pointer is.
    private var pressed: (grid: Int, rowOffset: Int, colOffset: Int)?

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onFocus?()
        mouse(event, button: "left", action: "press")
    }

    override func mouseDragged(with event: NSEvent) { mouse(event, button: "left", action: "drag") }
    override func mouseUp(with event: NSEvent) { mouse(event, button: "left", action: "release") }
    override func rightMouseDown(with event: NSEvent) { mouse(event, button: "right", action: "press") }
    override func rightMouseDragged(with event: NSEvent) { mouse(event, button: "right", action: "drag") }
    override func rightMouseUp(with event: NSEvent) { mouse(event, button: "right", action: "release") }
    override func otherMouseDown(with event: NSEvent) { mouse(event, button: "middle", action: "press") }
    override func otherMouseDragged(with event: NSEvent) { mouse(event, button: "middle", action: "drag") }
    override func otherMouseUp(with event: NSEvent) { mouse(event, button: "middle", action: "release") }

    override func scrollWheel(with event: NSEvent) {
        if event.phase == .began { scroll.reset() }
        let steps = scroll.steps(
            deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas
        )
        guard !steps.isEmpty else { return }
        let (grid, row, col) = cell(event)
        for step in steps {
            channel.send(.mouse(
                button: "wheel", action: step, modifiers: Mouse.modifiers(event.modifierFlags), grid: grid, row: row,
                col: col
            ))
        }
    }

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

    /// The grid and cell under the pointer.
    private func cell(_ event: NSEvent) -> (grid: Int, row: Int, col: Int) {
        let point = convert(event.locationInWindow, from: nil)
        return screen.hit(row: Int(point.y / metrics.height), col: Int(point.x / metrics.width))
    }

    private func mouse(_ event: NSEvent, button: String, action: String) {
        let point = convert(event.locationInWindow, from: nil)
        let row = Int(floor(point.y / metrics.height)), col = Int(floor(point.x / metrics.width))
        let target: (grid: Int, row: Int, col: Int)
        if action == "press" {
            target = screen.hit(row: row, col: col)
            pressed = (target.grid, row - target.row, col - target.col)
        } else if let pressed {
            target = (pressed.grid, row - pressed.rowOffset, col - pressed.colOffset)
        } else {
            target = screen.hit(row: row, col: col)
        }
        if action == "release" { pressed = nil }
        channel.send(.mouse(
            button: button, action: action, modifiers: Mouse.modifiers(event.modifierFlags), grid: target.grid,
            row: target.row, col: target.col
        ))
    }
}

// MARK: - NSTextInputClient

/// Input methods (Japanese, Chinese, Korean; dead keys). Every answer comes from what the view already has, the
/// marked text and the cached screen's cursor: input methods ask on the main thread and wait, so nothing here asks
/// nvim.
extension EditorView: @preconcurrency NSTextInputClient {
    func insertText(_ string: Any, replacementRange _: NSRange) {
        handledByInputMethod = true
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedText = ""
        showMarkedText()
        guard !text.isEmpty else { return }
        channel.send(keys: text.replacingOccurrences(of: "<", with: "<lt>"))
    }

    func setMarkedText(_ string: Any, selectedRange _: NSRange, replacementRange _: NSRange) {
        handledByInputMethod = true
        markedText = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        showMarkedText()
    }

    func unmarkText() {
        markedText = ""
        showMarkedText()
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func markedRange() -> NSRange {
        markedText.isEmpty ? NSRange(location: NSNotFound, length: 0) :
            NSRange(location: 0, length: (markedText as NSString).length)
    }

    func hasMarkedText() -> Bool { !markedText.isEmpty }

    func attributedSubstring(forProposedRange _: NSRange, actualRange _: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    /// Where the input method puts its candidate window: under the cursor's cell, on screen.
    func firstRect(forCharacterRange _: NSRange, actualRange _: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(cursorRect, to: nil))
    }

    func characterIndex(for _: NSPoint) -> Int { NSNotFound }

    override func doCommand(by _: Selector) {
        // Keys AppKit turns into editing commands (Return, arrows) were already sent by keyDown; leaving this empty
        // also keeps the system beep away.
        handledByInputMethod = true
    }
}

/// Marked text at the cursor while an input method composes, underlined as macOS shows composition.
final class MarkedTextView: NSView {
    private let metrics: CellMetrics
    var text = "" {
        didSet { needsDisplay = true }
    }

    init(metrics: CellMetrics) {
        self.metrics = metrics
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    private var attributed: NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: metrics.regular, .foregroundColor: NSColor.white,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
    }

    override var fittingSize: NSSize {
        NSSize(width: ceil(attributed.size().width) + 2, height: metrics.height)
    }

    override func draw(_: NSRect) {
        NSColor(white: 0.15, alpha: 1).setFill()
        bounds.fill()
        attributed.draw(at: NSPoint(x: 1, y: metrics.textOffset))
    }
}
