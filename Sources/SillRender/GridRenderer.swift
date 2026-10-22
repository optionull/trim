import AppKit
import CoreText
import Metal
import SillCore

/// What one frame draws: a screen, the grids terminal panes cover, and the cursor.
public struct Frame: Sendable {
    public var screen: Screen
    /// Grids not to draw: those under a terminal pane.
    public var covered: Set<Int>
    public var cursor: Cursor?

    public struct Cursor: Sendable, Equatable {
        public enum Shape: Sendable, Equatable { case block, bar, underline }
        public var shape: Shape

        public init(shape: Shape) { self.shape = shape }
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
    private var rowsGeneration = -1
    private var shapes: [ShapeKey: [ShapedGlyph]] = [:]

    private struct RowKey: Hashable {
        let grid: Int
        let row: Int
    }

    private struct Row {
        var version: UInt64
        var backgrounds: [RectInstance]
        var glyphs: [GlyphInstance]
        var decorations: [RectInstance]
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
        for layer in layers.order {
            if !layer.backgrounds.isEmpty, let rectBuffer {
                draw(encoder, rectPipeline, rectBuffer, layer.backgrounds, MemoryLayout<RectInstance>.stride, &uniforms)
            }
            if !layer.glyphs.isEmpty, let glyphBuffer {
                draw(encoder, glyphPipeline, glyphBuffer, layer.glyphs, MemoryLayout<GlyphInstance>.stride, &uniforms)
            }
            if !layer.decorations.isEmpty, let rectBuffer {
                draw(encoder, rectPipeline, rectBuffer, layer.decorations, MemoryLayout<RectInstance>.stride, &uniforms)
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
            for row in 0 ..< visible {
                let key = RowKey(grid: grid, row: row)
                live.insert(key)
                let built: Row
                if let cached = rows[key], cached.version == buffer.rowVersions[row] {
                    built = cached
                    stats.rowsReused += 1
                } else {
                    built = buildRow(buffer, row: row, style: style)
                    rows[key] = built
                    stats.rowsBuilt += 1
                }
                let offset = SIMD2<Float>(Float(placement.col) * cellWidth, Float(placement.row + row) * cellHeight)
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
            if grid == screen.cursorGrid, let cursor = frame.cursor {
                decorations.append(cursorRect(cursor, screen: screen, placement: placement))
            }
            let decorationStart = layers.rects.count
            layers.rects.append(contentsOf: decorations)
            layers.order.append(Layer(
                backgrounds: backgroundStart ..< decorationStart, glyphs: glyphStart ..< layers.glyphs.count,
                decorations: decorationStart ..< layers.rects.count
            ))
        }
        // Rows of grids that are gone, or rows past a grid's new end.
        if rows.count > live.count {
            rows = rows.filter { live.contains($0.key) }
        }
        stats.rects = layers.rects.count
        stats.glyphs = layers.glyphs.count
        return layers
    }

    private func cursorRect(_ cursor: Frame.Cursor, screen: Screen, placement: Placement) -> RectInstance {
        let x = Float(placement.col + screen.cursorCol) * cellWidth
        let y = Float(placement.row + screen.cursorRow) * cellHeight
        var color = Self.color(screen.defaultForeground)
        color.w = 0.75
        switch cursor.shape {
        case .block:
            return RectInstance(origin: [x, y], size: [cellWidth, cellHeight], color: color)
        case .bar:
            return RectInstance(origin: [x, y], size: [max(2, Float(scale) * 1.5), cellHeight], color: color)
        case .underline:
            let height = max(2, Float(scale) * 1.5)
            return RectInstance(origin: [x, y + cellHeight - height], size: [cellWidth, height], color: color)
        }
    }

    /// Instances for one row, positioned from the row's top-left corner.
    private func buildRow(_ buffer: GridBuffer, row: Int, style: Style) -> Row {
        var built = Row(version: buffer.rowVersions[row], backgrounds: [], glyphs: [], decorations: [])
        let cols = buffer.cols
        var col = 0
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
            let x = Float(col) * cellWidth, width = Float(end - col) * cellWidth
            if background != style.background {
                built.backgrounds.append(RectInstance(
                    origin: [x, 0], size: [width, cellHeight], color: Self.color(background)
                ))
            }
            appendGlyphs(buffer, row: row, cols: col ..< end, highlight: highlight, color: foreground, to: &built)
            appendDecorations(highlight, x: x, width: width, foreground: foreground, to: &built)
            col = end
        }
        return built
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
                origin: [Float(col) * cellWidth, 0], size: [region.width, region.height],
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

    private func shape(_ text: String, _ highlight: Highlight) -> [ShapedGlyph] {
        let key = ShapeKey(text: text, bold: highlight.bold, italic: highlight.italic)
        if let shaped = shapes[key] { return shaped }
        if shapes.count > 20000 { shapes.removeAll(keepingCapacity: true) }
        let shaped = atlas.shape(text, bold: highlight.bold, italic: highlight.italic)
        shapes[key] = shaped
        return shaped
    }

    private func appendDecorations(
        _ highlight: Highlight, x: Float, width: Float, foreground: Int, to built: inout Row
    ) {
        let color = Self.color(highlight.special ?? foreground)
        let thickness = lineThickness
        if highlight.undercurl {
            let band = max(thickness * 3, 3 * Float(scale))
            built.decorations.append(RectInstance(
                origin: [x, cellHeight - band], size: [width, band], color: color, kind: RectInstance.undercurl,
                thickness: thickness
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
