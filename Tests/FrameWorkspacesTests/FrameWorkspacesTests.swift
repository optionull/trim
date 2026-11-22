import Foundation
import FrameTree
@testable import FrameWorkspaces
import SillAgent
import SillCore
import Testing

@Suite struct FuzzyTests {
    @Test func `finds the characters in order and says where`() {
        let match = Fuzzy.match("sl", in: "sill")
        #expect(match?.positions == [0, 2] || match?.positions == [0, 3])
        #expect(Fuzzy.match("ls", in: "sill") == nil)
        #expect(Fuzzy.match("x", in: "sill") == nil)
    }

    @Test func `ignores case`() {
        #expect(Fuzzy.match("SILL", in: "sill")?.positions == [0, 1, 2, 3])
    }

    @Test func `prefers the start of words and runs`() throws {
        let boundary = try #require(Fuzzy.match("fb", in: "foo-bar"))
        let inside = try #require(Fuzzy.match("fb", in: "foobar-xbox"))
        #expect(boundary.score > inside.score)
        let run = try #require(Fuzzy.match("bar", in: "xbarx"))
        let split = try #require(Fuzzy.match("bar", in: "bxaxr"))
        #expect(run.score > split.score)
    }

    @Test func `an empty query matches everything`() {
        #expect(Fuzzy.match("", in: "anything")?.positions == [])
    }

    @Test func `a longer query than text does not match`() {
        #expect(Fuzzy.match("abcd", in: "abc") == nil)
    }
}

@Suite struct WorkspaceIndexTests {
    let temp: String = {
        let path = RealPath.of(NSTemporaryDirectory()) + "frame-ws-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: path + "/main", withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: path + "/wt-one", withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: path + "/elsewhere", withIntermediateDirectories: true)
        return path
    }()

    var checkouts: [Checkout] {
        [
            Checkout(path: temp + "/main", repository: temp + "/main", isWorktree: false),
            Checkout(path: temp + "/wt-one", repository: temp + "/main", isWorktree: true),
        ]
    }

    func session(
        _ directory: String, title: String, at: TimeInterval = 0, needs: Bool = false, repo: String? = "me/main"
    ) -> HeedSession {
        HeedSession(
            id: UUID().uuidString, title: title, agent: "claude", state: needs ? "asking" : "working",
            needsYou: needs, directory: directory, repo: repo, branch: "feature/x",
            lastActivity: Date(timeIntervalSince1970: at)
        )
    }

    @Test func `a worktree is named by heed's title, else its branch, a main checkout by its repository`() {
        var states: [String: CheckoutState] = [:]
        states[temp + "/main"] = CheckoutState(branch: "main")
        states[temp + "/wt-one"] = CheckoutState(branch: "feature/curb-review")
        let plain = WorkspaceIndex.build(checkouts: checkouts, states: states)
        let main = plain.first { $0.path == temp + "/main" }
        let worktree = plain.first { $0.path == temp + "/wt-one" }
        #expect(main?.primary == "main" && main?.secondary == "main")
        #expect(worktree?.primary == "feature/curb-review" && worktree?.secondary == "main · wt-one")
        let named = WorkspaceIndex.build(
            checkouts: checkouts, states: states, sessions: [session(temp + "/wt-one", title: "Add the blog option")]
        )
        let titled = named.first { $0.path == temp + "/wt-one" }
        #expect(titled?.primary == "Add the blog option")
        #expect(titled?.secondary == "main · feature/curb-review")
    }

    @Test func `every row has its branch at once, from .git, before git is asked`() throws {
        try FileManager.default.createDirectory(atPath: temp + "/main/.git", withIntermediateDirectories: true)
        try "ref: refs/heads/trunk\n".write(toFile: temp + "/main/.git/HEAD", atomically: true, encoding: .utf8)
        let built = WorkspaceIndex.build(checkouts: checkouts)
        let main = built.first { $0.path == temp + "/main" }
        #expect(main?.branch == "trunk" && main?.secondary == "trunk")
    }

    @Test func `a session is found by the real path of its folder`() throws {
        let link = temp + "-link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: temp)
        let built = WorkspaceIndex.build(
            checkouts: checkouts, sessions: [session(link + "/wt-one", title: "Through a link")]
        )
        #expect(built.first { $0.path == temp + "/wt-one" }?.title == "Through a link")
    }

