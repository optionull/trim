import Foundation
import Testing
@testable import TrimTree

/// A folder to read, made from the paths given (a trailing / is a folder), and made a git repository on request.
private struct Fixture {
    let root: String

    init(_ paths: [String], git: Bool = false, ignore: String? = nil) throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("trim-tree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // As the tree sees it: /var and /tmp are links, and git reports the real paths.
        root = RealPath.of(base.path)
        for path in paths {
            let url = URL(fileURLWithPath: root + "/" + path)
            if path.hasSuffix("/") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try "x\n".write(to: url, atomically: true, encoding: .utf8)
            }
        }
        // Before the first commit, so what it names is never tracked.
        if let ignore { try ignore.write(toFile: root + "/.gitignore", atomically: true, encoding: .utf8) }
        if git {
            try run("init", "-q", "-b", "main")
            try run("add", ".")
            try run("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "first", "--allow-empty")
        }
    }

    func run(_ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "git \(arguments.joined(separator: " "))")
    }

    func write(_ path: String, _ text: String = "y\n") throws {
        try text.write(toFile: root + "/" + path, atomically: true, encoding: .utf8)
    }

    func names(_ nodes: [TreeNode]) -> [String] { nodes.map(\.name) }
}

@Suite("the file tree")
struct FileTreeTests {
    @Test("folders first, then files, each in the order Finder sorts names; git's own folder is left out")
    func order() throws {
        let fixture = try Fixture([
            "b.txt",
            "a.txt",
            "file10.txt",
            "file2.txt",
            "Zed/",
            "alpha/",
            ".hidden",
            ".git/config",
        ])
        let tree = FileTree(root: fixture.root)
        #expect(fixture.names(tree.children(of: tree.root)) == [
            "alpha", "Zed", ".hidden", "a.txt", "b.txt", "file2.txt", "file10.txt",
        ])
    }

    @Test("a folder is read when it is asked for, not before")
    func lazy() throws {
        let fixture = try Fixture(["src/deep/a.swift"])
        let tree = FileTree(root: fixture.root)
        #expect(tree.root.children == nil)
        let src = try #require(tree.children(of: tree.root).first)
        #expect(src.children == nil)
        #expect(fixture.names(tree.children(of: src)) == ["deep"])
        #expect(tree.node(at: fixture.root + "/src/deep") != nil)
        #expect(tree.node(at: fixture.root + "/src/deep/a.swift") == nil)
    }

    @Test("a node keeps its identity when the folder is read again, and a removed one is forgotten")
    func reloading() throws {
        let fixture = try Fixture(["keep.txt", "gone.txt", "dir/inner.txt"])
        let tree = FileTree(root: fixture.root)
        let before = tree.children(of: tree.root)
        let keep = try #require(before.first { $0.name == "keep.txt" })
        let dir = try #require(before.first { $0.name == "dir" })
        let inner = try #require(tree.children(of: dir).first)
        try FileManager.default.removeItem(atPath: fixture.root + "/gone.txt")
        try fixture.write("new.txt")
        let after = tree.reload(tree.root)
        #expect(fixture.names(after) == ["dir", "keep.txt", "new.txt"])
        #expect(after.contains { $0 === keep } && after.contains { $0 === dir })
        #expect(tree.node(at: fixture.root + "/gone.txt") == nil)
        try FileManager.default.removeItem(atPath: fixture.root + "/dir")
        _ = tree.reload(tree.root)
        #expect(tree.node(at: fixture.root + "/dir") == nil)
        #expect(tree.node(at: inner.path) == nil, "what was below a removed folder goes with it")
    }

    @Test("a file replaced by a folder of the same name is a new node")
    func replaced() throws {
        let fixture = try Fixture(["thing"])
        let tree = FileTree(root: fixture.root)
        let file = try #require(tree.children(of: tree.root).first)
        #expect(!file.isDirectory)
        try FileManager.default.removeItem(atPath: fixture.root + "/thing")
        try FileManager.default.createDirectory(atPath: fixture.root + "/thing", withIntermediateDirectories: true)
        let now = try #require(tree.reload(tree.root).first)
        #expect(now.isDirectory && now !== file)
    }

    @Test("a folder given by a link is the real one: paths from nvim and git, which follow links, find it")
    func links() throws {
        let fixture = try Fixture(["real/a/b.txt"])
        try FileManager.default.createSymbolicLink(
            atPath: fixture.root + "/link",
            withDestinationPath: fixture.root + "/real"
        )
        let tree = FileTree(root: fixture.root + "/link")
        #expect(tree.root.path == fixture.root + "/real")
        #expect(tree.reveal(fixture.root + "/link/a/b.txt").node?.name == "b.txt")
        #expect(tree.reveal(fixture.root + "/real/a/b.txt").node?.name == "b.txt")
        // The system's temporary folder is itself under a link.
        let temporary = RealPath.of(NSTemporaryDirectory())
        #expect(temporary.hasPrefix("/private/var/"), "\(temporary)")
        #expect(FileTree(root: NSTemporaryDirectory()).root
            .path == (temporary.hasSuffix("/") ? String(temporary.dropLast()) : temporary))
    }

    @Test("reveal reads the way down to a path and returns the folders to open and the node")
    func reveal() throws {
        let fixture = try Fixture(["a/b/c.txt", "a/other.txt", "z.txt"])
        let tree = FileTree(root: fixture.root)
        let found = tree.reveal(fixture.root + "/a/b/c.txt")
        #expect(fixture.names(found.folders) == [(fixture.root as NSString).lastPathComponent, "a", "b"])
        #expect(found.node?.name == "c.txt")
        #expect(tree.reveal(fixture.root + "/a/missing.txt").node == nil)
        #expect(tree.reveal("/somewhere/else.txt").node == nil)
        #expect(tree.reveal(fixture.root + "/z.txt/under").node == nil)
    }
}

