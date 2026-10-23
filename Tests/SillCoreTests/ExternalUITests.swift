import Foundation
@testable import SillCore
import Testing

/// M2 step 1: the command line, messages, completion and tabs come from nvim as events, for sill to draw.
@Suite("nvim's external UI", .serialized)
struct ExternalUITests {
    @Test("the command line: what is typed, where the cursor is, and its end")
    func commandLine() async throws {
        let nvim = try await Harness.start()
        defer { Task { await nvim.stop() } }

        await nvim.keys(":echo 'héllo'")
        var screen = try await nvim.screen("the command line") { $0.commandLine?.text == "echo 'héllo'" }
        let line = try #require(screen.commandLine)
        #expect(line.firstc == ":" && line.level == 1)
        #expect(line.cursorIndex == 12, "after the last character, counted in characters not bytes")
        await nvim.keys("<Left><Left>")
        screen = try await nvim.screen("the cursor moved") { $0.commandLine?.cursorIndex == 10 }
        await nvim.keys("<Esc>")
        screen = try await nvim.screen("the command line gone") { $0.commandLine == nil }
        #expect(screen.messages.isEmpty)

        await nvim.keys("/needle")
        screen = try await nvim.screen("a search") { $0.commandLine?.firstc == "/" }
        #expect(screen.commandLine?.text == "needle")
        await nvim.keys("<Esc>")
    }

    @Test("messages come with their kind; an error is an error")
    func messages() async throws {
        let nvim = try await Harness.start()
        defer { Task { await nvim.stop() } }

        try await nvim.command("echo 'plain message'")
        var screen = try await nvim.screen("an echo") { $0.messages.last?.text == "plain message" }
        #expect(screen.messages.last?.kind == "echo")
        #expect(screen.messages.last?.isError == false)

        await nvim.keys(":call nosuchfunction()<CR>")
        screen = try await nvim.screen("an error") { $0.messages.contains { $0.isError } }
        let error = try #require(screen.messages.first { $0.isError })
        #expect(error.text.contains("E117"), "\(error.text)")
    }

    @Test("a listing is output, and :messages shows the history")
    func listingAndHistory() async throws {
        let nvim = try await Harness.start()
        defer { Task { await nvim.stop() } }

        await nvim.keys(":ls<CR>")
        var screen = try await nvim.screen("the buffer list") { $0.messages.contains { $0.kind == "list_cmd" } }
        #expect(screen.messages.first { $0.kind == "list_cmd" }?.isOutput == true)

        try await nvim.command("echomsg 'remember me'")
        await nvim.keys(":messages<CR>")
        screen = try await nvim.screen("the history") { $0.messageHistory != nil }
        #expect(screen.messageHistory?.contains { $0.text.contains("remember me") } == true)
    }

    @Test("completion: the items, the selection, and where the word starts")
    func completion() async throws {
        let nvim = try await Harness.start()
        defer { Task { await nvim.stop() } }

        try await nvim.command("call setline(1, ['alpha', 'alphabet', 'alpine', ''])")
        await nvim.keys("Gial<C-n>")
        var screen = try await nvim.screen("the popup") { $0.popupMenu != nil }
        let menu = try #require(screen.popupMenu)
        #expect(Set(menu.items.map(\.word)) == ["alpha", "alphabet", "alpine"])
        #expect(menu.selected == 0)
        #expect(menu.row == 3 && menu.col == 0 && menu.grid != 1 && menu.grid != -1)
        await nvim.keys("<C-n>")
        screen = try await nvim.screen("the next item selected") { $0.popupMenu?.selected == 1 }
        await nvim.keys("<Esc>")
        screen = try await nvim.screen("the popup gone") { $0.popupMenu == nil }
    }

    @Test("command-line completion anchors to the command line")
    func wildmenu() async throws {
        let nvim = try await Harness.start()
        defer { Task { await nvim.stop() } }

        await nvim.keys(":colorscheme <Tab>")
        let screen = try await nvim.screen("the wildmenu") { $0.popupMenu?.grid == -1 }
        #expect(screen.popupMenu?.items.contains { $0.word == "default" } == true)
        await nvim.keys("<Esc><Esc>")
    }

