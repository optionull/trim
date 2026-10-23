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
