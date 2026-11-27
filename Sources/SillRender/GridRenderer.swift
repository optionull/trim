import AppKit
import CoreText
import Metal
import SillCore
import TrimDiagram

/// What one frame draws: a screen, the grids terminal panes cover, and the cursor.
public struct Frame: Sendable {
    public var screen: Screen
    /// Grids not to draw: those under a terminal pane.
    public var covered: Set<Int>
    public var cursor: Cursor?
    /// Windows paint their blank cells too, covering what grid 1 holds under them. Off, a window's blank cells are
    /// left to what is under them, which is what a terminal pane drawn beneath relies on; on, nothing that was once
    /// drawn on grid 1 (a status line that went away) can show through.
    public var windowsCover = false

    /// The cursor as nvim's `mode_info_set` describes it for the current mode.
    public struct Cursor: Sendable, Equatable {
        public enum Shape: Sendable, Equatable { case block, vertical, horizontal }
        public var shape: Shape
        /// How much of the cell a vertical or horizontal cursor takes, in percent.
        public var percentage: Int
        /// The cursor's highlight; 0 shows the cell under it in reverse.
        public var highlight: Int

        public init(shape: Shape, percentage: Int = 100, highlight: Int = 0) {
            self.shape = shape
            self.percentage = percentage
            self.highlight = highlight
        }
    }

    /// Windows sliding to where nvim scrolled them, by grid.
    public var scrolls: [Int: ScrollAnimation] = [:]

    /// A window part-way through a smooth scroll: the rows it showed before, how many lines it moved (down positive),
    /// and how far along the slide is, 0 to 1.
    public struct ScrollAnimation: Sendable {
        public var previous: GridBuffer
        public var lines: Int
        public var progress: Float

        public init(previous: GridBuffer, lines: Int, progress: Float) {
            self.previous = previous
            self.lines = lines
            self.progress = progress
        }
    }

    public init(screen: Screen, covered: Set<Int> = [], cursor: Cursor? = nil) {
        self.screen = screen
        self.covered = covered
        self.cursor = cursor
    }
}

/// Timings of the last frame the renderer built, for the benchmark and the debug overlay.
public struct FrameStats: Sendable {
    /// CPU time spent turning the screen into instances.
    public var buildMilliseconds = 0.0
    /// Rows built this frame; the rest came from the row cache.
    public var rowsBuilt = 0
    public var rowsReused = 0
    public var rects = 0
    public var glyphs = 0
    /// Glyphs in rebuilt rows that span more than one cell: ligatures and double-width characters.
    public var multiCellGlyphs = 0
}

struct RectInstance {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var color: SIMD4<Float>
    var kind: UInt32 = 0
    var thickness: Float = 0

    static let fill: UInt32 = 0
    static let underline: UInt32 = 1
    static let undercurl: UInt32 = 2
    static let dotted: UInt32 = 3
    static let dashed: UInt32 = 4
    static let border: UInt32 = 5
    static let cardTop: UInt32 = 6
    static let cardMiddle: UInt32 = 7
    static let cardBottom: UInt32 = 8
}

struct GlyphInstance {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var atlasOrigin: SIMD2<Float>
    var atlasSize: SIMD2<Float>
    var color: SIMD4<Float>
    var colored: UInt32
}

/// Draws screens with Metal: per-row instances (backgrounds, glyphs, decorations) built on the CPU and cached by row
/// version, then two instanced passes per grid in multigrid drawing order. Not thread-safe: one thread uses it.
public final class GridRenderer {
    public let device: MTLDevice
    public let queue: MTLCommandQueue
    /// Cell size in points.
    public let cellSize: CGSize
    public let scale: CGFloat
    public private(set) var stats = FrameStats()

    private let rectPipeline: MTLRenderPipelineState
    private let glyphPipeline: MTLRenderPipelineState
    private let atlas: GlyphAtlas
    private let cellWidth: Float
    private let cellHeight: Float
    private let lineThickness: Float

    /// What was built for each row, by grid and row, with the row version it was built from.
    private var rows: [RowKey: Row] = [:]
    private var rowsStyle: Style?

    // MARK: Moving diagrams

