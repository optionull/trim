import Foundation
import Testing

/// `runtime/lua/frame/base.lua` and `init.lua`, run in a headless nvim: Frame's defaults, what its settings file
/// changes,
/// the plugins it carries, and a colour scheme the person chose being left alone.
@Suite("Frame's base config")
struct FrameBaseLuaTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private func check(settings: String = "{}", _ script: String) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("frame-base-\(UUID().uuidString).lua")
        let source = """
        vim.g.frame_settings = vim.json.decode([==[\(settings)]==])
        vim.opt.runtimepath:prepend('\(Self.root.appendingPathComponent("runtime").path)')
        require('sill.base')
        require('frame.base')

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

    private var hasPlugins: Bool {
        FileManager.default.fileExists(atPath: Self.root.appendingPathComponent("Vendor/plugins/tokyonight.nvim").path)
    }

    @Test("an editor's defaults, and the leader nvim's own unless the settings say another")
    func defaults() throws {
        try check("""
        assert(vim.g.frame == true and vim.g.mapleader == '\\\\', 'leader ' .. tostring(vim.g.mapleader))
        assert(vim.o.expandtab and vim.o.shiftwidth == 4 and vim.o.tabstop == 4, 'indent')
        assert(vim.o.clipboard == 'unnamedplus', 'clipboard')
        assert(vim.o.smoothscroll and vim.o.timeoutlen == 400 and not vim.o.wrap, 'scrolling and keys')
        """)
    }

    @Test("the leader from the settings file")
    func leader() throws {
        try check(settings: #"{"editor":{"leader":" "}}"#, """
        assert(vim.g.mapleader == ' ', 'leader ' .. tostring(vim.g.mapleader))
        """)
    }

    @Test("the bundled schemes are found, a plugin the settings disable is not, and tokyonight is the default")
    func plugins() throws {
        guard hasPlugins else { return }
        try check("""
        assert(#vim.api.nvim_get_runtime_file('colors/tokyonight-night.lua', true) == 1, 'tokyonight is there')
        assert(#vim.api.nvim_get_runtime_file('colors/catppuccin-mocha.lua', true) == 1, 'catppuccin is there')
        require('frame.init').setup()
        assert(vim.g.colors_name == 'tokyonight-night', 'default scheme ' .. tostring(vim.g.colors_name))
        """)
        try check(settings: #"{"plugins":{"disabled":["catppuccin"]},"theme":{"colorscheme":"rose-pine"}}"#, """
        assert(#vim.api.nvim_get_runtime_file('colors/catppuccin-mocha.lua', true) == 0, 'catppuccin is left out')
        require('frame.init').setup()
        assert(vim.g.colors_name == 'rose-pine', 'the settings scheme ' .. tostring(vim.g.colors_name))
        """)
    }

    @Test("a scheme the person's own config chose stays")
    func theirs() throws {
        guard hasPlugins else { return }
        try check("""
        vim.cmd.colorscheme('catppuccin-mocha')
        require('frame.init').setup()
        assert(vim.g.colors_name == 'catppuccin-mocha', 'theirs stays: ' .. tostring(vim.g.colors_name))
        """)
    }

    @Test("a scheme with variants is put back exactly: its name alone would not, as it remembers the last variant")
    func restore() throws {
        guard hasPlugins else { return }
        try check(settings: #"{"theme":{"colorscheme":"rose-pine"}}"#, """
        require('frame.init').setup()
        local function normal() return vim.api.nvim_get_hl(0, { name = 'Normal' }).bg end
        local original = normal()
        local theme = require('frame.theme')
        theme.snapshot()
        vim.cmd.colorscheme('rose-pine-dawn')
        assert(normal() ~= original, 'the variant looks different')
        vim.cmd.colorscheme('rose-pine')
        assert(normal() ~= original, 'the family name alone keeps the last variant (why a snapshot is needed)')
        theme.restore()
        assert(normal() == original, 'put back exactly')
        assert(vim.g.colors_name == 'rose-pine' and vim.o.background == 'dark', 'name and background too')
        """)
    }

    @Test("the bundled plugins start, and one named in plugins.disabled does not")
    func bundledPlugins() throws {
        guard hasPlugins else { return }
        try check(settings: #"{"plugins":{"disabled":["gitsigns.nvim"]}}"#, """
        require('frame.init').setup()
        assert(package.loaded['which-key'], 'which-key starts')
        assert(package.loaded['mini.pairs'], 'mini starts')
        assert(not package.loaded['gitsigns'], 'a disabled plugin stays off')
        """)
    }

    @Test(
        "a language server that dies is started again, waits longer each time, is given up on, and restart revives it"
    )
    func supervisor() throws {
        try check(settings: "{}", #"""
        local lsp = require('frame.lsp')
        lsp.wait_first, lsp.wait_max = 30, 200
        local dir = vim.fn.tempname(); vim.fn.mkdir(dir, 'p')
        local log = dir .. '/starts'
        lsp.specs.crashy = { filetypes = { 'crashy' }, root = { '.git' }, aliases = {} }
        lsp.specs.polite = { filetypes = { 'polite' }, root = { '.git' }, aliases = {} }
        local function starts(file) local f = io.open(file) if not f then return 0 end local n = #f:read('*a') f:close() return n end
        local function open(ft) vim.cmd('enew') vim.bo.filetype = ft return vim.api.nvim_get_current_buf() end
        -- Dies at once, each time it is started.
        lsp.commands.crashy = { 'sh', '-c', 'printf s >> ' .. log .. '; exit 3' }
        local buf = open('crashy')
        lsp.start('crashy', buf)
        assert(vim.wait(5000, function() return lsp.state.crashy.status == 'failed' end, 20), 'given up on: ' .. lsp.state.crashy.status)
        assert(starts(log) == lsp.max_deaths, 'started ' .. starts(log) .. ' times, wanted ' .. lsp.max_deaths)
        assert(lsp.state.crashy.wait >= 120, 'the wait grew: ' .. lsp.state.crashy.wait)
        local before = starts(log)
        vim.wait(400)
        assert(starts(log) == before, 'a server given up on stays down')
        -- restart: the count forgotten, started again.
        lsp.restart('crashy')
        assert(vim.wait(5000, function() return starts(log) > before end, 20), 'restart starts it again')
        assert(vim.wait(5000, function() return lsp.state.crashy.status == 'failed' end, 20), 'and it dies again')
        -- A server that ends cleanly is not started again.
        local quiet = dir .. '/quiet'
        lsp.commands.polite = { 'sh', '-c', 'printf s >> ' .. quiet .. '; exit 0' }
        lsp.start('polite', open('polite'))
        vim.wait(600)
        assert(starts(quiet) == 1, 'a clean exit is not restarted: ' .. starts(quiet))
        """#)
    }

    @Test("the bar's servers include one that is down")
    func downServerShows() throws {
        try check(settings: "{}", """
        local lsp = require('frame.lsp')
        lsp.specs.crashy = { filetypes = { 'crashy' }, root = { '.git' }, aliases = {} }
        vim.cmd('enew') vim.bo.filetype = 'crashy'
        lsp.state.crashy = { status = 'restarting', deaths = {}, wait = 1000 }
        local names = require('frame.status').snapshot().lsp
        assert(vim.tbl_contains(names, 'crashy ↻'), vim.inspect(names))
        lsp.state.crashy.status = 'failed'
        assert(vim.tbl_contains(require('frame.status').snapshot().lsp, 'crashy ✗'))
        """)
    }

    @Test("a scheme that does not exist falls back to the default instead of failing")
    func missing() throws {
        guard hasPlugins else { return }
        try check(settings: #"{"theme":{"colorscheme":"no-such-scheme"}}"#, """
        require('frame.init').setup()
        assert(vim.g.colors_name == 'tokyonight-night', 'fell back to ' .. tostring(vim.g.colors_name))
        """)
    }
}
