import Foundation
import Testing

/// scripts/treesitter.lua's plan: what the bundle's parsers are built from.
@Suite("tree-sitter's build")
struct TreesitterBuildTests {
    @Test("the plan: the languages sill wants, what their queries require first; nvim's own and the unwanted left out")
    func plan() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "nvim", "--clean", "-l", root.appendingPathComponent("scripts/treesitter.lua").path, "--plan",
            root.appendingPathComponent("Tests/SillCoreTests/Fixtures/treesitter-parsers.lua").path,
        ]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let plan = try #require(try JSONSerialization.jsonObject(with: data) as? [String: [String]])
        // In the order sill wants them, each after what its queries require; lua is nvim's own, ada not wanted.
        #expect(plan["parsers"] == ["c_sharp", "typescript", "tsx", "swift"])
        #expect(plan["queries"] == ["c_sharp", "ecma", "typescript", "jsx", "tsx", "swift"])
    }
}
