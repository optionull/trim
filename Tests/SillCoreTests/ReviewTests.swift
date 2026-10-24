import Foundation
import SillCore
import Testing

@Suite("review")
struct ReviewTests {
    /// A repository with two committed files and one ignored.
    func repository() throws -> String {
        let folder = NSTemporaryDirectory() + "sill-review-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        func write(_ name: String, _ text: String) throws {
            try text.write(toFile: folder + "/" + name, atomically: true, encoding: .utf8)
        }
        try write("a.txt", (1 ... 20).map { "line \($0)" }.joined(separator: "\n") + "\n")
        try write("b.txt", "keep\n")
        try write(".gitignore", "*.log\n")
        for command in [
            ["init", "-q"],
            ["add", "-A"],
            ["-c", "user.email=a@b", "-c", "user.name=t", "commit", "-qm", "x"],
        ] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git"] + command
            process.currentDirectoryURL = URL(fileURLWithPath: folder)
            try process.run()
            process.waitUntilExit()
        }
        return folder
    }

    @Test("what changed since a baseline: files, hunks, and a hunk taken back")
    func review() throws {
        let folder = try repository()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let index = try Data(contentsOf: URL(fileURLWithPath: folder + "/.git/index"))
        let base = try #require(Review.snapshot(in: folder))
        // The agent's work: two places in a.txt, a new file, an ignored log, b.txt gone.
        var lines = (1 ... 20).map { "line \($0)" }
        lines[2] = "line three"
        lines[16] = "line seventeen"
        try (lines.joined(separator: "\n") + "\n").write(toFile: folder + "/a.txt", atomically: true, encoding: .utf8)
        try "new\n".write(toFile: folder + "/c.txt", atomically: true, encoding: .utf8)
        try "noise\n".write(toFile: folder + "/run.log", atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(atPath: folder + "/b.txt")
        let now = try #require(Review.snapshot(in: folder))
        #expect(try Data(contentsOf: URL(fileURLWithPath: folder + "/.git/index")) == index, "the index untouched")

        let files = Review.files(from: base, to: now, in: folder)
        #expect(files.map(\.path) == ["a.txt", "b.txt", "c.txt"], "the log is ignored")
        #expect(files.map(\.status) == [.modified, .deleted, .added])
        #expect(files[0].added == 2 && files[0].removed == 2)
        let diff = Review.diff("a.txt", from: base, to: now, in: folder)
        #expect(diff.hunks.count == 2 && diff.hunks[0].lines.contains("+line three"))
        #expect(diff.hunks.map(\.firstChange) == [3, 17], "named by the first changed line")

        // The second hunk taken back: line 17 as it was, line 3 as the agent left it.
        #expect(Review.reject(diff.hunks[1], of: diff, in: folder))
        let text = try String(contentsOfFile: folder + "/a.txt", encoding: .utf8)
        #expect(text.contains("line three") && text.contains("line 17\n") && !text.contains("seventeen"))
        #expect(Review.text(of: "b.txt", in: base, directory: folder) == "keep\n", "the baseline's text")
        #expect(!Review.reject(diff.hunks[1], of: diff, in: folder), "taken back already: it no longer applies")
    }
}

@Suite("file events")
struct FileEventsTests {
    @Test("a file only written on the way to another is no one's change")
    func temporary() {
        #expect(FileEvents.temporary("/w/a.txt.sb-a7968322-gfH2Jc") && FileEvents.temporary("/w/4913"))
        #expect(FileEvents.temporary("/w/.a.txt.swp") && FileEvents.temporary("/w/a.txt~"))
        #expect(!FileEvents.temporary("/w/a.txt") && !FileEvents.temporary("/w/Program.cs"))
    }
}
