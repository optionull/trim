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

/// `runtime/lua/frame/theme.lua`: the selection colour, from the colour scheme's `Visual`, or the group a config names.
@Suite("the theme's selection colour")
struct ThemeLuaTests {
    private static let runtime = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("runtime").path

    private func check(_ script: String) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("frame-theme-\(UUID().uuidString).lua")
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

    @Test("Visual's background, even when Visual is a link, and the group a config names instead")
    func selection() throws {
        try check("""
        local theme = require('frame.theme')
        vim.api.nvim_set_hl(0, 'Visual', { bg = 0x283457 })
        assert(theme.selection() == 0x283457, 'visual')
        vim.api.nvim_set_hl(0, 'MySelection', { bg = 0x112233 })
        vim.api.nvim_set_hl(0, 'Visual', { link = 'MySelection' })
        assert(theme.selection() == 0x112233, 'through a link')
        vim.api.nvim_set_hl(0, 'PmenuSel', { bg = 0x445566 })
        vim.g.frame_selection_group = 'PmenuSel'
        assert(theme.selection() == 0x445566, 'the named group')
        vim.api.nvim_set_hl(0, 'NoBackground', { fg = 0xFFFFFF })
        vim.g.frame_selection_group = 'NoBackground'
        assert(theme.selection() == nil, 'none when the scheme gives none')
        """)
    }
}

/// `runtime/lua/frame/keys.lua`: each mode on the leader, where nothing is bound, and never over a key of the config's.
@Suite("Frame's default keys")
struct KeysLuaTests {
    private static let runtime = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("runtime").path

    private func check(_ script: String) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("frame-keys-\(UUID().uuidString).lua")
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

    @Test("every mode has a key on the leader, each with a description, and all of them are bound when nothing is")
    func allBound() throws {
        try check("""
        vim.g.mapleader = ','
        local keys = require('frame.keys')
        local what = {}
        for _, key in ipairs(keys.defaults) do
          assert(key[3] and key[3] ~= '', 'a description for ' .. key[1])
          what[key[2]] = true
        end
        for _, plug in ipairs({ 'tree-toggle', 'tree-focus', 'tree-filter', 'workspace', 'tabs-list', 'theme' }) do
          assert(what['<Plug>(frame-' .. plug .. ')'], 'a key for ' .. plug)
        end
        for _, lhs in ipairs({ '<leader>e', '<leader>w', '<leader>t', '<leader>o', '<leader>c' }) do
          local found = false
          for _, key in ipairs(keys.defaults) do if key[1] == lhs then found = true end end
          assert(found, 'one-letter key ' .. lhs)
        end
        local bound = keys.apply()
        assert(#bound == #keys.defaults, 'all bound: ' .. #bound)
        assert(vim.fn.maparg('<leader>w', 'n') ~= '' and vim.fn.maparg('<leader>t', 'n') ~= '')
        """)
    }

    @Test("a key the config has bound is left as it is")
    func leavesYours() throws {
        try check("""
        vim.g.mapleader = ','
        vim.keymap.set('n', '<leader>w', 'ihello<Esc>', { desc = 'mine' })
        local bound = require('frame.keys').apply()
        local map = vim.fn.maparg('<leader>w', 'n', false, true)
        assert(map.desc == 'mine', 'still mine: ' .. vim.inspect(map))
        for _, lhs in ipairs(bound) do assert(lhs ~= '<leader>w', 'not rebound') end
        assert(vim.fn.maparg('<leader>t', 'n') ~= '', 'the others are')
        """)
    }
}
