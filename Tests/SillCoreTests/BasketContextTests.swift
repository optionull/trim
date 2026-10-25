import Foundation
import SillCore
import Testing

@Suite("basket context")
struct BasketContextTests {
    typealias Test = BasketContext.Test

    @Test("git's history of the lines: how many, and the newest")
    func history() {
        let log = "a1b2c3d\tAda\t2026-10-22\tRound the tax\n9f8e7d6\tLin\t2026-09-01\tAdd tax\n\nnot a commit"
        let (changes, last) = BasketContext.history(log)
        #expect(changes == 2)
        #expect(last == .init(commit: "a1b2c3d", author: "Ada", date: "2026-10-22", subject: "Round the tax"))
        #expect(BasketContext.history("").changes == 0 && BasketContext.history("").last == nil)
    }

    @Test("a hover: its signature and the first sentence of its documentation")
    func hover() {
        let roslyn = """
        ```csharp
        decimal Tax.Of(decimal amount)
        ```
        ---
        The tax on an amount, rounded to cents. Uses the current rate.
        """
        #expect(BasketContext.hover(roslyn) == (
            "decimal Tax.Of(decimal amount)",
            "The tax on an amount, rounded to cents."
        ))
        #expect(BasketContext.hover("```cs\nint X()\n```") == ("int X()", nil))
        #expect(BasketContext.hover("Only prose") == (nil, "Only prose"))
    }

    @Test("chips, the agent's lines, the overview; kept beside the basket")
    func showing() throws {
        var piece = BasketContext.Piece()
        piece.project = "Shop.Core"
        piece.projectKind = "library"
        piece.symbol = "Tax.Of"
        piece.signature = "decimal Tax.Of(decimal amount)"
        piece.summary = "The tax on an amount."
        piece.tests = [Test(name: "Rounds", path: "tests/TaxTests.cs", line: 9)]
        piece.changes = 3
        piece.last = .init(commit: "a1b2c3d", author: "Ada", date: "2026-10-22", subject: "Round the tax")
        var other = BasketContext.Piece()
        other.project = "Shop.Core"
        other.tests = [Test(name: "Rounds", path: "tests/TaxTests.cs", line: 9), Test(name: "A", path: "a.cs", line: 1)]
        other.problems = ["CS0103 x", "CS0103 y"]
        let context = BasketContext(pieces: ["Tax.Of": piece, "Pricing.cs:3-7": other])
        let today = try #require(ISO8601DateFormatter().date(from: "2026-10-25T12:00:00Z"))
        #expect(context.chips("Tax.Of", today: today) == [
            "Shop.Core",
            "Tax.Of",
            "1 test",
            "3 changes, last 3 days ago",
        ])
        #expect(context.chips("Pricing.cs:3-7", today: today) == ["Shop.Core", "2 tests", "2 problems"])
        #expect(context.chips("nothing").isEmpty)
        // How long ago, by day.
        for (date, said) in [("2026-10-25", "today"), ("2026-10-24", "yesterday"), ("2026-01-02", "in 2026-01")] {
            var dated = BasketContext.Piece()
            dated.changes = 1
            dated.last = .init(commit: "c", author: "a", date: date, subject: "s")
            #expect(BasketContext(pieces: ["x": dated]).chips("x", today: today) == ["1 change, last \(said)"])
        }
        #expect(context.text("Tax.Of") == [
            "Context: in Shop.Core (library), decimal Tax.Of(decimal amount)",
            "Documented as: The tax on an amount.",
            "Tests reaching it: Rounds (tests/TaxTests.cs:9)",
            "History: 3 commits, last a1b2c3d \"Round the tax\" by Ada on 2026-10-22",
        ])
        let overview = context.overview
        #expect(overview.projects.map(\.0) == ["Shop.Core"] && overview.projects.map(\.1) == [2])
        #expect(overview.tests.map(\.name) == ["A", "Rounds"], "once each")
        #expect(overview.authors.map(\.0) == ["Ada"])

        let basket = NSTemporaryDirectory() + "ctx-\(UUID().uuidString).basket.md"
        defer { try? FileManager.default.removeItem(atPath: BasketContext.file(for: basket)) }
        #expect(BasketContext.file(for: "/a/report.basket.md") == "/a/report.basket.context.json")
        context.save(for: basket)
        #expect(BasketContext.load(for: basket) == context)
        #expect(BasketContext.load(for: "/nowhere.basket.md") == BasketContext())
    }
}
