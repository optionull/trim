import Foundation
import SillCore

/// Frame's own settings: `~/.config/frame/settings.toml` (`$XDG_CONFIG_HOME/frame/settings.toml`, or the file
/// `$FRAME_SETTINGS` names). What is in it reaches nvim as `vim.g.frame_settings` before anything else loads, so the
/// base
/// settings, the leader and the colour scheme follow it; a key bound in `~/.config/frame/init.lua` wins over a setting.
/// A value that is commented out is at its default. Changed from Frame (the theme picker, later the settings window) in
/// place: comments and layout are kept.
enum FrameSettings {
    static var file: URL {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["FRAME_SETTINGS"], !path.isEmpty { return URL(fileURLWithPath: path) }
        let config = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory() + "/.config"
        return URL(fileURLWithPath: config + "/frame/settings.toml")
    }

    static let defaultSource = """
    # Frame's settings. A value that is commented out is at its default. Frame's own nvim config reads this file; what you
    # bind in ~/.config/frame/init.lua wins over it.

    [editor]
    # The leader key.
    # leader = "\\\\"
    # The editor's font (any installed monospaced family; "Font…" in the View menu or the leader and F chooses one live), its size in
    # points (⌘+ and ⌘- change it for a session) and its line height as a multiple of the font's.
    # font = "JetBrains Mono"
    # font_size = 13
    # line_height = 1.2

    [theme]
    # The colour scheme, by its :colorscheme name. Frame's sidebar, tabs and status bar follow it.
    # colorscheme = "tokyonight-night"
    """

    /// A font being tried by the font picker (not yet kept); nil when there is none.
    @MainActor static var fontPreview: String?

    /// The font, size and line height this file asks for (the font being tried first), over what the base settings say.
    @MainActor
    static func fontSettings(over base: SillSettings) -> SillSettings {
        var settings = base
        let editor = load()["editor"]?.table
        if let family = fontPreview ?? editor?["font"]?.string, !family.isEmpty { settings.font = family }
        func number(_ value: TOMLValue?) -> Double? {
            switch value {
            case let .integer(value): Double(value)
            case let .float(value): value
            default: nil
            }
        }
        if let size = number(editor?["font_size"]), size > 0 { settings.size = size }
        if let height = number(editor?["line_height"]), height > 0 { settings.lineHeight = height }
        return settings
    }

    /// What the file says, as a table (empty when there is no file or it does not parse).
    static func load() -> TOMLTable {
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let document = try? TOMLDocument(text) else { return TOMLTable() }
        return document.root
    }

    /// The values the file sets, as the JSON object nvim decodes (`vim.g.frame_settings`).
    static func json() -> String {
        func convert(_ table: TOMLTable) -> [String: Any] {
            var result: [String: Any] = [:]
            for key in table.keys {
                guard let value = table[key] else { continue }
                if let text = value.string {
                    result[key] = text
                } else if let number = value.integer {
                    result[key] = number
                } else if let flag = value.bool {
                    result[key] = flag
                } else if let nested = value.table {
                    result[key] = convert(nested)
                } else if let list = value.array {
                    result[key] = list.compactMap(\.string)
                }
            }
            return result
        }
        let data = try? JSONSerialization.data(withJSONObject: convert(load()))
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// One value changed in place (the file, and its folder, made first if there are none).
    static func set(_ path: [String], to value: TOMLValue) {
        let folder = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? defaultSource
        guard let changed = try? SettingsEdit.setting(path, to: value, in: text) else { return }
        try? changed.write(to: file, atomically: true, encoding: .utf8)
    }
}
