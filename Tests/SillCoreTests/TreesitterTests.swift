import Foundation
import SillCore
import Testing

@Suite("tree-sitter")
struct TreesitterTests {
    /// nvim-treesitter's `parsers.lua` as `vim.json.encode` gives it, cut down.
    private let json = Data("""
    {
      "c_sharp": {"install_info": {"url": "https://github.com/tree-sitter/tree-sitter-c-sharp", "revision": "v0.23.5"},
                  "tier": 1},
      "tsx": {"install_info": {"location": "tsx", "url": "https://github.com/tree-sitter/tree-sitter-typescript",
              "revision": "75b3874"}, "requires": ["ecma", "jsx", "typescript"]},
      "typescript": {"install_info": {"location": "typescript",
                     "url": "https://github.com/tree-sitter/tree-sitter-typescript", "revision": "75b3874"},
                     "requires": ["ecma"]},
      "ecma": {"readme_note": "queries required by javascript, typescript, tsx"},
      "jsx": {"readme_note": "queries required by javascript, tsx"},
      "swift": {"install_info": {"generate": true, "url": "https://github.com/alex-pinkus/tree-sitter-swift",
                "revision": "9e3b87f"}},
      "markdown": {"install_info": {"location": "tree-sitter-markdown",
                   "url": "https://github.com/tree-sitter-grammars/tree-sitter-markdown", "revision": "41ff24a"}},
      "lua": {"install_info": {"url": "https://github.com/tree-sitter-grammars/tree-sitter-lua", "revision": "10fe005"}}
    }
    """.utf8)

    @Test("parsers.lua's entries: a grammar where it has install_info, queries alone where not")
    func entries() throws {
        let entries = try Treesitter.entries(json: json)
        #expect(entries["c_sharp"]?.grammar?.revision == "v0.23.5")
        #expect(entries["tsx"]?.grammar?.location == "tsx" && entries["tsx"]?.requires == ["ecma", "jsx", "typescript"])
        #expect(entries["ecma"]?.grammar == nil)
        #expect(entries["swift"]?.grammar?.generate == true)
        #expect(entries["c_sharp"]?.grammar?.archive?.absoluteString ==
            "https://codeload.github.com/tree-sitter/tree-sitter-c-sharp/tar.gz/v0.23.5")
    }

    @Test("the plan: what each language needs, its queries' languages first; nvim's own and the unknown left out")
    func plan() throws {
        let entries = try Treesitter.entries(json: json)
        let (parsers, queries) = Treesitter.plan(entries, languages: ["tsx", "c_sharp", "markdown", "lua", "nope"])
        #expect(parsers == ["typescript", "tsx", "c_sharp"])
        #expect(queries == ["ecma", "jsx", "typescript", "tsx", "c_sharp"])
    }

    @Test("stale: a parser never built or built from another revision; fresh: checked within the week")
    func state() throws {
        let entries = try Treesitter.entries(json: json)
        let now = Date()
        var state = Treesitter.State(
            commit: "abc",
            checked: now.addingTimeInterval(-3600),
            built: [
                "c_sharp": "v0.23.5",
                "tsx": "old",
            ]
        )
        #expect(state.stale(entries, parsers: ["c_sharp", "tsx", "typescript"]) == ["tsx", "typescript"])
        #expect(state.fresh(now: now))
        state.checked = now.addingTimeInterval(-8 * 24 * 3600)
        #expect(!state.fresh(now: now))
        #expect(!Treesitter.State().fresh(now: now), "never checked")
    }

    @Test("Swift's grammar: its newest tag with the generated files")
    func generated() {
        let tags = """
        7b7909f\trefs/tags/0.7.2-with-generated-files
        31d17fe\trefs/tags/0.7.10-with-generated-files
        31d17fe\trefs/tags/0.7.10-with-generated-files^{}
        82bb3a5\trefs/tags/0.7.4-with-generated-files
        aaaaaaa\trefs/tags/0.8.0
        """
        #expect(Treesitter.generatedTag(tags) == "0.7.10-with-generated-files")
        #expect(Treesitter.generatedTag("") == nil)
    }

    @Test("the languages sill wants are none of nvim's own, each once")
    func languages() {
        #expect(Set(Treesitter.languages).isDisjoint(with: Treesitter.bundled))
        #expect(Set(Treesitter.languages).count == Treesitter.languages.count)
    }
}