@Suite("git in the tree")
struct GitTreeTests {
    @Test("the two letters git starts a line with become a status")
    func porcelain() {
        #expect(GitState.Status(porcelain: "??") == .untracked)
        #expect(GitState.Status(porcelain: " M") == .modified)
        #expect(GitState.Status(porcelain: "M ") == .modified)
        #expect(GitState.Status(porcelain: "MM") == .modified)
        #expect(GitState.Status(porcelain: "A ") == .added)
        #expect(GitState.Status(porcelain: " D") == .deleted)
        #expect(GitState.Status(porcelain: "R ") == .renamed)
        #expect(GitState.Status(porcelain: "UU") == .conflicted)
        #expect(GitState.Status(porcelain: "AA") == .conflicted)
        #expect(GitState.Status(porcelain: "  ") == nil)
        #expect(GitState.Status(porcelain: "M") == nil)
    }

    @Test("a repository's branch, changed files and ignored paths, as absolute paths")
    func reads() throws {
        let fixture = try Fixture(["tracked.txt", "src/code.swift", ".gitignore"], git: true)
        try fixture.write(".gitignore", "build/\n*.log\n")
        try fixture.write("src/code.swift", "changed\n")
        try fixture.write("fresh.txt")
        try fixture.write("debug.log")
        try FileManager.default.createDirectory(atPath: fixture.root + "/build", withIntermediateDirectories: true)
        try fixture.write("build/out.o")
        let state = GitState.read(in: fixture.root)
        #expect(state.branch == "main")
        #expect(state.status[fixture.root + "/src/code.swift"] == .modified)
        #expect(state.status[fixture.root + "/fresh.txt"] == .untracked)
        #expect(state.status[fixture.root + "/tracked.txt"] == nil)
        #expect(state.ignored.contains(fixture.root + "/build"))
        #expect(state.ignored.contains(fixture.root + "/debug.log"))
    }

    @Test("ignored files and dotfiles are shown or hidden on request, in the folders already read")
    func visibility() throws {
        let fixture = try Fixture(["src/a.swift", "src/.hidden", ".env", "top.txt", ".gitignore"], git: true)
        try fixture.write(".gitignore", "build/\nsrc/skip.log\n")
        try FileManager.default.createDirectory(atPath: fixture.root + "/build", withIntermediateDirectories: true)
        try fixture.write("build/out.o")
        try fixture.write("src/skip.log")
        let tree = FileTree(root: fixture.root)
        tree.apply(GitState.read(in: fixture.root))
        let src = try #require(tree.children(of: tree.root).first { $0.name == "src" })
        #expect(fixture.names(tree.children(of: src)) == ["a.swift", ".hidden"]
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        #expect(fixture.names(tree.children(of: tree.root)) == ["src", ".env", ".gitignore", "top.txt"])
        #expect(tree.showDotfiles && !tree.showIgnored)

        let hidden = tree.setVisibility(dotfiles: false)
        #expect(hidden.contains(tree.root) && hidden.contains(src))
        #expect(fixture.names(tree.children(of: tree.root)) == ["src", "top.txt"])
        #expect(fixture.names(tree.children(of: src)) == ["a.swift"])

        let ignored = tree.setVisibility(ignored: true)
        #expect(ignored.contains(tree.root) && ignored.contains(src))
        #expect(
            fixture.names(tree.children(of: tree.root)) == ["build", "src", "top.txt"],
            "ignored shown, dotfiles still hidden"
        )
        #expect(tree.children(of: tree.root).first { $0.name == "build" }?.ignored == true)
        #expect(fixture.names(tree.children(of: src)) == ["a.swift", "skip.log"])

