import Testing
@testable import TrimWalk

@Suite("walkthroughs")
struct WalkthroughTests {
    let source = """
    ---
    title: How an order reaches the database
    for: Orders.slnx
    ---
    What this covers.

    ## The request comes in
    Kestrel hands the POST to `Create`.
    @code OrdersController.Create
    Then pricing.
    @code src/Pricing.cs:12-30
    @ask "Why is the total not cached?"
    > Prices change per request.
    > Caching would serve stale ones.

    ## Pricing
    @code Pricing.Total lines 3-9
    @code Program.cs:5
    @ask Who calls this?
    """

    @Test("front matter, steps, prose, anchors and questions with their answers")
    func parse() {
        let walk = Walkthrough(source)
        #expect(walk.title == "How an order reaches the database" && walk.target == "Orders.slnx")
        #expect(walk.intro == "What this covers." && walk.steps.map(\.title) == ["The request comes in", "Pricing"])
        #expect(walk.steps[0].line == 7)
        #expect(walk.steps[0].blocks == [
            .prose("Kestrel hands the POST to `Create`."),
            .code(.symbol("OrdersController.Create", lines: nil), line: 9),
            .prose("Then pricing."),
            .code(.file("src/Pricing.cs", lines: 12 ... 30), line: 11),
            .ask(
                "Why is the total not cached?",
                answer: "Prices change per request.\nCaching would serve stale ones.",
                line: 12
            ),
        ])
        #expect(walk.steps[1].blocks == [
            .code(.symbol("Pricing.Total", lines: 3 ... 9), line: 17),
            .code(.file("Program.cs", lines: 5 ... 5), line: 18),
            .ask("Who calls this?", answer: nil, line: 19),
        ])
    }

    @Test("a file alone or with lines, a symbol alone or with lines")
    func anchors() {
        let walk = Walkthrough("## A\n@code Program.cs\n@code Pricing.Total\n@code src/Pricing.cs\n")
        #expect(walk.steps[0].blocks == [
            .code(.file("Program.cs", lines: nil), line: 2), .code(.symbol("Pricing.Total", lines: nil), line: 3),
            .code(.file("src/Pricing.cs", lines: nil), line: 4),
        ])
    }

    @Test("an answer is written under its question, and replaces one already there")
    func answer() {
        let answered = Walkthrough.answering(source, questionAt: 19, with: "Program.cs, once per order.")
        #expect(Walkthrough(answered).steps[1].blocks.last == .ask(
            "Who calls this?",
            answer: "Program.cs, once per order.",
            line: 19
        ))
        let replaced = Walkthrough.answering(source, questionAt: 12, with: "Because prices move.")
        #expect(Walkthrough(replaced).steps[0].blocks.last == .ask(
            "Why is the total not cached?",
            answer: "Because prices move.",
            line: 12
        ))
        #expect(replaced.contains("## Pricing\n@code Pricing.Total lines 3-9"), "the rest untouched")
    }
}

@Suite("review walkthroughs")
struct ReviewWalkthroughTests {
    @Test("a review's base, and its diffs and examples")
    func review() {
        let walk = Walkthrough("""
        ---
        title: Review: pricing by seed
        base: 4b825dc642cb6eb9a060e54bf8d69288fbee4904
        ---
        ## What changed
        Total now scales with the seed.
        @diff src/Orders/Pricing.cs
        @example examples/total.cs
        """)
        #expect(walk.base == "4b825dc642cb6eb9a060e54bf8d69288fbee4904")
        #expect(walk.steps[0].blocks == [
            .prose("Total now scales with the seed."), .diff("src/Orders/Pricing.cs", line: 7),
            .example("examples/total.cs", line: 8),
        ])
    }
}
