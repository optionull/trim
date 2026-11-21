import Foundation
import Testing

/// `runtime/lua/frame/tabs.lua`, run in a headless nvim: which buffers are tabs, what selecting and closing do, and the
/// policy that closes the tabs nobody edited when there are too many.
@Suite("the tabs' feeder")
struct TabsLuaTests {
    private static let runtime = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("runtime").path

    private func check(_ script: String) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("frame-tabs-\(UUID().uuidString).lua")
        let source = """
        vim.opt.runtimepath:prepend('\(Self.runtime)')
        local dir = vim.fn.tempname()
        vim.fn.mkdir(dir, 'p')
        local function open(name)
          local path = dir .. '/' .. name
          vim.fn.writefile({ name }, path)
          vim.cmd('edit ' .. path)
          return vim.api.nvim_get_current_buf()
        end
        local function names(tabs)
          local out = {}
          for _, tab in ipairs(tabs) do out[#out + 1] = vim.fn.fnamemodify(tab.path, ':t') end
          return table.concat(out, ',')
        end

        """ + script + "\nio.stdout:write('PASSED')\n"
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

    @Test("the open files are the tabs, the one shown marked, and what is not a file is not one")
    func list() throws {
        try check("""
        local tabs = require('frame.tabs')
        tabs.start()
        local a = open('a.txt'); local b = open('b.txt')
        vim.cmd('enew')
        vim.cmd('help')
        local list = tabs.list()
        assert(names(list) == 'a.txt,b.txt', 'files only: ' .. names(list))
        vim.cmd('buffer ' .. a)
        list = tabs.list()
        assert(list[1].current and not list[2].current, 'the shown one')
        assert(not list[1].modified and not list[1].edited, 'not edited')
        vim.api.nvim_buf_set_lines(b, 0, -1, false, { 'changed' })
        vim.cmd('buffer ' .. b)
        vim.api.nvim_exec_autocmds('TextChanged', { buffer = b })
        list = tabs.list()
        assert(list[2].modified and list[2].edited, 'edited')
        """)
    }

    @Test("selecting, stepping round, and closing, the one shown giving way to the one used before it")
    func navigate() throws {
        try check("""
        local tabs = require('frame.tabs')
        tabs.start()
        local a = open('a.txt'); local b = open('b.txt'); local c = open('c.txt')
        tabs.select(a)
        assert(vim.api.nvim_get_current_buf() == a, 'select')
        tabs.step(1); assert(vim.api.nvim_get_current_buf() == b, 'next')
        tabs.step(-1); tabs.step(-1); assert(vim.api.nvim_get_current_buf() == c, 'previous goes round')
        tabs.step(1); assert(vim.api.nvim_get_current_buf() == a, 'next goes round')
        tabs.select(c); tabs.select(b)
        tabs.close(b)
        assert(vim.api.nvim_get_current_buf() == c, 'the one used before: ' .. vim.api.nvim_get_current_buf())
        assert(names(tabs.list()) == 'a.txt,c.txt', 'closed: ' .. names(tabs.list()))
        tabs.close(a)
        tabs.close(c)
        assert(#tabs.list() == 0 and vim.api.nvim_get_current_buf() ~= nil, 'the window stays')
        """)
    }

    @Test("a tab with changes is not closed")
    func modified() throws {
        try check("""
        local tabs = require('frame.tabs')
        tabs.start()
        local a = open('a.txt'); local b = open('b.txt')
        vim.api.nvim_buf_set_lines(a, 0, -1, false, { 'changed' })
        tabs.close(a)
        assert(names(tabs.list()) == 'a.txt,b.txt', 'kept: ' .. names(tabs.list()))
        """)
    }

    @Test("past the maximum the tabs nobody edited are closed, the least recently used first, and the edited stay")
    func autoclose() throws {
        try check("""
        local tabs = require('frame.tabs')
        tabs.start()
        tabs.configure({ max = 3, autoclose = true })
        local a = open('a.txt')
        vim.api.nvim_buf_set_lines(a, 0, -1, false, { 'edited' })
        vim.api.nvim_exec_autocmds('TextChanged', { buffer = a })
        vim.cmd('write')
        open('b.txt'); open('c.txt'); open('d.txt')
        assert(names(tabs.list()) == 'a.txt,c.txt,d.txt', 'b went, a was edited: ' .. names(tabs.list()))
        open('e.txt')
        assert(names(tabs.list()) == 'a.txt,d.txt,e.txt', 'c, the least recent: ' .. names(tabs.list()))
        """)
    }

    @Test("a change made in one call, with no event yet, still makes a tab edited")
    func editedWithoutEvents() throws {
        try check("""
        local tabs = require('frame.tabs')
        tabs.start()
        local a = open('a.txt')
        assert(not tabs.list()[1].edited, 'not yet')
        vim.api.nvim_buf_set_lines(a, 0, -1, false, { 'changed' })
        vim.cmd('write')
        assert(tabs.list()[1].edited and not tabs.list()[1].modified, 'edited, then saved')
        """)
    }

    @Test("with autoclose off, or no maximum, nothing is closed")
    func optedOut() throws {
        try check("""
        local tabs = require('frame.tabs')
        tabs.start()
        tabs.configure({ max = 2, autoclose = false })
        open('a.txt'); open('b.txt'); open('c.txt')
        assert(#tabs.list() == 3, 'autoclose off')
        tabs.configure({ max = 0, autoclose = true })
        open('d.txt')
        assert(#tabs.list() == 4, 'no maximum')
        """)
    }
}
