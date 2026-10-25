import Foundation
import SillCore
import Testing

@Suite(".sill folder")
struct SillFolderTests {
    func git(_ arguments: [String], in directory: String) -> String {
        Review.git(arguments, in: directory)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    @Test("made at the repository's root, kept out of git once, what .git/sill had moved in")
    func folder() throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("sill-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root + "/src", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        _ = git(["init", "-q"], in: root)
        let real = git(["rev-parse", "--show-toplevel"], in: root)
        try FileManager.default.createDirectory(
            atPath: real + "/.git/sill/reviews/1",
            withIntermediateDirectories: true
        )
        try "old".write(toFile: real + "/.git/sill/reviews/1/review.walk.md", atomically: true, encoding: .utf8)

        let folder = SillFolder.path(for: root + "/src")
        #expect(folder == real + "/.sill")
        #expect(FileManager.default.fileExists(atPath: folder + "/reviews/1/review.walk.md"), "moved from .git/sill")
        #expect(!FileManager.default.fileExists(atPath: real + "/.git/sill"))
        try "x".write(toFile: folder + "/a.basket.md", atomically: true, encoding: .utf8)
        try "y".write(toFile: real + "/src/b.txt", atomically: true, encoding: .utf8)
        #expect(
            git(["status", "--porcelain", "--untracked-files=all"], in: root) == "?? src/b.txt",
            "git sees no .sill"
        )
        _ = SillFolder.path(for: root)
        let exclude = try String(contentsOfFile: real + "/.git/info/exclude", encoding: .utf8)
        #expect(exclude.components(separatedBy: "\n").count(where: { $0 == "/.sill/" }) == 1, "added once")
        #expect(SillFolder.repository(containing: folder + "/reviews/1/review.walk.md") == real)
        #expect(SillFolder.repository(containing: real + "/src/b.txt") == nil)
    }

    @Test("outside a repository: in the folder itself")
    func outside() throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("sill-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(SillFolder.path(for: root) == root + "/.sill")
    }
}
