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
package final class EditorView: NSView {
    package private(set) var screen = Screen()
    private let channel: NvimChannel
    /// The grid's font and cell size, as the settings (and ⌘+, ⌘-) have them now.
    package var metrics: CellMetrics { EditorFont.metrics }
    /// Called with the new size in cells when the view is resized.
    package var onResize: ((_ cols: Int, _ rows: Int) -> Void)?
    /// Called when the editor takes the keyboard back (a click on it).
    package var onFocus: (() -> Void)?
    /// Called for every key the editor gets, before nvim does.
    package var onKey: (() -> Void)?
    /// Sees keys before nvim, after `onKey`; true when it took the key (a tool view whose window is current).
    package var keyInterceptor: ((NSEvent) -> Bool)?
    /// Grids not to draw: those under a terminal pane.
    package var coveredGrids: Set<Int> = [] {
        didSet { if coveredGrids != oldValue { submit() } }
    }

    /// Windows cover what is under them (see `Frame.windowsCover`).
    package var windowsCover = false {
        didSet { if windowsCover != oldValue { submit() } }
    }

    private let metalLayer = CAMetalLayer()
    package private(set) var loop: RenderLoop?
    /// Tags the frames handed to the render loop, so a measurement can tell which screen reached the display.
    package private(set) var frameTag: UInt64 = 0

    package init(channel: NvimChannel) {
        self.channel = channel
        super.init(frame: NSRect(x: 0, y: 0, width: 1100, height: 700))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        metalLayer.isOpaque = true
        startRenderer(scale: NSScreen.main?.backingScaleFactor ?? 2)
    }

    override package func makeBackingLayer() -> CALayer { metalLayer }

    @available(*, unavailable)
    package required init?(coder _: NSCoder) { fatalError("not used") }

    override package var isFlipped: Bool { true }
    override package var acceptsFirstResponder: Bool { true }

    package var gridSize: (cols: Int, rows: Int) {
        (max(Int(bounds.width / metrics.width), 1), max(Int(bounds.height / metrics.height), 1))
    }

    package func show(_ screen: Screen) {
        startScrolls(from: self.screen, to: screen)
        self.screen = screen
        submit()
    }

    // MARK: Smooth scrolling

    /// How long a slide takes. nvim has already moved; this only shows the move.
    package static let scrollDuration: CFTimeInterval = ScrollSlide.duration
    private struct Slide {
        var previous: GridBuffer
        var motion: ScrollSlide
    }

    /// A scroll that comes while a window is still sliding goes on from where the window is drawn, to the new place,
    /// instead of starting over from the rows it had before (which jumps the window back, and steps line by line when
    /// scrolling is fast). Off, a slide always starts from the rows as they were.
    package var chainsScrolls = false

    private var slides: [Int: Slide] = [:]
    private var seenScrolls: [Int: Int] = [:]
    private var slideLink: CADisplayLink?
    /// Off with `smooth_scroll = false` (SILL_SMOOTH_SCROLL=0); read as it is now, so a change applies at once.
    private var smoothScrolling: Bool { Settings.shared.value("SILL_SMOOTH_SCROLL") != "0" }

    /// A window that scrolled less than its height slides there from where it was.
    private func startScrolls(from old: Screen, to new: Screen) {
        let now = CACurrentMediaTime()
        for (grid, scroll) in new.scrolls where scroll.serial > (seenScrolls[grid] ?? 0) {
            seenScrolls[grid] = scroll.serial
            guard smoothScrolling, let placement = new.placements[grid], placement.kind == .window else { continue }
            if chainsScrolls, let active = slides[grid], active.previous.rows == placement.height {
                // Not a slide any more when the scrolls together are nothing or a screenful: the window is where it is.
                slides[grid] = ScrollSlide.chained(active.motion, then: scroll.lines, at: now, height: placement.height)
                    .map { Slide(previous: active.previous, motion: $0) }
                continue
            }
            guard let previous = old.grids[grid], abs(scroll.lines) < placement.height,
                  previous.rows == placement.height else { continue }
            slides[grid] = Slide(previous: previous, motion: ScrollSlide(lines: scroll.lines, start: now))
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
            if slide.motion.isDone(at: now) || screen.placements[grid] == nil {
                slides[grid] = nil
                continue
            }
            result[grid] = Frame.ScrollAnimation(
                previous: slide.previous, lines: slide.motion.lines, progress: Float(slide.motion.progress(at: now))
            )
        }
        if slides.isEmpty {
            slideLink?.invalidate()
            slideLink = nil
        }
        return result
    }

    /// The rectangle of a run of cells on grid 1, in points.
    package func rect(row: Int, col: Int, width: Int, height: Int) -> NSRect {
        NSRect(
            x: CGFloat(col) * metrics.width, y: CGFloat(row) * metrics.height,
            width: CGFloat(width) * metrics.width, height: CGFloat(height) * metrics.height
        )
    }

    override package func setFrameSize(_ newSize: NSSize) {
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

    /// The font changed (`EditorFont`): the glyph atlas made again at the new size, and nvim told how many cells now
    /// fit.
    package func fontChanged() {
        startRenderer(scale: rendererScale > 0 ? rendererScale : (window?.backingScaleFactor ?? 2))
        scroll = ScrollAccumulator(lineHeight: metrics.height, columnWidth: metrics.width)
        let size = gridSize
        onResize?(size.cols, size.rows)
    }

    override package func viewDidChangeBackingProperties() {
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
    package var currentFrame: Frame {
        var frame = Frame(screen: screen, covered: coveredGrids, cursor: cursor)
        frame.windowsCover = windowsCover
        frame.scrolls = currentScrolls()
        return frame
    }

    /// Whether a window is sliding now.
    package var isSliding: Bool { !slides.isEmpty }

    /// How many lines each sliding window is moving, for the self-check.
    package var slidingLines: [Int: Int] { slides.mapValues(\.motion.lines) }

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
    private lazy var markedView = MarkedTextView()
    /// Set while `interpretKeyEvents` runs, so a key the input method did not take is sent as it is.
    private var handledByInputMethod = false

    override package func keyDown(with event: NSEvent) {
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
    override package func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown,
              event.modifierFlags.contains(.control), !event.modifierFlags.contains(.command)
        else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    /// The cursor's cell, in this view's coordinates: where marked text is shown and input methods put candidates.
    package var cursorRect: NSRect {
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
    @objc package func paste(_: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        channel.send(.paste(text))
    }

    /// ⌘C and ⌘X: in Visual mode, yank or delete into the `+` register, which nvim keeps in the system clipboard.
    @objc package func copy(_: Any?) {
        if isVisual { channel.send(keys: "\"+y") }
    }

    @objc package func cut(_: Any?) {
        if isVisual { channel.send(keys: "\"+d") }
    }

    private var isVisual: Bool { screen.mode.hasPrefix("visual") || screen.mode.hasPrefix("select") }

    // MARK: Mouse

    private lazy var scroll = ScrollAccumulator(lineHeight: metrics.height, columnWidth: metrics.width)
    /// The grid a button was pressed in: drags and the release go to it, in its coordinates, wherever the pointer is.
    private var pressed: (grid: Int, rowOffset: Int, colOffset: Int)?

    override package func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onFocus?()
        mouse(event, button: "left", action: "press")
    }

    override package func mouseDragged(with event: NSEvent) { mouse(event, button: "left", action: "drag") }
    override package func mouseUp(with event: NSEvent) { mouse(event, button: "left", action: "release") }
    /// The right-click menu, made by the app (it knows the folder and runs commands in a terminal).
    package var contextMenu: (() -> NSMenu)?

    /// Right-click: the cursor goes where the click is (unless a selection is being made), then sill's menu.
    override package func rightMouseDown(with event: NSEvent) {
        guard let contextMenu else {
            mouse(event, button: "right", action: "press")
            return
        }
        if !(screen.mode.hasPrefix("visual") || screen.mode.hasPrefix("select")) {
            mouse(event, button: "left", action: "press")
            mouse(event, button: "left", action: "release")
        }
        NSMenu.popUpContextMenu(contextMenu(), with: event, for: self)
    }

    override package func otherMouseDown(with event: NSEvent) { mouse(event, button: "middle", action: "press") }
    override package func otherMouseDragged(with event: NSEvent) { mouse(event, button: "middle", action: "drag") }
    override package func otherMouseUp(with event: NSEvent) { mouse(event, button: "middle", action: "release") }

    // Separators: nvim resizes windows when their separators are dragged (grid 1 holds them); the pointer says so.

    override package func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override package func mouseMoved(with event: NSEvent) {
        separatorCursor(event)?.set() ?? NSCursor.iBeam.set()
        hover(event)
    }

    /// The pointer rested on an expression (the debugger shows its value while paused): the expression and the cells
    /// it is drawn in, in this view's coordinates.
    package var onHover: ((_ expression: String, _ rect: NSRect) -> Void)?
    /// The pointer left it.
    package var onHoverEnd: (() -> Void)?
    private var hovered: String?
    private var hoverWait: Task<Void, Never>?

    private func hover(_ event: NSEvent) {
        guard onHover != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        let row = Int(point.y / metrics.height), col = Int(point.x / metrics.width)
        let hit = screen.hit(row: row, col: col)
        var expression: String?
        if let grid = screen.grids[hit.grid], hit.row >= 0, hit.row < grid.rows, hit.col >= 0, hit.col < grid.cols {
            let line = (0 ..< grid.cols).map { grid[hit.row, $0].text.first ?? " " }
            expression = HoverExpression.at(line, col: hit.col)
        }
        guard expression != hovered else { return }
        hovered = expression
        hoverWait?.cancel()
        onHoverEnd?()
        guard let expression else { return }
        let rect = NSRect(
            x: CGFloat(col) * metrics.width,
            y: CGFloat(row) * metrics.height,
            width: metrics.width,
            height: metrics.height
        )
        // Resting, not passing over: a moment before asking.
        hoverWait = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, self?.hovered == expression else { return }
            self?.onHover?(expression, rect)
        }
    }

    /// The resize cursor over a separator nvim draws: │ between side-by-side windows, ─ between stacked ones.
    package func separatorCursor(_ event: NSEvent) -> NSCursor? {
        let point = convert(event.locationInWindow, from: nil)
        let row = Int(point.y / metrics.height), col = Int(point.x / metrics.width)
        guard screen.hit(row: row, col: col).grid == 1, let grid = screen.grids[1], row < grid.rows, col < grid.cols
        else { return nil }
        switch grid[row, col].text {
        case "│", "┤", "├": return .resizeLeftRight
        case "─", "┬", "┴": return .resizeUpDown
        default: return nil
        }
    }

    override package func scrollWheel(with event: NSEvent) {
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

    override package func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        submit()
        return accepted
    }

    override package func resignFirstResponder() -> Bool {
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
    package func insertText(_ string: Any, replacementRange _: NSRange) {
        handledByInputMethod = true
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedText = ""
        showMarkedText()
        guard !text.isEmpty else { return }
        channel.send(keys: text.replacingOccurrences(of: "<", with: "<lt>"))
    }

    package func setMarkedText(_ string: Any, selectedRange _: NSRange, replacementRange _: NSRange) {
        handledByInputMethod = true
        markedText = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        showMarkedText()
    }

    package func unmarkText() {
        markedText = ""
        showMarkedText()
    }

    package func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    package func markedRange() -> NSRange {
        markedText.isEmpty ? NSRange(location: NSNotFound, length: 0) :
            NSRange(location: 0, length: (markedText as NSString).length)
    }

    package func hasMarkedText() -> Bool { !markedText.isEmpty }

    package func attributedSubstring(
        forProposedRange _: NSRange,
        actualRange _: NSRangePointer?
    ) -> NSAttributedString? {
        nil
    }

    package func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    /// Where the input method puts its candidate window: under the cursor's cell, on screen.
    package func firstRect(forCharacterRange _: NSRange, actualRange _: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(cursorRect, to: nil))
    }

    package func characterIndex(for _: NSPoint) -> Int { NSNotFound }

    override package func doCommand(by _: Selector) {
        // Keys AppKit turns into editing commands (Return, arrows) were already sent by keyDown; leaving this empty
        // also keeps the system beep away.
        handledByInputMethod = true
    }
}

/// Marked text at the cursor while an input method composes, underlined as macOS shows composition.
package final class MarkedTextView: NSView {
    private var metrics: CellMetrics { EditorFont.metrics }
    package var text = "" {
        didSet { needsDisplay = true }
    }

    package init() {
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    package required init?(coder _: NSCoder) { fatalError("not used") }

    override package var isFlipped: Bool { true }

    private var attributed: NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: metrics.regular, .foregroundColor: NSColor.white,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
    }

    override package var fittingSize: NSSize {
        NSSize(width: ceil(attributed.size().width) + 2, height: metrics.height)
    }

    override package func draw(_: NSRect) {
        NSColor(white: 0.15, alpha: 1).setFill()
        bounds.fill()
        attributed.draw(at: NSPoint(x: 1, y: metrics.textOffset))
    }
}