    private let diagramLock = NSLock()
    private var diagramFrames: [Int: DiagramImage] = [:]
    private var shownDiagrams: Set<Int> = []
    private var onShown: (@Sendable () -> Void)?

    /// The diagrams with rows in the last frame built.
    public var visibleDiagrams: Set<Int> {
        diagramLock.lock()
        defer { diagramLock.unlock() }
        return shownDiagrams
    }

    /// Called (on the render thread) when a frame built has a moving diagram in it: what starts the clock that plays
    /// it.
    public func onMovingDiagramShown(_ body: (@Sendable () -> Void)?) {
        diagramLock.lock()
        onShown = body
        diagramLock.unlock()
    }

    /// A new frame of diagram `id`, to be put in the atlas by the next frame built (ask for one to be drawn).
    public func submitDiagramFrame(id: Int, image: DiagramImage) {
        diagramLock.lock()
        diagramFrames[id] = image
        diagramLock.unlock()
    }

    private func takeDiagramFrames() -> [Int: DiagramImage] {
        diagramLock.lock()
        defer { diagramLock.unlock() }
        let frames = diagramFrames
        diagramFrames = [:]
        return frames
    }

    private func publishShown(_ shown: Set<Int>) {
        diagramLock.lock()
        shownDiagrams = shown
        let callback = onShown
        diagramLock.unlock()
        if let callback, shown.contains(where: { DiagramStore.shared.entry($0)?.playback != nil }) { callback() }
    }

    private var rowsGeneration = -1
    private var shapes: [ShapeKey: [ShapedGlyph]] = [:]

    private struct RowKey: Hashable {
        let grid: Int
        let row: Int
    }

    private struct Row {
        var version: UInt64
        /// Built with the default background drawn (for a float or the message grid).
        var covers: Bool
        var backgrounds: [RectInstance]
        var glyphs: [GlyphInstance]
        var decorations: [RectInstance]
        /// The diagrams whose rows these are.
        var diagrams: [Int] = []
    }

    private struct ShapeKey: Hashable {
        let text: String
        let bold: Bool
        let italic: Bool
    }

    /// What every cached row depends on besides its cells.
    private struct Style: Equatable {
        var highlights: [Int: Highlight]
        var foreground: Int
        var background: Int
    }

