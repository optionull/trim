import Foundation
import SillCore
import Testing

@Suite("file references")
struct FileReferenceTests {
    let files: Set<String> = [
        "/repo/src/Orders/Pricing.cs", "/repo/tools/run.py", "/repo/README.md", "/home/notes.txt",
        "/repo/build/out.log", "/repo/build/README.md",
    ]

    func find(_ line: String, at marker: String, directory: String = "/repo/build") -> FileReference? {
        let column = line.distance(from: line.startIndex, to: line.range(of: marker)!.lowerBound)
        return FileReference.find(in: line, at: column, directory: directory, root: "/repo") { files.contains($0) }
    }

    @Test("the forms agents, compilers and stack traces print")
    func forms() {
        #expect(find("Updated src/Orders/Pricing.cs:42 and more", at: "Pricing") ==
            FileReference(path: "/repo/src/Orders/Pricing.cs", line: 42))
        #expect(find("src/Orders/Pricing.cs:42:7: error CS1002", at: "src") ==
            FileReference(path: "/repo/src/Orders/Pricing.cs", line: 42, column: 7))
        #expect(find("/repo/src/Orders/Pricing.cs(12,5): error CS0103", at: "(12") ==
            FileReference(path: "/repo/src/Orders/Pricing.cs", line: 12, column: 5))
        #expect(find("see `src/Orders/Pricing.cs#L40-L52`.", at: "#L") ==
            FileReference(path: "/repo/src/Orders/Pricing.cs", line: 40))
        #expect(find("   at Orders.Pricing.Total() in /repo/src/Orders/Pricing.cs:line 9", at: "/repo") ==
            FileReference(path: "/repo/src/Orders/Pricing.cs", line: 9))
        #expect(find("  File \"tools/run.py\", line 3, in <module>", at: "run") ==
            FileReference(path: "/repo/tools/run.py", line: 3))
        #expect(find("⏺ Read(README.md)", at: "README", directory: "/repo/src") ==
            FileReference(path: "/repo/README.md"))
        #expect(find("Wrote src/Orders/Pricing.cs:10-20.", at: "Orders") ==
            FileReference(path: "/repo/src/Orders/Pricing.cs", line: 10))
        #expect(find("in ~/notes.txt", at: "notes") == nil, "the home folder here is not /home")
    }

    @Test("relative to the terminal first, then the project; only files that exist; only where clicked")
    func resolving() {
        #expect(find("tail out.log", at: "out") == FileReference(path: "/repo/build/out.log"))
        #expect(find("../README.md:2", at: "READ") == FileReference(path: "/repo/README.md", line: 2))
        #expect(find("README.md:2", at: "READ") == FileReference(path: "/repo/build/README.md", line: 2))
        #expect(find("README.md:2", at: "READ", directory: "/repo/src") == FileReference(
            path: "/repo/README.md",
            line: 2
        ))
        #expect(find("It is in src/Orders/Pricing.cs.", at: "Pricing") ==
            FileReference(path: "/repo/src/Orders/Pricing.cs"))
        #expect(find("src/Orders/Missing.cs:3", at: "Missing") == nil)
        #expect(find("src/Orders/Pricing.cs:4 is slow", at: "slow") == nil)
    }

    @Test("on disk: a file is found, a folder is not")
    func disk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: root + "/src", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "x".write(toFile: root + "/src/a.txt", atomically: true, encoding: .utf8)
        #expect(FileReference.find(in: "src/a.txt:3", at: 0, directory: root, root: root) ==
            FileReference(path: (root as NSString).standardizingPath + "/src/a.txt", line: 3))
        #expect(FileReference.find(in: "src:3", at: 0, directory: root, root: root) == nil, "a folder is not a file")
    }

    @Test("what other apps ask sill to open")
    func urls() throws {
        let url = try #require(URL(string: "sill://open?path=/repo/src/My%20Orders/Pricing.cs&line=42&column=7"))
        #expect(FileReference(url: url) == FileReference(path: "/repo/src/My Orders/Pricing.cs", line: 42, column: 7))
        #expect(FileReference(url: URL(fileURLWithPath: "/repo/a/../README.md")) ==
            FileReference(path: "/repo/README.md"))
        #expect(
            try FileReference(url: #require(URL(string: "sill://open?path=src/Foo.cs&line=1"))) == nil,
            "only absolute paths: there is no folder to be relative to"
        )
        #expect(try FileReference(url: #require(URL(string: "sill://edit?path=/a.cs"))) == nil)
        #expect(try FileReference(url: #require(URL(string: "https://example.com/a.cs"))) == nil)
    }
}