    @Test func `of two sessions in a folder the last active names it`() {
        let built = WorkspaceIndex.build(checkouts: checkouts, sessions: [
            session(temp + "/wt-one", title: "Old", at: 10), session(temp + "/wt-one", title: "New", at: 20),
        ])
        #expect(built.first { $0.path == temp + "/wt-one" }?.title == "New")
    }

    @Test func `a folder heed knows outside the roots is a place to go, a chat is not`() {
        let built = WorkspaceIndex.build(checkouts: checkouts, sessions: [
            session(temp + "/elsewhere", title: "Elsewhere", repo: "me/other"),
            HeedSession(id: "chat", title: "A chat", agent: "claude", state: "done", directory: temp + "/main"),
        ])
        let other = built.first { $0.path == temp + "/elsewhere" }
        #expect(other?.repository == "other" && other?.title == "Elsewhere")
        #expect(built.first { $0.path == temp + "/main" }?.title == nil)
    }

    @Test func `the order is when Frame last opened them, then repository and path; heed and git never move a row`() {
        var states: [String: CheckoutState] = [:]
        var busy = CheckoutState(branch: "x")
        busy.lastCommit = Date(timeIntervalSince1970: 5000)
        states[temp + "/wt-one"] = busy
        let working = session(temp + "/wt-one", title: "t", at: 9000, needs: true)
        // Never opened: by repository, then path, whatever git and heed say.
        var built = WorkspaceIndex.build(checkouts: checkouts, states: states, sessions: [working])
        #expect(built.map(\.path) == [temp + "/main", temp + "/wt-one"])
        // Opened: the last opened first.
        built = WorkspaceIndex.build(
            checkouts: checkouts, states: states, sessions: [working],
            opened: [temp + "/wt-one": Date(timeIntervalSince1970: 10), temp + "/main": Date(timeIntervalSince1970: 20)]
        )
        #expect(built.map(\.path) == [temp + "/main", temp + "/wt-one"])
        built = WorkspaceIndex.build(
            checkouts: checkouts, states: states, sessions: [working],
            opened: [temp + "/wt-one": Date(timeIntervalSince1970: 30), temp + "/main": Date(timeIntervalSince1970: 20)]
        )
        #expect(built.map(\.path) == [temp + "/wt-one", temp + "/main"])
        // One opened comes before any never opened.
        built = WorkspaceIndex.build(checkouts: checkouts, opened: [temp + "/wt-one": Date(timeIntervalSince1970: 1)])
        #expect(built.map(\.path) == [temp + "/wt-one", temp + "/main"])
        #expect(built.first?.openedAt == Date(timeIntervalSince1970: 1))
    }

    @Test func `the order is the same with no metadata and with all of it`() {
        let opened = [temp + "/wt-one": Date(timeIntervalSince1970: 7)]
        var states: [String: CheckoutState] = [:]
        var recent = CheckoutState(branch: "b")
        recent.lastCommit = Date()
        states[temp + "/main"] = recent
        let bare = WorkspaceIndex.build(checkouts: checkouts, opened: opened).map(\.path)
        let full = WorkspaceIndex.build(
            checkouts: checkouts, states: states, sessions: [session(temp + "/main", title: "x", at: 99, needs: true)],
            opened: opened
        ).map(\.path)
        #expect(bare == full)
    }

    @Test func `which have a window and which is the current one`() {
        let built = WorkspaceIndex.build(checkouts: checkouts, open: [temp + "/main"], current: temp + "/wt-one")
        #expect(built.first { $0.path == temp + "/main" }?.isOpen == true)
        #expect(built.first { $0.path == temp + "/wt-one" }?.isOpen == false)
        #expect(built.first { $0.path == temp + "/wt-one" }?.isCurrent == true)
    }
}

@Suite struct WorkspaceSearchTests {
    func workspaces() -> [Workspace] {
        [
            Workspace(path: "/p/sill", repository: "sill"),
            Workspace(path: "/wt/sill/feature-frame", repository: "sill", isWorktree: true, branch: "feature/frame"),
            Workspace(
                path: "/wt/musicbox/feature-x", repository: "musicbox", isWorktree: true, branch: "feature/x",
                title: "Add macOS default output switching"
            ),
        ]
    }

