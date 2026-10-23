// Lifted from Veil (https://github.com/0x1b2c/Veil, MIT, a29c3d0); see THIRD_PARTY_NOTICES.md.
import Foundation
import MessagePack

// MARK: - Supporting types

public struct GridCellData: Equatable, Sendable {
    public var text: String
    public var hlId: Int
    public var repeats: Int

    public init(text: String, hlId: Int, repeats: Int) {
        self.text = text
        self.hlId = hlId
        self.repeats = repeats
    }
}

public struct TabpageInfo: Equatable, Sendable {
    public var handle: Int
    public var name: String

    public init(handle: Int, name: String) {
        self.handle = handle
        self.name = name
    }
}

/// A run of text in one highlight, as the command line and messages send it. The highlight is an attribute id
/// (messages) or the attributes themselves (the command line).
public struct StyledChunk: Equatable, Sendable {
    public var text: String
    public var attrId: Int
    public var attrs: [String: MessagePackValue]?

    public init(text: String, attrId: Int = 0, attrs: [String: MessagePackValue]? = nil) {
        self.text = text
        self.attrId = attrId
        self.attrs = attrs
    }
}

/// An item of the completion popup: `[word, kind, menu, info]`.
public struct PopupItem: Equatable, Sendable {
    public var word: String
    public var kind: String
    public var menu: String
    public var info: String

    public init(word: String, kind: String = "", menu: String = "", info: String = "") {
        self.word = word
        self.kind = kind
        self.menu = menu
        self.info = info
    }
}

public struct ModeInfo: Equatable, Sendable {
    public enum CursorShape: String, Equatable, Sendable {
        case block
        case horizontal
        case vertical
    }

    public var name: String
    public var cursorShape: CursorShape
    public var cellPercentage: Int
    /// The highlight the cursor is drawn in; 0 for the default (reversed colours).
    public var attrId = 0

    public init(name: String, cursorShape: CursorShape, cellPercentage: Int, attrId: Int = 0) {
        self.name = name
        self.cursorShape = cursorShape
        self.cellPercentage = cellPercentage
        self.attrId = attrId
    }
}

// MARK: - NvimEvent

public enum NvimEvent: Sendable {
    case gridResize(grid: Int, width: Int, height: Int)
    case gridLine(grid: Int, row: Int, colStart: Int, cells: [GridCellData])
    case gridClear(grid: Int)
    case gridCursorGoto(grid: Int, row: Int, col: Int)
    case gridScroll(grid: Int, top: Int, bottom: Int, left: Int, right: Int, rows: Int, cols: Int)
    case flush
    case hlAttrDefine(
        id: Int, rgbAttrs: [String: MessagePackValue], ctermAttrs: [String: MessagePackValue],
        info: [MessagePackValue]
    )
    case defaultColorsSet(rgbFg: Int, rgbBg: Int, rgbSp: Int, ctermFg: Int, ctermBg: Int)
    case modeChange(mode: String, modeIdx: Int)
    case modeInfoSet(enabled: Bool, modeInfoList: [ModeInfo])
    case tablineUpdate(current: Int, tabs: [TabpageInfo])
    case setTitle(title: String)
    case optionSet(name: String, value: MessagePackValue)
    case bell
    case visualBell
    case mouseOn
    case mouseOff
    case busyStart
    case busyStop
    // Multigrid (`ext_multigrid`): where each window's grid sits on the default grid 1.
    case winPos(grid: Int, win: Int, row: Int, col: Int, width: Int, height: Int)
    case winFloatPos(
        grid: Int, win: Int, anchor: String, anchorGrid: Int, anchorRow: Double, anchorCol: Double, zindex: Int,
        compindex: Int, screenRow: Int, screenCol: Int
    )
    case winHide(grid: Int)
    case winClose(grid: Int)
    case gridDestroy(grid: Int)
    case msgSetPos(grid: Int, row: Int, scrolled: Bool, zindex: Int, compindex: Int)
    case winViewport(
        grid: Int, win: Int, topline: Int, botline: Int, curline: Int, curcol: Int, lineCount: Int, scrollDelta: Int
    )
    // The command line (`ext_cmdline`). `pos` is a byte offset into the content's text.
    case cmdlineShow(content: [StyledChunk], pos: Int, firstc: String, prompt: String, indent: Int, level: Int)
    case cmdlinePos(pos: Int, level: Int)
    case cmdlineSpecialChar(char: String, shift: Bool, level: Int)
    case cmdlineHide(level: Int, abort: Bool)
    case cmdlineBlockShow(lines: [[StyledChunk]])
    case cmdlineBlockAppend(line: [StyledChunk])
    case cmdlineBlockHide
    // Messages (`ext_messages`).
    case msgShow(kind: String, content: [StyledChunk], replaceLast: Bool, history: Bool, append: Bool, id: String)
    case msgClear
    case msgShowmode(content: [StyledChunk])
    case msgShowcmd(content: [StyledChunk])
    case msgRuler(content: [StyledChunk])
    case msgHistoryShow(entries: [(kind: String, content: [StyledChunk])])
    case msgHistoryClear
    // Completion (`ext_popupmenu`). `grid` is -1 when the popup belongs to the command line.
    case popupmenuShow(items: [PopupItem], selected: Int, row: Int, col: Int, grid: Int)
    case popupmenuSelect(selected: Int)
    case popupmenuHide
    /// An `rpcnotify` from sill's runtime (anything but `redraw`), delivered in order with the redraw batches.
    case notification(method: String, args: [MessagePackValue])

