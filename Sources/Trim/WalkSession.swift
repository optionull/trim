import Foundation
import MessagePack
import SillNvim

/// A walkthrough's own nvim: headless, holding the `.walk.md` as a real buffer, so the pane has every motion, search,
/// register and mode of nvim without drawing a grid. The editor's nvim is not touched. It reports the cursor, the text
/// and
/// Trim's keys (see runtime/lua/trim/walkdoc.lua).
actor WalkSession {
    enum Event: Sendable, Equatable {
        case cursor(line: Int, col: Int, mode: String)
        case text([String])
        case saved
        case action(String, line: Int)
    }

    nonisolated let channel = NvimChannel()
    nonisolated let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private var pump: Task<Void, Never>?

    init() {
        (events, continuation) = AsyncStream<Event>.makeStream()
    }

    /// Starts nvim on `file`. `runtime` is Trim's runtime folder (it has `trim/walkdoc.lua`).
    func start(file: String, runtime: URL) async throws {
        try await channel.start(
            cwd: (file as NSString).deletingLastPathComponent, appName: "trim-walk",
            extraArgs: ["--headless", "-u", "NONE", "-i", "NONE", "-n", "--cmd", "set runtimepath^=\(runtime.path)"]
        )
        let stream = channel.events
        let events = continuation
        pump = Task {
            for await batch in stream {
                for case let .notification(method, args) in batch {
                    if let event = Self.event(method, args) { events.yield(event) }
                }
            }
            events.finish()
        }
        let id = try await channel.channelId()
        _ = try await channel.lua("require('trim.walkdoc').setup(...)", args: [.int(Int64(id))])
        _ = try await channel.lua("vim.cmd.edit(vim.fn.fnameescape(...))", args: [.string(file)])
        _ = try await channel.lua("require('trim.walkdoc').report()")
    }

    static func event(_ method: String, _ args: [MessagePackValue]) -> Event? {
        switch method {
        case "walk_cursor":
            guard args.count >= 3, let line = args[0].integerValue, let col = args[1].integerValue,
                  let mode = args[2].stringValue else { return nil }
            return .cursor(line: Int(line), col: Int(col), mode: Self.modeName(mode))
        case "walk_text":
            return .text((args.first?.arrayValue ?? []).compactMap(\.stringValue))
        case "walk_saved":
            return .saved
        case "walk_action":
            guard args.count >= 2, let name = args[0].stringValue, let line = args[1].integerValue else { return nil }
            return .action(name, line: Int(line))
        default:
            return nil
        }
    }

    /// nvim's mode as `nvim_get_mode` says it (`n`, `i`, `v`, `no`...), as the names the status bar knows.
    static func modeName(_ mode: String) -> String {
        switch mode.first {
        case "n": mode.hasPrefix("no") ? "operator" : "normal"
        case "i": "insert"
        case "v", "V", "\u{16}": "visual"
        case "s", "S", "\u{13}": "select"
        case "R": "replace"
        case "c": "cmdline_normal"
        case "t": "terminal"
        default: "normal"
        }
    }

    /// Keys, in nvim's notation, as if typed in the document.
    nonisolated func send(keys: String) { channel.send(keys: keys) }

    func moveCursor(to line: Int) async {
        _ = try? await channel.lua("vim.api.nvim_win_set_cursor(0, { ..., 0 })", args: [.int(Int64(line))])
    }

    /// The document's text as it is now.
    func lines() async -> [String] {
        let value = try? await channel.lua("return vim.api.nvim_buf_get_lines(0, 0, -1, false)")
        return (value?.arrayValue ?? []).compactMap(\.stringValue)
    }

    /// Replaces the document's text (a checklist ticked from the pane) and saves it.
    func replace(lines: [String]) async {
        _ = try? await channel.lua(
            "vim.api.nvim_buf_set_lines(0, 0, -1, false, ...); vim.cmd('silent write')",
            args: [.array(lines.map { .string($0) })]
        )
    }

    /// The file changed on disk (an agent still writing it): read it again unless it has edits of its own.
    func reload() async {
        _ = try? await channel.lua("if not vim.bo.modified then vim.cmd('silent! edit') end")
    }

    func stop() async {
        await channel.stop()
        pump?.cancel()
        continuation.finish()
    }
}
