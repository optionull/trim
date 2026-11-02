import Foundation
import SillCore
import Testing

@Suite struct LookedTests {
    func folder() throws -> String {
        let folder = NSTemporaryDirectory() + "sill-looked-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func aRealAbsenceMovesThePointAGlanceDoesNot() throws {
        let sill = try folder(), start = Date(timeIntervalSince1970: 1_000_000)
        #expect(Looked.returned(sill, checkout: "/w") == nil)
        Looked.left(sill, checkout: "/w", tree: "t1", at: start)
        // Back after ten minutes: what is new is since t1.
        #expect(Looked.returned(sill, checkout: "/w", now: start + 600) == .init(at: start, tree: "t1"))
        // Away a minute: still since t1.
        Looked.left(sill, checkout: "/w", tree: "t2", at: start + 700)
        #expect(Looked.returned(sill, checkout: "/w", now: start + 760)?.tree == "t1")
        #expect(Looked.point(sill, checkout: "/w")?.tree == "t1" && Looked.point(sill, checkout: "/other") == nil)
        // Away an hour: since t3.
        Looked.left(sill, checkout: "/w", tree: "t3", at: start + 800)
        #expect(Looked.returned(sill, checkout: "/w", now: start + 4400)?.tree == "t3")
    }

    @Test func seenFilesKeepTheirContent() throws {
        let root = try folder()
        let git = { (arguments: [String]) in _ = Review.git(arguments, in: root) }
        git(["init", "-q"])
        try "a".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: root + "/src/x", withIntermediateDirectories: true)
        try "b".write(toFile: root + "/src/x/b.txt", atomically: true, encoding: .utf8)
        let tree = try #require(Review.snapshot(in: root))
        let contents = SeenFiles.contents(of: ["a.txt", "src/x/b.txt", "gone.txt"], in: tree, directory: root)
        #expect(contents["gone.txt"] == SeenFiles.deleted && contents["a.txt"]?.count == 40)
        #expect(contents["a.txt"] != contents["src/x/b.txt"])
        let sill = try folder()
        SeenFiles.mark(["a.txt": contents["a.txt"], "src/x/b.txt": contents["src/x/b.txt"]], in: sill, checkout: root)
        SeenFiles.mark(["src/x/b.txt": nil], in: sill, checkout: root)
        #expect(SeenFiles.read(sill, checkout: root) == ["a.txt": contents["a.txt"]!])
    }

    @Test func areasMostChangedFirst() {
        let files: [Review.File] = [
            .init(path: "README.md", status: .modified, added: 1, removed: 0),
            .init(path: "src/Shop/Tax.cs", status: .modified, added: 3, removed: 1),
            .init(path: "src/Shop/Api/Cart.cs", status: .added, added: 9, removed: 0),
            .init(path: "tests/Shop.Tests/TaxTests.cs", status: .modified, added: 2, removed: 0),
        ]
        let areas = Review.byArea(files)
        #expect(areas.map(\.area) == ["src/Shop/", "tests/Shop.Tests/", "(the root)"])
        #expect(areas[0].files.map(\.path) == ["src/Shop/Api/Cart.cs", "src/Shop/Tax.cs"])
    }
}
