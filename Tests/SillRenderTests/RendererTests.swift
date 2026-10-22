import AppKit
import MessagePack
import Metal
import SillCore
import SillNvim
@testable import SillRender
import Testing

/// Renders screens offscreen and reads the pixels back.
@MainActor
final class Canvas {
    static let metrics = CellMetrics()
    let renderer: GridRenderer
    let cols: Int
    let rows: Int
    let scale: CGFloat = 2
    private(set) var pixels: [UInt8] = []
    private(set) var width = 0

    init(cols: Int = 20, rows: Int = 6) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        renderer = try GridRenderer(
            device: device, font: Self.metrics.regular, cellSize: Self.metrics.cellSize, scale: scale,
            pixelFormat: .bgra8Unorm
        )
        self.cols = cols
        self.rows = rows
    }

    var cellWidth: Int { Int(Self.metrics.width * scale) }
    var cellHeight: Int { Int(Self.metrics.height * scale) }

    func render(_ frame: Frame) throws {
        width = cols * cellWidth
        let height = rows * cellHeight
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try #require(renderer.device.makeTexture(descriptor: descriptor))
        let commands = try #require(renderer.render(frame, to: texture))
        commands.waitUntilCompleted()
        pixels = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    }

    /// The colour at a pixel, as 0xRRGGBB.
    func pixel(x: Int, y: Int) -> Int {
        let index = (y * width + x) * 4
        return Int(pixels[index + 2]) << 16 | Int(pixels[index + 1]) << 8 | Int(pixels[index])
    }

    /// Every pixel in a cell of grid 1.
    func cell(row: Int, col: Int) -> [Int] {
        var colors: [Int] = []
        for y in row * cellHeight ..< (row + 1) * cellHeight {
            for x in col * cellWidth ..< (col + 1) * cellWidth {
                colors.append(pixel(x: x, y: y))
            }
        }
        return colors
    }

    func centre(row: Int, col: Int) -> Int {
        pixel(x: col * cellWidth + cellWidth / 2, y: row * cellHeight + cellHeight / 2)
    }
}

/// Builds screens from redraw events.
struct ScreenBuilder {
    var screen = Screen()

    init(cols: Int, rows: Int, background: Int = 0x101010, foreground: Int = 0xF0F0F0) {
        screen.apply(.defaultColorsSet(rgbFg: foreground, rgbBg: background, rgbSp: 0, ctermFg: 0, ctermBg: 0))
        screen.apply(.gridResize(grid: 1, width: cols, height: rows))
    }

    mutating func window(grid: Int, row: Int, col: Int, cols: Int, rows: Int) {
        screen.apply(.gridResize(grid: grid, width: cols, height: rows))
        screen.apply(.winPos(grid: grid, win: 1000 + grid, row: row, col: col, width: cols, height: rows))
    }

    mutating func float(grid: Int, row: Int, col: Int, cols: Int, rows: Int) {
        screen.apply(.gridResize(grid: grid, width: cols, height: rows))
        screen.apply(.winFloatPos(
            grid: grid, win: 1000 + grid, anchor: "NW", anchorGrid: 1, anchorRow: Double(row),
            anchorCol: Double(col), zindex: 50, compindex: 1, screenRow: row, screenCol: col
        ))
    }

    mutating func text(_ text: String, grid: Int, row: Int, col: Int = 0, hl: Int = 0) {
        screen.apply(.gridLine(
            grid: grid, row: row, colStart: col,
            cells: text.map { GridCellData(text: String($0), hlId: hl, repeats: 1) }
        ))
    }

    mutating func highlight(_ id: Int, _ attrs: [String: MessagePackValue]) {
        screen.apply(.hlAttrDefine(id: id, rgbAttrs: attrs, ctermAttrs: [:], info: []))
    }
}

@Suite("Metal grid")
@MainActor
struct RendererTests {
    private let background = 0x101010
    private let foreground = 0xF0F0F0

