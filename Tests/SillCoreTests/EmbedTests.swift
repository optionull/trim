import Foundation
@testable import SillCore
import Testing

/// Day 1: sill starts `nvim --embed`, talks msgpack-RPC to it, and gets a screen back.
@Suite("nvim --embed", .serialized)
struct EmbedTests {
    @Test("hello: text set over RPC comes back in a window grid")
    func hello() async throws {
        let nvim = try await Harness.start()
        defer { Task { await nvim.stop() } }

        try await nvim.command("call setline(1, 'hello, sill')")
        let screen = try await nvim.screen("hello in a window grid") { screen in
            screen.windows.contains { screen.grids[$0.grid]?.line(0).hasPrefix("hello, sill") == true }
        }
        // Multigrid: the text is in the window's own grid, not in grid 1.
        #expect(screen.grids[1]?.line(0).hasPrefix("hello, sill") != true)
    }

    @Test("one window fills the screen above the command line")
    func singleWindowLayout() async throws {
        let nvim = try await Harness.start(cols: 100, rows: 30)
        defer { Task { await nvim.stop() } }

        let screen = try await nvim.screen("one window") { $0.windows.count == 1 }
        let window = try #require(screen.windows.first?.placement)
        #expect(window.row == 0 && window.col == 0)
        #expect(window.width == 100)
        // Below the window: its status line (laststatus=2 is the default) and the command line, both on grid 1.
        #expect(window.height == 28)
        #expect(screen.grids[1]?.rows == 30)
    }

    @Test("a resize before nvim is attached is applied once it is")
    func resizeBeforeAttach() async throws {
        let nvim = try await Harness.start(cols: 80, rows: 24) { session in
            await session.resize(cols: 50, rows: 40)
        }
        defer { Task { await nvim.stop() } }

        try await nvim.screen("grid 1 at 50x40") { $0.grids[1]?.cols == 50 && $0.grids[1]?.rows == 40 }
    }

    @Test("a resize after attaching resizes grid 1 and the window")
    func resizeAfterAttach() async throws {
        let nvim = try await Harness.start(cols: 80, rows: 24)
        defer { Task { await nvim.stop() } }

        try await nvim.screen("grid 1 at 80x24") { $0.grids[1]?.cols == 80 }
        await nvim.session.resize(cols: 100, rows: 30)
        let screen = try await nvim.screen("grid 1 at 100x30") { $0.grids[1]?.cols == 100 && $0.grids[1]?.rows == 30 }
        #expect(screen.windows.first?.placement.width == 100)
    }

    @Test("keys are delivered in the order they are sent")
    func keyOrder() async throws {
        let nvim = try await Harness.start()
        defer { Task { await nvim.stop() } }

        // Long enough that keys sent from a task each would come out of order.
        let text = String(repeating: "abcdefghijklmnopqrstuvwxyz0123456789", count: 20)
        await nvim.keys("i")
        for character in text {
            await nvim.keys(String(character))
        }
        await nvim.keys("<Esc>")
        try await nvim.screen("the typed text") { screen in
            let window = screen.windows.first.flatMap { screen.grids[$0.grid] }
            // The line wraps: read the rows it fills.
            let rows = window.map { grid in (0 ..< grid.rows).map(grid.line).joined() } ?? ""
            return rows.hasPrefix(text)
        }
    }
}