    public init(device: MTLDevice, font: NSFont, cellSize: CGSize, scale: CGFloat, pixelFormat: MTLPixelFormat) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw RenderError.noQueue }
        self.queue = queue
        self.cellSize = cellSize
        self.scale = scale
        cellWidth = Float(cellSize.width * scale)
        cellHeight = Float(cellSize.height * scale)
        lineThickness = Float(max(1, (CTFontGetUnderlineThickness(font as CTFont) * scale).rounded()))
        atlas = GlyphAtlas(device: device, font: font, cellSize: cellSize, scale: scale)

        let library = try device.makeLibrary(source: Shaders.source, options: nil)
        func pipeline(_ vertex: String, _ fragment: String) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = pixelFormat
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        rectPipeline = try pipeline("rect_vertex", "rect_fragment")
        glyphPipeline = try pipeline("glyph_vertex", "glyph_fragment")
    }

    /// The colour the screen is cleared to.
    public func clearColor(_ screen: Screen) -> MTLClearColor {
        let color = Self.color(screen.defaultBackground)
        return MTLClearColor(red: Double(color.x), green: Double(color.y), blue: Double(color.z), alpha: 1)
    }

    /// Encodes `frame` into a render pass whose target is `viewport` pixels.
    public func encode(_ frame: Frame, into encoder: MTLRenderCommandEncoder, viewport: CGSize) {
        let start = DispatchTime.now().uptimeNanoseconds
        let layers = build(frame)
        stats.buildMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000

        var uniforms = SIMD2<Float>(Float(viewport.width), Float(viewport.height))
        let rectBuffer = buffer(layers.rects)
        let glyphBuffer = buffer(layers.glyphs)
        encoder.setFragmentTexture(atlas.coverage, index: 0)
        encoder.setFragmentTexture(atlas.color, index: 1)
        let full = MTLScissorRect(x: 0, y: 0, width: Int(viewport.width), height: Int(viewport.height))
        for layer in layers.order {
            encoder.setScissorRect(layer.clip ?? full)
            if !layer.backgrounds.isEmpty, let rectBuffer {
                draw(encoder, rectPipeline, rectBuffer, layer.backgrounds, MemoryLayout<RectInstance>.stride, &uniforms)
            }
            if !layer.glyphs.isEmpty, let glyphBuffer {
                draw(encoder, glyphPipeline, glyphBuffer, layer.glyphs, MemoryLayout<GlyphInstance>.stride, &uniforms)
            }
            if !layer.decorations.isEmpty, let rectBuffer {
                draw(encoder, rectPipeline, rectBuffer, layer.decorations, MemoryLayout<RectInstance>.stride, &uniforms)
            }
            // The cursor goes over its grid, and the character under a block cursor over the cursor.
            if !layer.cursor.isEmpty, let rectBuffer {
                draw(encoder, rectPipeline, rectBuffer, layer.cursor, MemoryLayout<RectInstance>.stride, &uniforms)
            }
            if !layer.cursorGlyph.isEmpty, let glyphBuffer {
                draw(
                    encoder,
                    glyphPipeline,
                    glyphBuffer,
                    layer.cursorGlyph,
                    MemoryLayout<GlyphInstance>.stride,
                    &uniforms
                )
            }
        }
    }

    /// Renders `frame` into `texture` and returns the committed command buffer: for tests and screenshots.
    public func render(_ frame: Frame, to texture: MTLTexture) -> MTLCommandBuffer? {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = clearColor(frame.screen)
        guard let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encode(frame, into: encoder, viewport: CGSize(width: texture.width, height: texture.height))
        encoder.endEncoding()
        commands.commit()
        return commands
    }

    /// Renders flame graph blocks, one row per depth, `rowHeight` pixels each, into `texture`.
    public func render(
        _ blocks: [FlameGraph.Block], rowHeight: Float, to texture: MTLTexture, background: Int
    ) -> MTLCommandBuffer? {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let clear = Self.color(background)
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(clear.x), green: Double(clear.y), blue: Double(clear.z), alpha: 1
        )
        guard let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        let start = DispatchTime.now().uptimeNanoseconds
        // Hot to cool by name, as flame graphs are; merged blocks are greyed so aggregation shows.
        let rects = blocks.map { block -> RectInstance in
            let hue = Float((block.node &* 2_654_435_761) % 1000) / 1000
            let color: SIMD4<Float> = block.merged ? [0.45, 0.45, 0.48, 1] : [
                0.85 + 0.15 * hue,
                0.3 + 0.5 * hue,
                0.15,
                1,
            ]
            return RectInstance(
                origin: [block.x, Float(block.depth) * rowHeight], size: [max(block.width - 0.5, 1), rowHeight - 1],
                color: color
            )
        }
        stats.buildMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        stats.rects = rects.count
        if let buffer = buffer(rects) {
            var uniforms = SIMD2<Float>(Float(texture.width), Float(texture.height))
            draw(encoder, rectPipeline, buffer, 0 ..< rects.count, MemoryLayout<RectInstance>.stride, &uniforms)
        }
        encoder.endEncoding()
        commands.commit()
        return commands
    }

    private func draw(
        _ encoder: MTLRenderCommandEncoder, _ pipeline: MTLRenderPipelineState, _ buffer: MTLBuffer,
        _ range: Range<Int>, _ stride: Int, _ uniforms: inout SIMD2<Float>
    ) {
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(buffer, offset: range.lowerBound * stride, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: range.count)
    }

    private func buffer(_ items: [some Any]) -> MTLBuffer? {
        guard !items.isEmpty else { return nil }
        return items.withUnsafeBytes { device.makeBuffer(
            bytes: $0.baseAddress!,
            length: $0.count,
            options: .storageModeShared
        ) }
    }

    // MARK: Building instances

    private struct Layer {
        var backgrounds: Range<Int>
        var glyphs: Range<Int>
        var decorations: Range<Int>
        var cursor: Range<Int> = 0 ..< 0
        var cursorGlyph: Range<Int> = 0 ..< 0
        /// Pixels to clip the layer to: a window part-way through a smooth scroll.
        var clip: MTLScissorRect?
    }

    private struct Layers {
        var rects: [RectInstance] = []
        var glyphs: [GlyphInstance] = []
        var order: [Layer] = []
    }

    private func build(_ frame: Frame) -> Layers {
        let screen = frame.screen
        let style = Style(
            highlights: screen.highlights, foreground: screen.defaultForeground, background: screen.defaultBackground
        )
        if style != rowsStyle || atlas.generation != rowsGeneration {
            rows.removeAll(keepingCapacity: true)
            rowsStyle = style
            rowsGeneration = atlas.generation
        }
        stats.rowsBuilt = 0
        stats.rowsReused = 0
        stats.multiCellGlyphs = 0
        // Frames of moving diagrams that came since the last build go into the atlas, here on the render thread.
        for (id, image) in takeDiagramFrames() {
            atlas.replaceImage(id: id, with: image)
        }
        var shown = Set<Int>()
        defer { publishShown(shown) }

        var layers = Layers()
        var decorations: [RectInstance] = []
        var live = Set<RowKey>()
        let screenRows = screen.grids[1]?.rows ?? 0
        for (grid, placement) in screen.drawOrder where !frame.covered.contains(grid) {
            guard let buffer = screen.grids[grid] else { continue }
            // The message grid is as tall as the screen and starts part-way down: only what fits is drawn.
            let visible = min(buffer.rows, max(screenRows - placement.row, 0))
            let backgroundStart = layers.rects.count, glyphStart = layers.glyphs.count
            decorations.removeAll(keepingCapacity: true)
            // Floats and the message grid cover what is under them, so their rows draw the default background too.
            let covers = placement.kind != .window || frame.windowsCover
            /// Adds a row of `source` (cached under `key`) at `y` pixels from the grid's top.
            func add(_ source: GridBuffer, row: Int, key: RowKey, y: Float) {
                live.insert(key)
                let built: Row
                if let cached = rows[key], cached.version == source.rowVersions[row], cached.covers == covers {
                    built = cached
                    stats.rowsReused += 1
                } else {
                    built = buildRow(source, row: row, style: style, covers: covers)
                    rows[key] = built
                    stats.rowsBuilt += 1
                }
                let offset = SIMD2<Float>(Float(placement.col) * cellWidth, Float(placement.row) * cellHeight + y)
                shown.formUnion(built.diagrams)
                for var rect in built.backgrounds {
                    rect.origin += offset
                    layers.rects.append(rect)
                }
                for var glyph in built.glyphs {
                    glyph.origin += offset
                    layers.glyphs.append(glyph)
                }
                for var rect in built.decorations {
                    rect.origin += offset
                    decorations.append(rect)
                }
            }
            // A smooth scroll: the rows slide by what is left of the move, and the rows they have not yet covered
            // come from before it. Old row i goes where new row i - lines is, so the content moves as one piece.
            var slide: Float = 0
            let scroll = placement.kind == .window ? frame.scrolls[grid] : nil
            if let scroll, scroll.progress < 1 {
                slide = Float(scroll.lines) * cellHeight * (1 - scroll.progress)
                let previous = scroll.previous
                for row in 0 ..< min(previous.rows, visible)
                    where row - scroll.lines < 0 || row - scroll.lines >= visible
                {
                    add(
                        previous,
                        row: row,
                        key: RowKey(grid: -grid, row: row),
                        y: Float(row - scroll.lines) * cellHeight + slide
                    )
                }
            }
            for row in 0 ..< visible {
                add(buffer, row: row, key: RowKey(grid: grid, row: row), y: Float(row) * cellHeight + slide)
            }
            let decorationStart = layers.rects.count
            layers.rects.append(contentsOf: decorations)
            var layer = Layer(
                backgrounds: backgroundStart ..< decorationStart, glyphs: glyphStart ..< layers.glyphs.count,
                decorations: decorationStart ..< layers.rects.count
            )
            if slide != 0 {
                layer.clip = MTLScissorRect(
                    x: Int(Float(placement.col) * cellWidth), y: Int(Float(placement.row) * cellHeight),
                    width: Int(Float(placement.width) * cellWidth), height: Int(Float(visible) * cellHeight)
                )
            }
            if grid == screen.cursorGrid, let cursor = frame.cursor, slide == 0 {
                let (rect, glyph) = cursorInstances(cursor, buffer: buffer, screen: screen, placement: placement)
                layer.cursor = layers.rects.count ..< layers.rects.count + 1
                layers.rects.append(rect)
                if let glyph {
                    layer.cursorGlyph = layers.glyphs.count ..< layers.glyphs.count + 1
                    layers.glyphs.append(glyph)
                }
            }
            layers.order.append(layer)
        }
        // Rows of grids that are gone, or rows past a grid's new end.
        if rows.count > live.count {
            rows = rows.filter { live.contains($0.key) }
        }
        stats.rects = layers.rects.count
        stats.glyphs = layers.glyphs.count
        return layers
    }

    /// The cursor's rect, and for a block cursor the character under it drawn in the cursor's text colour.
    private func cursorInstances(
        _ cursor: Frame.Cursor, buffer: GridBuffer, screen: Screen, placement: Placement
    ) -> (RectInstance, GlyphInstance?) {
        let (row, col) = (screen.cursorRow, screen.cursorCol)
        let inside = row < buffer.rows && col < buffer.cols
        let cell = inside ? buffer[row, col] : Cell.blank
        // The cell's own colours, which the default cursor (highlight 0) shows reversed.
        let cellHighlight = screen.highlights[cell.hl] ?? Highlight()
        // On a scaled row the cursor is as many times as wide and tall, at that many times the column.
        let factor = inside ? cellHighlight.scale : 1
        var x = Float(placement.col + col) * cellWidth, y = Float(placement.row + row) * cellHeight
        if let offsets = Self.columnOffsets(buffer, row: row, highlights: screen.highlights), col < offsets.count {
            x = (Float(placement.col) + offsets[col]) * cellWidth
        }
        let cellWidth = cellWidth * factor, cellHeight = cellHeight * factor
        var cellForeground = cellHighlight.foreground ?? screen.defaultForeground
        var cellBackground = cellHighlight.background ?? screen.defaultBackground
        if cellHighlight.reverse { swap(&cellForeground, &cellBackground) }
        var fill = cellForeground, text = cellBackground
        if cursor.highlight != 0, let style = screen.highlights[cursor.highlight] {
            fill = style.background ?? fill
            text = style.foreground ?? text
            if style.reverse { swap(&fill, &text) }
        }
        let fraction = Float(min(max(cursor.percentage, 1), 100)) / 100
        switch cursor.shape {
        case .vertical where fraction < 1:
            let width = max(Float(scale), (cellWidth * fraction).rounded())
            return (RectInstance(origin: [x, y], size: [width, cellHeight], color: Self.color(fill)), nil)
        case .horizontal where fraction < 1:
            let height = max(Float(scale), (cellHeight * fraction).rounded())
            return (RectInstance(
                origin: [x, y + cellHeight - height], size: [cellWidth, height], color: Self.color(fill)
            ), nil)
        default:
            let wide = inside && col + 1 < buffer.cols && buffer[row, col + 1].text.isEmpty
            let rect = RectInstance(
                origin: [x, y], size: [cellWidth * (wide ? 2 : 1), cellHeight], color: Self.color(fill)
            )
            guard inside, !cell.text.isEmpty, cell.text != " " else { return (rect, nil) }
            let region = atlas.region(
                text: cell.text, bold: cellHighlight.bold, italic: cellHighlight.italic, cellCount: wide ? 2 : 1,
                factor: CGFloat(factor)
            )
            return (rect, GlyphInstance(
                origin: [x, y], size: [region.width, region.height], atlasOrigin: [region.x, region.y],
                atlasSize: [region.width, region.height], color: Self.color(text), colored: region.colored ? 1 : 0
            ))
        }
    }

    /// For the row being built: where each column starts, in cells, when some of its cells are scaled (each takes its
    /// scale's
    /// width, so what follows a scaled run starts after it, not under it); nil for an ordinary row.
    private var offsets: [Float]?

    /// Where column `col` of the row being built starts, in points of pixels from the grid's left.
    private func columnX(_ col: Int) -> Float {
        guard let offsets else { return Float(col) * cellWidth }
        return offsets[min(max(col, 0), offsets.count - 1)] * cellWidth
    }

    /// The column offsets of a row with scaled cells: the running sum of their scales; nil when none is.
    static func columnOffsets(_ buffer: GridBuffer, row: Int, highlights: [Int: Highlight]) -> [Float]? {
        var result: [Float] = [0]
        var scaled = false
        for col in 0 ..< buffer.cols {
            let scale = highlights[buffer[row, col].hl]?.scale ?? 1
            if scale != 1 { scaled = true }
            result.append(result[col] + scale)
        }
        return scaled ? result : nil
    }

    /// Instances for one row, positioned from the row's top-left corner.
    private func buildRow(_ buffer: GridBuffer, row: Int, style: Style, covers: Bool) -> Row {
        var built = Row(version: buffer.rowVersions[row], covers: covers, backgrounds: [], glyphs: [], decorations: [])
        let cols = buffer.cols
        offsets = Self.columnOffsets(buffer, row: row, highlights: style.highlights)
        defer { offsets = nil }
        var col = 0
        let cardFill = cardFill(buffer, row: row, style: style)
        var overCard: [RectInstance] = []
        while col < cols {
            let hl = buffer[row, col].hl
            var end = col + 1
            while end < cols, buffer[row, end].hl == hl {
                end += 1
            }
            let highlight = style.highlights[hl] ?? Highlight()
            var foreground = highlight.foreground ?? style.foreground
            var background = highlight.background ?? style.background
            if highlight.reverse { swap(&foreground, &background) }
            let x = columnX(col), width = columnX(end) - columnX(col)
            if highlight.scale != 1 {
                // A scaled run: `scale` cells to a character, from a font that many times the size, over this row and
                // the blank one under it (its underline there too).
                let scale = highlight.scale
                if covers || background != style.background {
                    var color = Self.color(background)
                    color.w = highlight.altfont ? 1 : 1 - Float(highlight.blend) / 100
                    built.backgrounds.append(RectInstance(origin: [x, 0], size: [width, cellHeight], color: color))
                }
                appendScaledGlyphs(
                    buffer, row: row, cols: col ..< end, highlight: highlight, color: foreground, to: &built
                )
                appendDecorations(
                    highlight, x: x, width: min(width, Float(cols) * cellWidth - x), foreground: foreground,
                    to: &built, factor: scale
                )
                col = end
                continue
            }
            // A card's cells have the block's fill, drawn by the card's own rounded shape (below), so what is under it
            // is the
            // page; any other background inside a card (a diff's added line) is a plain rect.
            var inCard = false
            if highlight.card != nil {
                if background == cardFill { background = style.background } else { inCard = true }
            }
            if covers || background != style.background {
                var color = Self.color(background)
                // (`blend` on a marked run is a size, a box or a card, not a transparency.)
                color.w = highlight.altfont ? 1 : 1 - Float(highlight.blend) / 100
                let rect = RectInstance(origin: [x, 0], size: [width, cellHeight], color: color)
                // A background inside a card goes over the card's fill, which is drawn below.
                if inCard { overCard.append(rect) } else { built.backgrounds.append(rect) }
            }
            appendGlyphs(buffer, row: row, cols: col ..< end, highlight: highlight, color: foreground, to: &built)
            appendDecorations(highlight, x: x, width: width, foreground: foreground, to: &built)
            col = end
        }
        appendBoxes(buffer, row: row, style: style, to: &built)
        appendCards(buffer, row: row, style: style, to: &built)
        built.backgrounds.append(contentsOf: overCard)
        return built
    }

    /// The fill of a row's card: the background of its first card cell, or nil when the row has none.
    private func cardFill(_ buffer: GridBuffer, row: Int, style: Style) -> Int? {
        for col in 0 ..< buffer.cols {
            if let highlight = style.highlights[buffer[row, col].hl], highlight.card != nil {
                return highlight.background ?? style.background
            }
        }
        return nil
    }

    /// A card's row: one rounded, shaded rect over the stretch of its cells, in the card's fill, and along the bottom
    /// row's
    /// bottom edge a line in its special colour (inset from the corners).
    private func appendCards(_ buffer: GridBuffer, row: Int, style: Style, to built: inout Row) {
        var col = 0
        while col < buffer.cols {
            guard let first = style.highlights[buffer[row, col].hl], let edge = first.card else {
                col += 1
                continue
            }
            var end = col + 1
            while end < buffer.cols, style.highlights[buffer[row, end].hl]?.card != nil {
                end += 1
            }
            let kind = edge == .top ? RectInstance.cardTop : edge == .middle ? RectInstance.cardMiddle : RectInstance
                .cardBottom
            let x = columnX(col), width = columnX(end) - columnX(col)
            built.backgrounds.append(RectInstance(
                origin: [x, 0], size: [width, cellHeight], color: Self.color(first.background ?? style.background),
                kind: kind, thickness: Float(scale)
            ))
            if edge == .bottom, let special = first.special {
                let inset = 10 * Float(scale), line = 2 * Float(scale)
                built.decorations.append(RectInstance(
                    origin: [x + inset, cellHeight - line - Float(scale)], size: [max(width - inset * 2, 0), line],
                    color: Self.color(special)
                ))
            }
            col = end
        }
    }

    /// A rounded outline round each stretch of cells whose highlight is a box (inline code): one outline for the
    /// stretch,
    /// whatever the highlights inside it, in the highlight's special colour (else its text colour).
    private func appendBoxes(_ buffer: GridBuffer, row: Int, style: Style, to built: inout Row) {
        var col = 0
        while col < buffer.cols {
            guard let first = style.highlights[buffer[row, col].hl], first.boxed else {
                col += 1
                continue
            }
            var end = col + 1
            while end < buffer.cols, style.highlights[buffer[row, end].hl]?.boxed == true {
                end += 1
            }
            let inset = Float(scale)
            let color = Self.color(first.special ?? first.foreground ?? style.foreground)
            built.decorations.append(RectInstance(
                origin: [columnX(col) + inset, inset],
                size: [columnX(end) - columnX(col) - inset * 2, cellHeight - inset * 2], color: color,
                kind: RectInstance.border, thickness: lineThickness
            ))
            col = end
        }
    }

    /// Glyphs for a run of cells with one highlight: shaped in segments (for ligatures), with double-width cells on
    /// their own.
    private func appendGlyphs(
        _ buffer: GridBuffer, row: Int, cols: Range<Int>, highlight: Highlight, color: Int, to built: inout Row
    ) {
        let color = Self.color(color)
        var segment = "", segmentStart = cols.lowerBound
        func flush() {
            guard segment.contains(where: { $0 != " " }) else {
                segment = ""
                return
            }
            for glyph in shape(segment, highlight) where glyph.text != " " {
                emit(glyph.text, col: segmentStart + glyph.colOffset, cells: glyph.cellCount)
                if glyph.cellCount > 1 { stats.multiCellGlyphs += 1 }
            }
            segment = ""
        }
        func emit(_ text: String, col: Int, cells: Int) {
            let region = atlas.region(text: text, bold: highlight.bold, italic: highlight.italic, cellCount: cells)
            built.glyphs.append(GlyphInstance(
                origin: [columnX(col), 0], size: [region.width, region.height],
                atlasOrigin: [region.x, region.y], atlasSize: [region.width, region.height], color: color,
                colored: region.colored ? 1 : 0
            ))
        }
        var col = cols.lowerBound
        while col < cols.upperBound {
            let text = buffer[row, col].text
            let wide = col + 1 < buffer.cols && buffer[row, col + 1].text.isEmpty
            if text.isEmpty {
                col += 1 // The right half of a double-width cell before this run.
                continue
            }
            if let (id, slice) = DiagramStore.decode(text) {
                // A row of a diagram: its slice of the picture, from here to the right (the cells after it are blank).
                flush()
                emitDiagram(id: id, slice: slice, col: col, to: &built)
                col += 1
                segmentStart = col
                continue
            }
            if wide {
                flush()
                emit(text, col: col, cells: 2)
                col += 2
                segmentStart = col
                continue
            }
            if segment.isEmpty { segmentStart = col }
            segment += text
            col += 1
        }
        flush()
    }

    /// Glyphs of a scaled run, each at `scale` times the size and the advance; what would run past the grid's edge is
    /// not
    /// drawn.
    private func appendScaledGlyphs(
        _ buffer: GridBuffer, row: Int, cols: Range<Int>, highlight: Highlight, color: Int, to built: inout Row
    ) {
        let color = Self.color(color)
        let scale = highlight.scale
        let limit = Float(buffer.cols) * cellWidth
        var col = cols.lowerBound
        while col < cols.upperBound {
            let text = buffer[row, col].text
            let wide = col + 1 < buffer.cols && buffer[row, col + 1].text.isEmpty
            let cells = wide ? 2 : 1
            defer { col += cells }
            let x = columnX(col)
            guard !text.isEmpty, text != " ", x + Float(cells) * scale * cellWidth <= limit else { continue }
            let region = atlas.region(
                text: text, bold: highlight.bold, italic: highlight.italic, cellCount: cells, factor: CGFloat(scale)
            )
            built.glyphs.append(GlyphInstance(
                origin: [x, 0], size: [region.width, region.height], atlasOrigin: [region.x, region.y],
                atlasSize: [region.width, region.height], color: color, colored: region.colored ? 1 : 0
            ))
        }
    }

    /// The slice of diagram `id` that row `slice` of its block shows, at the cell `col`.
    private func emitDiagram(id: Int, slice: Int, col: Int, to built: inout Row) {
        guard let entry = DiagramStore.shared.entry(id),
              let region = atlas.imageRegion(id: id, entry: entry) else { return }
        // The picture was drawn for some scale; where the screen's is another it is stretched to the same size in
        // points.
        let ratio = Float(scale) / Float(entry.image.scale)
        let sliceHeight = (cellHeight / ratio).rounded()
        let top = Float(slice) * sliceHeight
        guard top < region.height else { return }
        let height = min(sliceHeight, region.height - top)
        built.diagrams.append(id)
        built.glyphs.append(GlyphInstance(
            origin: [columnX(col), 0], size: [region.width * ratio, height * ratio],
            atlasOrigin: [region.x, region.y + top], atlasSize: [region.width, height], color: [1, 1, 1, 1], colored: 1
        ))
    }

    private func shape(_ text: String, _ highlight: Highlight) -> [ShapedGlyph] {
        let key = ShapeKey(text: text, bold: highlight.bold, italic: highlight.italic)
        if let shaped = shapes[key] { return shaped }
        if shapes.count > 20000 { shapes.removeAll(keepingCapacity: true) }
        let shaped = atlas.shape(text, bold: highlight.bold, italic: highlight.italic)
        shapes[key] = shaped
        return shaped
    }

    private func appendDecorations(
        _ highlight: Highlight, x: Float, width: Float, foreground: Int, to built: inout Row, factor: Float = 1
    ) {
        let color = Self.color(highlight.special ?? foreground)
        let thickness = lineThickness * factor
        let cellHeight = cellHeight * factor
        if highlight.undercurl {
            let band = max(thickness * 3, 3 * Float(scale))
            built.decorations.append(RectInstance(
                origin: [x, cellHeight - band], size: [width, band], color: color, kind: RectInstance.undercurl,
                thickness: thickness
            ))
        } else if highlight.underdouble {
            for offset in [thickness * 3, thickness] {
                built.decorations.append(RectInstance(
                    origin: [x, cellHeight - offset], size: [width, thickness], color: color,
                    kind: RectInstance.underline, thickness: thickness
                ))
            }
        } else if highlight.underdotted || highlight.underdashed {
            built.decorations.append(RectInstance(
                origin: [x, cellHeight - thickness * 2], size: [width, thickness], color: color,
                kind: highlight.underdotted ? RectInstance.dotted : RectInstance.dashed, thickness: thickness
            ))
        } else if highlight.underline {
            built.decorations.append(RectInstance(
                origin: [x, cellHeight - thickness * 2], size: [width, thickness], color: color,
                kind: RectInstance.underline, thickness: thickness
            ))
        }
        if highlight.strikethrough {
            built.decorations.append(RectInstance(
                origin: [x, (cellHeight - thickness) / 2], size: [width, thickness],
                color: Self.color(foreground), kind: RectInstance.underline, thickness: thickness
            ))
        }
    }

    static func color(_ rgb: Int) -> SIMD4<Float> {
        SIMD4(Float((rgb >> 16) & 0xFF) / 255, Float((rgb >> 8) & 0xFF) / 255, Float(rgb & 0xFF) / 255, 1)
    }
}

public enum RenderError: Error {
    case noDevice
    case noQueue
}
