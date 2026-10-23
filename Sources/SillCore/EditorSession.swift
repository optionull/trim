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
        // nvim reads the user's config once attached, and a plugin manager may reset the runtimepath (lazy.nvim does),
        // dropping sill's runtime before its plugin/ is read. Requests wait until startup is done, so this puts it
        // back and loads it after whatever the config did; once loaded, the module and its commands stay.
        _ = try await channel.lua(
            "vim.opt.runtimepath:prepend(...); require('sill').setup()", args: [.string(runtime.path)]
        )
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

    /// How nvim starts: the name it runs under and the arguments before the user's own.
    public struct Startup: Equatable, Sendable {
        public var appName: String
        public var arguments: [String]
        /// The user's config is loaded (their init.lua, plugins and lockfile, as in a terminal).
        public var userConfig: Bool
    }

    /// With a config of the user's (`$XDG_CONFIG_HOME/nvim` or `~/.config/nvim` holding an init.lua or init.vim),
    /// nvim runs under its own name so that config loads as it always does, plugins and lockfile shared with nvim in
    /// a terminal; sill's base settings go first (`--cmd`), so the user's win. Without one, or when `own` asks for
    /// sill alone (the self-check), nvim runs as `sill` with only the base settings.
    public static func startup(environment: [String: String], own: Bool) -> Startup {
        let base = ["--cmd", "lua require('sill.base')"]
        guard !own else { return Startup(appName: "sill", arguments: base, userConfig: false) }
        let home = environment["HOME"] ?? NSHomeDirectory()
        let configHome = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(home)/.config"
        let folder = "\(configHome)/\(environment["NVIM_APPNAME"] ?? "nvim")"
        let hasConfig = ["init.lua", "init.vim"].contains {
            FileManager.default.fileExists(atPath: "\(folder)/\($0)")
        }
        return hasConfig ? Startup(appName: environment["NVIM_APPNAME"] ?? "nvim", arguments: base, userConfig: true)
            : Startup(appName: "sill", arguments: base, userConfig: false)
    }

    /// `set` treats spaces and backslashes in a value specially.
    static func escape(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: " ", with: "\\ ")
            .replacingOccurrences(of: ",", with: "\\,")
    }
}
