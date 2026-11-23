import SillCore

/// How nvim runs in Trim: always its own isolated config, never the one in `~/.config/nvim` (nor any other the
/// person has). It runs under the name `frame`, so its config, data, state and cache folders are Trim's own
/// (`~/.config/trim`, `~/.local/share/trim`...), and `~/.config/trim/init.lua`, if there is one, is the place for
/// the
/// person's additions: nvim loads it as it loads any init.lua, after Trim's base settings. `NVIM_APPNAME` is not
/// asked.
enum TrimNvim {
    static let appName = "trim"

    /// What nvim is started with, before any config: Trim's settings (`vim.g.trim_settings`), sill's base settings,
    /// then
    /// Trim's own; all of it ahead of anything of the person's (`~/.config/trim/init.lua`), which wins.
    static var arguments: [String] {
        [
            "--cmd", "lua vim.g.trim_settings = vim.json.decode([==[\(TrimSettings.json())]==])",
            "--cmd", "lua require('sill.base')",
            "--cmd", "lua require('trim.base')",
        ]
    }

    static var startup: EditorSession.Startup {
        EditorSession.Startup(appName: appName, arguments: arguments, userConfig: false)
    }
}