    @Test("instances have the layout the shaders read")
    func layout() {
        #expect(MemoryLayout<RectInstance>.stride == 48)
        #expect(MemoryLayout<RectInstance>.offset(of: \.kind) == 32)
        #expect(MemoryLayout<GlyphInstance>.stride == 64)
        #expect(MemoryLayout<GlyphInstance>.offset(of: \.color) == 32)
        #expect(MemoryLayout<GlyphInstance>.offset(of: \.colored) == 48)
    }

    @Test("an empty screen is the default background")
    func empty() throws {
        let canvas = try Canvas()
        try canvas.render(Frame(screen: ScreenBuilder(cols: 20, rows: 6).screen))
        #expect(Set(canvas.cell(row: 2, col: 5)) == [background])
    }

    @Test("text is drawn in its cells in the foreground colour, and nowhere else")
    func text() throws {
        let canvas = try Canvas()
        var builder = ScreenBuilder(cols: 20, rows: 6)
        builder.window(grid: 2, row: 0, col: 0, cols: 20, rows: 5)
        builder.text("hello", grid: 2, row: 1, col: 2)
        try canvas.render(Frame(screen: builder.screen))
        for col in 2 ..< 7 {
            #expect(canvas.cell(row: 1, col: col).contains(foreground), "cell \(col) has ink")
        }
        #expect(Set(canvas.cell(row: 1, col: 8)) == [background])
        #expect(Set(canvas.cell(row: 3, col: 3)) == [background])
    }

    @Test("a highlight's background fills its cells")
    func highlightBackground() throws {
        let canvas = try Canvas()
        var builder = ScreenBuilder(cols: 20, rows: 6)
        builder.highlight(5, ["background": .int(0xC03030)])
        builder.window(grid: 2, row: 0, col: 0, cols: 20, rows: 5)
        builder.text("   ", grid: 2, row: 2, col: 4, hl: 5)
        try canvas.render(Frame(screen: builder.screen))
        #expect(Set(canvas.cell(row: 2, col: 5)) == [0xC03030])
        #expect(canvas.centre(row: 2, col: 3) == background)
        #expect(canvas.centre(row: 2, col: 7) == background)
    }

    @Test("a float covers the window under it")
    func floatOnTop() throws {
        let canvas = try Canvas()
        var builder = ScreenBuilder(cols: 20, rows: 6)
        builder.highlight(7, ["background": .int(0x3050C0)])
        builder.window(grid: 2, row: 0, col: 0, cols: 20, rows: 5)
        for row in 0 ..< 5 {
            builder.text(String(repeating: "x", count: 20), grid: 2, row: row)
        }
        builder.float(grid: 3, row: 1, col: 4, cols: 6, rows: 2)
        builder.text("      ", grid: 3, row: 0, hl: 7)
        builder.text("      ", grid: 3, row: 1, hl: 7)
        try canvas.render(Frame(screen: builder.screen))
        #expect(Set(canvas.cell(row: 1, col: 6)) == [0x3050C0])
        #expect(Set(canvas.cell(row: 2, col: 9)) == [0x3050C0])
        #expect(canvas.cell(row: 3, col: 6).contains(foreground), "the window shows below the float")
    }

    @Test("a grid under a terminal pane is not drawn")
    func coveredGrid() throws {
        let canvas = try Canvas()
        var builder = ScreenBuilder(cols: 20, rows: 6)
        builder.window(grid: 2, row: 0, col: 0, cols: 20, rows: 5)
        builder.text("visible", grid: 2, row: 0)
        try canvas.render(Frame(screen: builder.screen, covered: [2]))
        #expect(Set(canvas.cell(row: 0, col: 1)) == [background])
    }

