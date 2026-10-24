import Foundation

/// The expression a pointer rests on in a line of code, for the debugger to evaluate: the identifier under it with the
/// member accesses before it (`order.Customer` over `Customer`, `order` over `order`), as a person reading `a.b.c`
/// means the part up to where they point.
public enum HoverExpression {
    public static func at(_ line: [Character], col: Int) -> String? {
        func identifier(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        guard line.indices.contains(col), identifier(line[col]) else { return nil }
        var end = col
        while end + 1 < line.count, identifier(line[end + 1]) {
            end += 1
        }
        var start = col
        while start > 0, identifier(line[start - 1]) {
            start -= 1
        }
        // Member accesses to the left: `a.b` and `this.a`.
        while start >= 2, line[start - 1] == ".", identifier(line[start - 2]) {
            start -= 2
            while start > 0, identifier(line[start - 1]) {
                start -= 1
            }
        }
        let text = String(line[start ... end])
        // A number is not worth asking about, nor is a keyword.
        guard !(text.first?.isNumber ?? true), !keywords.contains(text) else { return nil }
        return text
    }

    static let keywords: Set<String> = [
        "var", "new", "return", "if", "else", "for", "foreach", "while", "in", "public", "private", "static", "class",
        "record", "struct", "void", "int", "double", "string", "bool", "true", "false", "null", "using", "namespace",
    ]
}
