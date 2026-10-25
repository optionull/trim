import SillCore
import Testing

@Suite struct EditorContextTests {
    let selection = EditorContext.Selection(path: "src/Tax.cs", from: 3, to: 5, text: "a\nb\nc")

    @Test func allOfItTheFirstTime() throws {
        let text = try #require(EditorContext(
            path: "src/Tax.cs",
            line: 4,
            selection: selection,
            basket: "tax.basket.md"
        )
        .text())
        #expect(text.contains("Open in the editor: src/Tax.cs:4"))
        #expect(text.contains("Selected, src/Tax.cs:3-5:\n```\na\nb\nc\n```"))
        #expect(text.contains("Open basket: .sill/baskets/tax.basket.md"))
    }

    @Test func onlyWhatChanged() throws {
        let first = EditorContext(path: "src/Tax.cs", line: 4, selection: selection, basket: "tax.basket.md")
        #expect(first.text(after: first) == nil)
        var moved = first
        moved.line = 9
        let text = try #require(moved.text(after: first))
        #expect(text.contains("src/Tax.cs:9"))
        #expect(!text.contains("Selected") && !text.contains("basket"))
    }

    @Test func nothingOpenIsNothing() {
        #expect(EditorContext().text() == nil)
    }

    @Test func aLongSelectionIsCut() throws {
        let lines = (1 ... 100).map { "line \($0)" }.joined(separator: "\n")
        let long = EditorContext.Selection(path: "a.cs", from: 1, to: 100, text: lines)
        let text = try #require(EditorContext(selection: long).text())
        #expect(text.contains("line 60\n… (40 more lines)"))
        #expect(!text.contains("line 61"))
    }

    @Test func thePullRequestWhenItChanges() throws {
        let failing = EditorContext(pullRequest: "#12 (https://example.test/pr/12): 1 check failing: build")
        let text = try #require(failing.text())
        #expect(text.contains("The branch's pull request #12 (https://example.test/pr/12): 1 check failing: build"))
        #expect(failing.text(after: failing) == nil)
        #expect(EditorContext(path: "a.cs").text(after: failing)?.contains("pull request") == false)
    }
}
