import Foundation
@testable import SillCore
import Testing

/// Day 2: a terminal pane is a placeholder nvim window, so nvim's own window commands move across it, resize it and
/// close it, and the UI learns where to draw the terminal from the window's grid.
@Suite("terminal panes", .serialized)
struct TerminalPaneTests {
    /// Opens a pane next to the editor window and returns the screen once it is current.
    private func openPane(_ nvim: Harness) async throws -> Screen {
        try await nvim.command("SillTerminal")
        return try await nvim.screen("a pane that is the current window") { screen in
            screen.paneRects.count == 1 && screen.currentPane == 1
        }
    }

    @Test(":SillTerminal opens a pane to the right, at its placeholder window's cells")
    func paneSitsOnItsWindow() async throws {
        let nvim = try await Harness.start(cols: 100, rows: 30)
        defer { Task { await nvim.stop() } }

        let screen = try await openPane(nvim)
        let pane = try #require(screen.paneRects.first)
        let windows = screen.windows
        try #require(windows.count == 2)
        let (editor, placeholder) = (windows[0].placement, windows[1].placement)

        #expect(pane.grid == windows[1].grid)
        #expect(pane.win == placeholder.win)
        #expect((pane.row, pane.col, pane.width, pane.height) ==
            (placeholder.row, placeholder.col, placeholder.width, placeholder.height))
        // Side by side, with nvim's vertical separator between them on grid 1.
        #expect(editor.col == 0 && pane.col == editor.width + 1)
        #expect(editor.width + 1 + pane.width == 100)
        #expect(screen.panes == [placeholder.win: 1])
    }

    @Test("<C-w>h and <C-w>l move between the editor window and the pane")
    func windowKeysCrossThePane() async throws {
        let nvim = try await Harness.start()
        defer { Task { await nvim.stop() } }

        let opened = try await openPane(nvim)
        let editorWin = try #require(opened.windows.first?.placement.win)

        await nvim.keys("<C-w>h")
        try await nvim.screen("the editor window current") { $0.cursorWindow == editorWin && $0.currentPane == nil }
        await nvim.keys("<C-w>l")
        try await nvim.screen("the pane current again") { $0.currentPane == 1 }
        await nvim.keys("<C-w>w")
        try await nvim.screen("<C-w>w wraps to the editor") { $0.cursorWindow == editorWin }
    }

    @Test("i in the pane hands it the keyboard; in the editor window it inserts")
    func insertFocusesTheTerminal() async throws {
        let nvim = try await Harness.start()
        defer { Task { await nvim.stop() } }

        _ = try await openPane(nvim)
        await nvim.keys("i")
        try await waitFor { await nvim.focusRequests == [1] }
        // The placeholder stays in normal mode; it is the terminal that takes the keys.
        try await nvim.screen("normal mode in the pane") { $0.mode == "normal" && $0.currentPane == 1 }

        await nvim.keys("<C-w>hi")
        try await nvim.screen("insert mode in the editor window") { $0.mode == "insert" && $0.currentPane == nil }
        #expect(await nvim.focusRequests == [1])
    }

    @Test(":vertical resize and <C-w>= move the pane with its window")
    func resizeMovesThePane() async throws {
        let nvim = try await Harness.start(cols: 100, rows: 30)
        defer { Task { await nvim.stop() } }

        _ = try await openPane(nvim)
        try await nvim.command("vertical resize 30")
        var screen = try await nvim.screen("the pane 30 wide") { $0.paneRects.first?.width == 30 }
        #expect(screen.paneRects.first?.col == 100 - 30)

        await nvim.keys("<C-w>=")
        // 99 columns between two windows: nvim gives the odd one to the right.
        screen = try await nvim.screen("equal widths") { $0.paneRects.first?.width == 50 }
        #expect(screen.paneRects.first?.col == 50)
        #expect(screen.windows.first?.placement.width == 49)
    }

    @Test(":only in the editor window closes the pane")
    func onlyClosesThePane() async throws {
        let nvim = try await Harness.start()
        defer { Task { await nvim.stop() } }

        _ = try await openPane(nvim)
        await nvim.keys("<C-w>h:only<CR>")
        let screen = try await nvim.screen("no panes") { $0.paneRects.isEmpty && $0.panes.isEmpty }
        #expect(screen.windows.count == 1)
    }

    @Test("another tab page hides the pane, and coming back shows it at the same cells")
    func tabsHideThePane() async throws {
        let nvim = try await Harness.start()
        defer { Task { await nvim.stop() } }

        let opened = try await openPane(nvim)
        let before = try #require(opened.paneRects.first)
        try await nvim.command("tabnew")
        try await nvim.screen("the pane hidden") { $0.paneRects.isEmpty && $0.panes.count == 1 }
        try await nvim.command("tabprevious")
        let back = try await nvim.screen("the pane back") { $0.paneRects.count == 1 }
        // The tab line now takes the top row, so the pane is one row lower and one shorter.
        let pane = try #require(back.paneRects.first)
        #expect((pane.pane, pane.col, pane.width) == (before.pane, before.col, before.width))
        #expect(pane.row == before.row + 1 && pane.height == before.height - 1)
    }

    @Test("two panes are told apart")
    func twoPanes() async throws {
        let nvim = try await Harness.start(cols: 120, rows: 40)
        defer { Task { await nvim.stop() } }

        _ = try await openPane(nvim)
        try await nvim.command("belowright SillTerminal")
        let screen = try await nvim.screen("two panes") { $0.paneRects.count == 2 && $0.currentPane == 2 }
        let (first, second) = (screen.paneRects[0], screen.paneRects[1])
        #expect(first.col == second.col && first.width == second.width)
        #expect(second.row == first.row + first.height + 1)

        await nvim.keys("<C-w>k")
        try await nvim.screen("the first pane current") { $0.currentPane == 1 }
    }
}

/// Polls `condition` until it holds.
func waitFor(timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw Timeout(description: "timed out")
}
