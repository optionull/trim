import Foundation
@testable import SillSidecar
import Testing

@Suite("Roslyn provisioning", .serialized, .timeLimit(.minutes(1)))
struct RoslynTests {
    /// A local feed: a flat container with the language server package in three versions.
    private func feed() throws -> (feed: URL, cache: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sill-roslyn-\(UUID().uuidString)")
        let id = "microsoft.codeanalysis.languageserver.\(Sidecar.rid)"
        let versions = ["5.0.0-1.1", "5.9.0-2.3", "5.10.0-1.2"]
        let package = root.appendingPathComponent("feed/\(id)")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["versions": versions])
            .write(to: package.appendingPathComponent("index.json"))
        let staging = root.appendingPathComponent("staging")
        for (file, text) in [
            ("content/LanguageServer/\(Sidecar.rid)/Microsoft.CodeAnalysis.LanguageServer.dll", "the server"),
            ("content/LanguageServer/\(Sidecar.rid)/BuildHost/host.dll", "a dependency"),
            ("content/LanguageServer/other-rid/Microsoft.CodeAnalysis.LanguageServer.dll", "not this one"),
        ] {
            let url = staging.appendingPathComponent(file)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let version = "5.10.0-1.2"
        let nupkg = package.appendingPathComponent("\(version)/\(id).\(version).nupkg")
        try FileManager.default.createDirectory(
            at: nupkg.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-qr", nupkg.path, "content"]
        zip.currentDirectoryURL = staging
        try zip.run()
        zip.waitUntilExit()
        return (root.appendingPathComponent("feed"), root.appendingPathComponent("cache"))
    }

    @Test("the newest version is downloaded, this Mac's server only, then served from the cache")
    func provision() async throws {
        let (feed, cache) = try feed()
        let (sidecar, _) = try await BuiltSidecar.start()
        defer { Task { await sidecar.stop() } }
        let server = try await sidecar.roslyn(cache: cache, feed: feed.path)
        #expect(server.version == "5.10.0-1.2", "5.10 is newer than 5.9")
        #expect(server.downloaded)
        #expect(try String(contentsOfFile: server.dll, encoding: .utf8) == "the server")
        #expect(FileManager.default.fileExists(
            atPath: cache.appendingPathComponent("5.10.0-1.2/BuildHost/host.dll").path
        ))
        #expect(!FileManager.default.fileExists(atPath: cache.appendingPathComponent("5.10.0-1.2/other-rid").path))

        let again = try await sidecar.roslyn(cache: cache, feed: feed.path)
        #expect(again.dll == server.dll && !again.downloaded)

        let offline = try await sidecar.roslyn(cache: cache, feed: "https://127.0.0.1:9/nothing/index.json")
        #expect(offline.version == "5.10.0-1.2" && !offline.downloaded, "offline, the cached one")
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
