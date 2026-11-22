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
        // Whatever a test installs goes to a data folder of its own.
        var environment = ProcessInfo.processInfo.environment
        environment["XDG_DATA_HOME"] = FileManager.default.temporaryDirectory.appendingPathComponent("frame-test-data")
            .path
        process.environment = environment
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

    @Test(
        "the catalog: bundled ones, a bundled one left out, an installed one found in the data folder, the rest available"
    )
    func catalog() throws {
        try check(settings: #"{"plugins":{"disabled":["rose-pine"]}}"#, #"""
        local catalog = require('frame.catalog')
        local by = {}
        for _, row in ipairs(catalog.list()) do by[row.name] = row end
        assert(by['tokyonight.nvim'].status == 'bundled', 'bundled: ' .. by['tokyonight.nvim'].status)
        assert(by['rose-pine'].status == 'disabled', 'a bundled one left out')
        assert(by['flash.nvim'].status == 'available' and by['flash.nvim'].tag ~= '', 'available, with its tag')
        assert(#by['flash.nvim'].commit == 40, 'pinned to a full commit')
        for _, p in ipairs(catalog.packages) do
            if not p.bundled then assert(#p.commit == 40 and p.repo:find('/') and p.tag ~= '', p.name .. ' is pinned') end
        end
        assert(by['flash.nvim'].dir:find('/site/pack/frame/start/flash.nvim', 1, true), by['flash.nvim'].dir)
        -- Installed: a folder in the data folder; its plugin runs, and its setup, without a restart.
        local dir = catalog.dir('flash.nvim')
        vim.fn.mkdir(dir .. '/lua/flash', 'p')
        vim.fn.writefile({ 'vim.g.flash_setup_ran = true', 'return { setup = function() vim.g.flash_setup_ran = true end, jump = function() end, treesitter = function() end }' }, dir .. '/lua/flash/init.lua')
        assert(catalog.status(catalog.packages[9]) == 'installed' or catalog.status({ name = 'flash.nvim' }) == 'installed', 'installed')
        catalog.loaded('flash.nvim')
        assert(vim.g.flash_setup_ran, 'its setup ran')
        assert(vim.fn.maparg('s', 'n') ~= '', 'its keys were bound')
        catalog.unloaded('flash.nvim')
        vim.fn.delete(dir, 'rf')
        assert(catalog.status({ name = 'flash.nvim' }) == 'available', 'gone again')
        """#)
    }

    @Test(
        "the editor settings (tab width, wrapping, line numbers) win over the defaults, and apply live to every window"
    )
    func editorOptions() throws {
        try check(
            settings: #"{"editor":{"tabwidth":2,"wrap":true,"number":false,"scrolloff":7,"expandtab":false}}"#,
            """
            assert(vim.o.shiftwidth == 2 and vim.o.tabstop == 2 and vim.o.softtabstop == 2, 'tab width')
            assert(vim.o.expandtab == false and vim.o.scrolloff == 7, 'tabs and margin')
            assert(vim.wo.wrap == true and vim.wo.number == false, 'window options')
            vim.cmd('vsplit')
            require('frame.options').apply({ number = true, tabwidth = 99, scrolloff = 100 })
            for _, win in ipairs(vim.api.nvim_list_wins()) do assert(vim.wo[win].number, 'every window') end
            assert(vim.o.shiftwidth == 2, 'a tab width out of range is ignored')
            assert(vim.o.scrolloff == 20, 'the margin is capped')
            assert(require('frame.options').current().tabwidth == 2)
            """
        )
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
