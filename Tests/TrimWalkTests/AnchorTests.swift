import Foundation
import Testing
@testable import TrimWalk

/// A throwaway git repository with a small C# file in it.
private func fixture() throws -> String {
    let root = NSTemporaryDirectory() + "trimwalk-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: root + "/src", withIntermediateDirectories: true)
    try """
    namespace Orders;

    public class Pricing
    {
        public decimal Total(Order order)
        {
            var sum = 0m;
            foreach (var line in order.Lines) { sum += line.Price; }
            return sum;
        }

        public decimal Tax(decimal amount) => amount * 0.2m;
    }
    """.write(toFile: root + "/src/Pricing.cs", atomically: true, encoding: .utf8)
    for arguments in [
        ["init", "-q", "-b", "main"],
        ["add", "."],
        ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "first"],
    ] {
        _ = Git.run(arguments, in: root)
    }
    return root
}

@Suite("anchors: where the code is, and whether it moved")
struct AnchorTests {
    @Test("a file anchor reads its lines, clamped to the file")
    func file() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let resolver = AnchorResolver(root: root)
        guard case let .found(found) = resolver.resolve(.file("src/Pricing.cs", lines: 3 ... 5))
        else { Issue.record("not found"); return }
        #expect(found.lines == 3 ... 5 && found.text.first == "public class Pricing" && found.by == "path")
        guard case let .found(clamped) = resolver.resolve(.file("src/Pricing.cs", lines: 10 ... 900))
        else { Issue.record("not found"); return }
        #expect(clamped.lines.upperBound == 13)
        #expect(resolver.resolve(.file("src/Nope.cs", lines: nil)) == .problem("no file src/Nope.cs"))
    }

    @Test("a symbol is found by its declaration, with the lines of its braces; `lines a-b` counts from its first")
    func symbol() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let resolver = AnchorResolver(root: root)
        guard case let .found(total) = resolver.resolve(.symbol("Pricing.Total", lines: nil))
        else { Issue.record("not found"); return }
        #expect(total.by == "text" && total.lines == 5 ... 10 && total.text.last == "    }")
        guard case let .found(part) = resolver.resolve(.symbol("Pricing.Total", lines: 3 ... 4))
        else { Issue.record("not found"); return }
        #expect(part.lines == 7 ... 8)
        guard case let .found(tax) = resolver.resolve(.symbol("Pricing.Tax", lines: nil))
        else { Issue.record("not found"); return }
        #expect(tax.lines == 12 ... 12, "an arrow body ends at its semicolon")
        #expect(resolver
            .resolve(.symbol("Nothing.Here", lines: nil)) == .problem("no declaration of Nothing.Here found"))
        #expect(
            resolver.resolve(.symbol("Orders.Total", lines: nil)) != .problem("x"),
            "a wrong container is not an error of the format"
        )
    }

    @Test("a language server's answer is used before any text is read")
    func servers() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let resolver = AnchorResolver(
            root: root,
            symbols: { name in name == "Pricing.Tax" ? (root + "/src/Pricing.cs", 5, "roslyn") : nil }
        )
        guard case let .found(found) = resolver.resolve(.symbol("Pricing.Tax", lines: nil))
        else { Issue.record("not found"); return }
        #expect(found.by == "roslyn" && found.lines == 5 ... 10)
    }

    @Test("fresh while the lines are the same, changed when they are not, orphaned when the anchor is gone")
    func freshness() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let resolver = AnchorResolver(root: root)
        guard case let .found(now) = resolver.resolve(.symbol("Pricing.Tax", lines: nil))
        else { Issue.record("not found"); return }
        let recorded = Walkthrough.fingerprint(now.text)
        #expect(Freshness.of(recorded: recorded, now: now) == .fresh)
        #expect(Freshness.of(recorded: "0000000", now: now) == .changed)
        #expect(Freshness.of(recorded: recorded, now: nil) == .orphaned)
        #expect(Freshness.of(recorded: nil, now: now) == .unchecked)
        #expect(Freshness.of(recorded: recorded, now: nil, searched: false) == .unchecked)
    }

    @Test(
        "the check names what an author can fix: a missing file, a diagram of no kind, a step with no code, a changed anchor"
    )
    func check() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let source = """
        # Pricing

        How a total is made.

        ## Total
        Adds the lines up.
        @code Pricing.Total #0000000
        @code src/Missing.cs:1-5

        ## Flow
        ```mermaid
        wibble
        ```
        @link Nowhere -> Pricing.Tax

        ## Prose only
        Nothing to see.
        """
        let report = WalkCheck.run(source, resolver: AnchorResolver(root: root))
        #expect(!report.ok && report.steps == 3 && report.title == "Pricing")
        let messages = report.problems.map(\.message)
        #expect(messages.contains("Pricing.Total changed since the walkthrough was written"))
        #expect(messages.contains("no file src/Missing.cs"))
        #expect(messages.contains("unknown diagram type `wibble`"))
        #expect(messages.contains("the diagram above has no node `Nowhere`"))
        #expect(messages.contains(#"step "Prose only" shows no code: anchor it with @code"#))
        #expect(WalkCheck.run("no steps here", resolver: AnchorResolver(root: root)).problems.first?.message
            .hasPrefix("no steps") == true)
        let good = WalkCheck.run(
            "# Tax\n\nIntro.\n\n## Tax\nIt is a fifth.\n@code Pricing.Tax",
            resolver: AnchorResolver(root: root)
        )
        #expect(good.ok && good.problems.isEmpty && good.anchors == 1)
        let untitled = WalkCheck.run("Intro.\n\n## Tax\nIt.\n@code Pricing.Tax", resolver: AnchorResolver(root: root))
        #expect(untitled.ok && untitled.problems.contains { $0.message.hasPrefix("no `# Title`") })
        #expect(good.json().contains("\"ok\" : true"))
    }
}

@Suite("where walkthroughs live")
struct DiscoveryTests {
    @Test("those in .trim/walkthroughs and any *.walk.md git knows, newest first; .trim is kept out of git")
    func find() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "# A tracked tour\n## Step\n@code Pricing.Tax".write(
            toFile: root + "/docs.walk.md",
            atomically: true,
            encoding: .utf8
        )
        _ = Git.run(["add", "docs.walk.md"], in: root)
        let folder = TrimFolder.path(for: root)
        try "---\ntitle: Written by an agent\nby: claude\n---\nIntro\n## Step".write(
            toFile: folder + "/walkthroughs/agent.walk.md", atomically: true, encoding: .utf8
        )
        let found = WalkFiles.find(in: root)
        #expect(Set(found.map(\.relative)) == [".trim/walkthroughs/agent.walk.md", "docs.walk.md"])
        let agent = try #require(found.first { $0.isPrivate })
        #expect(agent.title == "Written by an agent" && agent.by == "claude")
        let exclude = try String(contentsOfFile: root + "/.git/info/exclude", encoding: .utf8)
        #expect(exclude.contains("/.trim/"))
        #expect(Git.run(["status", "--porcelain"], in: root)?.contains(".trim") != true, "git does not see the folder")
        TrimFolder.path(for: root)
        #expect(
            try String(contentsOfFile: root + "/.git/info/exclude", encoding: .utf8).components(separatedBy: "/.trim/")
                .count == 2,
            "the line is added once"
        )
    }
}
