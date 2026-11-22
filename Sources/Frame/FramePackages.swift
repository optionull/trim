import Foundation

/// Installing a package from the catalog (`frame/catalog.lua`): its tarball at the pinned tag, from GitHub, no git
/// needed; the
/// commit GitHub puts in the archive's header must be the one pinned; unpacked into Frame's own data folder (a `start`
/// pack),
/// never the person's config.
enum FramePackages {
    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    /// The commit GitHub wrote in a tarball's header (`comment=<sha>`), or nil.
    static func commit(inArchive file: String) async -> String? {
        guard let header = try? await FrameServers.run(
            "/bin/sh", ["-c", "gzip -dc \"$0\" 2>/dev/null | head -c 2048 | tr -d '\\000'", file], timeout: .seconds(30)
        ) else { return nil }
        return commit(inHeader: header.output)
    }

    static func commit(inHeader text: String) -> String? {
        guard let range = text.range(of: "comment=") else { return nil }
        let sha = text[range.upperBound...].prefix(40)
        return sha.count == 40 && sha.allSatisfy(\.isHexDigit) ? String(sha) : nil
    }

    /// Whether `dir` is somewhere a package may be put or taken from: a pack folder of Frame's, whatever the catalog
    /// says.
    static func isPackageFolder(_ dir: String) -> Bool {
        dir.contains("/site/pack/frame/start/") && !dir.contains("..") && !dir.hasSuffix("/start/")
    }

    static func install(repo: String, tag: String, commit expected: String, to dir: String) async throws {
        guard isPackageFolder(dir) else { throw Failure(description: "not a package folder: \(dir)") }
        guard let url = URL(string: "https://codeload.github.com/\(repo)/tar.gz/refs/tags/\(tag)") else {
            throw Failure(description: "no address for \(repo)")
        }
        let (download, response) = try await URLSession.shared.download(from: url)
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
            throw Failure(description: "GitHub answered \(status) for \(repo) \(tag)")
        }
        guard await commit(inArchive: download.path) == expected else {
            throw Failure(
                description: "\(repo) \(tag) is not the commit Frame pinned (\(expected.prefix(7))): not installed"
            )
        }
        let temporary = NSTemporaryDirectory() + "frame-package-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: temporary) }
        let unpacked = try await FrameServers.run(
            "/usr/bin/tar",
            ["-xzf", download.path, "-C", temporary, "--strip-components=1"]
        )
        guard unpacked.code == 0
        else { throw Failure(description: "the archive did not unpack: \(unpacked.output.suffix(200))") }
        try FileManager.default.createDirectory(
            atPath: (dir as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(atPath: dir)
        try FileManager.default.moveItem(atPath: temporary, toPath: dir)
    }

    static func remove(_ dir: String) throws {
        guard isPackageFolder(dir) else { throw Failure(description: "not a package folder: \(dir)") }
        try FileManager.default.removeItem(atPath: dir)
    }
}
