import SillCore

/// How nvim runs in Frame: always its own isolated config, never the one in `~/.config/nvim` (nor any other the
/// person has). It runs under the name `frame`, so its config, data, state and cache folders are Frame's own
/// (`~/.config/frame`, `~/.local/share/frame`...), and `~/.config/frame/init.lua`, if there is one, is the place for
/// the
/// person's additions: nvim loads it as it loads any init.lua, after Frame's base settings. `NVIM_APPNAME` is not
/// asked.
enum FrameNvim {
    static let appName = "frame"

    /// Sill's base settings, then Frame's own, ahead of anything of the person's.
    static let arguments = ["--cmd", "lua require('sill.base')", "--cmd", "lua require('frame.base')"]

    static var startup: EditorSession.Startup {
        EditorSession.Startup(appName: appName, arguments: arguments, userConfig: false)
    }
}
