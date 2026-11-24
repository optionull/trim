import Foundation
import MessagePack
@testable import SillCore
import SillNvim
import Testing

@Suite("screen model")
struct ScreenTests {
    private func grid(_ lines: [String]) -> GridBuffer {
        var grid = GridBuffer()
        grid.resize(rows: lines.count, cols: lines.map(\.count).max() ?? 0)
        for (row, line) in lines.enumerated() {
            grid.put(row: row, colStart: 0, cells: line.map { GridCellData(text: String($0), hlId: 0, repeats: 1) })
        }
        return grid
    }

    @Test("grid_scroll up moves rows up within the region")
    func scrollUp() {
        var buffer = grid(["aaaa", "bbbb", "cccc", "dddd"])
        buffer.scroll(top: 0, bottom: 4, left: 1, right: 3, count: 1)
        #expect((0 ..< 4).map(buffer.line) == ["abba", "bccb", "cddc", "dddd"])
    }

    @Test("grid_scroll down moves rows down within the region")
    func scrollDown() {
        var buffer = grid(["aaaa", "bbbb", "cccc", "dddd"])
        buffer.scroll(top: 0, bottom: 4, left: 0, right: 4, count: -1)
        // Bottom up, or row 0 would be copied all the way down.
        #expect((0 ..< 4).map(buffer.line) == ["aaaa", "aaaa", "bbbb", "cccc"])
    }

    @Test("repeated cells fill their run, clipped at the edge")
    func repeats() {
        var buffer = GridBuffer()
        buffer.resize(rows: 1, cols: 5)
        buffer.put(row: 0, colStart: 1, cells: [GridCellData(text: "x", hlId: 3, repeats: 9)])
        #expect(buffer.line(0) == " xxxx")
        #expect(buffer[0, 4].hl == 3)
    }

    @Test("a pane is drawn only while its window is shown")
    func paneFollowsItsWindow() {
        var screen = Screen()
        screen.apply(.gridResize(grid: 4, width: 20, height: 10))
        screen.apply(.winPos(grid: 4, win: 1001, row: 0, col: 21, width: 20, height: 10))
        #expect(screen.paneRects.isEmpty)
        screen.apply(.notification(method: "sill_panes", args: [.array([.array([.int(1001), .int(7)])])]))
        #expect(screen.paneRects == [PaneRect(pane: 7, win: 1001, grid: 4, row: 0, col: 21, width: 20, height: 10)])
        screen.apply(.winHide(grid: 4))
        #expect(screen.paneRects.isEmpty)
        screen.apply(.winPos(grid: 4, win: 1001, row: 1, col: 21, width: 20, height: 9))
        #expect(screen.paneRects.first?.row == 1)
        screen.apply(.winClose(grid: 4))
        #expect(screen.paneRects.isEmpty)
    }

    @Test("windows draw before floats and the message grid, which go by compindex")
    func drawOrder() {
        var screen = Screen()
        screen.apply(.gridResize(grid: 1, width: 80, height: 24))
        for grid in [2, 3, 5, 6] {
            screen.apply(.gridResize(grid: grid, width: 10, height: 2))
        }
        screen.apply(.winPos(grid: 3, win: 1001, row: 0, col: 0, width: 40, height: 22))
        screen.apply(.winPos(grid: 2, win: 1000, row: 0, col: 41, width: 39, height: 22))
        screen.apply(.msgSetPos(grid: 5, row: 20, scrolled: false, zindex: 200, compindex: 1))
        screen.apply(.winFloatPos(
            grid: 6, win: 1002, anchor: "NW", anchorGrid: 1, anchorRow: 3, anchorCol: 4, zindex: 50,
            compindex: 0, screenRow: 3, screenCol: 4
        ))
        #expect(screen.drawOrder.map(\.grid) == [1, 2, 3, 6, 5])
        #expect(screen.placements[6]?.row == 3 && screen.placements[6]?.width == 10)
    }
}

@Suite("hit testing")
struct HitTests {
    @Test("a click goes to the grid on top, in its own cells")
    func hit() {
        var screen = Screen()
        screen.apply(.gridResize(grid: 1, width: 80, height: 24))
        for grid in [2, 3, 4] {
            screen.apply(.gridResize(grid: grid, width: 10, height: 3))
        }
        screen.apply(.winPos(grid: 2, win: 1000, row: 0, col: 0, width: 40, height: 22))
        screen.apply(.winPos(grid: 3, win: 1001, row: 0, col: 41, width: 39, height: 22))
        screen.apply(.winFloatPos(
            grid: 4, win: 1002, anchor: "NW", anchorGrid: 1, anchorRow: 5, anchorCol: 38, zindex: 50,
            compindex: 1, screenRow: 5, screenCol: 38
        ))
        #expect(screen.hit(row: 2, col: 3) == (2, 2, 3))
        #expect(screen.hit(row: 2, col: 45) == (3, 2, 4))
        #expect(screen.hit(row: 6, col: 40) == (4, 1, 2), "the float is on top")
        #expect(screen.hit(row: 23, col: 5) == (1, 23, 5), "the command line is grid 1")
    }