        tree.setVisibility(ignored: false, dotfiles: true)
        #expect(fixture.names(tree.children(of: tree.root)) == ["src", ".env", ".gitignore", "top.txt"])
        #expect(tree.setVisibility(dotfiles: true).isEmpty, "nothing changed, nothing to show again")
    }

    @Test("a folder that is not in a repository has nothing to report")
    func notARepository() throws {
        let fixture = try Fixture(["a.txt"])
        #expect(GitState.read(in: fixture.root) == GitState())
    }

    @Test("a subfolder of a repository reports the repository's changes by absolute path")
    func subfolder() throws {
        let fixture = try Fixture(["pkg/a.txt", "other/b.txt"], git: true)
        try fixture.write("pkg/a.txt", "changed\n")
        let state = GitState.read(in: fixture.root + "/pkg")
        #expect(state.status[fixture.root + "/pkg/a.txt"] == .modified)
    }

    @Test("files are marked, folders know of a change below them, and ignored ones are left out unless shown")
    func applied() throws {
        let fixture = try Fixture(["src/deep/a.swift", "src/b.swift", "docs/readme.md", ".gitignore"], git: true)
        try fixture.write(".gitignore", "build/\n")
        try fixture.write("src/deep/a.swift", "changed\n")
        try FileManager.default.createDirectory(atPath: fixture.root + "/build", withIntermediateDirectories: true)
        try fixture.write("build/out.o")
        let tree = FileTree(root: fixture.root)
        let top = tree.children(of: tree.root)
        #expect(top.map(\.name).contains("build"), "ignored until git has been read")
        tree.apply(GitState.read(in: fixture.root))
        #expect(!tree.children(of: tree.root).map(\.name).contains("build"))
        let src = try #require(tree.children(of: tree.root).first { $0.name == "src" })
        let docs = try #require(tree.children(of: tree.root).first { $0.name == "docs" })
        let deep = try #require(tree.children(of: src).first { $0.name == "deep" })
        let file = try #require(tree.children(of: deep).first)
        #expect(file.status == .modified)
        #expect(deep.changedBelow && src.changedBelow && tree.root.changedBelow)
        #expect(!docs.changedBelow)
        let affected = tree.setVisibility(ignored: true)
        #expect(affected.contains(tree.root))
        tree.apply(GitState.read(in: fixture.root))
        let build = try #require(tree.children(of: tree.root).first { $0.name == "build" })
        #expect(build.ignored)
        let out = try #require(tree.children(of: build).first)
        #expect(out.ignored, "what is in an ignored folder is ignored too")
    }
}

@Suite("file icons")
struct FileIconTests {
    @Test("folders open and closed, by extension without regard to case, by name, and a plain file otherwise")
    func icons() {
        #expect(FileIcons.icon(name: "src", isDirectory: true) == FileIcons.folder)
        #expect(FileIcons.icon(name: "src", isDirectory: true, expanded: true) == FileIcons.folderOpen)
        #expect(FileIcons.folder != FileIcons.folderOpen)
        let cs = FileIcons.icon(name: "Order.cs", isDirectory: false)
        #expect(cs.tint == .dotnet)
        #expect(FileIcons.icon(name: "ORDER.CS", isDirectory: false) == cs)
        #expect(FileIcons.icon(name: "Order.fs", isDirectory: false) != cs)
        #expect(FileIcons.icon(name: "Dockerfile", isDirectory: false).tint == .data)
        #expect(FileIcons.icon(name: "app.csproj", isDirectory: false).tint == .project)
        #expect(FileIcons.icon(name: "mystery.qqq", isDirectory: false) == FileIcons.file)
        #expect(FileIcons.icon(name: "noextension", isDirectory: false) == FileIcons.file)
    }

    @Test("every glyph is a private-use character of the Nerd Font, none empty")
    func glyphs() {
        for icon in FileIcons.all {
            let value = icon.glyph.unicodeScalars.first!.value
            #expect((0xE000 ... 0xF8FF).contains(value) || (0xF0000 ... 0xFFFFD).contains(value), "\(value)")
        }
    }
}