    // MARK: - Parse

    public nonisolated static func parse(redrawArgs: [MessagePackValue]) -> [NvimEvent] {
        var events: [NvimEvent] = []
        for arg in redrawArgs {
            guard let array = arg.arrayValue, let eventName = array.first?.stringValue else {
                continue
            }
            let eventArgs = Array(array.dropFirst())
            switch eventName {
            case "flush":
                events.append(.flush)
            case "bell":
                events.append(.bell)
            case "visual_bell":
                events.append(.visualBell)
            case "mouse_on":
                events.append(.mouseOn)
            case "mouse_off":
                events.append(.mouseOff)
            case "busy_start":
                events.append(.busyStart)
            case "busy_stop":
                events.append(.busyStop)
            case "grid_resize":
                for args in eventArgs {
                    guard let a = args.arrayValue, a.count >= 3 else { continue }
                    let grid = a[0].intValue
                    let width = a[1].intValue
                    let height = a[2].intValue
                    events.append(.gridResize(grid: grid, width: width, height: height))
                }
            case "grid_line":
                for args in eventArgs {
                    guard let a = args.arrayValue, a.count >= 4 else { continue }
                    let grid = a[0].intValue
                    let row = a[1].intValue
                    let colStart = a[2].intValue
                    guard let rawCells = a[3].arrayValue else { continue }
                    let cells = parseGridLineCells(rawCells)
                    events.append(.gridLine(grid: grid, row: row, colStart: colStart, cells: cells))
                }
            case "grid_clear":
                for args in eventArgs {
                    guard let a = args.arrayValue, a.count >= 1 else { continue }
                    events.append(.gridClear(grid: a[0].intValue))
                }
            case "grid_cursor_goto":
                for args in eventArgs {
                    guard let a = args.arrayValue, a.count >= 3 else { continue }
                    events.append(
                        .gridCursorGoto(grid: a[0].intValue, row: a[1].intValue, col: a[2].intValue)
                    )
                }
            case "grid_scroll":
                for args in eventArgs {
                    guard let a = args.arrayValue, a.count >= 7 else { continue }
                    events.append(
                        .gridScroll(
                            grid: a[0].intValue,
                            top: a[1].intValue,
                            bottom: a[2].intValue,
                            left: a[3].intValue,
                            right: a[4].intValue,
                            rows: a[5].intValue,
                            cols: a[6].intValue
                        ))
                }
            case "cmdline_show":
                for args in eventArgs {
                    guard let a = args.arrayValue, a.count >= 6 else { continue }
                    events.append(.cmdlineShow(
                        content: chunks(a[0]), pos: a[1].intValue, firstc: a[2].stringValue ?? "",
                        prompt: a[3].stringValue ?? "", indent: a[4].intValue, level: a[5].intValue
                    ))
                }
            case "cmdline_pos":
                for args in eventArgs {
                    guard let a = args.arrayValue, a.count >= 2 else { continue }
                    events.append(.cmdlinePos(pos: a[0].intValue, level: a[1].intValue))
                }
            case "cmdline_special_char":
                for args in eventArgs {
                    guard let a = args.arrayValue, a.count >= 3 else { continue }
                    events.append(.cmdlineSpecialChar(
                        char: a[0].stringValue ?? "", shift: a[1].boolValue ?? false, level: a[2].intValue
                    ))
                }
            case "cmdline_hide":
                for args in eventArgs {
                    let a = args.arrayValue ?? []
                    events.append(.cmdlineHide(
                        level: a.first?.intValue ?? 1, abort: a.count > 1 ? a[1].boolValue ?? false : false
                    ))
                }
            case "cmdline_block_show":
                for args in eventArgs {
                    guard let a = args.arrayValue, let lines = a.first?.arrayValue else { continue }
                    events.append(.cmdlineBlockShow(lines: lines.map(chunks)))
                }
            case "cmdline_block_append":
                for args in eventArgs {
                    guard let a = args.arrayValue, let line = a.first else { continue }
                    events.append(.cmdlineBlockAppend(line: chunks(line)))
                }
            case "cmdline_block_hide":
                events.append(.cmdlineBlockHide)
            case "msg_show":
                for args in eventArgs {
                    guard let a = args.arrayValue, a.count >= 3 else { continue }
                    let id: String = a.count > 6 ? (a[6].stringValue ?? String(a[6].intValue)) : ""
                    events.append(.msgShow(
                        kind: a[0].stringValue ?? "", content: chunks(a[1]), replaceLast: a[2].boolValue ?? false,
                        history: a.count > 3 ? a[3].boolValue ?? false : false,
                        append: a.count > 4 ? a[4].boolValue ?? false : false, id: id
                    ))
                }
            case "msg_clear":
                events.append(.msgClear)
            case "msg_showmode":
                for args in eventArgs {
                    events.append(.msgShowmode(content: chunks(args.arrayValue?.first ?? .nil)))
                }
            case "msg_showcmd":
                for args in eventArgs {
                    events.append(.msgShowcmd(content: chunks(args.arrayValue?.first ?? .nil)))
                }
            case "msg_ruler":
                for args in eventArgs {
                    events.append(.msgRuler(content: chunks(args.arrayValue?.first ?? .nil)))
                }
            case "msg_history_show":
                for args in eventArgs {
                    guard let a = args.arrayValue, let entries = a.first?.arrayValue else { continue }
                    events.append(.msgHistoryShow(entries: entries.compactMap { entry in
                        guard let e = entry.arrayValue, e.count >= 2 else { return nil }
                        return (kind: e[0].stringValue ?? "", content: chunks(e[1]))
                    }))
                }
            case "msg_history_clear":
                events.append(.msgHistoryClear)
            case "popupmenu_show":
                for args in eventArgs {
                    guard let a = args.arrayValue, a.count >= 4, let items = a[0].arrayValue else { continue }
                    events.append(.popupmenuShow(
                        items: items.map { item in
                            let fields = (item.arrayValue ?? []).map { $0.stringValue ?? "" }
                            func field(_ index: Int) -> String { index < fields.count ? fields[index] : "" }
                            return PopupItem(word: field(0), kind: field(1), menu: field(2), info: field(3))
                        },
                        selected: a[1].intValue, row: a[2].intValue, col: a[3].intValue,
                        grid: a.count > 4 ? a[4].intValue : 1
                    ))
                }
            case "popupmenu_select":
                for args in eventArgs {
                    guard let a = args.arrayValue, let selected = a.first else { continue }
                    events.append(.popupmenuSelect(selected: selected.intValue))
                }
            case "popupmenu_hide":
                events.append(.popupmenuHide)
            case "win_pos":
                for args in eventArgs {
                    guard let a = args.arrayValue, a.count >= 6 else { continue }
                    events.append(.winPos(
                        grid: a[0].intValue, win: a[1].intValue, row: a[2].intValue, col: a[3].intValue,
                        width: a[4].intValue, height: a[5].intValue
                    ))
                }
            case "win_float_pos":
                for args in eventArgs {
                    guard let a = args.arrayValue, a.count >= 6 else { continue }
                    events.append(.winFloatPos(
                        grid: a[0].intValue, win: a[1].intValue, anchor: a[2].stringValue ?? "NW",
                        anchorGrid: a[3].intValue, anchorRow: a[4].numberValue, anchorCol: a[5].numberValue,
                        zindex: a.count > 7 ? a[7].intValue : 50, compindex: a.count > 8 ? a[8].intValue : 0,
                        screenRow: a.count > 9 ? a[9].intValue : 0, screenCol: a.count > 10 ? a[10].intValue : 0
                    ))
                }
            case "win_hide":
                for args in eventArgs {
                    guard let a = args.arrayValue, a.count >= 1 else { continue }
                    events.append(.winHide(grid: a[0].intValue))
                }
            case "win_close":
                for args in eventArgs {
                    guard let a = args.arrayValue, a.count >= 1 else { continue }
                    events.append(.winClose(grid: a[0].intValue))
                }
            case "grid_destroy":
                for args in eventArgs {
                    guard let a = args.arrayValue, a.count >= 1 else { continue }
                    events.append(.gridDestroy(grid: a[0].intValue))
                }
            case "msg_set_pos":
                for args in eventArgs {
                    guard let a = args.arrayValue, a.count >= 3 else { continue }
                    events.append(.msgSetPos(
                        grid: a[0].intValue, row: a[1].intValue, scrolled: a[2].boolValue ?? false,
                        zindex: a.count > 4 ? a[4].intValue : 200, compindex: a.count > 5 ? a[5].intValue : 0
                    ))
                }
            case "win_viewport":
                for args in eventArgs {
                    guard let a = args.arrayValue, a.count >= 7 else { continue }
                    events.append(.winViewport(
                        grid: a[0].intValue, win: a[1].intValue, topline: a[2].intValue, botline: a[3].intValue,
                        curline: a[4].intValue, curcol: a[5].intValue, lineCount: a[6].intValue,
                        scrollDelta: a.count > 7 ? a[7].intValue : 0
                    ))
                }
            case "hl_attr_define":
                for args in eventArgs {
                    guard let a = args.arrayValue, a.count >= 4 else { continue }
                    let id = a[0].intValue
                    let rgbAttrs =
                        a[1].dictionaryValue.flatMap { dict -> [String: MessagePackValue]? in
                            var result: [String: MessagePackValue] = [:]
                            for (k, v) in dict {
                                if let key = k.stringValue { result[key] = v }
                            }
                            return result
                        } ?? [:]
                    let ctermAttrs =
                        a[2].dictionaryValue.flatMap { dict -> [String: MessagePackValue]? in
                            var result: [String: MessagePackValue] = [:]
                            for (k, v) in dict {
                                if let key = k.stringValue { result[key] = v }
                            }
                            return result
                        } ?? [:]
                    let info = a[3].arrayValue ?? []
                    events.append(
                        .hlAttrDefine(
                            id: id, rgbAttrs: rgbAttrs, ctermAttrs: ctermAttrs, info: info
                        ))
                }
            case "default_colors_set":
                for args in eventArgs {
                    guard let a = args.arrayValue, a.count >= 5 else { continue }
                    events.append(
                        .defaultColorsSet(
                            rgbFg: a[0].intValue,
                            rgbBg: a[1].intValue,
                            rgbSp: a[2].intValue,
                            ctermFg: a[3].intValue,
                            ctermBg: a[4].intValue
                        ))
                }
            case "mode_change":
                for args in eventArgs {
                    guard let a = args.arrayValue, a.count >= 2,
                          let mode = a[0].stringValue
                    else { continue }
                    events.append(.modeChange(mode: mode, modeIdx: a[1].intValue))
                }
            case "mode_info_set":
                for args in eventArgs {
                    guard let a = args.arrayValue, a.count >= 2,
                          let enabled = a[0].boolValue,
                          let rawList = a[1].arrayValue
                    else { continue }
                    let modeInfoList = rawList.compactMap { parseModeInfo($0) }
                    events.append(.modeInfoSet(enabled: enabled, modeInfoList: modeInfoList))
                }
            case "tabline_update":
                for args in eventArgs {
                    guard let a = args.arrayValue, a.count >= 2,
                          let rawTabs = a[1].arrayValue
                    else { continue }
                    let current = a[0].intValue
                    let tabs = rawTabs.compactMap { parseTabpageInfo($0) }
                    events.append(.tablineUpdate(current: current, tabs: tabs))
                }
            case "set_title":
                for args in eventArgs {
                    guard let a = args.arrayValue, a.count >= 1,
                          let title = a[0].stringValue
                    else { continue }
                    events.append(.setTitle(title: title))
                }
            case "option_set":
                for args in eventArgs {
                    guard let a = args.arrayValue, a.count >= 2,
                          let name = a[0].stringValue
                    else { continue }
                    events.append(.optionSet(name: name, value: a[1]))
                }
            default:
                break
            }
        }
        return events
    }

