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
    /// `terminal`, `sidebar` or `panel`.
    public var kind: String = "terminal"
    public var win: Int
    public var grid: Int
    public var row: Int
    public var col: Int
    public var width: Int
    public var height: Int
}

/// A diagnostic, as `vim.diagnostic` has it: what the Problems panel lists.
public struct Diagnostic: Sendable, Equatable {
    /// 1 error, 2 warning, 3 information, 4 hint.
    public var severity: Int
    public var message: String
    public var source: String
    public var code: String
    public var path: String
    /// The buffer it is in: a problem in a buffer with no file has no path.
    public var buffer: Int
    public var line: Int
    public var col: Int

    public init(
        severity: Int, message: String, source: String, code: String, path: String, buffer: Int, line: Int, col: Int
    ) {
        self.severity = severity
        self.message = message
        self.source = source
        self.code = code
        self.path = path
        self.buffer = buffer
        self.line = line
        self.col = col
    }
}

/// An editor window's tabs: the files opened in it, and which it shows.
public struct WindowTabs: Sendable, Equatable {
    public struct Tab: Sendable, Equatable {
        public var buffer: Int
        public var name: String
        public var modified: Bool
    }

    public var win: Int
    public var current: Int
    public var tabs: [Tab]

    public init(win: Int, current: Int, tabs: [Tab]) {
        self.win = win
        self.current = current
        self.tabs = tabs
    }
}

/// The current buffer, as sill's runtime reports it: what the status bar shows.
public struct BufferInfo: Sendable, Equatable {
    public var path = ""
    public var name = ""
    public var filetype = ""
    public var modified = false
    /// The pane kind when the buffer is a pane's placeholder; empty for a file.
    public var kind = ""

    public init() {}
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

/// The command line, as `ext_cmdline` describes it.
public struct Cmdline: Sendable, Equatable {
    public var content: [StyledChunk]
    /// The cursor, as a byte offset into `text`.
    public var pos: Int
    /// `:`, `/`, `?`, or empty for a prompt.
    public var firstc: String
    /// An `input()` prompt.
    public var prompt: String
    public var indent: Int
    public var level: Int
    /// A pending special character (after <C-v>, say), shown at the cursor.
    public var special: String?

    public var text: String { content.map(\.text).joined() }

    /// The cursor as a character index into `text`.
    public var cursorIndex: Int {
        let bytes = Array(text.utf8)
        return String(decoding: bytes.prefix(min(max(pos, 0), bytes.count)), as: UTF8.self).count
    }
}

/// A message on screen (`msg_show`).
public struct Message: Sendable, Equatable {
    public var kind: String
    public var content: [StyledChunk]
    public var id: String
    /// Grows with every message shown, so a view can tell a new message from one it already has.
    public var serial: Int

    public var text: String { content.map(\.text).joined() }

