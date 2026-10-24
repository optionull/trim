import Foundation

// After heed's ConfigWatcher (the owner's own app).

/// Watches the settings file's folder (editors often save by replacing the file) and reports the new source,
/// debounced. Runs on its own queue; the callback is where the caller hops to the main actor.
public final class SettingsWatcher: @unchecked Sendable {
    public let file: URL
    private let queue = DispatchQueue(label: "sill.settings")
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private let onChange: @Sendable (String) -> Void

    public init(file: URL, onChange: @escaping @Sendable (String) -> Void) {
        self.file = file
        self.onChange = onChange
    }

    deinit { source?.cancel() }

    /// Writes the commented default if the file does not exist yet, then starts watching. Returns the current source.
    public func start() -> String {
        let folder = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) {
            try? SettingsLoader.defaultSource.write(to: file, atomically: true, encoding: .utf8)
        }
        let fd = open(folder.path, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue
            )
            source.setEventHandler { [weak self] in self?.changed() }
            source.setCancelHandler { close(fd) }
            source.resume()
            self.source = source
        }
        return (try? String(contentsOf: file, encoding: .utf8)) ?? SettingsLoader.defaultSource
    }

    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let text = try? String(contentsOf: file, encoding: .utf8) else { return }
            onChange(text)
        }
        pending = work
        queue.asyncAfter(deadline: .now() + .milliseconds(200), execute: work)
    }

    /// Changes one value in place (comments and layout kept) and writes the file; the watcher then reads it again.
    /// A key only commented out in the file is set on the commented line's place: the line is uncommented.
    public static func set(_ path: [String], to value: TOMLValue, in file: URL) throws {
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? SettingsLoader.defaultSource
        try SettingsEdit.setting(path, to: value, in: text).write(to: file, atomically: true, encoding: .utf8)
    }
}

public enum SettingsEdit {
    /// The source with `path` set: in place when the file has it, on its commented-out line (`# key = …`) in its
    /// table when the file has that, else added to its table.
    public static func setting(_ path: [String], to value: TOMLValue, in text: String) throws -> String {
        let document = try TOMLDocument(text)
        if document.root.value(at: path) != nil { return document.setting(path, to: value) }
        let table = path.dropLast().joined(separator: ".")
        let key = TOMLValue.key(path.last!)
        var lines = text.components(separatedBy: "\n")
        var current = ""
        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                current = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            } else if current == table, trimmed.hasPrefix("#") {
                let uncommented = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                if uncommented.hasPrefix(key + " =") || uncommented.hasPrefix(key + "=") {
                    lines[index] = "\(key) = \(value.literal)"
                    return lines.joined(separator: "\n")
                }
            }
        }
        return document.setting(path, to: value)
    }
}
