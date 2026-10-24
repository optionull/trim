import Foundation
@testable import SillCore
import Testing

// From heed's ConfigTests (the TOML part), with heed's keys as they were.
struct TOMLTests {
    @Test func parsesTheConstructsTheConfigUses() throws {
        let doc = try TOMLDocument("""
        # comment
        top = "level" # trailing
        [worktrees]
        root = '~/code/wt'
        roots = [
          "~/Projects", # one
          "~/code",
        ]
        [agents.claude]
        command = "claude \\"quoted\\""
        days = 1_4
        ratio = 0.5
        on = true
        [repos."acme/docs-toolkit".tasks]
        test = "dotnet test"
        inline = { a = 1, "b c" = "d" }
        prompt = \"\"\"
        line one
        line two\"\"\"
        """)
        #expect(doc.root.value(at: ["top"]) == .string("level"))
        #expect(doc.root.value(at: ["worktrees", "root"]) == .string("~/code/wt"))
        #expect(doc.root.value(at: ["worktrees", "roots"])?.array?.count == 2)
        #expect(doc.root.value(at: ["agents", "claude", "command"]) == .string("claude \"quoted\""))
        #expect(doc.root.value(at: ["agents", "claude", "days"]) == .integer(14))
        #expect(doc.root.value(at: ["agents", "claude", "ratio"]) == .float(0.5))
        #expect(doc.root.value(at: ["agents", "claude", "on"]) == .bool(true))
        #expect(doc.root.value(at: ["repos", "acme/docs-toolkit", "tasks", "test"]) == .string("dotnet test"))
        #expect(doc.root.value(at: ["repos", "acme/docs-toolkit", "tasks", "inline", "b c"]) == .string("d"))
        #expect(doc.root
            .value(at: ["repos", "acme/docs-toolkit", "tasks", "prompt"]) == .string("line one\nline two"))
    }

    @Test func reportsErrorsWithLines() {
        #expect(throws: TOMLError.self) { try TOMLDocument("a = \"open") }
        #expect(throws: TOMLError.self) { try TOMLDocument("[[arrays]]") }
        #expect(throws: TOMLError.self) { try TOMLDocument("a = 1\na = 2") }
        do {
            _ = try TOMLDocument("ok = 1\n[t]\nbad = \n")
        } catch {
            #expect(error.line == 3)
        }
    }

    @Test func settingKeepsCommentsAndLayout() throws {
        let source = """
        # my notes
        [worktrees]
        root = "~/code/wt"   # where they go

        [cleanup]
        idle_days = 14
        """
        let doc = try TOMLDocument(source)
        let edited = doc.setting(["worktrees", "root"], to: .string("~/wt"))
        #expect(edited.contains("root = \"~/wt\"   # where they go"))
        #expect(edited.contains("# my notes"))
        let added = try TOMLDocument(edited).setting(["cleanup", "delete_branch"], to: .bool(false))
        #expect(added.contains("idle_days = 14\ndelete_branch = false"))
        let newTable = try TOMLDocument(added).setting(["orgs", "acme", "color"], to: .string("teal"))
        #expect(try TOMLDocument(newTable).root.value(at: ["orgs", "acme", "color"]) == .string("teal"))
        #expect(newTable.hasSuffix("[orgs.acme]\ncolor = \"teal\"\n"))
    }
}
