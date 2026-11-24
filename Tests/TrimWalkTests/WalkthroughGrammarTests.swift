import Testing
@testable import TrimWalk

@Suite("walkthrough grammar: fences, links, checklists, provenance")
struct WalkthroughGrammarTests {
    let source = """
    ---
    title: How pricing works
    by: claude
    model: claude-opus
    commit: 4107714
    created: 2026-11-24
    ---
    Intro with a fence that must stay whole:
    ```text
    ## not a step
    @code Nope.Nothing
    ```

    ## The call path
    Who calls whom.
    ```mermaid
    sequenceDiagram
      Client->>Orders: Create
      Orders->>Pricing: Total
    ```
    @link Orders -> OrdersController.Create
    @link Pricing -> src/Pricing.cs:12-30 #a1b2c3d

    ## Checklist
    - [ ] Reviewed the pricing change
    - [x] Ran the tests
    @code Pricing.Total
    """

    @Test("a fence is one block, verbatim, and what is inside it is never a heading or a directive")
    func fences() {
        let walk = Walkthrough(source)
        #expect(walk.steps.map(\.title) == ["The call path", "Checklist"])
        #expect(walk.intro.contains("## not a step") && walk.intro.contains("@code Nope.Nothing"))
        #expect(walk.steps[0].blocks[0] == .prose("Who calls whom."))
        #expect(walk.steps[0].blocks[1] == .fence(
            language: "mermaid",
            text: "sequenceDiagram\n  Client->>Orders: Create\n  Orders->>Pricing: Total",
            line: 16
        ))
    }

    @Test("@link says where a node of the diagram goes; a fingerprint after it is dropped from the anchor")
    func links() {
        let blocks = Walkthrough(source).steps[0].blocks
        #expect(blocks.contains(.link(
            node: "Orders",
            anchor: .symbol("OrdersController.Create", lines: nil),
            line: 21
        )))
        #expect(blocks.contains(.link(node: "Pricing", anchor: .file("src/Pricing.cs", lines: 12 ... 30), line: 22)))
    }

    @Test("checklist items are blocks, done or not, and toggling writes the file's own line")
    func tasks() {
        let blocks = Walkthrough(source).steps[1].blocks
        #expect(blocks[0] == .task("Reviewed the pricing change", done: false, line: 25))
        #expect(blocks[1] == .task("Ran the tests", done: true, line: 26))
        let ticked = Walkthrough.toggling(source, taskAt: 25)
        #expect(ticked.contains("- [x] Reviewed the pricing change") && ticked.contains("- [x] Ran the tests"))
        #expect(Walkthrough.toggling(ticked, taskAt: 26).contains("- [ ] Ran the tests"))
        #expect(Walkthrough.toggling(source, taskAt: 27) == source, "a line that is not a task is left alone")
    }

    @Test("who wrote it, with what, against which commit")
    func provenance() {
        let walk = Walkthrough(source)
        #expect(walk.by == "claude" && walk.model == "claude-opus" && walk.commit == "4107714")
        #expect(walk.created == "2026-11-24")
    }

    @Test("a fingerprint is the first seven hex digits of the lines' SHA-256, and moves when the lines do")
    func fingerprint() {
        let one = Walkthrough.fingerprint(["let a = 1", "let b = 2"])
        #expect(one.count == 7 && one.allSatisfy(\.isHexDigit))
        #expect(one == Walkthrough.fingerprint(["let a = 1", "let b = 2"]))
        #expect(one != Walkthrough.fingerprint(["let a = 1", "let b = 3"]))
    }
}
