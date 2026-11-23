import Foundation
import Testing
@testable import TrimTree

@Suite("Diagnostic marks in the tree")
struct DiagnosticMarksTests {
    @Test("a folder takes the worst of what is below it, up to the root and no further")
    func fold() {
        let marks = DiagnosticMarks.fold([
            "/r/a/b/x.cs": .warning, "/r/a/y.cs": .hint, "/r/c/z.cs": .error, "/elsewhere/q.cs": .error,
        ], under: "/r")
        #expect(marks.level(of: "/r/a/b/x.cs") == .warning)
        #expect(marks.level(of: "/r/a/b") == .warning)
        #expect(marks.level(of: "/r/a") == .warning, "the warning beats the hint")
        #expect(marks.level(of: "/r/c") == .error)
        #expect(marks.level(of: "/r") == .error)
        #expect(marks.level(of: "/elsewhere") == nil && marks.level(of: "/elsewhere/q.cs") == nil)
    }

    @Test("order is by badness: error, warning, info, hint")
    func order() {
        #expect(DiagnosticLevel.error > .warning && DiagnosticLevel.warning > .info && DiagnosticLevel.info > .hint)
    }

    @Test("only what changed is drawn again, including what went away")
    func changes() {
        let before = DiagnosticMarks.fold(["/r/a/x": .error, "/r/b/y": .hint], under: "/r")
        let after = DiagnosticMarks.fold(["/r/a/x": .warning, "/r/c/z": .hint], under: "/r")
        #expect(after.changed(from: before) == ["/r/a/x", "/r/a", "/r", "/r/b/y", "/r/b", "/r/c/z", "/r/c"])
        #expect(after.changed(from: after).isEmpty)
    }

    @Test("a tree marks its files and folders, and a folder read later is marked too")
    func tree() throws {
        let root = RealPath.of(NSTemporaryDirectory()) + "/trim-diag-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/src/deep", withIntermediateDirectories: true)
        try "x".write(toFile: root + "/src/deep/a.cs", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let tree = FileTree(root: root)
        let src = try #require(tree.children(of: tree.root).first)
        let changed = tree.apply(.fold([root + "/src/deep/a.cs": .error], under: root))
        #expect(Set(changed.map(\.path)) == [root, root + "/src"], "only the nodes read so far")
        #expect(src.diagnostic == .error && tree.root.diagnostic == .error)
        let deep = try #require(tree.children(of: src).first)
        #expect(deep.diagnostic == .error, "a folder read after the marks arrived")
        #expect(tree.children(of: deep).first?.diagnostic == .error)
        #expect(tree.apply(.none).count == 4)
        #expect(deep.diagnostic == nil)
    }
}
