import AppKit
import MessagePack
import Metal
import SillCore
import SillEditor
import SillNvim
import SillRender

/// `SILL_BENCH=1`: the grid spike's go/no-go numbers (plan §3), measured offscreen at 4K so they do not depend on the
/// window or the display. Run it on a release build (`mise run bench`): a debug build measures Swift's -Onone.
///
/// - Scroll: a 4K grid of highlighted code with ligatures, scrolled a line every frame, so every row changes every
///   frame, the worst case for the row cache.
/// - Flame graph: a synthetic 11.8M-sample profile drawn by level of detail while it zooms in 2000x and pans.
///
/// Each frame is built, encoded and waited for, so a frame's time is all the work it costs, CPU and GPU together.
@MainActor
enum Bench {
    static let budget = 1000.0 / 120

    static func run() {
        do {
            let device = try unwrap(MTLCreateSystemDefaultDevice(), "a Metal device")
            let metrics = CellMetrics()
            let renderer = try GridRenderer(
                device: device, font: metrics.regular, cellSize: metrics.cellSize, scale: 2, pixelFormat: .bgra8Unorm
            )
            let texture = try target(device)
            print("sill bench: \(texture.width)x\(texture.height) pixels, \(metrics.regular.fontName)")
            let scroll = try scrollBench(renderer, texture, metrics)
            let flame = try flameBench(renderer, texture)
            let passed = scroll && flame
            print("sill bench: \(passed ? "passed" : "FAILED"): every frame within \(format(budget)) ms at p99")
            exit(passed ? 0 : 1)
        } catch {
            print("sill bench: FAILED: \(error)")
            exit(1)
        }
    }

