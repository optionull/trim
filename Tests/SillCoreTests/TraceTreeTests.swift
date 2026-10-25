import SillCore
import Testing

@Suite("trace tree")
struct TraceTreeTests {
    typealias Item = TraceTree.Item

    static let tax = Item(id: 1, name: "Of", detail: "Tax.Of(decimal)", path: "/r/Tax.cs", line: 3)
    static let total = Item(id: 2, name: "Total", path: "/r/Pricing.cs", line: 5, at: 7)
    static let run = Item(id: 3, name: "Run", path: "/r/Checkout.cs", line: 4, at: 9)
    static let print = Item(id: 4, name: "Print", path: "/r/Report.cs", line: 2, at: 3)
    static let main = Item(id: 5, name: "<Main>$", path: "/r/Program.cs", line: 1, at: 1)

    @Test("levels as they are asked, sorted by where they are; what is shown follows what is open")
    func levels() {
        var tree = TraceTree(root: Self.tax, direction: .incoming)
        #expect(tree.visible == [0] && tree.unasked(within: 3) == [0])
        tree.setChildren(of: 0, [Self.total])
        tree.setChildren(of: 1, [Self.print, Self.run])
        #expect(
            tree.visible.map { tree.nodes[$0].item.name } == ["Of", "Total", "Run", "Print"],
            "Checkout.cs before Report.cs"
        )
        #expect(tree.unasked(within: 3).map { tree.nodes[$0].item.name } == ["Run", "Print"])
        #expect(tree.unasked(within: 2).isEmpty, "depth 2 is asked")
        tree.setExpanded(1, false)
        #expect(tree.visible.map { tree.nodes[$0].item.name } == ["Of", "Total"])
        tree.setExpanded(2, true)
        #expect(!tree.nodes[2].expanded, "a node not asked yet does not open")
        let run = tree.nodes.firstIndex { $0.item.name == "Run" }!
        #expect(tree.path(to: run).map { tree.nodes[$0].item.name } == ["Of", "Total", "Run"])
    }

    @Test("a symbol among its own ancestors is marked and not asked again")
    func recursion() {
        var tree = TraceTree(root: Self.total, direction: .outgoing)
        tree.setChildren(of: 0, [Item(id: 9, name: "Total", path: "/r/Pricing.cs", line: 5), Self.tax])
        let again = tree.nodes.firstIndex { $0.item.id == 9 }!
        #expect(tree.nodes[again].recursive && tree.nodes[again].children == [])
        #expect(!tree.unasked(within: 5).contains(again))
        #expect(!tree.nodes[tree.nodes.firstIndex { $0.item.id == 1 }!].recursive)
    }

    @Test("as text: indented, paths from the root, where each call is")
    func text() {
        var tree = TraceTree(root: Self.tax, direction: .incoming)
        tree.setChildren(of: 0, [Self.total])
        tree.setChildren(of: 1, [Self.run, Self.print])
        tree.setChildren(of: 2, [Self.main])
        #expect(tree.text(relativeTo: "/r") == """
        Callers of Of (Tax.cs:3):
          Total  Pricing.cs:5, calls at line 7
            Run  Checkout.cs:4, calls at line 9
              <Main>$  Program.cs:1, calls at line 1
            Print  Report.cs:2, calls at line 3
        """)
        var lonely = TraceTree(root: Self.main, direction: .incoming)
        lonely.setChildren(of: 0, [])
        #expect(lonely.text(relativeTo: "/r").hasSuffix("  (no callers found)"))
        var callees = TraceTree(root: Self.run, direction: .outgoing)
        callees.setChildren(of: 0, [Self.total])
        #expect(callees.text(relativeTo: "/r") == "Callees of Run (Checkout.cs:4):\n  Total  Pricing.cs:5")
    }
}
