import Foundation
import SillCore
import Testing

@Suite struct StoryTests {
    func git(_ arguments: [String], _ folder: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process
            .arguments = ["git", "-c", "user.email=a@b", "-c", "user.name=s", "-c", "commit.gpgsign=false"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: folder)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    /// main with a.txt and b.txt; a branch that changed a.txt in a commit, renamed b.txt, and has a new file and a
    /// change not committed.
    func fixture() throws -> String {
        let folder = realPath(NSTemporaryDirectory()) + "/sill-story-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], folder)
        try "one\ntwo\n".write(toFile: folder + "/a.txt", atomically: true, encoding: .utf8)
        try "keep\n".write(toFile: folder + "/b.txt", atomically: true, encoding: .utf8)
        try git(["add", "."], folder)
        try git(["commit", "-qm", "base"], folder)
        try git(["checkout", "-qb", "feature"], folder)
        try "one\ntwo\nthree\n".write(toFile: folder + "/a.txt", atomically: true, encoding: .utf8)
        try git(["mv", "b.txt", "c.txt"], folder)
        try git(["commit", "-qam", "Count to three"], folder)
        try "one\n2\nthree\n".write(toFile: folder + "/a.txt", atomically: true, encoding: .utf8)
        try "new\nfile\n".write(toFile: folder + "/n.txt", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: folder + "/.sill", withIntermediateDirectories: true)
        try "{}".write(toFile: folder + "/.sill/seen.json", atomically: true, encoding: .utf8)
        return folder
    }

    @Test func aBranchsStory() throws {
        let folder = try fixture()
        let story = Story.read(folder, transcripts: folder + "/none")
        #expect(story.base == "main" && story.fork != nil)
        #expect(story.commits.map(\.subject) == ["Count to three"])
        let touched = Dictionary(uniqueKeysWithValues: story.touched.map { ($0.path, $0) })
        #expect(Set(touched.keys) == ["a.txt", "c.txt", "n.txt"])
        #expect(touched["a.txt"].map { ($0.added, $0.removed) } ?? (0, 0) == (2, 1))
        #expect(touched["n.txt"]?.status == .added && touched["n.txt"]?.added == 2)
    }

    @Test func onTheBaseOnlyWhatIsNotCommitted() throws {
        let folder = try fixture()
        try git(["checkout", "-q", "-f", "main"], folder)
        let story = Story.read(folder, transcripts: folder + "/none")
        #expect(story.commits.isEmpty && story.touched.map(\.path) == ["n.txt"])
    }

    @Test func thePromptsNewestFirst() throws {
        let transcripts = realPath(NSTemporaryDirectory()) + "/sill-story-transcripts-\(UUID().uuidString)"
        let cwd = "/work/shop"
        let folder = AgentActivity.folder(for: cwd, in: transcripts)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"user","timestamp":"2026-11-02T08:00:00.000Z","message":{"content":"Round the tax once"}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}"#,
            #"{"type":"user","message":{"content":"<command-name>/clear</command-name>"}}"#,
            #"{"type":"user","timestamp":"2026-11-02T09:00:00.000Z","message":{"content":[{"type":"text","text":"And the tests"}]}}"#,
        ]
        try lines.joined(separator: "\n").write(toFile: folder + "/s.jsonl", atomically: true, encoding: .utf8)
        let prompts = Story.read("/work/shop", transcripts: transcripts).prompts
        #expect(prompts.map(\.text) == ["And the tests", "Round the tax once"])
        #expect(prompts.first?.at != nil)
    }
}
