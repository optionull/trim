import Foundation
import Testing

/// `runtime/lua/trim/mdblocks.lua` and the blocks of `trim.mdstyle`, run in a headless nvim: tables, callouts, quotes
/// and
/// checklists.
@Suite("markdown blocks")
struct MdBlocksLuaTests {
    private static let runtime = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("runtime").path

    private func check(_ script: String) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("trim-blocks-\(UUID().uuidString).lua")
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

    private static let helpers = """
    local blocks = require('trim.mdblocks')
    local function text_of(line) local t = '' for _, c in ipairs(line) do t = t .. c[1] end return t end
    local function cells_of(line) local w = 0 for _, c in ipairs(line) do w = w + vim.fn.strdisplaywidth(c[1]) end return w end
    """

    @Test(
        "a table is a grid as wide as the window at every width, aligned as the separator says, its cells wrapped, and only a real table is one"
    )
    func table() throws {
        try check(Self.helpers + "\n" + """
        local tbl = { '| Dough | Hydration | Notes |', '|:---|---:|:---:|',
          '| sourdough | 75% | `wet` and **sticky** with a long note that should wrap when narrow |', '| baguette | 70% | ok |' }
        assert(blocks.is_table(tbl))
        assert(not blocks.is_table({ '| a | b |', '| not | a separator |' }) and not blocks.is_table({ '| a |' }))
        for _, width in ipairs({ 80, 60, 40 }) do
          local lines = blocks.table_lines(tbl, width)
          for i, line in ipairs(lines) do
            assert(cells_of(line) <= width and cells_of(line) >= width - 40, ('width %d line %d is %d'):format(width, i, cells_of(line)))
          end
          assert(text_of(lines[1]):find('^╭') and text_of(lines[#lines]):find('^╰'), 'rounded corners')
          local all = ''
          for _, line in ipairs(lines) do all = all .. text_of(line) .. '\\n' end
          assert(all:find('sticky', 1, true) and all:find('baguette', 1, true) and not all:find('**', 1, true), 'inline marks are applied, not shown')
        end
        local wide = blocks.table_lines(tbl, 100)
        local widths = {}
        for _, line in ipairs(wide) do widths[cells_of(line)] = true end
        assert(vim.tbl_count(widths) == 1, 'every line of the grid is one width')
        local row = text_of(wide[4])
        assert(row:find('%s75%%%s') and row:find('│%s+75%%'), 'a right-aligned column is flush right: ' .. row)
        """)
    }

    @Test("a callout is a block of the width asked, named and coloured by its kind; a plain quote has none")
    func callout() throws {
        try check(Self.helpers + "\n" + """
        local lines, kind = blocks.quote_lines({ '> [!warning] Heads up', '> The limit is a bare number, and two callers pass `Fahrenheit` which is wrong.', '>', '> Second paragraph.' }, 50)
        assert(kind == 'warning')
        for i, line in ipairs(lines) do assert(cells_of(line) == 50, ('line %d is %d'):format(i, cells_of(line))) end
        assert(text_of(lines[1]):find('Warning', 1, true) and not text_of(lines[1]):find('Heads up', 1, true), text_of(lines[1]))
        assert(text_of(lines[2]):find('Heads up', 1, true), 'the text after the marker is the body: ' .. text_of(lines[2]))
        local long = blocks.quote_lines({ '> [!warning] ' .. string.rep('word ', 30) }, 40)
        assert(#long > 3, 'a long text after the marker wraps: ' .. #long)
        for _, line in ipairs(long) do assert(cells_of(line) == 40) end
        assert(lines[1][1][2] == 'TrimCalloutWarnBar', 'the bar is amber')
        assert(#lines == 5, 'head, two wrapped rows, a gap, a paragraph: ' .. #lines)
        local quote, none = blocks.quote_lines({ '> just a quote that is rather long and wraps around the edge of it' }, 30)
        assert(none == nil and #quote == 3 and quote[1][1][2] == 'TrimQuoteBar')
        local _, unknown = blocks.quote_lines({ '> [!nonsense] x' }, 30)
        assert(unknown == nil, 'an unknown kind is a quote')
        """)
    }