    /// Errors and warnings stay longer and are coloured.
    public var isError: Bool { ["emsg", "echoerr", "lua_error", "rpc_error", "shell_err"].contains(kind) }
    public var isWarning: Bool { kind == "wmsg" }
    /// Listings and command output read as a block, not a notification.
    public var isOutput: Bool {
        ["list_cmd", "shell_out", "shell_err", "shell_ret", "wildlist", "verbose"].contains(kind) ||
            text.split(separator: "\n", omittingEmptySubsequences: false).count > 3
    }
}

/// The completion popup (`ext_popupmenu`).
public struct PopupMenu: Sendable, Equatable {
    public var items: [PopupItem]
    public var selected: Int
    /// Where the completed word starts: a cell of `grid`, or with `grid` -1 a byte offset into the command line.
    public var row: Int
    public var col: Int
    public var grid: Int
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
    /// Command lines by nesting level; the deepest is the one being edited.
    public private(set) var commandLines: [Int: Cmdline] = [:]
    /// Context shown above the command line (a `:function` being typed, say).
    public private(set) var commandLineBlock: [[StyledChunk]] = []
    public private(set) var messages: [Message] = []
    /// The history `:messages` asked for, shown until dismissed.
    public private(set) var messageHistory: [Message]?
    public private(set) var showmode: [StyledChunk] = []
    public private(set) var showcmd: [StyledChunk] = []
    public private(set) var ruler: [StyledChunk] = []
    public private(set) var popupMenu: PopupMenu?
    public private(set) var tabs: [TabpageInfo] = []
    public private(set) var currentTab = 0
    private var messageSerial = 0
    /// Terminal panes by the handle of the placeholder window backing them, as sill's runtime last reported.
    public private(set) var panes: [Int: Int] = [:]
    /// Each pane's kind: `terminal`, `sidebar` or `panel`.
    public private(set) var paneKinds: [Int: String] = [:]
    public private(set) var buffer = BufferInfo()
    public private(set) var diagnostics: [Diagnostic] = []
    /// Language servers sill starts, by name: `starting`, `ready` or `stopped`.
    public private(set) var languageServers: [String: String] = [:]
    /// A merge in progress (`:SillMerge`): conflicts left in the result, the one under the cursor (1-based, 0 for
    /// none), and the file.
    public private(set) var merge: (left: Int, current: Int, file: String)?
    /// What nvim asked of the agents last (`:SillAgent next|send|list`), numbered so the same ask twice is two.
    public private(set) var agentAsk: (action: String, serial: Int)?
    /// The files the person wrote from nvim, the latest last (at most 50), and how many writes in all.
    public private(set) var written: [String] = []
    public private(set) var writes = 0
    /// `:SillAsk` questions: the file, its lines and the question.
    public private(set) var askQuestions: [(path: String, from: Int, to: Int, lines: [String], question: String)] = []
    /// `:SillTelemetry` asks: a pid, "stop", or "" to pick.
    public private(set) var telemetryAsks: [String] = []
    /// How many times `:SillFollow` was asked.
    public private(set) var followAsks = 0
    /// `:SillHooks install|remove|status`.
    public private(set) var hooksAsks: [String] = []
    /// `:SillPR`: the worktree's pull request, asked for.
    public private(set) var pullRequestAsks = 0
    /// `:SillSummary`: the checkout's summary, asked for.
    public private(set) var summaryAsks = 0
    /// `:SillReplay [session]`: a session's log to replay ("" to pick one).
    public private(set) var replayAsks: [String] = []
    /// `:SillMap`s asked for.
    public private(set) var mapAsks = 0
    /// `:SillBasket`s: what is asked (new, add, send, open, or pick), its argument, and for add the file, its lines
    /// and what they are in the editor (none: the whole file).
    public struct BasketAsk: Equatable, Sendable {
        public var action: String
        public var argument: String
        public var path: String?
        public var from: Int?
        public var to: Int?
        public var lines: [String]?
    }

    public private(set) var basketAsks: [BasketAsk] = []
    /// `:SillTrace`s: the place of the symbol to trace and which way.
    public private(set) var traceAsks: [(path: String, line: Int, column: Int, direction: String)] = []
    /// `:SillWalk` asks: open a walkthrough, install the skill.
    public private(set) var walkAsks: [(action: String, argument: String)] = []
    /// `:SillReview` asks: "show" or "mark".
    public private(set) var reviewAsks: [String] = []
    /// How many times the packages were asked for (`:SillPackages`).
    public private(set) var packagesAsks = 0
    /// What nvim asked of the debugger (`:SillDebug …`), in order.
    public private(set) var debugAsks: [String] = []
    /// A breakpoint: its line as it is now, and what it has beyond it.
    public struct Breakpoint: Equatable, Sendable {
        public var line: Int
        /// Break only when this is true.
        public var condition: String?
        /// Break on these hits (`5`, `>=5`, `%5`).
        public var hit: String?
        /// Log this (expressions in braces) instead of breaking.
        public var log: String?

        public init(line: Int, condition: String? = nil, hit: String? = nil, log: String? = nil) {
            self.line = line
            self.condition = condition
            self.hit = hit
            self.log = log
        }
    }