@Suite("the sidebar's colours")
struct TreePaletteTests {
    @Test("a dark editor gets a sidebar of its own hue, a shade darker")
    func dark() {
        let palette = TreePalette(background: 0x1A1B26, foreground: 0xC0CAF5)
        #expect(palette.isDark)
        #expect(palette.sidebar == 0x13131B) // each channel 72% of the editor's (0x1A, 0x1B, 0x26)
        #expect(TreePalette.luminance(palette.sidebar) < TreePalette.luminance(0x1A1B26))
        // The hue is kept: blue stays the strongest channel and the channels keep their order.
        let red = (palette.sidebar >> 16) & 0xFF, green = (palette.sidebar >> 8) & 0xFF, blue = palette.sidebar & 0xFF
        #expect(blue > green && green >= red)
    }

    @Test("a light editor gets a sidebar only a little darker")
    func light() {
        let palette = TreePalette(background: 0xFFFFFF, foreground: 0x333333)
        #expect(!palette.isDark)
        #expect(palette.sidebar == 0xF2F2F2)
        #expect(TreePalette(background: 0xFAF4ED, foreground: 0x575279).sidebar < 0xFAF4ED)
    }

    @Test("the quieter text is the foreground fading into the background, the fainter one nearer it")
    func fading() {
        let palette = TreePalette(background: 0x000000, foreground: 0xFFFFFF)
        #expect(palette.muted == 0x8C8C8C)
        #expect(palette.faint == 0x595959)
        #expect(TreePalette.luminance(palette.faint) < TreePalette.luminance(palette.muted), "nearer the background")
        #expect(TreePalette.mix(0x102030, 0xF0E0D0, 0) == 0x102030)
        #expect(TreePalette.mix(0x102030, 0xF0E0D0, 1) == 0xF0E0D0)
        #expect(TreePalette.mix(0x000000, 0xFFFFFF, 2) == 0xFFFFFF, "kept within a colour")
    }

    @Test("the same editor colours give the same palette, and another background another one")
    func equality() {
        #expect(TreePalette(background: 1, foreground: 2) == TreePalette(background: 1, foreground: 2))
        #expect(TreePalette(background: 1, foreground: 2) != TreePalette(background: 3, foreground: 2))
    }
}

@Suite("filtering the tree")
struct TreeFilterTests {
    private func fixture() throws -> Fixture {
        try Fixture([
            "src/Orders/Order.cs", "src/Orders/Total.cs", "src/Util.swift", "docs/guide.md", "docs/orders.md",
            ".hidden/Order.txt", "build/order.o", "README.md",
        ], git: true, ignore: "build/\n")
    }

    private func scan(
        _ fixture: Fixture, _ text: String, dotfiles: Bool = true, ignored: Bool = false, limit: Int = 50000
    ) -> FilterResult {
        FileTree.scan(
            root: fixture.root, text: text, showDotfiles: dotfiles, showIgnored: ignored,
            ignored: GitState.read(in: fixture.root).ignored, limit: limit
        )
    }

    @Test("the files whose path holds the text, without regard to case, and the folders above them")
    func scans() throws {
        let fixture = try fixture()
        let root = fixture.root
        let found = scan(fixture, "ORDER")
        #expect(found.paths == [
            root, root + "/src", root + "/src/Orders", root + "/src/Orders/Order.cs", root + "/src/Orders/Total.cs",
            root + "/docs", root + "/docs/orders.md", root + "/.hidden", root + "/.hidden/Order.txt",
        ], "a folder's name counts, so everything in src/Orders is there; build/ is ignored")
        #expect(!found.truncated)
        #expect(scan(fixture, "").paths.isEmpty)
        #expect(scan(fixture, "nothing like this").paths.isEmpty)
        #expect(scan(fixture, "guide").paths == [root, root + "/docs", root + "/docs/guide.md"])
    }

    @Test("what the tree leaves out is not walked: dotfiles and ignored files, as asked")
    func skipping() throws {
        let fixture = try fixture()
        let root = fixture.root
        #expect(!scan(fixture, "order", dotfiles: false).paths.contains(root + "/.hidden/Order.txt"))
        #expect(scan(fixture, "order", dotfiles: true).paths.contains(root + "/.hidden/Order.txt"))
        #expect(!scan(fixture, "order").paths.contains(root + "/build/order.o"))
        #expect(scan(fixture, "order", ignored: true).paths.contains(root + "/build/order.o"))
        #expect(!scan(fixture, "config").paths.contains { $0.contains("/.git/") }, "git's own folder is never walked")
    }

    @Test("a walk that reaches its limit says so")
    func limit() throws {
        let fixture = try fixture()
        let found = scan(fixture, "order", limit: 3)
        #expect(found.truncated)
        #expect(!scan(fixture, "order").truncated)
    }

    @Test("a filtered tree lists only what was found, opens the way to it, and shows everything again when cleared")
    func filtered() throws {
        let fixture = try fixture()
        let root = fixture.root
        let tree = FileTree(root: root)
        tree.apply(GitState.read(in: root))
        let everything = fixture.names(tree.children(of: tree.root))
        let result = scan(fixture, "total")
        let affected = tree.setFilter("total", result: result)
        #expect(affected.contains(tree.root))
        #expect(fixture.names(tree.children(of: tree.root)) == ["src"])
        #expect(tree.filter == "total")
        let open = tree.foldersToExpand()
        #expect(fixture.names(open) == ["src", "Orders"], "the way down to the match")
        #expect(fixture.names(tree.children(of: open[1])) == ["Total.cs"])
        tree.setFilter("", result: nil)
        #expect(fixture.names(tree.children(of: tree.root)) == everything)
        #expect(tree.foldersToExpand().isEmpty)
        // A filter with no result at all shows everything too: nothing was found out, so nothing is hidden.
        tree.setFilter("total", result: nil)
        #expect(fixture.names(tree.children(of: tree.root)) == everything)
    }
}

