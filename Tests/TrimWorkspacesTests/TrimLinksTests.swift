import Foundation
import Testing
@testable import TrimWorkspaces

@Suite("Links into the app")
struct TrimLinksTests {
    @Test("a link names a file, with a line and a column, or a folder")
    func parse() {
        #expect(TrimLink.parse(URL(string: "frame://open?path=/a/b.cs&line=12&column=3")!) == .file(
            path: "/a/b.cs",
            line: 12,
            column: 3
        ))
        #expect(TrimLink.parse(URL(string: "frame://open?path=/a/b.cs")!) == .file(
            path: "/a/b.cs",
            line: nil,
            column: nil
        ))
        #expect(TrimLink.parse(URL(string: "frame://workspace?path=/a/folder")!) == .workspace(path: "/a/folder"))
        #expect(TrimLink.parse(URL(string: "frame:///a/b.cs?line=7")!) == .file(path: "/a/b.cs", line: 7, column: nil))
        #expect(TrimLink.parse(URL(string: "frame://open?path=/a/b.cs:12:3")!) == .file(
            path: "/a/b.cs",
            line: 12,
            column: 3
        ))
    }

    @Test(
        "a file handed over by the system is a file, a position after it a position; a link that asks nothing is nothing"
    )
    func files() {
        #expect(TrimLink.parse(URL(fileURLWithPath: "/a/b.cs")) == .file(path: "/a/b.cs", line: nil, column: nil))
        #expect(TrimLink.parse(URL(string: "frame://open")!) == nil)
        #expect(TrimLink.parse(URL(string: "frame://open?path=relative.cs")!) == nil)
        #expect(TrimLink.parse(URL(string: "https://example.com/a")!) == nil)
        #expect(TrimLink.parse(URL(string: "frame://elsewhere?path=/a")!) == nil)
    }

    @Test("a file with no window on it is worked in at its repository's root")
    func workspace() throws {
        let root = NSTemporaryDirectory() + "trim-link-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/.git", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/src/deep", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(TrimLink.workspace(for: root + "/src/deep/x.cs") == root)
        let loose = NSTemporaryDirectory() + "trim-link-loose-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: loose, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: loose) }
        #expect(TrimLink.workspace(for: loose + "/x.cs") == loose)
    }
}