    /// The breakpoints nvim has, by file.
    public private(set) var breakpoints: [String: [Breakpoint]] = [:]
    /// Zen mode (`:SillZen`): only the text, in a column.
    public private(set) var zen = false
    /// Function breakpoints, by the method's name.
    public private(set) var functionBreakpoints: [String] = []
    /// The language servers nvim asked sill for (`sill_server`), in order: each the first time a file it serves opened.
    public private(set) var serverAsks: [String] = []
    /// What nvim asked of the solution last (`:SillSlnx sync|apply`), numbered likewise.
    public private(set) var slnxAsk: (action: String, serial: Int)?
    /// What nvim asked of the profiler last (`:SillProfile run|snapshot|stop|synthetic`), numbered likewise.
    public private(set) var profileAsk: (action: String, serial: Int)?
    /// Each editor window's tabs, by window handle.
    public private(set) var windowTabs: [Int: WindowTabs] = [:]

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
        case let .winViewport(grid, _, _, _, curline, curcol, _, scrollDelta):
            viewportCursors[grid] = (curline, curcol)
            if scrollDelta != 0 {
                scrollSerial += 1
                scrolls[grid] = Scroll(lines: scrollDelta, serial: scrollSerial)
            }
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
        case let .cmdlineShow(content, pos, firstc, prompt, indent, level):
            commandLines[level] = Cmdline(
                content: content, pos: pos, firstc: firstc, prompt: prompt, indent: indent, level: level
            )
        case let .cmdlinePos(pos, level):
            commandLines[level]?.pos = pos
        case let .cmdlineSpecialChar(char, _, level):
            commandLines[level]?.special = char
        case let .cmdlineHide(level, _):
            commandLines[level] = nil
            if commandLines.isEmpty { commandLineBlock = [] }
        case let .cmdlineBlockShow(lines):
            commandLineBlock = lines
        case let .cmdlineBlockAppend(line):
            commandLineBlock.append(line)
        case .cmdlineBlockHide:
            commandLineBlock = []
        case let .msgShow(kind, content, replaceLast, _, append, id):
            show(kind: kind, content: content, replaceLast: replaceLast, append: append, id: id)
        case .msgClear:
            messages = []
        case let .msgShowmode(content):
            showmode = content
        case let .msgShowcmd(content):
            showcmd = content
        case let .msgRuler(content):
            ruler = content
        case let .msgHistoryShow(entries):
            messageHistory = entries.map { entry in
                messageSerial += 1
                return Message(kind: entry.kind, content: entry.content, id: "", serial: messageSerial)
            }
        case .msgHistoryClear:
            messageHistory = nil
        case let .popupmenuShow(items, selected, row, col, grid):
            popupMenu = PopupMenu(items: items, selected: selected, row: row, col: col, grid: grid)
        case let .popupmenuSelect(selected):
            popupMenu?.selected = selected
        case .popupmenuHide:
            popupMenu = nil
        case let .tablineUpdate(current, tabs):
            currentTab = current
            self.tabs = tabs
        case let .notification(method, args) where method == "sill_panes":
            (panes, paneKinds) = Self.panes(args)
        case let .notification(method, args) where method == "sill_buffer":
            buffer = Self.buffer(args)
        case let .notification(method, args) where method == "sill_lsp":
            let fields = args.first?.dictionaryValue ?? [:]
            if let name = fields[.string("name")]?.stringValue {
                languageServers[name] = fields[.string("status")]?.stringValue ?? ""
            }
        case let .notification(method, args) where method == "sill_merge":
            var left = 0, current = 0, file = ""
            for (key, value) in args.first?.dictionaryValue ?? [:] {
                switch key.stringValue {
                case "left": left = value.intValue
                case "current": current = value.intValue
                case "file": file = value.stringValue ?? ""
                default: break
                }
            }
            merge = (left, current, file)
        case let .notification(method, args) where method == "sill_zen":
            zen = args.first?.boolValue ?? false
        case let .notification(method, args) where method == "sill_wrote":
            if let path = args.first?.stringValue {
                writes += 1
                written.append(path)
                if written.count > 50 { written.removeFirst(written.count - 50) }
            }
        case let .notification(method, args) where method == "sill_ask":
            if let map = args.first?.dictionaryValue, let path = map[.string("path")]?.stringValue,
               let question = map[.string("question")]?.stringValue
            {
                askQuestions.append((
                    path,
                    Int(map[.string("from")]?.integerValue ?? 1),
                    Int(map[.string("to")]?.integerValue ?? 1),
                    (map[.string("lines")]?.arrayValue ?? []).compactMap(\.stringValue),
                    question
                ))
            }
        case let .notification(method, args) where method == "sill_telemetry":
            telemetryAsks.append(args.first?.stringValue ?? "")
        case let .notification(method, _) where method == "sill_follow":
            followAsks += 1
        case let .notification(method, args) where method == "sill_hooks":
            hooksAsks.append(args.first?.stringValue ?? "status")
        case let .notification(method, _) where method == "sill_pr":
            pullRequestAsks += 1
        case let .notification(method, _) where method == "sill_summary":
            summaryAsks += 1
        case let .notification(method, args) where method == "sill_replay":
            replayAsks.append(args.first?.stringValue ?? "")
        case let .notification(method, _) where method == "sill_map":
            mapAsks += 1
        case let .notification(method, args) where method == "sill_basket":
            if let map = args.first?.dictionaryValue {
                basketAsks.append(BasketAsk(
                    action: map[.string("action")]?.stringValue ?? "pick",
                    argument: map[.string("arg")]?.stringValue ?? "",
                    path: map[.string("path")]?.stringValue,
                    from: map[.string("from")]?.integerValue.map(Int.init),
                    to: map[.string("to")]?.integerValue.map(Int.init),
                    lines: map[.string("lines")]?.arrayValue?.compactMap(\.stringValue)
                ))
            }
        case let .notification(method, args) where method == "sill_trace":
            if let map = args.first?.dictionaryValue, let path = map[.string("path")]?.stringValue {
                traceAsks.append((
                    path,
                    Int(map[.string("line")]?.integerValue ?? 1),
                    Int(map[.string("col")]?.integerValue ?? 1),
                    map[.string("direction")]?.stringValue ?? "incoming"
                ))
            }
        case let .notification(method, args) where method == "sill_walk":
            walkAsks.append((args.first?.stringValue ?? "", args.count > 1 ? args[1].stringValue ?? "" : ""))
        case let .notification(method, args) where method == "sill_review":
            reviewAsks.append(args.first?.stringValue ?? "show")
        case let .notification(method, _) where method == "sill_packages":
            packagesAsks += 1
        case let .notification(method, args) where method == "sill_debug":
            if let action = args.first?.stringValue { debugAsks.append(action) }
        case let .notification(method, args) where method == "sill_breakpoints":
            var found: [String: [Breakpoint]] = [:]
            for (key, value) in args.first?.dictionaryValue ?? [:] {
                guard let path = key.stringValue else { continue }
                found[path] = (value.arrayValue ?? []).compactMap { entry in
                    // A bare line (as before), or a map with the line and what it has beyond it.
                    if let line = entry.integerValue { return Breakpoint(line: Int(line)) }
                    guard let map = entry.dictionaryValue, let line = map[.string("line")]?.integerValue else {
                        return nil
                    }
                    return Breakpoint(
                        line: Int(line),
                        condition: map[.string("condition")]?.stringValue,
                        hit: map[.string("hit")]?.stringValue,
                        log: map[.string("log")]?.stringValue
                    )
                }
            }
            breakpoints = found
            functionBreakpoints = (args.count > 1 ? args[1].arrayValue ?? [] : []).compactMap(\.stringValue)
        case let .notification(method, args) where method == "sill_server":
            if let name = args.first?.stringValue { serverAsks.append(name) }
        case let .notification(method, args) where method == "sill_slnx":
            slnxAsk = (args.first?.stringValue ?? "", (slnxAsk?.serial ?? 0) + 1)
        case let .notification(method, args) where method == "sill_profile":
            profileAsk = (args.first?.stringValue ?? "", (profileAsk?.serial ?? 0) + 1)
        case let .notification(method, args) where method == "sill_agent":
            agentAsk = (args.first?.stringValue ?? "", (agentAsk?.serial ?? 0) + 1)
        case let .notification(method, args) where method == "sill_tabs":
            windowTabs = Self.windowTabs(args)
        case let .notification(method, args) where method == "sill_diagnostics":
            diagnostics = (args.first?.arrayValue ?? []).compactMap(Self.diagnostic)
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