    // MARK: - Private helpers

    /// Chunks as the command line (`[attrs, text, hl_id]`) and messages (`[attr_id, text, hl_id]`) send them.
    private nonisolated static func chunks(_ value: MessagePackValue) -> [StyledChunk] {
        (value.arrayValue ?? []).compactMap { chunk in
            guard let c = chunk.arrayValue, c.count >= 2, let text = c[1].stringValue else { return nil }
            if let map = c[0].dictionaryValue {
                var attrs: [String: MessagePackValue] = [:]
                for (key, value) in map {
                    if let key = key.stringValue { attrs[key] = value }
                }
                return StyledChunk(text: text, attrs: attrs)
            }
            return StyledChunk(text: text, attrId: c[0].intValue)
        }
    }

    private nonisolated static func parseGridLineCells(_ rawCells: [MessagePackValue])
        -> [GridCellData]
    {
        var cells: [GridCellData] = []
        var lastHlId = 0
        for cell in rawCells {
            guard let a = cell.arrayValue, !a.isEmpty,
                  let text = a[0].stringValue
            else { continue }
            // hlId is optional — if missing, reuse lastHlId (sticky)
            if a.count >= 2 {
                lastHlId = a[1].intValue
            }
            let repeats = a.count >= 3 ? a[2].intValue : 1
            cells.append(GridCellData(text: text, hlId: lastHlId, repeats: repeats))
        }
        return cells
    }

