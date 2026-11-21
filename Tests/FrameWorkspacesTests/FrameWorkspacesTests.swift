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

    @Test func `those that need you come first, then the latest of git, heed and Frame`() {
        var states: [String: CheckoutState] = [:]
        var older = CheckoutState(branch: "main")
        older.lastCommit = Date(timeIntervalSince1970: 100)
        states[temp + "/main"] = older
        var newer = CheckoutState(branch: "x")
        newer.lastCommit = Date(timeIntervalSince1970: 50)
        states[temp + "/wt-one"] = newer
        // Git says main is the newer; Frame opened wt-one since.
        var built = WorkspaceIndex.build(checkouts: checkouts, states: states)
        #expect(built.map(\.path) == [temp + "/main", temp + "/wt-one"])
        built = WorkspaceIndex.build(
            checkouts: checkouts, states: states, opened: [temp + "/wt-one": Date(timeIntervalSince1970: 200)]
        )
        #expect(built.map(\.path) == [temp + "/wt-one", temp + "/main"])
        built = WorkspaceIndex.build(
            checkouts: checkouts, states: states, sessions: [session(temp + "/wt-one", title: "t", at: 1, needs: true)],
            opened: [temp + "/main": Date(timeIntervalSince1970: 300)]
        )
        #expect(built.first?.path == temp + "/wt-one")
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
