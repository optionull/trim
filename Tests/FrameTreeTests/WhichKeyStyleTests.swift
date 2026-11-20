import Foundation
import Testing

/// `runtime/lua/frame/whichkey.lua`, run in a headless nvim: which-key.nvim's window groups take the colours Frame
/// hands
/// over, keep them across a colour scheme being applied, and can be left alone.
@Suite("which-key.nvim's colours")
struct WhichKeyStyleTests {
    private static let runtime = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("runtime").path

    private func check(_ script: String) throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("frame-whichkey-\(UUID().uuidString).lua")
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

    @Test("the window's groups take the colours handed over, and the colour scheme being applied does not undo them")
    func styled() throws {
        try check("""
        local wk = require('frame.whichkey')
        wk.style(0x112233, 0xEEEEEE, 0x888888)
        local function hl(name) return vim.api.nvim_get_hl(0, { name = name }) end
        assert(hl('WhichKeyNormal').bg == 0x112233 and hl('WhichKeyNormal').fg == 0xEEEEEE, 'normal')
        assert(hl('WhichKeyBorder').bg == 0x112233 and hl('WhichKeyBorder').fg == 0x888888, 'border')
        assert(hl('WhichKeyTitle').bg == 0x112233 and hl('WhichKeyTitle').bold, 'title')
        vim.cmd('highlight clear WhichKeyNormal')
        assert(hl('WhichKeyNormal').bg == nil, 'cleared')
        vim.cmd('doautocmd ColorScheme')
        assert(hl('WhichKeyNormal').bg == 0x112233, 'put back when a colour scheme is applied')
        wk.style(0x445566, 0xEEEEEE, 0x888888)
        assert(hl('WhichKeyNormal').bg == 0x445566, 'new colours replace the old')
        """)
    }

    @Test("a config that does not want it is left alone")
    func optedOut() throws {
        try check("""
        vim.g.frame_style_whichkey = false
        local wk = require('frame.whichkey')
        wk.style(0x112233, 0xEEEEEE, 0x888888)
        assert(vim.api.nvim_get_hl(0, { name = 'WhichKeyNormal' }).bg == nil, 'not styled')
        vim.g.frame_style_whichkey = nil
        wk.restyle()
        assert(vim.api.nvim_get_hl(0, { name = 'WhichKeyNormal' }).bg == 0x112233, 'styled once allowed')
        """)
    }

    @Test("nothing is set before the app hands over any colours")
    func untouched() throws {
        try check("""
        require('frame.whichkey').restyle()
        assert(vim.api.nvim_get_hl(0, { name = 'WhichKeyNormal' }).bg == nil, 'untouched')
        """)
    }
}
