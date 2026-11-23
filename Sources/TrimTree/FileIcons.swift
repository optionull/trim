import Foundation

/// How a file or folder is drawn: a Nerd Font glyph and a colour family (the UI maps a family to its palette).
public struct FileIcon: Equatable, Sendable {
    public enum Tint: Equatable, Sendable {
        case folder, dotnet, systems, web, script, data, project, docs, image, plain
    }

    public var glyph: Character
    public var tint: Tint
}

/// The glyphs are code points of the Symbols Nerd Font (Seti, Devicons and Font Awesome sets), checked against the real
/// font by Trim's self-check: a code point that is not in the font would draw as nothing.
public enum FileIcons {
    public static let folder = FileIcon(glyph: "\u{F07B}", tint: .folder)
    public static let folderOpen = FileIcon(glyph: "\u{F07C}", tint: .folder)
    public static let file = FileIcon(glyph: "\u{F016}", tint: .plain)

    public static func icon(name: String, isDirectory: Bool, expanded: Bool = false) -> FileIcon {
        if isDirectory { return expanded ? folderOpen : folder }
        if let named = byName[name.lowercased()] { return named }
        let ext = (name as NSString).pathExtension.lowercased()
        return byExtension[ext] ?? file
    }

    /// Every icon there is, for checking them against the font.
    public static var all: [FileIcon] {
        [folder, folderOpen, file] + Array(byName.values) + Array(byExtension.values)
    }

    private static func make(_ code: UInt32, _ tint: FileIcon.Tint) -> FileIcon {
        FileIcon(glyph: Character(Unicode.Scalar(code)!), tint: tint)
    }

    private static let byName: [String: FileIcon] = [
        "dockerfile": make(0xE650, .data),
        "license": make(0xE60A, .docs), "licence": make(0xE60A, .docs),
        ".gitignore": make(0xE702, .plain), ".gitattributes": make(0xE702, .plain), ".gitmodules": make(0xE702, .plain),
        "package.json": make(0xE71E, .web),
        "makefile": make(0xE615, .plain),
    ]

    private static let byExtension: [String: FileIcon] = [
        "cs": make(0xE648, .dotnet), "fs": make(0xE65A, .dotnet), "fsx": make(0xE65A, .dotnet),
        "fsi": make(0xE65A, .dotnet), "razor": make(0xE648, .dotnet), "cshtml": make(0xE648, .dotnet),
        "csproj": make(0xE601, .project), "fsproj": make(0xE601, .project), "props": make(0xE601, .project),
        "targets": make(0xE601, .project), "sln": make(0xE70C, .project), "slnx": make(0xE70C, .project),
        "swift": make(0xE699, .systems), "rs": make(0xE68B, .systems), "go": make(0xE627, .systems),
        "c": make(0xE649, .systems), "h": make(0xE649, .systems), "cpp": make(0xE646, .systems),
        "cc": make(0xE646, .systems), "hpp": make(0xE646, .systems), "java": make(0xE66D, .systems),
        "kt": make(0xE634, .systems),
        "js": make(0xE60C, .web), "mjs": make(0xE60C, .web), "ts": make(0xE628, .web), "tsx": make(0xE625, .web),
        "jsx": make(0xE625, .web), "html": make(0xE60E, .web), "css": make(0xE614, .web), "scss": make(0xE603, .web),
        "vue": make(0xE6A0, .web),
        "lua": make(0xE620, .script), "py": make(0xE606, .script), "rb": make(0xE605, .script),
        "sh": make(0xE691, .script), "zsh": make(0xE691, .script), "fish": make(0xE691, .script),
        "json": make(0xE80B, .data), "yml": make(0xE6A8, .data), "yaml": make(0xE6A8, .data),
        "toml": make(0xE615, .data), "xml": make(0xE619, .data), "plist": make(0xE619, .data),
        "lock": make(0xE672, .data), "sql": make(0xE706, .data),
        "md": make(0xE609, .docs), "txt": make(0xE64E, .docs),
        "png": make(0xE60D, .image), "jpg": make(0xE60D, .image), "jpeg": make(0xE60D, .image),
        "gif": make(0xE60D, .image), "svg": make(0xE698, .image), "ico": make(0xE60D, .image),
    ]
}
