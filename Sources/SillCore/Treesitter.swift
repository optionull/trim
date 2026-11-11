import Foundation

/// Tree-sitter for sill's own nvim: the parsers nvim does not ship (it has C, Lua, Vim script, its help, queries and
/// Markdown), built on the person's Mac from the grammars nvim-treesitter pins, and nvim-treesitter's queries with
/// them, all in sill's cache. What to build, from nvim-treesitter's list of parsers (`parsers.lua`, as JSON).
public enum Treesitter {
    /// The languages sill highlights: those it has language servers for, and what a repository is mostly made of.
    public static let languages = [
        "c_sharp", "razor", "fsharp", "typescript", "tsx", "javascript", "json", "yaml", "toml", "bash", "rust",
        "swift",
        "python", "go", "html", "css", "xml", "dockerfile", "diff", "gitcommit", "sql", "java", "kotlin", "ruby",
    ]

    /// nvim's own: never built.
    public static let bundled: Set<String> = ["c", "lua", "vim", "vimdoc", "query", "markdown", "markdown_inline"]

    /// A grammar as nvim-treesitter has it: where it is, at which revision, in which folder of its repository.
    public struct Grammar: Codable, Equatable, Sendable {
        public var url: String
        public var revision: String
        public var location: String?
        /// Its parser.c is not in the repository: it is generated (with tree-sitter's CLI, which sill does not ask
        /// for). Swift's is the one sill wants; its repository tags the generated files, which sill builds instead.
        public var generate: Bool?

        public init(url: String, revision: String, location: String? = nil, generate: Bool? = nil) {
            self.url = url
            self.revision = revision
            self.location = location
            self.generate = generate
        }

        /// The archive of the revision: GitHub's tarball.
        public var archive: URL? {
            guard url.hasPrefix("https://github.com/") else { return nil }
            let repository = url.dropFirst("https://github.com/".count).replacingOccurrences(of: ".git", with: "")
            return URL(string: "https://codeload.github.com/\(repository)/tar.gz/\(revision)")
        }
    }

    /// An entry of `parsers.lua`: a grammar to build, or queries alone (`ecma`, `jsx`, `html_tags`), and the languages
    /// whose queries its own build on.
    public struct Entry: Codable, Equatable, Sendable {
        public var grammar: Grammar?
        public var requires: [String]

        public init(grammar: Grammar?, requires: [String] = []) {
            self.grammar = grammar
            self.requires = requires
        }
    }

    /// `parsers.lua` as JSON (`vim.json.encode(dofile(...))`): each language's `install_info` and `requires`.
    public static func entries(json: Data) throws -> [String: Entry] {
        struct Raw: Decodable {
            struct Info: Decodable {
                var url: String?
                var revision: String?
                var location: String?
                var generate: Bool?
            }

            var install_info: Info?
            var requires: [String]?
        }
        let raw = try JSONDecoder().decode([String: Raw].self, from: json)
        return raw.mapValues { entry in
            let grammar = entry.install_info.flatMap { info -> Grammar? in
                guard let url = info.url, let revision = info.revision else { return nil }
                return Grammar(url: url, revision: revision, location: info.location, generate: info.generate)
            }
            return Entry(grammar: grammar, requires: entry.requires ?? [])
        }
    }

    /// What `languages` need: the parsers to have (each wanted language with a grammar, and those its queries build
    /// on), and every language whose queries to copy (those, and the query-only ones such as `ecma`). nvim's own are
    /// left out; a language nvim-treesitter does not list is dropped.
    public static func plan(_ entries: [String: Entry], languages: [String] = languages)
        -> (parsers: [String], queries: [String])
    {
        var queries: [String] = []
        var seen: Set<String> = []
        func visit(_ language: String) {
            guard !bundled.contains(language), let entry = entries[language], seen.insert(language).inserted else {
                return
            }
            for required in entry.requires {
                visit(required)
            }
            queries.append(language)
        }
        for language in languages {
            visit(language)
        }
        return (queries.filter { entries[$0]?.grammar != nil }, queries)
    }

    /// What the cache holds: the nvim-treesitter commit its queries are from, when that was last checked, and the
    /// revision each parser was built from.
    public struct State: Codable, Equatable, Sendable {
        public var commit: String
        public var checked: Date
        public var built: [String: String]

        public init(commit: String = "", checked: Date = .distantPast, built: [String: String] = [:]) {
            self.commit = commit
            self.checked = checked
            self.built = built
        }

        /// Checked within the week: nothing to ask the network.
        public func fresh(now: Date = Date()) -> Bool {
            now.timeIntervalSince(checked) < 7 * 24 * 3600 && !commit.isEmpty
        }

        /// The parsers whose revision is not the one built (or that were never built).
        public func stale(_ entries: [String: Entry], parsers: [String]) -> [String] {
            parsers.filter { built[$0] != entries[$0]?.grammar?.revision }
        }
    }

    /// The highest `<version>-with-generated-files` tag in `git ls-remote --tags` output (Swift's grammar).
    public static func generatedTag(_ lsRemote: String) -> String? {
        let tags = lsRemote.split(separator: "\n").compactMap { line -> String? in
            guard let ref = line.split(separator: "\t").last, ref.hasSuffix("-with-generated-files"),
                  !ref.hasSuffix("^{}") else { return nil }
            return String(ref.dropFirst("refs/tags/".count))
        }
        func version(_ tag: String) -> [Int] {
            tag.prefix { $0 != "-" }.split(separator: ".").map { Int($0) ?? 0 }
        }
        return tags.max { version($0).lexicographicallyPrecedes(version($1)) }
    }
}