    @Test func `no query is everything in the order given`() {
        #expect(WorkspaceIndex.search("", in: workspaces()).map(\.workspace.path) == workspaces().map(\.path))
    }

    @Test func `finds a worktree by what heed calls it, though its folder says nothing of it`() {
        let found = WorkspaceIndex.search("output sw", in: workspaces())
        #expect(found.map(\.workspace.path) == ["/wt/musicbox/feature-x"])
        #expect(found.first?.primaryHits.isEmpty == false)
    }

    @Test func `every word must be found, wherever it is`() {
        #expect(WorkspaceIndex.search("sill frame", in: workspaces())
            .map(\.workspace.path) == ["/wt/sill/feature-frame"])
        #expect(WorkspaceIndex.search("sill zzz", in: workspaces()).isEmpty)
    }

    @Test func `the better match comes first`() {
        let found = WorkspaceIndex.search("sill", in: workspaces())
        #expect(found.first?.workspace.path == "/p/sill")
    }
}

@Suite("The finder's files")
struct FileIndexTests {
    private func folder(_ files: [String]) throws -> String {
        let root = NSTemporaryDirectory() + "file-index-\(UUID().uuidString)"
        for file in files {
            let path = root + "/" + file
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
            )
            try "needle in \(file)\nsecond line\n".write(toFile: path, atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test("a walk lists the files, not the folders nothing is searched in")
    func walk() async throws {
        let root = try folder(["a.swift", "src/b.swift", "node_modules/x/c.js", ".git/config", "build/d.o"])
        let files = await FileIndex.files(in: root)
        #expect(files == ["a.swift", "src/b.swift"])
    }

    @Test("a repository lists what git lists: tracked and new files, the ignored left out")
    func repository() async throws {
        let root = try folder(["a.swift", "ignored.log", "src/new.swift"])
        try "*.log\n".write(toFile: root + "/.gitignore", atomically: true, encoding: .utf8)
        _ = FileIndex.git(["init", "-q"], in: root)
        let files = await FileIndex.files(in: root)
        #expect(files == [".gitignore", "a.swift", "src/new.swift"])
    }

    @Test(
        "a query ranks the name above the folders, a shorter path above a longer, and finds nothing that is not there"
    )
    func ranking() {
        let files = ["docs/readme-tree.md", "Sources/Tree/TreeView.swift", "Sources/Other/Thing.swift", "tree.swift"]
        let ranked = FileIndex.rank("tree", in: files)
        #expect(ranked.first == "tree.swift")
        #expect(ranked.contains("Sources/Other/Thing.swift") == false)
        #expect(FileIndex.rank("zzz", in: files).isEmpty)
        #expect(FileIndex.rank("", in: files, limit: 2) == ["docs/readme-tree.md", "Sources/Tree/TreeView.swift"])
        #expect(FileIndex.rank("tv", in: files).first == "Sources/Tree/TreeView.swift")
    }

    @Test("grep finds lines as text, by git or by grep, and tells the line")
    func grep() async throws {
        let root = try folder(["a.swift", "src/b.swift"])
        let plain = await FileIndex.grep("NEEDLE in", in: root)
        #expect(Set(plain.map(\.path)) == ["a.swift", "src/b.swift"])
        #expect(plain.allSatisfy { $0.line == 1 })
        _ = FileIndex.git(["init", "-q"], in: root)
        let tracked = await FileIndex.grep("second", in: root)
        #expect(tracked.map(\.line) == [2, 2])
        #expect(await FileIndex.grep("a.b(", in: root).isEmpty, "a query is text, not a pattern")
    }

    @Test("rows of path:line:text parse, a colon in the text stays")
    func parsing() {
        let hits = FileIndex.parse("./a.swift:3:let x: Int\nbroken\nb.swift:10:y\n", limit: 10)
        #expect(hits == [
            FileIndex.Hit(path: "a.swift", line: 3, text: "let x: Int"),
            FileIndex.Hit(path: "b.swift", line: 10, text: "y"),
        ])
    }
}
