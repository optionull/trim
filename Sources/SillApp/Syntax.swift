import Foundation
import SillCore
import SillNvim

/// Tree-sitter parsers for sill's own nvim, built on this Mac the first time sill runs and kept up to date: each
/// grammar at the revision nvim-treesitter pins, compiled with the Command Line Tools' `cc`, and nvim-treesitter's
/// queries beside them, in `~/Library/Caches/sill/treesitter` (nvim finds them on its runtimepath). Once a week sill
/// asks git for nvim-treesitter's newest commit and builds again only the parsers whose pin moved. Without the
/// Command Line Tools nothing is built (asking for `cc` would bring up macOS's installer) and nvim keeps its own
/// syntax files. One for the app: the first checkout to ask does it, the others wait for the same.
@MainActor
final class SyntaxParsers {
    static let shared = SyntaxParsers()

    nonisolated static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sill/treesitter")
    }

    private var running: Task<String?, Never>?

    /// What the last provisioning said (nil: all is well), for the checks.
    private(set) var outcome: String??

    /// Makes sure the parsers are there, then has `channel`'s nvim highlight with them (and says what went wrong, if
    /// anything did).
    func ensure(channel: NvimChannel) {
        let task = running ?? Task.detached {
            await Self.provision { path in
                guard let value = try? await channel.lua(
                    "return vim.json.encode(dofile(...))",
                    args: [.string(path)]
                ), let json = value.stringValue else { return nil }
                return Data(json.utf8)
            } notify: { message in
                Nvim.lua(channel, "vim.notify(...)", [.string(message)])
            }
        }
        running = task
        Task {
            let problem = await task.value
            outcome = .some(problem)
            _ = try? await channel.lua("require('sill.syntax').ready(...)", args: [.string(Self.folder.path)])
            if let problem { Nvim.lua(channel, "vim.notify(..., vim.log.levels.WARN)", [.string(problem)]) }
        }
    }

    // MARK: Building

    private nonisolated static var stateFile: URL { folder.appendingPathComponent("state.json") }

    private nonisolated static func parser(_ language: String) -> URL {
        folder.appendingPathComponent("parser/\(language).so")
    }

    /// Everything, off the main thread. Returns what went wrong, or nil.
    nonisolated static func provision(
        readParsers: @escaping @Sendable (String) async -> Data?,
        notify: @escaping @Sendable @MainActor (String) -> Void
    ) async -> String? {
        let manager = FileManager.default
        var state = (try? Data(contentsOf: stateFile)).flatMap { try? JSONDecoder().decode(
            Treesitter.State.self,
            from: $0
        ) } ?? Treesitter.State()
        let present = !state.built.isEmpty && state.built.keys
            .allSatisfy { manager.fileExists(atPath: parser($0).path) }
        if state.fresh(), present { return nil }

        guard await (try? run("/usr/bin/xcode-select", ["-p"]).code) == 0 else {
            return "sill: no tree-sitter highlighting without the Command Line Tools (xcode-select --install); " +
                "nvim's own syntax files are used"
        }
        guard let head = try? await run("/usr/bin/git", [
            "ls-remote", "https://github.com/nvim-treesitter/nvim-treesitter", "refs/heads/main",
        ]), head.code == 0, let commit = head.output.split(separator: "\t").first.map(String.init), !commit.isEmpty
        else {
            // Offline: what was built stays, and sill asks again next time.
            return present ? nil : "sill: could not reach GitHub for tree-sitter's parsers; it tries again next start"
        }
        if commit == state.commit, present {
            state.checked = Date()
            save(state)
            return nil
        }

        let work: URL
        do {
            work = try manager.url(
                for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder.deletingLastPathComponent(),
                create: true
            )
        } catch {
            return "sill: tree-sitter: \(error.localizedDescription)"
        }
        defer { try? manager.removeItem(at: work) }
        let source = work.appendingPathComponent("nvim-treesitter")
        guard let archive = URL(string: "https://codeload.github.com/nvim-treesitter/nvim-treesitter/tar.gz/\(commit)"),
              await unpack(archive, into: source),
              let json = await readParsers(source.appendingPathComponent("lua/nvim-treesitter/parsers.lua").path),
              let entries = try? Treesitter.entries(json: json)
        else { return "sill: could not read nvim-treesitter's list of parsers; it tries again next start" }

        let (parsers, queries) = Treesitter.plan(entries)
        // Built from another revision, never built, or gone from the cache.
        let stale = Set(state.stale(entries, parsers: parsers))
            .union(parsers.filter { !manager.fileExists(atPath: parser($0).path) })
            .sorted()
        if !stale.isEmpty {
            await notify("sill: building tree-sitter parsers for \(stale.count) languages, in the background")
        }
        try? manager.createDirectory(at: folder.appendingPathComponent("parser"), withIntermediateDirectories: true)
        var failed: [String] = []
        await withTaskGroup(of: (String, Bool).self) { group in
            var queue = stale[...]
            func next() {
                guard let language = queue.popFirst(), let grammar = entries[language]?.grammar else { return }
                group.addTask { await (language, build(language, grammar, in: work)) }
            }
            for _ in 0 ..< 4 {
                next()
            }
            for await (language, built) in group {
                if built {
                    state.built[language] = entries[language]?.grammar?.revision
                } else {
                    failed.append(language)
                }
                next()
            }
        }
        // The queries, all at once: the new folder in place of the old.
        let fresh = folder.appendingPathComponent("queries.new"), current = folder.appendingPathComponent("queries")
        try? manager.removeItem(at: fresh)
        try? manager.createDirectory(at: fresh, withIntermediateDirectories: true)
        for language in queries {
            let from = source.appendingPathComponent("runtime/queries/\(language)")
            if manager.fileExists(atPath: from.path) {
                try? manager.copyItem(at: from, to: fresh.appendingPathComponent(language))
            }
        }
        try? manager.removeItem(at: current)
        try? manager.moveItem(at: fresh, to: current)
        state.commit = failed.isEmpty ? commit : ""
        state.checked = Date()
        save(state)
        return failed.isEmpty ? nil : "sill: tree-sitter parsers not built: \(failed.sorted().joined(separator: ", "))"
    }

    /// One parser: its grammar's archive at the pinned revision (Swift's: its newest generated tag), `parser.c` and a
    /// scanner compiled into a shared library, put in place whole.
    private nonisolated static func build(_ language: String, _ grammar: Treesitter.Grammar, in work: URL) async
        -> Bool
    {
        var grammar = grammar
        if grammar.generate == true {
            guard let tags = try? await run("/usr/bin/git", ["ls-remote", "--tags", grammar.url]),
                  let tag = Treesitter.generatedTag(tags.output) else { return false }
            grammar.revision = tag
        }
        let folder = work.appendingPathComponent("grammar-\(language)")
        guard let archive = grammar.archive, await unpack(archive, into: folder) else { return false }
        let src = folder.appendingPathComponent((grammar.location.map { $0 + "/" } ?? "") + "src")
        let manager = FileManager.default
        var sources = [src.appendingPathComponent("parser.c").path]
        var libraries: [String] = []
        if manager.fileExists(atPath: src.appendingPathComponent("scanner.c").path) {
            sources.append(src.appendingPathComponent("scanner.c").path)
        } else if manager.fileExists(atPath: src.appendingPathComponent("scanner.cc").path) {
            // An old grammar's C++ scanner: clang compiles each file by its extension; the C++ library links in.
            sources.append(src.appendingPathComponent("scanner.cc").path)
            libraries = ["-lc++"]
        }
        guard manager.fileExists(atPath: sources[0]) else { return false }
        let output = work.appendingPathComponent("\(language).so")
        guard let compiled = try? await run(
            "/usr/bin/cc",
            ["-shared", "-fPIC", "-Os", "-I", src.path] + sources + libraries + ["-o", output.path],
            in: src.path
        ), compiled.code == 0 else { return false }
        // In place by a rename: an nvim that loaded the old one keeps it.
        let target = parser(language)
        _ = try? manager.replaceItemAt(target, withItemAt: output)
        if !manager.fileExists(atPath: target.path) { try? manager.moveItem(at: output, to: target) }
        return manager.fileExists(atPath: target.path)
    }

    private nonisolated static func unpack(_ archive: URL, into folder: URL) async -> Bool {
        guard let (download, response) = try? await URLSession.shared.download(from: archive),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let unpacked = try? await run(
            "/usr/bin/tar",
            ["xzf", download.path, "-C", folder.path, "--strip-components", "1"]
        )
        try? FileManager.default.removeItem(at: download)
        return unpacked?.code == 0
    }

    private nonisolated static func run(
        _ tool: String,
        _ arguments: [String],
        in directory: String = NSTemporaryDirectory()
    ) async throws -> (code: Int32, output: String) {
        let result = try await NativeRecorder.capture(tool, arguments, in: directory, timeout: .seconds(300))
        return (result.code, result.output)
    }

    private nonisolated static func save(_ state: Treesitter.State) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(state).write(to: stateFile, options: .atomic)
    }
}
