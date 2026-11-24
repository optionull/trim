import Foundation
import Testing

/// `runtime/lua/trim/mdstyle.lua`, run in a headless nvim: headings and inline code of markdown, outside fences and
/// front
/// matter.
@Suite("markdown styling")
struct MdStyleLuaTests {
    private static let runtime = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("runtime").path

    private func check(_ script: String) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("trim-md-\(UUID().uuidString).lua")
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

    @Test(
        "headings are big and their marks hidden, inline code is boxed with its backticks as padding, and fences and front matter are left alone"
    )
    func apply() throws {
        try check("""
        local md = require('trim.mdstyle')
        local lines = { '---', 'by: `x`', '---', '# Title', 'Some `code` here', '## Step', '```', '# not a heading `no`', '```', 'after `two` and `more`' }
        vim.cmd('enew')
        vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
        local ns = vim.api.nvim_create_namespace('t')
        md.apply(0, ns, lines, 3)
        local marks = vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })
        local function on(row) local out = {} for _, m in ipairs(marks) do if m[2] == row then out[#out + 1] = m end end return out end
        assert(#on(1) == 0, 'front matter is left alone')
        local title = on(3)
        local groups = {}
        for _, m in ipairs(title) do groups[#groups + 1] = m[4].hl_group or (m[4].conceal and 'conceal') or (m[4].virt_lines and 'filler') end
        table.sort(groups)
        assert(vim.inspect(groups) == vim.inspect({ 'TrimMdH1', 'conceal', 'filler' }), 'title ' .. vim.inspect(groups))
        local code = on(4)
        assert(#code == 3, 'a box and two backticks: ' .. #code)
        assert(vim.api.nvim_get_hl(0, { name = 'TrimMdCode' }).blend == 100, 'a box is blend 100')
        assert(vim.api.nvim_get_hl(0, { name = 'TrimMdH2' }).blend == 50, 'steps are 1.5 times')
        assert(#on(7) == 0 and #on(6) == 0 and #on(8) == 0, 'fenced lines are left alone')
        assert(#on(9) == 6, 'two spans, three marks each')
        """)
    }
}
