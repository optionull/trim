import Foundation
@testable import FrameRun
import Testing

@Suite("The person's own run configurations")
struct RunConfigsTests {
    private func folder() throws -> String {
        let root = NSTemporaryDirectory() + "frame-configs-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return root
    }

    @Test("saved, read back, listed first as entries that say where they are kept")
    func roundTrip() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "build:\n\t@echo hi\n".write(toFile: root + "/Makefile", atomically: true, encoding: .utf8)
        #expect(RunConfigs.load(in: root).isEmpty)
        let mine = RunConfig(
            name: "Build verbosely", command: "make build V=1", directory: "sub", environment: ["CI": "1", "A": "b=c"],
            kind: "build",
            basedOn: "make:build"
        )
        try RunConfigs.save([mine], in: root)
        #expect(RunConfigs.load(in: root) == [mine])
        let all = RunEntries.find(in: root)
        let entry = try #require(all.first)
        #expect(entry.isCustom && entry.title == "Build verbosely" && entry.kind == .build)
        #expect(entry.directory == root + "/sub" && entry.environment == ["CI": "1", "A": "b=c"])
        #expect(entry.origin == ".frame/run.json (from make:build)")
        #expect(all.contains { $0.source == "make" && $0.title == "build" && $0.origin == "Makefile:1" })
        try RunConfigs.save([], in: root)
        #expect(!FileManager.default.fileExists(atPath: RunConfigs.file(in: root)))
    }

    @Test("a file that is not what it should be is no configurations, not a failure")
    func broken() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/.frame", withIntermediateDirectories: true)
        try "{ not json".write(toFile: RunConfigs.file(in: root), atomically: true, encoding: .utf8)
        #expect(RunConfigs.load(in: root).isEmpty)
    }

    @Test("a copy of an entry starts as what it did, under a name that is free")
    func copy() {
        let entry = RunEntry(
            title: "serve", source: "npm", kind: .run, command: "npm run serve", directory: "/r/web",
            environment: ["PORT": "80"],
            origin: "web/package.json"
        )
        let config = RunConfigs.config(from: entry, in: "/r")
        #expect(config == RunConfig(
            name: "serve (mine)", command: "npm run serve", directory: "web", environment: ["PORT": "80"], kind: "run",
            basedOn: "npm:serve"
        ))
        #expect(RunConfigs.unusedName("serve (mine)", among: [config]) == "serve (mine) 2")
        #expect(RunConfigs.unusedName("other", among: [config]) == "other")
    }

    @Test("environment as lines and back; blank lines, comments and a value with = are kept as they should be")
    func environment() {
        let text = "# a comment\nA=1\n\n B = 2 \nC=x=y\nnotavariable"
        #expect(RunConfigs.environment(from: text) == ["A": "1", "B": "2", "C": "x=y"])
        #expect(RunConfigs.text(of: ["B": "2", "A": "1"]) == "A=1\nB=2")
    }
}
