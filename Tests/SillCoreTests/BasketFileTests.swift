import SillCore
import Testing

@Suite("basket files")
struct BasketFileTests {
    @Test("a new basket reads as one: title, question, who, open")
    func new() {
        let source = BasketFile.new(
            title: "Is tax applied twice?",
            question: "Twice on discounts?\nReally?",
            by: "claude"
        )
        let walk = Walkthrough(source)
        #expect(walk.title == "Is tax applied twice?" && walk.question == "Twice on discounts? Really?")
        #expect(walk.by == "claude" && walk.status == "open" && walk.steps.isEmpty)
        #expect(BasketFile.fileName(for: "Is tax applied twice?") == "is-tax-applied-twice.basket.md")
        #expect(BasketFile.fileName(for: "???") == "basket.basket.md")
    }

    @Test("pieces go under their section, with their note and fingerprint; sections before the findings")
    func adding() {
        var source = BasketFile.new(title: "T")
        source = BasketFile.adding(source, anchor: "Pricing.Total", fingerprint: "a1b2c3d", note: "the total")
        source = BasketFile.adding(source, anchor: "src/Tax.cs:3-5", fingerprint: "1234567", section: "Tax")
        source = BasketFile.concluding(source, "It is applied once.")
        source = BasketFile.adding(source, anchor: "src/Report.cs:1-2", fingerprint: nil, section: "Who reaches it")
        source = BasketFile.adding(source, anchor: "Checkout.Run", fingerprint: "7654321")
        let walk = Walkthrough(source)
        #expect(walk.steps.map(\.title) == ["Collected", "Tax", "Who reaches it", "Findings"])
        #expect(walk.steps[0].blocks == [
            .prose("the total"), .code(.symbol("Pricing.Total", lines: nil), line: 9),
            .code(.symbol("Checkout.Run", lines: nil), line: 10),
        ])
        #expect(walk.fingerprints[9] == "a1b2c3d" && walk.fingerprints[10] == "7654321")
        #expect(walk.steps[2].blocks == [.code(.file("src/Report.cs", lines: 1 ... 2), line: 16)])
        #expect(walk.steps[3].blocks == [.prose("It is applied once.")] && walk.status == "concluded")
    }

    @Test("a range touching or overlapping one in the basket joins it, its fingerprint renewed")
    func joining() {
        var source = BasketFile.adding(BasketFile.new(title: "T"), anchor: "src/Tax.cs:3-5", fingerprint: "1111111")
        source = BasketFile.adding(source, anchor: "src/Tax.cs:6-8", fingerprint: "2222222", note: "and after") {
            "\($0):\($1.lowerBound)-\($1.upperBound)" == "src/Tax.cs:3-8" ? "3333333" : nil
        }
        source = BasketFile.adding(source, anchor: "src/Tax.cs:10-12", fingerprint: "4444444")
        let walk = Walkthrough(source)
        #expect(walk.steps[0].blocks == [
            .prose("and after"), .code(.file("src/Tax.cs", lines: 3 ... 8), line: 9),
            .code(.file("src/Tax.cs", lines: 10 ... 12), line: 10),
        ], "line 9 is between: 10-12 stands apart")
        #expect(walk.fingerprints[9] == "3333333")
    }

    @Test("removing a piece takes its note; findings replaced; fields set")
    func editing() {
        var source = BasketFile.adding(BasketFile.new(title: "T"), anchor: "A.B", fingerprint: nil, note: "why")
        source = BasketFile.adding(source, anchor: "C.D", fingerprint: nil)
        source = BasketFile.noting(source, "A thought.\nOn two lines.")
        let anchor = Walkthrough(source).steps[0].blocks.compactMap { block -> Int? in
            if case let .code(.symbol("A.B", _), line) = block { return line }
            return nil
        }[0]
        source = BasketFile.removing(source, anchorAt: anchor)
        #expect(Walkthrough(source).steps[0].blocks == [
            .code(.symbol("C.D", lines: nil), line: 8), .prose("A thought.\nOn two lines."),
        ])
        #expect(BasketFile.removing(source, anchorAt: 2) == source, "only an anchor's line")
        source = BasketFile.concluding(BasketFile.concluding(source, "First."), "Second.")
        #expect(Walkthrough(source).steps.last?.blocks == [.prose("Second.")])
        #expect(Walkthrough(BasketFile.setting(source, "status", to: "sent")).status == "sent")
        #expect(Walkthrough(BasketFile.setting(source, "asked", to: "x")).steps.count == 2, "a new field")
    }

    @Test("fingerprints and the parser's reading of them; @trace")
    func fingerprints() {
        #expect(BasketFile.fingerprint(["a", "b"]) == BasketFile.fingerprint(["a", "b"]))
        #expect(BasketFile.fingerprint(["a", "b"]) != BasketFile.fingerprint(["a", "c"]))
        #expect(BasketFile.fingerprint(["a"]).count == 7)
        let walk = Walkthrough("""
        ## S
        @code src/a.cs:1-2 #abc
        @code Tax.Of lines 2-3 #0123abcd
        @trace Tax.Of callers 3
        @trace Pricing.Total callees
        """)
        #expect(walk.fingerprints == [3: "0123abcd"], "#abc is too short to be one")
        #expect(walk.steps[0].blocks == [
            .code(.file("src/a.cs", lines: 1 ... 2), line: 2), .code(.symbol("Tax.Of", lines: 2 ... 3), line: 3),
            .trace("Tax.Of", callers: true, depth: 3, line: 4), .trace(
                "Pricing.Total",
                callers: false,
                depth: 2,
                line: 5
            ),
        ])
    }
}