    /// The command line being edited, if any: the deepest level shown.
    public var commandLine: Cmdline? {
        commandLines.max { $0.key < $1.key }?.value
    }

    /// The history `:messages` showed has been read; it goes until asked for again.
    public mutating func dismissMessageHistory() {
        messageHistory = nil
    }

    /// The highlight of a chunk: its own attributes (the command line), else its attribute id's.
    public func highlight(of chunk: StyledChunk) -> Highlight {
        if let attrs = chunk.attrs { return Self.highlight(attrs) }
        return highlights[chunk.attrId] ?? Highlight()
    }

    private mutating func show(kind: String, content: [StyledChunk], replaceLast: Bool, append: Bool, id: String) {
        if kind == "empty", content.allSatisfy(\.text.isEmpty) {
            messages = []
            return
        }
        messageSerial += 1
        let message = Message(kind: kind, content: content, id: id, serial: messageSerial)
        if !id.isEmpty, let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index] = message
        } else if append, var last = messages.popLast() {
            last.content += content
            last.serial = messageSerial
            messages.append(last)
        } else if replaceLast, !messages.isEmpty {
            messages[messages.count - 1] = message
        } else {
            messages.append(message)
        }
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
                pane: pane, kind: paneKinds[pane] ?? "terminal", win: placement.win, grid: grid, row: placement.row,
                col: placement.col,
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

