import Foundation
import SillCore
import Testing

@Suite struct HandoffFileTests {
    @Test func aHandoffReadsBackAsAWalkthrough() {
        let text = HandoffFile.text(
            title: "The tax is rounded once", summary: "Tax.Of no longer rounds.\n", worktree: "/work/shop",
            by: "claude",
            read: [.init(path: "Tax.cs", lines: 3 ... 11, why: "Where the rounding was."), .init(path: "Pricing.cs")],
            run: [
                .init(name: "Tests", command: "dotnet test tests/Shop.Tests"),
                .init(name: "Shop: web", command: "dotnet run"),
            ]
        )
        let walk = Walkthrough(text)
        #expect(walk.title == "The tax is rounded once" && walk.worktree == "/work/shop" && walk.by == "claude")
        #expect(walk.status == "handoff" && walk.intro == "Tax.Of no longer rounds.")
        #expect(walk.steps.map(\.title) == ["Read in this order", "Run it"])
        let anchors = walk.steps[0].blocks.compactMap { if case let .code(anchor, _) = $0 { anchor.text } else { nil } }
        #expect(anchors == ["Tax.cs:3-11", "Pricing.cs"])
        #expect(HandoffFile.runs(in: walk) == [
            .init(name: "Tests", command: "dotnet test tests/Shop.Tests"), .init(
                name: "Shop  web",
                command: "dotnet run"
            ),
        ])
    }

    @Test func aBareRunIsItsOwnName() {
        let walk =
            Walkthrough(
                "---\ntitle: x\n---\n\n## Run it\n@run swift test --filter CoreTests\n@run cd src && make: all\n"
            )
        #expect(HandoffFile.runs(in: walk).map(\.name) == ["swift test --filter CoreTests", "cd src && make: all"])
        #expect(HandoffFile.fileName(title: "Round once!", at: Date(timeIntervalSince1970: 0)) ==
            "19700101-000000-round-once.walk.md")
    }
}
