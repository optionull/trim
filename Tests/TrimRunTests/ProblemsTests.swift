import Foundation
import Testing
@testable import TrimRun

@Suite("Problems in build output")
struct ProblemsTests {
    private func folder() throws -> String {
        let root = NSTemporaryDirectory() + "trim-problems-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/src", withIntermediateDirectories: true)
        for name in ["src/A.cs", "src/b.swift", "src/main.rs", "src/c.ts"] {
            try "x\n".write(toFile: root + "/" + name, atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test("MSBuild's lines, printed twice, are one problem each, with the project in brackets dropped")
    func msbuild() throws {
        let root = try folder()
        let output = """
        src/A.cs(12,34): error CS1002: ; expected [\(root)/App.csproj]
        \(root)/src/A.cs(12,34): error CS1002: ; expected [\(root)/App.csproj]
        src/A.cs(20,5): warning CS0168: The variable 'e' is declared but never used [\(root)/App.csproj]
        Build FAILED.
        """
        let found = Problems.parse(output, directory: root)
        #expect(found.count == 2, "\(found)")
        #expect(found[0] == Problem(
            path: root + "/src/A.cs",
            line: 12,
            column: 34,
            severity: .error,
            code: "CS1002",
            message: "; expected"
        ))
        #expect(found[1].severity == .warning && found[1].code == "CS0168")
    }

    @Test("swiftc, clang and gcc's file:line:col, with the colours the terminal had")
    func compilers() throws {
        let root = try folder()
        let output = "\u{1B}[1m\(root)/src/b.swift:3:9: \u{1B}[31merror:\u{1B}[0m cannot find 'x' in scope\n"
            + "src/b.swift:4:1: warning: unused\nsrc/missing.swift:1:1: error: not a file here\n"
        let found = Problems.parse(output, directory: root)
        #expect(found.map(\.message) == ["cannot find 'x' in scope", "unused"], "\(found)")
        #expect(found[0].line == 3 && found[0].column == 9 && found[0].severity == .error)
    }

    @Test("rustc's header and its --> line, and tsc's parenthesised ones")
    func rustAndTypeScript() throws {
        let root = try folder()
        let output = """
        error[E0425]: cannot find value `y` in this scope
         --> src/main.rs:7:13
          |
        warning: unused variable: `z`
         --> src/main.rs:9:5
        src/c.ts(2,7): error TS2322: Type 'string' is not assignable to type 'number'.
        """
        let found = Problems.parse(output, directory: root)
        #expect(found.map(\.code) == ["E0425", "", "TS2322"], "\(found)")
        #expect(found[0].line == 7 && found[1].severity == .warning && found[2].path == root + "/src/c.ts")
    }
}