    /// `sill_panes`: one argument, a list of `[win, pane, kind]`.
    static func panes(_ args: [MessagePackValue]) -> (panes: [Int: Int], kinds: [Int: String]) {
        var panes: [Int: Int] = [:], kinds: [Int: String] = [:]
        for entry in args.first?.arrayValue ?? [] {
            guard let entry = entry.arrayValue, entry.count >= 2 else { continue }
            panes[entry[0].intValue] = entry[1].intValue
            kinds[entry[1].intValue] = entry.count > 2 ? entry[2].stringValue ?? "terminal" : "terminal"
        }
        return (panes, kinds)
    }

    /// `sill_buffer`: one argument, a map of the buffer's path, name, file type, modified and kind.
    static func buffer(_ args: [MessagePackValue]) -> BufferInfo {
        var info = BufferInfo()
        for (key, value) in args.first?.dictionaryValue ?? [:] {
            switch key.stringValue {
            case "path": info.path = value.stringValue ?? ""
            case "name": info.name = value.stringValue ?? ""
            case "filetype": info.filetype = value.stringValue ?? ""
            case "modified": info.modified = value.boolValue ?? false
            case "kind": info.kind = value.stringValue ?? ""
            default: break
            }
        }
        return info
    }

    /// `sill_tabs`: one argument, a list of `[win, current buffer, [[buffer, name, modified], ...]]`.
    static func windowTabs(_ args: [MessagePackValue]) -> [Int: WindowTabs] {
        var result: [Int: WindowTabs] = [:]
        for entry in args.first?.arrayValue ?? [] {
            guard let entry = entry.arrayValue, entry.count >= 3 else { continue }
            let tabs = (entry[2].arrayValue ?? []).compactMap { tab -> WindowTabs.Tab? in
                guard let t = tab.arrayValue, t.count >= 3 else { return nil }
                return WindowTabs.Tab(
                    buffer: t[0].intValue,
                    name: t[1].stringValue ?? "",
                    modified: t[2].boolValue ?? false
                )
            }
            result[entry[0].intValue] = WindowTabs(win: entry[0].intValue, current: entry[1].intValue, tabs: tabs)
        }
        return result
    }

    static func diagnostic(_ value: MessagePackValue) -> Diagnostic? {
        guard let map = value.dictionaryValue else { return nil }
        var fields: [String: MessagePackValue] = [:]
        for (key, value) in map {
            if let key = key.stringValue { fields[key] = value }
        }
        return Diagnostic(
            severity: fields["severity"]?.intValue ?? 1, message: fields["message"]?.stringValue ?? "",
            source: fields["source"]?.stringValue ?? "", code: fields["code"]?.stringValue ?? "",
            path: fields["path"]?.stringValue ?? "", buffer: fields["buffer"]?.intValue ?? 0,
            line: fields["line"]?.intValue ?? 1,
            col: fields["col"]?.intValue ?? 1
        )
    }

    /// The kind of the pane whose window is current, if one is.
    public var currentPaneKind: String? {
        currentPane.flatMap { paneKinds[$0] }
    }

    /// A window's last scroll: how many lines its top moved (down positive), and a serial that grows with every
    /// scroll, so a view can tell a new one from one it has already animated.
    public struct Scroll: Sendable, Equatable {
        public var lines: Int
        public var serial: Int
    }

    public private(set) var scrolls: [Int: Scroll] = [:]
    private var scrollSerial = 0

    /// Each window grid's cursor, from `win_viewport`: line and column, zero-based.
    public private(set) var viewportCursors: [Int: (line: Int, column: Int)] = [:]

    /// The cursor in the current window, one-based, as a status bar shows it.
    public var cursorPosition: (line: Int, column: Int)? {
        viewportCursors[cursorGrid].map { ($0.line + 1, $0.column + 1) }
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
