import Foundation
import MessagePack
import SillNvim

/// What the UI gets at every `flush`, and when sill's runtime asks for a terminal pane to take the keyboard.
public struct ScreenUpdate: Sendable {
    public var screen: Screen
    /// The pane that asked for the keyboard (`i` in its placeholder window), if one did.
    public var focusPane: Int?
}

/// One embedded nvim: starts it with sill's runtime on the runtimepath, attaches as a multigrid UI, and turns its
/// redraw events into screens. Runs off the main thread; the UI only ever reads the screens it is handed.
public actor EditorSession {
    public nonisolated let channel = NvimChannel()
    public nonisolated let updates: AsyncStream<ScreenUpdate>
    private let continuation: AsyncStream<ScreenUpdate>.Continuation
    private var screen = Screen()
    /// The screen as of the last `flush`; events after it may leave `screen` half drawn.
    private var flushed = Screen()
    private var pump: Task<Void, Never>?
    private var attached: (cols: Int, rows: Int)?
    /// A size asked for before nvim was attached; applied once it is.
    private var pendingSize: (cols: Int, rows: Int)?

    public init() {
        (updates, continuation) = AsyncStream<ScreenUpdate>.makeStream()
    }

    /// The UI options sill attaches with.
    public static let uiOptions = [
        "ext_linegrid": true, "ext_multigrid": true, "ext_cmdline": true, "ext_messages": true,
        "ext_popupmenu": true, "ext_tabline": true,
    ]

    /// Starts nvim and attaches. `runtime` is sill's runtime directory (the `plugin/` that defines terminal panes);
    /// `extraArgs` go to nvim after it, e.g. `--clean` in tests.
    public func start(
        runtime: URL, cols: Int, rows: Int, nvimPath: String = "", cwd: String = NSHomeDirectory(),
        appName: String = "sill", extraArgs: [String] = [], env: [String: String]? = nil
    ) async throws {
        try await channel.start(
            nvimPath: nvimPath, cwd: cwd, appName: appName,
            extraArgs: ["--cmd", "set runtimepath^=\(Self.escape(runtime.path))"] + extraArgs, env: env
        )
        let events = channel.events
        pump = Task { [weak self] in
            for await batch in events {
                await self?.apply(batch)
            }
            self?.continuation.finish()
        }
        // `--embed` waits for the UI before reading startup files, but serves the API before that: the channel id is
        // in place before sill's runtime first reports.
        let id = try await channel.channelId()
        _ = try await channel.lua("vim.g.sill_channel = ...", args: [.int(Int64(id))])
        try await channel.uiAttach(width: cols, height: rows, options: Self.uiOptions)
        attached = (cols, rows)
        if let size = pendingSize {
            pendingSize = nil
            await resize(cols: size.cols, rows: size.rows)
        }
    }

    /// Asks nvim for a new screen size. A size asked for before nvim is attached is kept and applied once it is: the
    /// window can be resized (by a tiling window manager, say) while nvim is still starting.
    public func resize(cols: Int, rows: Int) async {
        guard let current = attached else {
            pendingSize = (cols, rows)
            return
        }
        guard current != (cols, rows) else { return }
        attached = (cols, rows)
        await channel.uiTryResize(width: cols, height: rows)
    }

    public func stop() async {
        await channel.stop()
        pump?.cancel()
        continuation.finish()
    }

    private func apply(_ batch: [NvimEvent]) {
        for event in batch {
            // sill's runtime notifies outside redraw, so no flush need follow: a focus request or a pane report goes
            // out at once, with the last consistent screen.
            if case let .notification(method, args) = event {
                if method == "sill_terminal" {
                    continuation.yield(ScreenUpdate(screen: flushed, focusPane: args.first?.intValue))
                } else if method.hasPrefix("sill_") {
                    screen.apply(event)
                    flushed.apply(event)
                    continuation.yield(ScreenUpdate(screen: flushed, focusPane: nil))
                }
                continue
            }
            if screen.apply(event) {
                flushed = screen
                continuation.yield(ScreenUpdate(screen: screen, focusPane: nil))
            }
        }
    }

    /// `set` treats spaces and backslashes in a value specially.
    static func escape(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: " ", with: "\\ ")
            .replacingOccurrences(of: ",", with: "\\,")
    }
}