    private nonisolated static func parseModeInfo(_ value: MessagePackValue) -> ModeInfo? {
        guard let dict = value.dictionaryValue else { return nil }
        var name = ""
        var shape = ModeInfo.CursorShape.block
        var cellPercentage = 0
        var attrId = 0
        for (k, v) in dict {
            switch k.stringValue {
            case "name":
                name = v.stringValue ?? ""
            case "cursor_shape":
                shape = ModeInfo.CursorShape(rawValue: v.stringValue ?? "") ?? .block
            case "cell_percentage":
                cellPercentage = v.intValue
            case "attr_id":
                attrId = v.intValue
            default:
                break
            }
        }
        return ModeInfo(name: name, cursorShape: shape, cellPercentage: cellPercentage, attrId: attrId)
    }

    private nonisolated static func parseTabpageInfo(_ value: MessagePackValue) -> TabpageInfo? {
        guard let dict = value.dictionaryValue else { return nil }
        var handle = 0
        var tabName = ""
        for (k, v) in dict {
            switch k.stringValue {
            case "tab":
                handle = v.intValue
            case "name":
                tabName = v.stringValue ?? ""
            default:
                break
            }
        }
        return TabpageInfo(handle: handle, name: tabName)
    }
}

extension MessagePackValue {
    /// Integers and floats alike, as a Double: float anchors (`win_float_pos`) may arrive as either.
    nonisolated var numberValue: Double {
        switch self {
        case let .double(value): value
        case let .float(value): Double(value)
        default: Double(intValue)
        }
    }
}
