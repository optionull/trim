import Foundation
import Testing

/// `runtime/lua/trim/base.lua` and `init.lua`, run in a headless nvim: Trim's defaults, what its settings file
/// changes,
/// the plugins it carries, and a colour scheme the person chose being left alone.
@Suite("Trim's base config")
struct TrimBaseLuaTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private func check(settings: String = "{}", _ script: String) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("trim-base-\(UUID().uuidString).lua")
        let source = """
        vim.g.trim_settings = vim.json.decode([==[\(settings)]==])
        vim.opt.runtimepath:prepend('\(Self.root.appendingPathComponent("runtime").path)')
        require('sill.base')
        require('trim.base')

        """ + script + "\nio.stdout:write('PASSED')\n"
        try source.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["nvim", "--headless", "-u", "NONE", "-l", file.path]
        // Whatever a test installs goes to a data folder of its own.
        var environment = ProcessInfo.processInfo.environment
        environment["XDG_DATA_HOME"] = FileManager.default.temporaryDirectory.appendingPathComponent("trim-test-data")
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
        assert(vim.g.trim == true and vim.g.mapleader == '\\\\', 'leader ' .. tostring(vim.g.mapleader))
        assert(vim.o.expandtab and vim.o.shiftwidth == 4 and vim.o.tabstop == 4, 'indent')
        assert(vim.o.clipboard == 'unnamedplus', 'clipboard')
        assert(vim.o.smoothscroll and vim.o.timeoutlen == 400 and not vim.o.wrap, 'scrolling and keys')
        assert(vim.o.mousescroll == 'ver:1,hor:1', 'a wheel step is a line: ' .. vim.o.mousescroll)
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
        require('trim.init').setup()
        assert(vim.g.colors_name == 'tokyonight-night', 'default scheme ' .. tostring(vim.g.colors_name))
        """)
        try check(settings: #"{"plugins":{"disabled":["catppuccin"]},"theme":{"colorscheme":"rose-pine"}}"#, """
        assert(#vim.api.nvim_get_runtime_file('colors/catppuccin-mocha.lua', true) == 0, 'catppuccin is left out')
        require('trim.init').setup()
        assert(vim.g.colors_name == 'rose-pine', 'the settings scheme ' .. tostring(vim.g.colors_name))
        """)
    }

    @Test("a scheme the person's own config chose stays")
    func theirs() throws {
        guard hasPlugins else { return }
        try check("""
        vim.cmd.colorscheme('catppuccin-mocha')
        require('trim.init').setup()
        assert(vim.g.colors_name == 'catppuccin-mocha', 'theirs stays: ' .. tostring(vim.g.colors_name))
        """)
    }

    @Test("a scheme with variants is put back exactly: its name alone would not, as it remembers the last variant")
    func restore() throws {
        guard hasPlugins else { return }
        try check(settings: #"{"theme":{"colorscheme":"rose-pine"}}"#, """
        require('trim.init').setup()
        local function normal() return vim.api.nvim_get_hl(0, { name = 'Normal' }).bg end
        local original = normal()
        local theme = require('trim.theme')
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
        require('trim.init').setup()
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
        local lsp = require('trim.lsp')
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
        local lsp = require('trim.lsp')
        lsp.specs.crashy = { filetypes = { 'crashy' }, root = { '.git' }, aliases = {} }
        vim.cmd('enew') vim.bo.filetype = 'crashy'
        lsp.state.crashy = { status = 'restarting', deaths = {}, wait = 1000 }
        local names = require('trim.status').snapshot().lsp
        assert(vim.tbl_contains(names, 'crashy ↻'), vim.inspect(names))
        lsp.state.crashy.status = 'failed'
        assert(vim.tbl_contains(require('trim.status').snapshot().lsp, 'crashy ✗'))
        """)
    }

    @Test(
        "the catalog: bundled ones, a bundled one left out, an installed one found in the data folder, the rest available"
    )
    func catalog() throws {
        try check(settings: #"{"plugins":{"disabled":["rose-pine"]}}"#, #"""
        local catalog = require('trim.catalog')
        local by = {}
        for _, row in ipairs(catalog.list()) do by[row.name] = row end
        assert(by['tokyonight.nvim'].status == 'bundled', 'bundled: ' .. by['tokyonight.nvim'].status)
        assert(by['rose-pine'].status == 'disabled', 'a bundled one left out')
        assert(by['flash.nvim'].status == 'available' and by['flash.nvim'].tag ~= '', 'available, with its tag')
        assert(#by['flash.nvim'].commit == 40, 'pinned to a full commit')
        for _, p in ipairs(catalog.packages) do
            if not p.bundled then assert(#p.commit == 40 and p.repo:find('/') and p.tag ~= '', p.name .. ' is pinned') end
        end
        assert(by['flash.nvim'].dir:find('/site/pack/trim/start/flash.nvim', 1, true), by['flash.nvim'].dir)
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
            require('trim.options').apply({ number = true, tabwidth = 99, scrolloff = 100 })
            for _, win in ipairs(vim.api.nvim_list_wins()) do assert(vim.wo[win].number, 'every window') end
            assert(vim.o.shiftwidth == 2, 'a tab width out of range is ignored')
            assert(vim.o.scrolloff == 20, 'the margin is capped')
            assert(require('trim.options').current().tabwidth == 2)
            """
        )
    }

    @Test("scrolling past the end stops with the last line near the bottom, and a short file is not scrolled at all")
    func scrollPast() throws {
        try check(settings: "{}", """
        local lines = {}
        for i = 1, 100 do lines[i] = 'line ' .. i end
        vim.cmd('enew') vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
        local win = vim.api.nvim_get_current_win()
        local height = vim.api.nvim_win_get_height(win)
        vim.fn.winrestview({ topline = 100 })
        assert(vim.fn.winsaveview().topline == 100, 'nvim itself allows it')
        require('trim.scrollpast').clamp(win)
        local top = vim.fn.winsaveview().topline
        assert(top == 100 - (height - 2) + 1, 'the last line is two rows off the bottom: ' .. top .. ' of ' .. height)
        -- A short file: it cannot be scrolled up out of view.
        vim.api.nvim_buf_set_lines(0, 5, -1, false, {})
        vim.fn.winrestview({ topline = 5 })
        require('trim.scrollpast').clamp(win)
        assert(vim.fn.winsaveview().topline == 1, 'short file back at the top: ' .. vim.fn.winsaveview().topline)
        """)
    }

    @Test("what a folder's project files call for: its own, src's and one level down; a solution before a project")
    func detectsServers() throws {
        try check(settings: "{}", #"""
        local lsp = require('trim.lsp')
        local root = vim.fn.tempname()
        local function touch(path) vim.fn.mkdir(vim.fs.dirname(root .. '/' .. path), 'p') vim.fn.writefile({}, root .. '/' .. path) end
        touch('App.slnx') touch('src/App/App.csproj') touch('src/Core/Core.fsproj')
        touch('tools/Cargo.toml') touch('node_modules/x/package.json') touch('deep/er/Package.swift')
        local found = lsp.detect(root)
        assert(found.csharp == root .. '/App.slnx', 'a solution before a project: ' .. tostring(found.csharp))
        assert(found.fsautocomplete == root .. '/src/Core/Core.fsproj', 'src is looked in: ' .. tostring(found.fsautocomplete))
        assert(found.rust_analyzer == root .. '/tools/Cargo.toml', 'a folder one level down: ' .. tostring(found.rust_analyzer))
        assert(found.sourcekit == nil, 'two levels down is too far: ' .. tostring(found.sourcekit))
        assert(found.typescript == nil, 'node_modules is not a project')
        -- A file in src belongs to the solution at the top: one server for the folder and every file in it.
        assert(vim.fs.root(root .. '/src/App/Program.cs', lsp.specs.csharp.root) == root, 'the solution is the root')
        assert(vim.fs.root(root .. '/src/Core/A.fs', lsp.specs.fsautocomplete.root) == root, 'F# too')
        """#)
    }

    @Test("a diagnostic for a line that is gone does not throw when its file is opened (nor hold nvim at a prompt)")
    func staleDiagnostics() throws {
        try check(settings: "{}", #"""
        require('trim.diag').harden()
        local file = vim.fn.tempname() .. '.txt'
        vim.fn.writefile({ 'one', 'two' }, file)
        local buf = vim.fn.bufadd(file)
        local ns = vim.api.nvim_create_namespace('stale')
        vim.diagnostic.set(ns, buf, {
          { lnum = 1, col = 0, message = 'there', severity = 2 },
          { lnum = 40, col = 0, message = 'gone', severity = 1 },
        })
        vim.v.errmsg = ''
        vim.cmd('edit ' .. vim.fn.fnameescape(file))
        vim.wait(100)
        assert(vim.v.errmsg == '', 'opening the file raised: ' .. vim.v.errmsg)
        assert(vim.g.trim_diagnostic_error == nil, 'a handler failed: ' .. tostring(vim.g.trim_diagnostic_error))
        assert(#vim.diagnostic.get(buf) == 2, 'the diagnostics themselves are kept')
        local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, {})
        assert(#marks > 0, 'the line that is there is still marked once the file is open')
        """#)
    }

    @Test("the client does not offer to watch files for the servers: nvim's own watcher holds it while a build runs")
    func noWatching() throws {
        try check(settings: "{}", #"""
        local capabilities = require('trim.lsp').capabilities()
        local watch = capabilities.workspace.didChangeWatchedFiles
        assert(watch and watch.dynamicRegistration == false, 'watching is not offered: ' .. vim.inspect(watch))
        assert(capabilities.textDocument.codeAction, 'the rest of what nvim offers is kept')
        """#)
    }

    @Test(
        "diagnostics for files that are not open are kept without a buffer each, scoped and capped, and handed over on open"
    )
    func remoteDiagnostics() throws {
        try check(settings: "{}", #"""
        local diag, lsp = require('trim.diag'), require('trim.lsp')
        diag.start()
        local before = #vim.api.nvim_list_bufs()
        local root = vim.fn.tempname()
        vim.fn.mkdir(root, 'p')
        root = vim.uv.fs_realpath(root)
        local function report(severity, line) return { range = { start = { line = line, character = 2 } }, severity = severity, message = 'm' .. line .. '\nmore', code = 'X' .. line } end
        vim.fn.writefile({ 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l' }, root .. '/f9.cs')
        for i = 1, 400 do
          diag.set_remote(root .. '/f' .. i .. '.cs', { report(i % 4 + 1, i), report(1, i + 1) })
        end
        -- Through the handler a server's push goes by, too.
        lsp.publish(nil, { uri = vim.uri_from_fname(root .. '/pushed.cs'), diagnostics = { report(2, 0) } }, {}, nil)
        assert(#vim.api.nvim_list_bufs() == before, 'no buffer was made: ' .. #vim.api.nvim_list_bufs() .. ' of ' .. before)
        assert(diag.remote_files() == 401, 'files kept: ' .. diag.remote_files())
        local totals = diag.totals()
        assert(totals[1] + totals[2] + totals[3] + totals[4] == 801, 'counted: ' .. vim.inspect(totals))
        local rows = diag.list({ limit = 3000 })
        assert(#rows == 801 and rows[1].message == 'm' .. rows[1].line - 1 or rows[1].message:match('^m%d+$'), 'rows are one line')
        assert(#diag.list({ limit = 100 }) == 100, 'capped')
        assert(diag.list({ limit = 100 })[1].severity == 1, 'the worst first when capped')
        local scoped = diag.list({ scope = 'file', active = root .. '/f7.cs' })
        assert(#scoped == 2, 'a file: ' .. #scoped)
        assert(#diag.list({ scope = 'folder', active = root .. '/f7.cs' }) == 801, 'a folder')
        -- Opened, the file is nvim's: what was kept of it goes.
        local path = root .. '/f9.cs'
        vim.cmd('edit ' .. vim.fn.fnameescape(path))
        vim.wait(50)
        assert(#diag.list({ scope = 'file', active = path }) == 0, 'nvim has the open file, the store does not')
        assert(diag.remote_files() == 400, 'one fewer kept: ' .. diag.remote_files())
        """#)
    }

    @Test(
        "completion: a menu even for one candidate, fuzzy, nothing taken until chosen; Tab, Enter and Ctrl-Space are bound"
    )
    func completionKeys() throws {
        try check(settings: "{}", #"""
        assert(vim.o.completeopt:find('menuone') and vim.o.completeopt:find('noselect') and vim.o.completeopt:find('fuzzy'), vim.o.completeopt)
        for _, lhs in ipairs({ '<Tab>', '<S-Tab>', '<CR>', '<C-Space>', '<C-S>' }) do
          assert(vim.fn.maparg(lhs, 'i') ~= '', lhs .. ' is bound')
        end
        """#)
    }

    @Test("autostart: the settings can turn it off")
    func autostartOff() throws {
        try check(settings: #"{"lsp":{"autostart":false}}"#, #"""
        local lsp = require('trim.lsp')
        local root = vim.fn.tempname()
        vim.fn.mkdir(root, 'p') vim.fn.writefile({}, root .. '/Cargo.toml')
        lsp.autostart(root)
        assert(next(lsp.warm) == nil, 'nothing was started: ' .. vim.inspect(lsp.warm))
        """#)
    }

    @Test("a scheme that does not exist falls back to the default instead of failing")
    func missing() throws {
        guard hasPlugins else { return }
        try check(settings: #"{"theme":{"colorscheme":"no-such-scheme"}}"#, """
        require('trim.init').setup()
        assert(vim.g.colors_name == 'tokyonight-night', 'fell back to ' .. tostring(vim.g.colors_name))
        """)
    }
}
