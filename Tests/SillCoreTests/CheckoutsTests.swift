import Foundation
import SillCore
import Testing

@Suite struct CheckoutsTests {
    /// A folder with: repository `alpha` (with a worktree outside the roots and a repository nested in it),
    /// `group/beta`, and a `.git` inside node_modules.
    func fixture() throws -> (root: String, outside: String) {
        let root = realPath(NSTemporaryDirectory()) + "/sill-checkouts-\(UUID().uuidString)"
        let outside = root + "-elsewhere"
        let fileManager = FileManager.default
        func git(_ arguments: [String], _ folder: String) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git", "-c", "user.email=a@b", "-c", "user.name=s", "-c", "commit.gpgsign=false"] +
                arguments
            process.currentDirectoryURL = URL(fileURLWithPath: folder)
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
        }
        for repository in ["alpha", "group/beta", "alpha/nested"] {
            let folder = root + "/" + repository
            try fileManager.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try git(["init", "-q", "-b", "main"], folder)
            try "one\n".write(toFile: folder + "/a.txt", atomically: true, encoding: .utf8)
            try git(["add", "a.txt"], folder)
            try git(["commit", "-qm", "one"], folder)
        }
        try git(["worktree", "add", "-q", "-b", "feature", outside], root + "/alpha")
        try fileManager.createDirectory(atPath: root + "/web/node_modules/dep/.git", withIntermediateDirectories: true)
        return (root, outside)
    }

    @Test func findsRepositoriesAndTheirWorktrees() throws {
        let (root, outside) = try fixture()
        let found = Checkouts.find(roots: [root]).sorted { $0.path < $1.path }
        #expect(found.map(\.path) == [root + "/alpha", outside, root + "/group/beta"].sorted())
        #expect(found.first { $0.path == outside }?.isWorktree == true)
        #expect(found.first { $0.path == outside }?.repository == root + "/alpha")
        #expect(found.first { $0.path == outside }?.repositoryName == "alpha")
    }

    @Test func aCheckoutsState() throws {
        let (root, outside) = try fixture()
        try "two\n".write(toFile: outside + "/a.txt", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: outside + "/.sill", withIntermediateDirectories: true)
        try "{}".write(toFile: outside + "/.sill/seen.json", atomically: true, encoding: .utf8)
        try "new\n".write(toFile: outside + "/b.txt", atomically: true, encoding: .utf8)
        let checkout = try #require(Checkouts.find(roots: [root]).first { $0.path == outside })
        let state = CheckoutState.read(checkout, transcripts: root + "/no-transcripts")
        #expect(state.branch == "feature" && state.touched == 2)
        #expect(state.lastCommit != nil && state.lastEdit != nil && state.agent == nil)
        #expect(state.active == state.lastEdit)
    }

    @Test func anAgentWorkingOrNot() throws {
        let transcripts = realPath(NSTemporaryDirectory()) + "/sill-transcripts-\(UUID().uuidString)"
        let cwd = "/Users/someone/Projects/a_b.c"
        let folder = AgentActivity.folder(for: cwd, in: transcripts)
        #expect(folder.hasSuffix("/-Users-someone-Projects-a-b-c"))
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let prompt = #"{"type":"user","message":{"role":"user","content":"Round the tax once"}}"#
        let tool = #"{"type":"assistant","message":{"stop_reason":"tool_use","content":[]}}"#
        let result = #"{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}"#
        let done = #"{"type":"assistant","message":{"stop_reason":"end_turn","content":[]}}"#
        let file = folder + "/session.jsonl"
        try [prompt, tool, result, #"{"type":"last-prompt"}"#].joined(separator: "\n")
            .write(toFile: file, atomically: true, encoding: .utf8)
        let working = try #require(AgentActivity.read(cwd: cwd, transcripts: transcripts))
        #expect(working.working && working.prompt == "Round the tax once")
        try [prompt, tool, result, done].joined(separator: "\n").write(toFile: file, atomically: true, encoding: .utf8)
        #expect(AgentActivity.read(cwd: cwd, transcripts: transcripts)?.working == false)
        // The prompt as Claude Code notes it, when the person's message is further back than the end read.
        let noted = #"{"type":"last-prompt","lastPrompt":"Make it fast"}"#
        try [tool, result, noted].joined(separator: "\n").write(toFile: file, atomically: true, encoding: .utf8)
        #expect(AgentActivity.read(cwd: cwd, transcripts: transcripts)?.prompt == "Make it fast")
        // A turn not ended but long untouched: the session was closed.
        try [prompt, tool].joined(separator: "\n").write(toFile: file, atomically: true, encoding: .utf8)
        #expect(AgentActivity.read(cwd: cwd, transcripts: transcripts, now: Date().addingTimeInterval(3600))?
            .working == false)
    }

    @Test func walkthroughsPreparedAndSeen() throws {
        let (root, outside) = try fixture()
        let sill = root + "/alpha/.sill"
        try FileManager.default.createDirectory(atPath: sill + "/handoffs", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: sill + "/reviews/1", withIntermediateDirectories: true)
        try "---\ntitle: The tax, once\nworktree: \(outside)\n---\nRounding moved to Pricing.\n\nMore.\n"
            .write(toFile: sill + "/handoffs/tax.walk.md", atomically: true, encoding: .utf8)
        try "---\ntitle: A review\n---\nWhat changed.\n"
            .write(toFile: sill + "/reviews/1/review.walk.md", atomically: true, encoding: .utf8)
        try "---\ntitle: Not a walkthrough\n---\n".write(
            toFile: sill + "/x.basket.md",
            atomically: true,
            encoding: .utf8
        )
        let checkouts = Checkouts.find(roots: [root])
        let worktree = try #require(checkouts.first { $0.path == outside })
        let main = try #require(checkouts.first { $0.path == root + "/alpha" })
        let prepared = CheckoutState.read(worktree, transcripts: root).walkthroughs
        #expect(prepared.map(\.title) == ["The tax, once"] && prepared.first?.kind == "handoff")
        #expect(prepared.first?.summary == "Rounding moved to Pricing." && prepared.first?.seen == false)
        #expect(CheckoutState.read(main, transcripts: root).walkthroughs.map(\.title) == ["A review"])
        Seen.mark(sill + "/handoffs/tax.walk.md", in: sill)
        #expect(CheckoutState.read(worktree, transcripts: root).unseen.isEmpty)
        // Written again after it was seen: unseen again.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: sill + "/handoffs/tax.walk.md"
        )
        #expect(CheckoutState.read(worktree, transcripts: root).unseen.count == 1)
    }
}