    @Test("tabs are sill's to draw")
    func tabs() async throws {
        let nvim = try await Harness.start()
        defer { Task { await nvim.stop() } }

        try await nvim.command("tabnew")
        try await nvim.command("file second")
        let screen = try await nvim.screen("two tabs") { $0.tabs.count == 2 && $0.tabs.last?.name == "second" }
        #expect(screen.currentTab == screen.tabs[1].handle)
    }
}

@Suite("the status bar's facts", .serialized)
struct StatusFactsTests {
    @Test("the cursor position is the current window's, as it moves between windows")
    func position() async throws {
        let nvim = try await Harness.start()
        defer { Task { await nvim.stop() } }
        try await nvim.command("call setline(1, map(range(40), 'v:val'))")
        try await nvim.command("vsplit")
        try await nvim.command("call cursor(30, 1)")
        try await nvim.screen("line 30 in the right window") { $0.cursorPosition?.line == 30 }
        await nvim.keys("<C-w>l")
        try await nvim.screen("line 1 in the other window") { $0.cursorPosition?.line == 1 }
        await nvim.keys("<C-w>h")
        try await nvim.screen("line 30 again") { $0.cursorPosition?.line == 30 }
    }

    @Test("the current buffer: name, file type, modified")
    func buffer() async throws {
        let nvim = try await Harness.start()
        defer { Task { await nvim.stop() } }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sill-status-\(UUID().uuidString).lua")
        try "return 1\n".write(to: file, atomically: true, encoding: .utf8)
        try await nvim.command("edit \(file.path)")
        var screen = try await nvim.screen("the file") { $0.buffer.filetype == "lua" }
        #expect(screen.buffer.name == file.lastPathComponent && !screen.buffer.modified && screen.buffer.kind.isEmpty)
        await nvim.keys("x")
        screen = try await nvim.screen("modified") { $0.buffer.modified }
    }

    @Test("diagnostics reach the screen")
    func diagnostics() async throws {
        let nvim = try await Harness.start()
        defer { Task { await nvim.stop() } }
        _ = try await nvim.session.channel.lua("""
        vim.diagnostic.set(vim.api.nvim_create_namespace('t'), 0, {
          { lnum = 2, col = 1, severity = 1, message = 'broken', source = 'test', code = 'E1' } })
        """)
        let screen = try await nvim.screen("a diagnostic") { !$0.diagnostics.isEmpty }
        let problem = try #require(screen.diagnostics.first)
        #expect(problem.message == "broken" && problem.line == 3 && problem.col == 2 && problem.severity == 1)
        #expect(problem.code == "E1")
    }

    @Test(":SillChrome opens the sidebar on the left and the panel under the editor")
    func chrome() async throws {
        let nvim = try await Harness.start(cols: 120, rows: 40)
        defer { Task { await nvim.stop() } }
        try await nvim.command("SillChrome")
        let screen = try await nvim.screen("the sidebar and the panel") { screen in
            screen.paneRects.contains { $0.kind == "sidebar" } && screen.paneRects.contains { $0.kind == "panel" }
        }
        let sidebar = try #require(screen.paneRects.first { $0.kind == "sidebar" })
        let panel = try #require(screen.paneRects.first { $0.kind == "panel" })
        #expect(sidebar.col == 0 && sidebar.row == 0 && sidebar.width == 32)
        #expect(panel.col == sidebar.width + 1 && panel.row + panel.height >= 39)
        #expect(screen.currentPane == nil, "the editor window is current")
        try await nvim.command("lua require'sill'.toggle('sidebar')")
        try await nvim.screen("the sidebar hidden") { !$0.paneRects.contains { $0.kind == "sidebar" } }
        try await nvim.command("lua require'sill'.focus('sidebar')")
        try await nvim.screen("the sidebar back and current") { $0.currentPaneKind == "sidebar" }
    }
}

