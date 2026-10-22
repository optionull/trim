import MessagePack
import SillNvim

/// Where a grid is drawn on the default grid (grid 1), in cells.
public struct Placement: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case window, float, message }

    public var kind: Kind
    /// The nvim window handle; 0 for the message grid.
    public var win: Int
    public var row: Int
    public var col: Int
    public var width: Int
    public var height: Int
    /// Drawing order among floats and the message grid; windows are drawn first.
    public var compindex = 0
    public var hidden = false

    public init(
        kind: Kind, win: Int, row: Int, col: Int, width: Int, height: Int, compindex: Int = 0, hidden: Bool = false
    ) {
        self.kind = kind
        self.win = win
        self.row = row
        self.col = col
        self.width = width
        self.height = height
        self.compindex = compindex
        self.hidden = hidden
    }
}

/// A terminal pane's place on screen: the cells of the placeholder window that backs it.
public struct PaneRect: Sendable, Equatable {
    public var pane: Int
    public var win: Int
    public var grid: Int
    public var row: Int
    public var col: Int
    public var width: Int
    public var height: Int
}

public struct Highlight: Sendable, Equatable {
    public var foreground: Int?
    public var background: Int?
    public var special: Int?
    public var reverse = false
    public var bold = false
    public var italic = false
    public var underline = false
    public var undercurl = false
    public var underdouble = false
    public var underdotted = false
    public var underdashed = false
    public var strikethrough = false
    /// How far a float's background lets what is under it show through, 0 (opaque) to 100.
    public var blend = 0

    public init() {}
}

/// Everything the UI draws, built by applying redraw events in order. A value: the session hands a copy to the UI at
/// every `flush`, and nothing the UI holds changes under it.
public struct Screen: Sendable {
    public private(set) var grids: [Int: GridBuffer] = [:]
    public private(set) var placements: [Int: Placement] = [:]
    public private(set) var highlights: [Int: Highlight] = [:]
    public private(set) var defaultForeground = 0xCFD3D8
    public private(set) var defaultBackground = 0x0C0D0F
    public private(set) var cursorGrid = 1
    public private(set) var cursorRow = 0
    public private(set) var cursorCol = 0
    public private(set) var mode = "normal"
    /// The cursor for each mode, from `mode_info_set`, and the index of the current one.
    public private(set) var modeInfo: [ModeInfo] = []
    public private(set) var modeIndex = 0
    /// nvim is busy (`busy_start`): the cursor is hidden.
    public private(set) var busy = false
    public private(set) var title = ""
    /// Terminal panes by the handle of the placeholder window backing them, as sill's runtime last reported.
    public private(set) var panes: [Int: Int] = [:]

    public init() {}

    /// Applies one event. True when it was `flush`, the point where the screen is consistent and can be drawn.
    @discardableResult
    public mutating func apply(_ event: NvimEvent) -> Bool {
        switch event {
        case .flush:
            return true
        case let .gridResize(grid, width, height):
            grids[grid, default: GridBuffer()].resize(rows: height, cols: width)
        case let .gridLine(grid, row, colStart, cells):
            grids[grid]?.put(row: row, colStart: colStart, cells: cells)
        case let .gridClear(grid):
            grids[grid]?.clear()
        case let .gridScroll(grid, top, bottom, left, right, rows, _):
            grids[grid]?.scroll(top: top, bottom: bottom, left: left, right: right, count: rows)
        case let .gridCursorGoto(grid, row, col):
            (cursorGrid, cursorRow, cursorCol) = (grid, row, col)
        case let .gridDestroy(grid):
            grids[grid] = nil
            placements[grid] = nil
        case let .winPos(grid, win, row, col, width, height):
            placements[grid] = Placement(kind: .window, win: win, row: row, col: col, width: width, height: height)
        case let .winFloatPos(grid, win, _, _, _, _, _, compindex, screenRow, screenCol):
            // nvim works out where the float lands (screen_row/col); its size is the grid's.
            let size = grids[grid]
            placements[grid] = Placement(
                kind: .float, win: win, row: screenRow, col: screenCol, width: size?.cols ?? 0,
                height: size?.rows ?? 0, compindex: compindex
            )
        case let .winHide(grid):
            placements[grid]?.hidden = true
        case let .winClose(grid):
            placements[grid] = nil
        case let .msgSetPos(grid, row, _, _, compindex):
            let size = grids[grid]
            placements[grid] = Placement(
                kind: .message, win: 0, row: row, col: 0, width: size?.cols ?? 0, height: size?.rows ?? 0,
                compindex: compindex
            )
        case let .hlAttrDefine(id, rgbAttrs, _, _):
            highlights[id] = Self.highlight(rgbAttrs)
        case let .defaultColorsSet(rgbFg, rgbBg, _, _, _):
            if rgbFg >= 0 { defaultForeground = rgbFg }
            if rgbBg >= 0 { defaultBackground = rgbBg }
        case let .modeChange(mode, index):
            self.mode = mode
            modeIndex = index
        case let .modeInfoSet(_, list):
            modeInfo = list
        case .busyStart:
            busy = true
        case .busyStop:
            busy = false
        case let .setTitle(title):
            self.title = title
        case let .notification(method, args) where method == "sill_panes":
            panes = Self.panes(args)
        default:
            break
        }
        return false
    }

