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

    @Test("one for the repository, at the main worktree, whichever worktree asks; a worktree's own merged in")
    func worktrees() throws {
        let base = (NSTemporaryDirectory() as NSString).appendingPathComponent("sill-wt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: base + "/main/src", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let main = base + "/main"
        _ = git(["init", "-q"], in: main)
        try "x".write(toFile: main + "/src/a.cs", atomically: true, encoding: .utf8)
        _ = git(["add", "-A"], in: main)
        _ = git(["-c", "user.email=a@b", "-c", "user.name=s", "commit", "-qm", "base"], in: main)
        _ = git(["worktree", "add", "-q", base + "/feature"], in: main)
        let realMain = git(["rev-parse", "--show-toplevel"], in: main)
        let feature = git(["rev-parse", "--show-toplevel"], in: base + "/feature")
        // What the feature worktree had of its own, and a basket of the same name in both.
        try FileManager.default.createDirectory(atPath: feature + "/.sill/baskets", withIntermediateDirectories: true)
        try "f".write(toFile: feature + "/.sill/baskets/only-here.basket.md", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: realMain + "/.sill/baskets", withIntermediateDirectories: true)
        try "main".write(toFile: realMain + "/.sill/baskets/both.basket.md", atomically: true, encoding: .utf8)
        try "feature".write(toFile: feature + "/.sill/baskets/both.basket.md", atomically: true, encoding: .utf8)

        #expect(SillFolder.path(for: feature + "/src") == realMain + "/.sill")
        #expect(SillFolder.path(for: main) == realMain + "/.sill")
        #expect(FileManager.default.fileExists(atPath: realMain + "/.sill/baskets/only-here.basket.md"), "merged in")
        #expect(try String(contentsOfFile: realMain + "/.sill/baskets/both.basket.md", encoding: .utf8) == "main")
        #expect(FileManager.default.fileExists(atPath: feature + "/.sill/baskets/both.basket.md"), "not lost")
        #expect(SillFolder.worktreeRoot(for: feature + "/src") == feature)
        #expect(SillFolder.relative(feature + "/src/a.cs", in: main) == "src/a.cs", "another worktree's path")
        #expect(SillFolder.relative(realMain + "/src/a.cs", in: feature) == "src/a.cs")
        #expect(SillFolder.relative("/elsewhere/a.cs", in: feature) == "/elsewhere/a.cs")
        #expect(git(["status", "--porcelain"], in: feature).isEmpty, "the feature worktree's git sees nothing")
    }

    @Test("outside a repository: in the folder itself")
    func outside() throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("sill-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(SillFolder.path(for: root) == root + "/.sill")
    }
}
