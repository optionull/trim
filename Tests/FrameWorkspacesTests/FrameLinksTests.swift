import Foundation
@testable import FrameWorkspaces
import Testing

@Suite("Links into the app")
struct FrameLinksTests {
    @Test("a link names a file, with a line and a column, or a folder")
    func parse() {
        #expect(FrameLink.parse(URL(string: "frame://open?path=/a/b.cs&line=12&column=3")!) == .file(
            path: "/a/b.cs",
            line: 12,
            column: 3
        ))
        #expect(FrameLink.parse(URL(string: "frame://open?path=/a/b.cs")!) == .file(
            path: "/a/b.cs",
            line: nil,
            column: nil
        ))
        #expect(FrameLink.parse(URL(string: "frame://workspace?path=/a/folder")!) == .workspace(path: "/a/folder"))
        #expect(FrameLink.parse(URL(string: "frame:///a/b.cs?line=7")!) == .file(path: "/a/b.cs", line: 7, column: nil))
        #expect(FrameLink.parse(URL(string: "frame://open?path=/a/b.cs:12:3")!) == .file(
            path: "/a/b.cs",
            line: 12,
            column: 3
        ))
    }

    @Test(
        "a file handed over by the system is a file, a position after it a position; a link that asks nothing is nothing"
    )
    func files() {
        #expect(FrameLink.parse(URL(fileURLWithPath: "/a/b.cs")) == .file(path: "/a/b.cs", line: nil, column: nil))
        #expect(FrameLink.parse(URL(string: "frame://open")!) == nil)
        #expect(FrameLink.parse(URL(string: "frame://open?path=relative.cs")!) == nil)
        #expect(FrameLink.parse(URL(string: "https://example.com/a")!) == nil)
        #expect(FrameLink.parse(URL(string: "frame://elsewhere?path=/a")!) == nil)
    }

    @Test("a file with no window on it is worked in at its repository's root")
    func workspace() throws {
        let root = NSTemporaryDirectory() + "frame-link-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/.git", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/src/deep", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(FrameLink.workspace(for: root + "/src/deep/x.cs") == root)
        let loose = NSTemporaryDirectory() + "frame-link-loose-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: loose, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: loose) }
        #expect(FrameLink.workspace(for: loose + "/x.cs") == loose)
    }
}
