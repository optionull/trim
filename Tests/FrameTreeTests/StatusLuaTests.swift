import Foundation
import Testing

/// `runtime/lua/frame/status.lua`, run in a headless nvim: what the bar is told, and nvim's own status line, ruler
/// and mode message going away while the bar shows and coming back when it hides.
@Suite("the status bar's feeder")
struct StatusLuaTests {
    private static let runtime = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("runtime").path

    private func check(_ script: String) throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("frame-status-\(UUID().uuidString).lua")
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

    @Test("the facts of the buffer and the cursor")
    func snapshot() throws {
        try check("""
        local status = require('frame.status')
        vim.cmd('enew')
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'one', 'two', 'three' })
        vim.api.nvim_win_set_cursor(0, { 2, 2 })
        vim.bo.filetype = 'lua'
        local s = status.snapshot()
        assert(s.line == 2 and s.col == 3 and s.lines == 3, 'position ' .. vim.inspect(s))
        assert(s.ft == 'lua' and s.modified == true, 'buffer')
        assert(s.errors == 0 and #s.lsp == 0 and s.recording == '', 'nothing else')
        local ns = vim.api.nvim_create_namespace('t')
        vim.diagnostic.set(ns, 0, {
          { lnum = 0, col = 0, message = 'a', severity = vim.diagnostic.severity.ERROR },
          { lnum = 1, col = 0, message = 'b', severity = vim.diagnostic.severity.WARN },
          { lnum = 2, col = 0, message = 'c', severity = vim.diagnostic.severity.WARN },
        })
        s = status.snapshot()
        assert(s.errors == 1 and s.warnings == 2, 'diagnostics ' .. vim.inspect(s))
        """)
    }

    @Test("nvim's own status line is off while the bar shows, put back when a plugin brings it back, and restored")
    func ownStatusLine() throws {
        try check("""
        vim.o.laststatus = 2; vim.o.ruler = true; vim.o.showmode = true
        local status = require('frame.status')
        status.start()
        assert(vim.o.laststatus == 0 and not vim.o.ruler and not vim.o.showmode, 'hidden')
        vim.o.laststatus = 3
        vim.wait(200, function() return vim.o.laststatus == 0 end)
        assert(vim.o.laststatus == 0, 'a plugin turning it back on is put back')
        vim.cmd('FrameStatusline hide')
        assert(vim.o.laststatus == 2 and vim.o.ruler and vim.o.showmode, 'restored')
        vim.o.laststatus = 3
        vim.wait(100)
        assert(vim.o.laststatus == 3, 'left alone while hidden')
        vim.cmd('FrameStatusline show')
        assert(vim.o.laststatus == 0, 'hidden again')
        vim.cmd('FrameStatusline toggle')
        assert(vim.o.laststatus == 3, 'toggled off')
        """)
    }

    @Test("a config that does not want the bar keeps its own status line")
    func optedOut() throws {
        try check("""
        vim.o.laststatus = 2
        vim.g.frame_statusline = false
        require('frame.status').start()
        assert(vim.o.laststatus == 2, 'untouched')
        """)
    }
}
