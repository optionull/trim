import Foundation
@testable import SillSidecar
import Testing

@Suite("Roslyn provisioning", .serialized, .timeLimit(.minutes(1)))
struct RoslynTests {
    /// A local feed: a flat container with the language server package in three versions.
    private func feed() throws -> (feed: URL, cache: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sill-roslyn-\(UUID().uuidString)")
        let id = "roslyn-language-server.\(Sidecar.rid)"
        let versions = ["5.0.0", "5.9.0", "5.10.0", "5.11.0-1.2"]
        let package = root.appendingPathComponent("feed/\(id)")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["versions": versions])
            .write(to: package.appendingPathComponent("index.json"))
        let staging = root.appendingPathComponent("staging")
        for (file, text) in [
            ("tools/net10.0/\(Sidecar.rid)/Microsoft.CodeAnalysis.LanguageServer.dll", "the server"),
            ("tools/net10.0/\(Sidecar.rid)/BuildHost/host.dll", "a dependency"),
            ("tools/net10.0/\(Sidecar.rid)/Microsoft.ServiceHub.Client.dll", "Visual Studio's"),
            ("tools/net10.0/\(Sidecar.rid)/cs/Microsoft.VisualStudio.RpcContracts.resources.dll", "Visual Studio's"),
            ("tools/net10.0/other-rid/Microsoft.CodeAnalysis.LanguageServer.dll", "not this one"),
        ] {
            let url = staging.appendingPathComponent(file)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let version = "5.10.0"
        let nupkg = package.appendingPathComponent("\(version)/\(id).\(version).nupkg")
        try FileManager.default.createDirectory(
            at: nupkg.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-qr", nupkg.path, "tools"]
        zip.currentDirectoryURL = staging
        try zip.run()
        zip.waitUntilExit()
        return (root.appendingPathComponent("feed"), root.appendingPathComponent("cache"))
    }

    @Test("the newest stable version is downloaded, this Mac's server only, then served from the cache")
    func provision() async throws {
        let (feed, cache) = try feed()
        let (sidecar, _) = try await BuiltSidecar.start()
        defer { Task { await sidecar.stop() } }
        let server = try await sidecar.roslyn(cache: cache, feed: feed.path)
        #expect(server.version == "5.10.0", "5.10 is newer than 5.9, and stable where 5.11 is not")
        #expect(server.downloaded)
        #expect(try String(contentsOfFile: server.dll, encoding: .utf8) == "the server")
        let folder = cache.appendingPathComponent("5.10.0")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("BuildHost/host.dll").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("other-rid").path))
        #expect(!FileManager.default
            .fileExists(atPath: folder.appendingPathComponent("Microsoft.ServiceHub.Client.dll").path))
        #expect(!FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("cs/Microsoft.VisualStudio.RpcContracts.resources.dll").path
        ))

        let again = try await sidecar.roslyn(cache: cache, feed: feed.path)
        #expect(again.dll == server.dll && !again.downloaded)

        let offline = try await sidecar.roslyn(cache: cache, feed: "https://127.0.0.1:9/nothing/index.json")
        #expect(offline.version == "5.10.0" && !offline.downloaded, "offline, the cached one")
    }

    @Test("offline with nothing cached says so")
    func nothingCached() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("sill-empty-\(UUID().uuidString)")
        let (sidecar, _) = try await BuiltSidecar.start()
        defer { Task { await sidecar.stop() } }
        do {
            _ = try await sidecar.roslyn(cache: cache, feed: "https://127.0.0.1:9/nothing/index.json")
            Issue.record("provisioned from nothing")
        } catch let SidecarError.failed(_, message) {
            #expect(message.contains("not cached"))
        }
    }
}
