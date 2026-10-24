import SillCore
import Testing

@Suite("hover expression")
struct HoverExpressionTests {
    func at(_ line: String, _ marker: String) -> String? {
        let col = line.distance(from: line.startIndex, to: line.range(of: marker)!.lowerBound)
        return HoverExpression.at(Array(line), col: col)
    }

    @Test("the identifier under the pointer, with the member accesses before it")
    func members() {
        let line = "    total += order.Customer.Length * 2;"
        #expect(at(line, "total") == "total")
        #expect(at(line, "order") == "order")
        #expect(at(line, "Customer") == "order.Customer")
        #expect(at(line, "ength") == "order.Customer.Length")
        #expect(at(line, "2;") == nil, "a number")
        #expect(at(line, "+=") == nil, "punctuation")
        #expect(at("var x = 1;", "var") == nil, "a keyword")
    }
}
