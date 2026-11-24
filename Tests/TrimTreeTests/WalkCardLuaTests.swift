import Foundation
import Testing

/// `runtime/lua/trim/walkcard.lua`, run in a headless nvim: the cards under a walkthrough's anchors.
@Suite("walkthrough cards")
struct WalkCardLuaTests {
    private static let runtime = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("runtime").path

    private func check(_ script: String) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("trim-card-\(UUID().uuidString).lua")
        let source = "vim.opt.runtimepath:prepend('\(Self.runtime)')\n" + script + "\nio.stdout:write('PASSED')\n"
        try source.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["nvim", "--headless", "-u", "NONE", "-l", file.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(text.contains("PASSED"), "\(text)")
    }

    @Test("every line of a card is exactly as wide as asked, whatever the code: wrapped, tabbed, wide characters")
    func width() throws {
        try check("""
        local card = require('trim.walkcard')
        local item = { kind = 'code', heading = 'Foo.bar', path = '/tmp/x.lua', relative = 'x.lua', from = 1, to = 4,
          badge = 'changed since written', level = 'warn',
          code = 'local a = 1\\n\\tlocal long = "' .. string.rep('x', 150) .. '"\\nlocal 日本語 = "テスト"\\n\\nreturn a' }
        for _, width in ipairs({ 40, 60, 110 }) do
          local lines = card.lines(item, width, true)
          for i, line in ipairs(lines) do
            local w = 0
            for _, chunk in ipairs(line) do w = w + vim.fn.strdisplaywidth(chunk[1]) end
            assert(w == width, ('width %d line %d is %d wide'):format(width, i, w))
          end
        end
        """)
    }

    @Test(
        "a long card opens as a peek (its first rows and how many more), a short one is never cut, and open shows it all"
    )
    func peek() throws {
        try check("""
        local card = require('trim.walkcard')
        local rows = {}
        for i = 1, 20 do rows[#rows + 1] = 'line ' .. i end
        local item = { kind = 'code', heading = 'Big', path = '/tmp/x.txt', from = 1, to = 20, code = table.concat(rows, '\\n') }
        local open, total = card.lines(item, 60, true)
        assert(total == 20 and #open == 22, 'open: ' .. #open)
        local peek = card.lines(item, 60, false)
        assert(#peek == 1 + card.PEEK + 1 + 1, 'peek: ' .. #peek)
        local footer = ''
        for _, chunk in ipairs(peek[#peek - 1]) do footer = footer .. chunk[1] end
        assert(footer:find('16 more lines', 1, true), footer)
        local short = { kind = 'code', heading = 'Small', path = '/tmp/x.txt', from = 1, to = 5, code = 'a\\nb\\nc\\nd\\ne' }
        assert(#card.lines(short, 60, false) == 7, 'five rows are not worth a peek')
        assert(card.OPEN_LIMIT == 14)
        """)
    }

    @Test("a diff's added and removed lines are coloured as such, padded to the card's width")
    func diff() throws {
        try check("""
        local card = require('trim.walkcard')
        local item = { kind = 'diff', heading = 'src/a.lua', text = 'diff --git a/x b/x\\nindex 1..2\\n--- a/x\\n+++ b/x\\n@@ -1 +1 @@\\n-old\\n+new\\n same' }
        local lines = card.lines(item, 50, true)
        local seen = {}
        for _, line in ipairs(lines) do
          for _, chunk in ipairs(line) do
            if chunk[1] == 'old' or chunk[1] == '-old' then seen.del = chunk[2] end
            if chunk[1] == '+new' then seen.add = chunk[2] end
          end
        end
        assert(seen.add == 'TrimCardAdd' and seen.del == 'TrimCardDel', vim.inspect(seen))
        assert(#lines == 1 + 4 + 1, 'header, hunk, -, +, context, footer: ' .. #lines)
        """)
    }
}