@Suite struct GitHeadTests {
    func folder() -> String {
        let path = RealPath.of(NSTemporaryDirectory()) + "trim-head-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    func write(_ text: String, _ path: String) {
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    @Test func `a repository's branch from HEAD`() {
        let repo = folder() + "/proj"
        write("ref: refs/heads/feature/x\n", repo + "/.git/HEAD")
        let info = GitHead.info(at: repo)
        #expect(info?.branch == "feature/x")
        #expect(info?.root == repo && info?.rootName == "proj" && info?.isWorktree == false)
    }

    @Test func `a detached HEAD is the start of the commit`() {
        let repo = folder() + "/proj"
        write("0123456789abcdef0123456789abcdef01234567\n", repo + "/.git/HEAD")
        #expect(GitHead.info(at: repo)?.branch == "01234567")
    }

    @Test func `a worktree knows its own branch and the repository it belongs to`() {
        let base = folder()
        let repo = base + "/main-checkout", worktree = base + "/wt/something-else"
        write("ref: refs/heads/main\n", repo + "/.git/HEAD")
        write("ref: refs/heads/feature/blog\n", repo + "/.git/worktrees/blog/HEAD")
        write("../..\n", repo + "/.git/worktrees/blog/commondir")
        write("gitdir: \(repo)/.git/worktrees/blog\n", worktree + "/.git")
        let info = GitHead.info(at: worktree)
        #expect(info?.branch == "feature/blog")
        #expect(info?.root == repo && info?.rootName == "main-checkout" && info?.isWorktree == true)
    }

    @Test func `a folder inside a repository finds it above`() {
        let repo = folder() + "/proj"
        write("ref: refs/heads/main\n", repo + "/.git/HEAD")
        try? FileManager.default.createDirectory(atPath: repo + "/src/deep", withIntermediateDirectories: true)
        let info = GitHead.info(at: repo + "/src/deep")
        #expect(info?.checkout == repo && info?.branch == "main")
    }

    @Test func `outside a repository there is nothing`() {
        #expect(GitHead.info(at: folder(), levels: 0) == nil)
    }
}

@Suite struct TreeSelectionColourTests {
    @Test func `the colour scheme's selection colour is the selection, and its quieter form is between it and the sidebar`(
    ) {
        let palette = TreePalette(background: 0x1A1B26, foreground: 0xC0CAF5, selection: 0x283457)
        #expect(palette.selection == 0x283457)
        #expect(palette.selectionDim == TreePalette.mix(palette.sidebar, 0x283457, 0.55))
        #expect(palette.selectionDim != palette.selection)
    }

    @Test func `without one the selection is the foreground faintly over the background`() {
        let palette = TreePalette(background: 0x000000, foreground: 0xFFFFFF)
        #expect(palette.selection == TreePalette.mix(0x000000, 0xFFFFFF, 0.2))
    }

    @Test func `a different selection colour is a different palette`() {
        #expect(TreePalette(background: 1, foreground: 2, selection: 3) != TreePalette(
            background: 1,
            foreground: 2,
            selection: 4
        ))
    }
}