    private static func target(_ device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 3840, height: 2160, mipmapped: false
        )
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .private
        return try unwrap(device.makeTexture(descriptor: descriptor), "a 4K texture")
    }

    // MARK: Scroll

    private static func scrollBench(_ renderer: GridRenderer, _ texture: MTLTexture, _ metrics: CellMetrics) throws
        -> Bool
    {
        let cols = Int(CGFloat(texture.width) / 2 / metrics.width)
        let rows = Int(CGFloat(texture.height) / 2 / metrics.height)
        var screen = Screen()
        screen.apply(.defaultColorsSet(rgbFg: 0xCFD3D8, rgbBg: 0x0C0D0F, rgbSp: 0, ctermFg: 0, ctermBg: 0))
        let palette: [(Int, [String: MessagePackValue])] = [
            (1, ["foreground": .int(0xC792EA), "bold": .bool(true)]), (2, ["foreground": .int(0xC3E88D)]),
            (3, ["foreground": .int(0x82AAFF)]), (4, ["foreground": .int(0x676E95), "italic": .bool(true)]),
            (5, ["foreground": .int(0xF78C6C)]), (6, ["background": .int(0x1C1F26)]),
        ]
        for (id, attrs) in palette {
            screen.apply(.hlAttrDefine(id: id, rgbAttrs: attrs, ctermAttrs: [:], info: []))
        }
        screen.apply(.gridResize(grid: 1, width: cols, height: rows))
        screen.apply(.gridResize(grid: 2, width: cols, height: rows - 2))
        screen.apply(.winPos(grid: 2, win: 1000, row: 0, col: 0, width: cols, height: rows - 2))
        let source = code(width: cols)
        for row in 0 ..< rows - 2 {
            screen.apply(.gridLine(grid: 2, row: row, colStart: 0, cells: cells(source[row % source.count])))
        }
        print("scroll: \(cols)x\(rows) cells, a line per frame")

        var times: [Double] = [], builds: [Double] = [], gpus: [Double] = []
        for frame in 0 ..< 720 {
            let start = DispatchTime.now().uptimeNanoseconds
            screen.apply(.gridScroll(grid: 2, top: 0, bottom: rows - 2, left: 0, right: cols, rows: 1, cols: 0))
            screen.apply(.gridLine(
                grid: 2, row: rows - 3, colStart: 0, cells: cells(source[(frame + rows) % source.count])
            ))
            screen.apply(.gridLine(grid: 1, row: rows - 2, colStart: 0, cells: cells(
                " NORMAL  bench.swift" + String(repeating: " ", count: max(cols - 40, 0)) + "Ln \(frame)", hl: 6
            )))
            let commands = try unwrap(renderer.render(Frame(screen: screen), to: texture), "a command buffer")
            commands.waitUntilCompleted()
            guard frame >= 120 else { continue } // Warm-up: the atlas fills.
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            builds.append(renderer.stats.buildMilliseconds)
            gpus.append((commands.gpuEndTime - commands.gpuStartTime) * 1000)
        }
        report("scroll frame", times)
        report("  build (CPU)", builds)
        report("  GPU", gpus)
        print("  rows rebuilt per frame: \(renderer.stats.rowsBuilt), glyphs: \(renderer.stats.glyphs), " +
            "multi-cell glyphs (ligatures) in them: \(renderer.stats.multiCellGlyphs)")
        return percentile(times, 0.99) <= budget
    }

    /// Code-like lines with ligatures (`->`, `=>`, `!=`, `===`, `<=`), as wide as the grid.
    private static func code(width: Int) -> [String] {
        let fragments = [
            "func render(_ frame: Frame) -> MTLCommandBuffer? {", "    guard let x = cache[key], x.version == v else {",
            "    let total = items.reduce(0) { $0 + $1.count } // sum",
            "    if a != b && c >= d || e <= f { return nil }",
            "    let map = values.map { $0 => $0 * 2 } // arrow", "    switch kind { case .a: break; default: () }",
            "}", "// ═══ box ─── drawing │ and ┼ crossings ═══", "    x === y ? \"strict\" : \"loose\"",
        ]
        return (0 ..< 97).map { index in
            var line = fragments[index % fragments.count]
            while line.count < width {
                line += "  " + fragments[(index * 7 + line.count) % fragments.count]
            }
            return String(line.prefix(width))
        }
    }

    /// Cells for a line, with a highlight per word so runs are short, as syntax highlighting makes them.
    private static func cells(_ line: String, hl: Int? = nil) -> [GridCellData] {
        var cells: [GridCellData] = []
        var word = 0
        for character in line {
            if character == " " { word += 1 }
            cells.append(GridCellData(text: String(character), hlId: hl ?? (word % 6), repeats: 1))
        }
        return cells
    }

    // MARK: Flame graph

    private static func flameBench(_ renderer: GridRenderer, _ texture: MTLTexture) throws -> Bool {
        let started = DispatchTime.now().uptimeNanoseconds
        // Harsher than a real profile: deep, wide, and split down to a few samples a frame.
        let profile = FlameGraph.synthetic(samples: 11_800_000, maxDepth: 64, minSamples: 3, maxChildren: 12)
        let built = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        print("flame graph: \(profile.totalSamples) samples, \(profile.nodes.count) frames, depth " +
            "\(profile.maxDepth), built in \(format(built)) ms")
        let rowHeight = Float(texture.height) / Float(profile.maxDepth + 1)
        let total = Double(profile.totalSamples)
        // Zoom 2000x into a point a third of the way in, then pan right at that zoom.
        let focus = total * 0.37
        var times: [Double] = [], lods: [Double] = [], counts: [Int] = []
        for frame in 0 ..< 720 {
            let t = Double(frame) / 719
            let span = total / pow(2000, min(t * 1.5, 1))
            let pan = t > 2.0 / 3 ? (t - 2.0 / 3) * 3 * span * 4 : 0
            let from = max(0, min(focus - span / 2 + pan, total - span))
            let start = DispatchTime.now().uptimeNanoseconds
            let blocks = profile.blocks(from: from, to: from + span, pixels: Double(texture.width))
            let lod = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            let commands = try unwrap(
                renderer.render(blocks, rowHeight: rowHeight, to: texture, background: 0x0C0D0F), "a command buffer"
            )
            commands.waitUntilCompleted()
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            lods.append(lod)
            counts.append(blocks.count)
        }
        report("flame frame", times)
        report("  level of detail (CPU)", lods)
        print("  blocks per frame: \(counts.min() ?? 0) to \(counts.max() ?? 0) (first frame \(counts[0]))")
        return percentile(times, 0.99) <= budget
    }

    // MARK: Reporting

    private static func report(_ name: String, _ values: [Double]) {
        let over = values.count(where: { $0 > budget })
        print("\(name): p50 \(format(percentile(values, 0.5))) ms, p95 \(format(percentile(values, 0.95))) ms, " +
            "p99 \(format(percentile(values, 0.99))) ms, max \(format(values.max() ?? 0)) ms" +
            (name.hasPrefix(" ") ? "" : ", \(over) of \(values.count) over \(format(budget)) ms"))
    }

    static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(Int(Double(sorted.count - 1) * fraction), sorted.count - 1)]
    }

    static func format(_ value: Double) -> String { String(format: "%.2f", value) }

    private static func unwrap<T>(_ value: T?, _ what: String) throws -> T {
        guard let value else { throw CheckFailure(description: "no \(what)") }
        return value
    }
}