    @Test(
        "checklists are boxes with a count, done items struck through; tables and callouts are drawn away from the cursor and are source in it"
    )
    func apply() throws {
        try check("""
        local md = require('trim.mdstyle')
        vim.cmd('enew')
        local lines = { 'Intro', '', '- [ ] one', '- [x] two', '- [x] three', '- [ ] four', '', '| a | b |', '|---|---|', '| 1 | 2 |', '', '> [!note] Hi', '> there', '', 'end' }
        vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        md.apply(0, lines, 0)
        local marks = vim.api.nvim_buf_get_extmarks(0, md.ns, 0, -1, { details = true })
        local function find(pred) for _, m in ipairs(marks) do if pred(m) then return m end end end
        local boxes = 0
        for _, m in ipairs(marks) do if m[4].conceal == '☐' or m[4].conceal == '☑' then boxes = boxes + 1 end end
        assert(boxes == 4, 'four boxes: ' .. boxes)
        local count = find(function(m) return m[2] == 2 and m[4].virt_text and m[4].virt_text[1][1]:find('2 of 4', 1, true) end)
        assert(count, 'the count is on the first item')
        assert(find(function(m) return m[2] == 3 and m[4].hl_group == 'TrimMdDoneText' end), 'done text is struck through')
        local hidden = 0
        for _, m in ipairs(marks) do if m[4].conceal_lines then hidden = hidden + 1 end end
        assert(hidden == 5, 'the table (3) and the callout (2) are hidden: ' .. hidden)
        assert(#md.blocks[0] == 2)
        -- The cursor in the table shows its source (and only the table's).
        vim.api.nvim_win_set_cursor(0, { 9, 0 })
        md.restyle(0)
        marks = vim.api.nvim_buf_get_extmarks(0, md.ns, 0, -1, { details = true })
        local rows = {}
        for _, m in ipairs(marks) do if m[4].conceal_lines then rows[#rows + 1] = m[2] + 1 end end
        table.sort(rows)
        assert(vim.inspect(rows) == vim.inspect({ 12, 13 }), 'only the callout is hidden: ' .. vim.inspect(rows))
        """)
    }

    @Test(
        "an @ask is a question block with its answer, numbered steps get their number before the heading, and both are source under the cursor"
    )
    func askAndSteps() throws {
        try check("""
        local md = require('trim.mdstyle')
        vim.cmd('enew')
        local lines = { '# T', '', '## First', 'text', '@ask Why is it so?', '> Because.', '> Really.', '', '## Second', 'more' }
        vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        md.apply(0, lines, 0, { steps = true })
        local marks = vim.api.nvim_buf_get_extmarks(0, md.ns, 0, -1, { details = true })
        local numbers, hidden, drawn = {}, {}, ''
        for _, m in ipairs(marks) do
          if m[4].virt_text_pos == 'inline' then numbers[#numbers + 1] = { m[2] + 1, m[4].virt_text[1][1] } end
          if m[4].conceal_lines then hidden[#hidden + 1] = m[2] + 1 end
          for _, row in ipairs(m[4].virt_lines or {}) do for _, c in ipairs(row) do drawn = drawn .. c[1] end end
        end
        assert(vim.inspect(numbers) == vim.inspect({ { 3, '01  ' }, { 9, '02  ' } }), 'steps: ' .. vim.inspect(numbers))
        table.sort(hidden)
        assert(vim.inspect(hidden) == vim.inspect({ 5, 6, 7 }), 'the question and answer are hidden: ' .. vim.inspect(hidden))
        assert(drawn:find('Question', 1, true) and drawn:find('Why is it so?', 1, true) and drawn:find('Because.', 1, true), drawn)
        vim.api.nvim_win_set_cursor(0, { 6, 0 })
        md.restyle(0)
        marks = vim.api.nvim_buf_get_extmarks(0, md.ns, 0, -1, { details = true })
        for _, m in ipairs(marks) do assert(not m[4].conceal_lines, 'source while the cursor is in the block') end
        local plain = {}
        md.apply(0, lines, 0)
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, md.ns, 0, -1, { details = true })) do
          assert(m[4].virt_text_pos ~= 'inline', 'no step numbers outside a walkthrough')
        end
        """)
    }
}
