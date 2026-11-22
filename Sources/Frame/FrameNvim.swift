import SillCore

/// How nvim runs in Frame: always its own isolated config, never the one in `~/.config/nvim` (nor any other the
/// person has). It runs under the name `frame`, so its config, data, state and cache folders are Frame's own
/// (`~/.config/frame`, `~/.local/share/frame`...), and `~/.config/frame/init.lua`, if there is one, is the place for
/// the
/// person's additions: nvim loads it as it loads any init.lua, after Frame's base settings. `NVIM_APPNAME` is not
/// asked.
enum FrameNvim {
    static let appName = "frame"

    /// What nvim is started with, before any config: Frame's settings (`vim.g.frame_settings`), sill's base settings,
    /// then
    /// Frame's own; all of it ahead of anything of the person's (`~/.config/frame/init.lua`), which wins.
    static var arguments: [String] {
        [
            "--cmd", "lua vim.g.frame_settings = vim.json.decode([==[\(FrameSettings.json())]==])",
            "--cmd", "lua require('sill.base')",
            "--cmd", "lua require('frame.base')",
        ]
    }

    static var startup: EditorSession.Startup {
        EditorSession.Startup(appName: appName, arguments: arguments, userConfig: false)
    }
}