    @Test("box drawing meets across cells without gaps")
    func boxDrawing() throws {
        let canvas = try Canvas()
        var builder = ScreenBuilder(cols: 20, rows: 6)
        builder.window(grid: 2, row: 0, col: 0, cols: 20, rows: 5)
        builder.text("────", grid: 2, row: 1, col: 2)
        try canvas.render(Frame(screen: builder.screen))
        // Some pixel row through the cells is lit from the first cell's left edge to the last one's right edge.
        let y0 = 1 * canvas.cellHeight, left = 2 * canvas.cellWidth, right = 6 * canvas.cellWidth
        let lit = (y0 ..< y0 + canvas.cellHeight).contains { y in
            (left ..< right).allSatisfy { canvas.pixel(x: $0, y: y) == foreground }
        }
        #expect(lit)
    }

    @Test("an emoji keeps its colours")
    func colourGlyph() throws {
        let canvas = try Canvas()
        var builder = ScreenBuilder(cols: 20, rows: 6)
        builder.window(grid: 2, row: 0, col: 0, cols: 20, rows: 5)
        builder.screen.apply(.gridLine(grid: 2, row: 1, colStart: 2, cells: [
            GridCellData(text: "🍎", hlId: 0, repeats: 1), GridCellData(text: "", hlId: 0, repeats: 1),
        ]))
        try canvas.render(Frame(screen: builder.screen))
        let colours = canvas.cell(row: 1, col: 2) + canvas.cell(row: 1, col: 3)
        let saturated = colours.contains { colour in
            let (r, g, b) = ((colour >> 16) & 0xFF, (colour >> 8) & 0xFF, colour & 0xFF)
            return r > 150 && r > g + 60 && r > b + 60
        }
        #expect(saturated, "a red pixel in the apple")
    }

    @Test("rows are rebuilt only when they change")
    func rowCache() throws {
        let canvas = try Canvas()
        var builder = ScreenBuilder(cols: 20, rows: 6)
        builder.window(grid: 2, row: 0, col: 0, cols: 20, rows: 5)
        builder.text("first", grid: 2, row: 0)
        try canvas.render(Frame(screen: builder.screen))
        #expect(canvas.renderer.stats.rowsBuilt == 6 + 5)

        try canvas.render(Frame(screen: builder.screen))
        #expect(canvas.renderer.stats.rowsBuilt == 0)
        #expect(canvas.renderer.stats.rowsReused == 11)

        builder.text("again", grid: 2, row: 3)
        try canvas.render(Frame(screen: builder.screen))
        #expect(canvas.renderer.stats.rowsBuilt == 1)

        builder.highlight(9, ["foreground": .int(0x00FF00)])
        try canvas.render(Frame(screen: builder.screen))
        #expect(canvas.renderer.stats.rowsBuilt == 11, "a new highlight table rebuilds every row")
    }

    @Test("an undercurl is drawn below the text")
    func undercurl() throws {
        let canvas = try Canvas()
        var builder = ScreenBuilder(cols: 20, rows: 6)
        builder.highlight(4, ["undercurl": .bool(true), "special": .int(0xFF3030)])
        builder.window(grid: 2, row: 0, col: 0, cols: 20, rows: 5)
        builder.text("    ", grid: 2, row: 2, col: 2, hl: 4)
        try canvas.render(Frame(screen: builder.screen))
        let bottom = (2 * canvas.cellHeight + canvas.cellHeight / 2 ..< 3 * canvas.cellHeight)
        // Antialiased: the line's pixels are shades of its colour, so look for a clearly red one.
        let curl = bottom.contains { y in
            (2 * canvas.cellWidth ..< 6 * canvas.cellWidth).contains {
                let colour = canvas.pixel(x: $0, y: y)
                return (colour >> 16) & 0xFF > 0xC0 && (colour >> 8) & 0xFF < 0x50
            }
        }
        #expect(curl)
        // A wave, not a bar: most of its band is still background.
        let band = (3 * canvas.cellHeight - 6 ..< 3 * canvas.cellHeight).flatMap { y in
            (2 * canvas.cellWidth ..< 6 * canvas.cellWidth).map { canvas.pixel(x: $0, y: y) }
        }
        #expect(band.count(where: { $0 == background }) * 2 > band.count)
        #expect(canvas.pixel(x: 3 * canvas.cellWidth, y: 2 * canvas.cellHeight + 2) == background)
    }
}