@Suite("tabs per split", .serialized)
struct SplitTabsTests {
    private func files(_ names: [String]) throws -> [URL] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sill-tabs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try names.map { name in
            let file = directory.appendingPathComponent(name)
            try "\(name)\n".write(to: file, atomically: true, encoding: .utf8)
            return file
        }
    }

    @Test("files opened in a window are its tabs; a split has its own; closing one shows its neighbour")
    func tabs() async throws {
        let nvim = try await Harness.start(cols: 140, rows: 40)
        defer { Task { await nvim.stop() } }
        let paths = try files(["one.txt", "two.txt", "three.txt"])
        try await nvim.command("SillChrome")
        try await nvim.command("edit \(paths[0].path)")
        try await nvim.command("edit \(paths[1].path)")
        var screen = try await nvim.screen("two tabs") { $0.windowTabs.values.contains { $0.tabs.count == 2 } }
        let left = try #require(screen.windowTabs.values.first { $0.tabs.count == 2 })
        #expect(left.tabs.map(\.name) == ["one.txt", "two.txt"])
        #expect(left.tabs.first { $0.buffer == left.current }?.name == "two.txt")

        try await nvim.command("vsplit \(paths[2].path)")
        screen = try await nvim.screen("a second window with its own tab") { screen in
            screen.windowTabs.values.contains { $0.tabs.map(\.name).contains("three.txt") && $0.win != left.win }
        }
        let right = try #require(screen.windowTabs.values.first { $0.win != left.win })
        #expect(!right.tabs.map(\.name).contains("one.txt"), "the split starts its own tabs: \(right.tabs.map(\.name))")

        let two = try #require(left.tabs.first { $0.name == "two.txt" })
        _ = try await nvim.session.channel.lua(
            "require'sill'.close_tab(...)",
            args: [.int(Int64(left.win)), .int(Int64(two.buffer))]
        )
        screen = try await nvim.screen("two.txt closed in the left window") { screen in
            screen.windowTabs[left.win]?.tabs.map(\.name) == ["one.txt"]
        }
        let one = try #require(screen.windowTabs[left.win]?.tabs.first)
        #expect(screen.windowTabs[left.win]?.current == one.buffer, "the neighbour shows")

        _ = try await nvim.session.channel.lua(
            "require'sill'.close_tab(...)",
            args: [.int(Int64(left.win)), .int(Int64(one.buffer))]
        )
        screen = try await nvim.screen("no tabs left") { $0.windowTabs[left.win]?.tabs.isEmpty == true }
    }
}

@Suite("compare with a ref", .serialized)
struct DiffTests {
    @Test(":SillDiff puts the file's version at HEAD beside it, in diff mode")
    func diff() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sill-diff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func git(_ arguments: String...) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = [
                "-C",
                directory.path,
                "-c",
                "user.email=t@t",
                "-c",
                "user.name=t",
                "-c",
                "commit.gpgsign=false",
            ] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
        }
        let file = directory.appendingPathComponent("a.txt")
        try "old line\n".write(to: file, atomically: true, encoding: .utf8)
        try git("init", "-q")
        try git("add", ".")
        try git("commit", "-q", "-m", "first")
        try "new line\n".write(to: file, atomically: true, encoding: .utf8)

        let nvim = try await Harness.start(cols: 120, rows: 30)
        defer { Task { await nvim.stop() } }
        try await nvim.command("edit \(file.path)")
        try await nvim.command("SillDiff")
        let screen = try await nvim.screen("two windows") { $0.windows.count == 2 }
        let (left, right) = (screen.windows[0], screen.windows[1])
        #expect(screen.grids[left.grid]?.line(0).contains("old line") == true)
        #expect(screen.grids[right.grid]?.line(0).contains("new line") == true)
        let diffOn = try await nvim.session.channel.lua(
            "return vim.tbl_map(function(w) return vim.wo[w].diff end, vim.api.nvim_list_wins())"
        )
        #expect(diffOn.arrayValue?.allSatisfy { $0.boolValue == true } == true)
    }
}
