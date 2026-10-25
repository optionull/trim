import Foundation
import SillCore
import Testing

@Suite("plans and hook settings")
struct PlanFileTests {
    @Test("a plan as a notebook: its title, its sections, the code it names (once, existing files only)")
    func plan() {
        let plan = """
        # Round the tax once

        ## Why
        `src/Tax.cs:5` rounds, and so does src/Pricing.cs:6.

        ## Steps
        1. Change src/Tax.cs:5 to not round.
        2. Leave docs/notes.md alone; src/Gone.cs does not matter.
        """
        let files: Set = ["/r/src/Tax.cs", "/r/src/Pricing.cs", "/r/docs/notes.md"]
        let source = PlanFile.notebook(plan, root: "/r") { files.contains($0) }
        let walk = Walkthrough(source)
        #expect(walk.title == "Round the tax once" && walk.status == "presented" && walk.by == "agent")
        #expect(walk.steps.map(\.title) == ["Why", "Steps", "Code it names"])
        #expect(walk.steps[2].blocks.map { if case let .code(anchor, _) = $0 { anchor.text } else { "" } } == [
            "src/Tax.cs:3-11", "src/Pricing.cs:4-12", "docs/notes.md",
        ])
        #expect(Walkthrough(PlanFile.notebook("Just do it.", root: "/r") { _ in false }).title == "Just do it.")
    }

    @Test("a root as the disk names it (/private/var…), references as paths say it (/var…)")
    func privatePaths() throws {
        let folder = NSTemporaryDirectory() + "plan-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try "x".write(toFile: folder + "/a.cs", atomically: true, encoding: .utf8)
        let real = try #require(realpath(folder, nil).map { String(cString: $0) })
        #expect(real.hasPrefix("/private/"), "the disk's name: \(real)")
        let plan = PlanFile.notebook("See \((folder as NSString).standardizingPath)/a.cs:3", root: real)
        #expect(plan.hasSuffix("@code a.cs:1-9\n"), "\(plan)")
        let name = PlanFile.fileName(title: "Round the tax once", at: Date(timeIntervalSince1970: 0))
        #expect(name == "19700101-000000-round-the-tax-once.plan.md")
    }

    @Test("sill's hooks go in beside the person's own, once, and come out leaving theirs")
    func settings() throws {
        let theirs: [String: Any] = [
            "permissions": ["allow": ["Bash(ls)"]],
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "say done"]]]]],
        ]
        let command = "… | nc -U '/tmp/sill-hooks-abc.sock' || true"
        var settings = HookSettings.installing(command, marker: "sill-hooks-", in: theirs)
        settings = HookSettings.installing(command, marker: "sill-hooks-", in: settings)
        let hooks = try #require(settings["hooks"] as? [String: Any])
        #expect(HookSettings.installed(marker: "sill-hooks-", in: settings))
        #expect((hooks["Stop"] as? [Any])?.count == 2, "theirs and sill's, sill's once")
        #expect((hooks["PreToolUse"] as? [[String: Any]])?.first?["matcher"] as? String == "*")
        #expect(
            (hooks["UserPromptSubmit"] as? [[String: Any]])?.first?["matcher"] == nil,
            "no matcher where none applies"
        )
        let removed = HookSettings.removing(marker: "sill-hooks-", from: settings)
        #expect(NSDictionary(dictionary: removed).isEqual(to: theirs), "as it was")
        #expect(!HookSettings.installed(marker: "sill-hooks-", in: removed))
        #expect(HookSettings.removing(marker: "sill-hooks-", from: [:]).isEmpty)
    }
}