    /// The grid the cursor is in, and the window that grid belongs to. nvim moves the cursor to the current window,
    /// so this is the current window except while the command line has it.
    public var cursorWindow: Int? {
        guard let placement = placements[cursorGrid], placement.kind == .window else { return nil }
        return placement.win
    }

    /// How the cursor looks in the current mode; nil when nvim hides it (busy).
    public var cursorStyle: ModeInfo? {
        guard !busy else { return nil }
        if modeInfo.indices.contains(modeIndex) { return modeInfo[modeIndex] }
        return ModeInfo(name: mode, cursorShape: .block, cellPercentage: 100)
    }

    /// The terminal pane whose placeholder window is the current window, if any.
    public var currentPane: Int? {
        cursorWindow.flatMap { panes[$0] }
    }

    /// Every terminal pane on screen, at the cells of its placeholder window.
    public var paneRects: [PaneRect] {
        placements.compactMap { grid, placement in
            guard placement.kind == .window, !placement.hidden, let pane = panes[placement.win] else { return nil }
            return PaneRect(
                pane: pane, win: placement.win, grid: grid, row: placement.row, col: placement.col,
                width: placement.width, height: placement.height
            )
        }
        .sorted { $0.pane < $1.pane }
    }

    /// The grid on top at a cell of grid 1, and the cell in that grid's own coordinates: where a click goes.
    public func hit(row: Int, col: Int) -> (grid: Int, row: Int, col: Int) {
        let hit = drawOrder.last { _, placement in
            row >= placement.row && row < placement.row + placement.height &&
                col >= placement.col && col < placement.col + placement.width
        }
        guard let (grid, placement) = hit else { return (1, row, col) }
        return (grid, row - placement.row, col - placement.col)
    }

    /// Grids in drawing order: grid 1, the windows, then floats and the message grid by their compindex.
    public var drawOrder: [(grid: Int, placement: Placement)] {
        let visible = placements.filter { !$0.value.hidden }.map { (grid: $0.key, placement: $0.value) }
        let windows = visible.filter { $0.placement.kind == .window }.sorted { $0.grid < $1.grid }
        let above = visible.filter { $0.placement.kind != .window }.sorted {
            ($0.placement.compindex, $0.grid) < ($1.placement.compindex, $1.grid)
        }
        let root = Placement(
            kind: .window, win: 0, row: 0, col: 0, width: grids[1]?.cols ?? 0, height: grids[1]?.rows ?? 0
        )
        return [(grid: 1, placement: root)] + windows + above
    }

    // MARK: Parsing

    /// `sill_panes`: one argument, a list of `[win, pane]` pairs.
    static func panes(_ args: [MessagePackValue]) -> [Int: Int] {
        var result: [Int: Int] = [:]
        for pair in args.first?.arrayValue ?? [] {
            guard let pair = pair.arrayValue, pair.count == 2 else { continue }
            result[pair[0].intValue] = pair[1].intValue
        }
        return result
    }

    static func highlight(_ attrs: [String: MessagePackValue]) -> Highlight {
        var highlight = Highlight()
        for (key, value) in attrs {
            switch key {
            case "foreground": highlight.foreground = value.intValue
            case "background": highlight.background = value.intValue
            case "special": highlight.special = value.intValue
            case "reverse": highlight.reverse = value.boolValue ?? false
            case "bold": highlight.bold = value.boolValue ?? false
            case "italic": highlight.italic = value.boolValue ?? false
            case "underline": highlight.underline = value.boolValue ?? false
            case "undercurl": highlight.undercurl = value.boolValue ?? false
            case "strikethrough": highlight.strikethrough = value.boolValue ?? false
            case "underdouble": highlight.underdouble = value.boolValue ?? false
            case "underdotted": highlight.underdotted = value.boolValue ?? false
            case "underdashed": highlight.underdashed = value.boolValue ?? false
            case "blend": highlight.blend = min(max(value.intValue, 0), 100)
            default: break
            }
        }
        return highlight
    }
}
