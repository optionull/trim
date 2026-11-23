import Foundation

/// What a `frame://` link, or a file handed to the app (`open -a Trim file.cs`), asks for: a file (at a line and
/// column)
/// or a folder to work in.
public enum TrimLink: Equatable, Sendable {
    case file(path: String, line: Int?, column: Int?)
    case workspace(path: String)

    /// `frame://open?path=/abs/file.cs&line=12&column=3`, `frame://workspace?path=/abs/folder`,
    /// `frame:///abs/file.cs?line=12`,
    /// and a `file://` URL (a path with `:12:3` after it is a line and a column).
    public static func parse(_ url: URL) -> TrimLink? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        func number(_ name: String) -> Int? { value(name).flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil } }
        if url.isFileURL {
            let (path, line, column) = splitPosition(url.path)
            return .file(path: path, line: line, column: column)
        }
        guard url.scheme == "frame" else { return nil }
        switch url.host {
        case "workspace", "folder":
            guard let path = value("path"), path.hasPrefix("/") else { return nil }
            return .workspace(path: path)
        case "open", "file":
            guard let path = value("path"), path.hasPrefix("/") else { return nil }
            let (clean, line, column) = splitPosition(path)
            return .file(path: clean, line: number("line") ?? line, column: number("column") ?? column)
        case nil, "":
            // frame:///abs/file.cs?line=12
            guard url.path.hasPrefix("/") else { return nil }
            let (clean, line, column) = splitPosition(url.path)
            return .file(path: clean, line: number("line") ?? line, column: number("column") ?? column)
        default:
            return nil
        }
    }

    /// `/a/b.cs:12:3` is a path, a line and a column; a path that has a file named so keeps it whole.
    static func splitPosition(_ text: String) -> (path: String, line: Int?, column: Int?) {
        if FileManager.default.fileExists(atPath: text) { return (text, nil, nil) }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if parts.count >= 3, let column = Int(parts[parts.count - 1]), let line = Int(parts[parts.count - 2]) {
            return (parts.dropLast(2).joined(separator: ":"), line, column)
        }
        if parts.count >= 2, let line = Int(parts[parts.count - 1]) {
            return (parts.dropLast().joined(separator: ":"), line, nil)
        }
        return (text, nil, nil)
    }

    /// The folder a file belongs to when no window is on it: its repository's root, else its own folder.
    public static func workspace(for file: String) -> String {
        var folder = (file as NSString).deletingLastPathComponent
        let start = folder
        while folder.count > 1 {
            if FileManager.default.fileExists(atPath: folder + "/.git") { return folder }
            folder = (folder as NSString).deletingLastPathComponent
        }
        return start
    }
}