    @Test(
        "altfont is twice the size, with a blend that many hundredths more than once, and 100 is a box of ordinary size"
    )
    func scaleOfAHighlight() {
        var plain = Highlight()
        #expect(plain.scale == 1 && !plain.boxed)
        plain.altfont = true
        #expect(plain.scale == 2)
        plain.blend = 50
        #expect(plain.scale == 1.5)
        plain.blend = 100
        #expect(plain.scale == 1 && plain.boxed)
        var float = Highlight()
        float.blend = 40
        #expect(float.scale == 1 && !float.boxed, "a float's blend is not a size")
    }

    @Test("on a double-height row a click lands on the cell it is over: two screen columns to a cell")
    func doubleRow() {
        var screen = Screen()
        screen.apply(.gridResize(grid: 1, width: 40, height: 10))
        screen.apply(.gridResize(grid: 2, width: 40, height: 9))
        screen.apply(.winPos(grid: 2, win: 1000, row: 0, col: 0, width: 40, height: 9))
        screen.apply(.hlAttrDefine(id: 7, rgbAttrs: ["altfont": .bool(true)], ctermAttrs: [:], info: []))
        screen.apply(.gridLine(
            grid: 2,
            row: 2,
            colStart: 0,
            cells: "Title".map { GridCellData(text: String($0), hlId: 7, repeats: 1) }
        ))
        #expect(screen.rowScale(grid: 2, row: 2) == 2 && screen.rowScale(grid: 2, row: 3) == 1)
        #expect(screen.hit(row: 2, col: 6) == (2, 2, 3), "the fourth letter spans screen columns 6 and 7")
        #expect(screen.hit(row: 3, col: 6) == (2, 3, 6), "other rows are as they were")
    }
}

@Suite("messages")
struct MessageTests {
    private func chunk(_ text: String) -> [StyledChunk] { [StyledChunk(text: text)] }

    @Test("replace_last replaces, append appends, an id replaces its message, empty clears")
    func showing() {
        var screen = Screen()
        screen.apply(.msgShow(
            kind: "echo",
            content: chunk("one"),
            replaceLast: false,
            history: false,
            append: false,
            id: ""
        ))
        screen.apply(.msgShow(
            kind: "echo",
            content: chunk("two"),
            replaceLast: false,
            history: false,
            append: false,
            id: ""
        ))
        #expect(screen.messages.map(\.text) == ["one", "two"])
        screen.apply(.msgShow(
            kind: "echo",
            content: chunk("2"),
            replaceLast: true,
            history: false,
            append: false,
            id: ""
        ))
        #expect(screen.messages.map(\.text) == ["one", "2"])
        screen.apply(.msgShow(
            kind: "echo",
            content: chunk("+"),
            replaceLast: false,
            history: false,
            append: true,
            id: ""
        ))
        #expect(screen.messages.map(\.text) == ["one", "2+"])
        screen.apply(.msgShow(
            kind: "progress",
            content: chunk("10%"),
            replaceLast: false,
            history: false,
            append: false,
            id: "lsp"
        ))
        screen.apply(.msgShow(
            kind: "progress",
            content: chunk("90%"),
            replaceLast: false,
            history: false,
            append: false,
            id: "lsp"
        ))
        #expect(screen.messages.map(\.text) == ["one", "2+", "90%"])
        screen.apply(.msgShow(kind: "empty", content: [], replaceLast: false, history: false, append: false, id: ""))
        #expect(screen.messages.isEmpty)
    }

    @Test("every shown message gets a new serial")
    func serials() {
        var screen = Screen()
        screen.apply(.msgShow(
            kind: "echo",
            content: chunk("a"),
            replaceLast: false,
            history: false,
            append: false,
            id: ""
        ))
        let first = screen.messages[0].serial
        screen.apply(.msgShow(
            kind: "echo",
            content: chunk("b"),
            replaceLast: true,
            history: false,
            append: false,
            id: ""
        ))
        #expect(screen.messages[0].serial > first)
    }
}

@Suite("how nvim starts")
struct StartupTests {
    private func folder(with files: [String]) throws -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sill-config-\(UUID().uuidString)")
        let nvim = root.appendingPathComponent("nvim")
        try FileManager.default.createDirectory(at: nvim, withIntermediateDirectories: true)
        for file in files {
            try "".write(to: nvim.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        return root.path
    }

    @Test("with the user's init.lua, nvim runs under its own name, sill's base first")
    func userConfig() throws {
        let startup = try EditorSession.startup(
            environment: ["XDG_CONFIG_HOME": folder(with: ["init.lua"])],
            own: false
        )
        #expect(startup == .init(appName: "nvim", arguments: ["--cmd", "lua require('sill.base')"], userConfig: true))
    }

    @Test("an init.vim counts too; NVIM_APPNAME picks the folder")
    func vimscriptAndAppName() throws {
        let root = try folder(with: ["init.vim"])
        try FileManager.default.moveItem(atPath: "\(root)/nvim", toPath: "\(root)/mine")
        let startup = EditorSession.startup(environment: ["XDG_CONFIG_HOME": root, "NVIM_APPNAME": "mine"], own: false)
        #expect(startup.appName == "mine" && startup.userConfig)
    }

    @Test("without a config, or asked for sill alone, nvim runs as sill")
    func alone() throws {
        let empty = try folder(with: [])
        #expect(EditorSession.startup(environment: ["XDG_CONFIG_HOME": empty], own: false).appName == "sill")
        let configured = try folder(with: ["init.lua"])
        let own = EditorSession.startup(environment: ["XDG_CONFIG_HOME": configured], own: true)
        #expect(own.appName == "sill" && !own.userConfig)
    }
}
