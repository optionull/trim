import CoreServices
import Foundation

/// The files changing under a folder, as FSEvents reports them (file by file, a fraction of a second late), less
/// what nobody reads: git's own folder, build output and what git ignores. `onChange` gets the changed files'
/// absolute paths on the main thread.
public final class FileEvents: @unchecked Sendable {
    public let root: String
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "sill.file-events")
    public var onChange: (@MainActor ([String]) -> Void)?

    /// Folders whose files are never anyone's change to follow.
    static let skipped = [
        "/.git/",
        "/.sill/",
        "/obj/",
        "/bin/",
        "/node_modules/",
        "/.build/",
        "/target/",
        "/artifacts/",
        "/.vs/",
        "/.idea/",
        "/DerivedData/",
    ]

    /// Every path as the file system reports it (Home: commits, branch switches and `.sill` count), not only the
    /// files git follows.
    public let raw: Bool

    public init(root: String, raw: Bool = false) {
        self.root = root
        self.raw = raw
    }

    deinit { stop() }

    public func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let events = Unmanaged<FileEvents>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            events.received(Array(list.prefix(count)))
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [root] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.25,
            flags
        )
        else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func received(_ paths: [String]) {
        if raw {
            let real = Array(Set(paths.map { realPath($0) }))
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.onChange?(real) }
            }
            return
        }
        // Real paths (/tmp is /private/tmp: realpath, not URL's resolving, which takes /private off again), files
        // only, not in skipped folders, then not ignored by git.
        let candidates = Set(paths.map { realPath($0) }).filter { path in
            !Self.skipped.contains { path.contains($0) } && !path.hasSuffix("/.git") && !Self.temporary(path) &&
                !((try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false)
        }
        guard !candidates.isEmpty else { return }
        let kept = Self.notIgnored(Array(candidates).sorted(), in: root)
        guard !kept.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onChange?(kept) }
        }
    }

    /// A file only written on the way to another: an atomic write's (Foundation's `.sb-`), an editor's backup or swap,
    /// vim's probe for whether it may write (`4913`).
    public static func temporary(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name.contains(".sb-") || name.hasSuffix("~") || name.hasSuffix(".swp") || name.hasSuffix(".swx") ||
            name == "4913" || name.hasSuffix(".tmp") || name.hasPrefix(".#")
    }

    /// The paths git does not ignore (all of them outside a repository).
    static func notIgnored(_ paths: [String], in root: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", root, "check-ignore", "--stdin"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return paths }
        input.fileHandleForWriting.write(Data((paths.joined(separator: "\n") + "\n").utf8))
        try? input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // 1: none ignored; 128: not a repository.
        guard process.terminationStatus == 0 else { return paths }
        let ignored = Set(String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init))
        return paths.filter { !ignored.contains($0) }
    }
}
