import Foundation
import Testing
@testable import TrimWalk

private func repo() throws -> String {
    let root = NSTemporaryDirectory() + "trimcmd-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: root + "/src", withIntermediateDirectories: true)
    try "public class Pricing\n{\n    public int Tax() => 1;\n}\n".write(
        toFile: root + "/src/Pricing.cs",
        atomically: true,
        encoding: .utf8
    )
    for arguments in [
        ["init", "-q", "-b", "main"],
        ["add", "."],
        ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "first"],
    ] {
        _ = Git.run(arguments, in: root)
    }
    return root
}

private struct Run { var code: Int32; var out: [String]; var err: [String]; var opened: [URL] }

private func trim(_ arguments: [String], in cwd: String) -> Run {
    nonisolated(unsafe) var out: [String] = [], err: [String] = [], opened: [URL] = []
    let code = WalkCommands.run(
        arguments,
        cwd: cwd,
        out: { out.append($0) },
        err: { err.append($0) },
        open: { opened.append($0) }
    )
    return Run(code: code, out: out, err: err, opened: opened)
}

@Suite("the trim tool: what an agent runs")
struct CommandTests {
    @Test(
        "new makes a skeleton in the private folder and prints its path; a second one of the same title does not overwrite"
    )
    func make() throws {
        let root = try repo()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let one = trim(["walk", "new", "How pricing works"], in: root)
        #expect(one.code == 0)
        let path = try #require(one.out.first)
        #expect(path.hasSuffix("/.trim/walkthroughs/how-pricing-works.walk.md"))
        #expect(try String(contentsOfFile: path, encoding: .utf8).hasPrefix("---\ntitle: How pricing works"))
        #expect(trim(["walk", "new", "How pricing works"], in: root).out.first?
            .hasSuffix("how-pricing-works-2.walk.md") == true)
    }

    @Test("check exits 1 and names each problem with file and line; 0 when it is fine; --json says the same")
    func check() throws {
        let root = try repo()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "Intro.\n\n## Tax\nIt is one.\n@code Pricing.Tax\n@code src/Gone.cs:1-3\n".write(
            toFile: root + "/bad.walk.md",
            atomically: true,
            encoding: .utf8
        )
        let bad = trim(["walk", "check", "bad.walk.md"], in: root)
        #expect(bad.code == 1 && bad.out.contains("bad.walk.md:6: error: no file src/Gone.cs") && bad.out
            .last == "1 error")
        try "Intro.\n\n## Tax\nIt is one.\n@code Pricing.Tax\n".write(
            toFile: root + "/good.walk.md",
            atomically: true,
            encoding: .utf8
        )
        let good = trim(["walk", "check", "good.walk.md"], in: root)
        #expect(good.code == 0 && good.out == ["ok: 1 steps, 1 anchors"])
        #expect(trim(["walk", "check", "bad.walk.md", "--json"], in: root).out.joined().contains("\"ok\" : false"))
        #expect(trim(["walk", "check", "missing.walk.md"], in: root).code == 2)
    }

    @Test("stamp records each anchor's fingerprint and the commit, and a later change shows as a warning")
    func stamp() throws {
        let root = try repo()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "Intro.\n\n## Tax\nIt is one.\n@code Pricing.Tax\n".write(
            toFile: root + "/t.walk.md",
            atomically: true,
            encoding: .utf8
        )
        #expect(trim(["walk", "stamp", "t.walk.md"], in: root).out == ["stamped t.walk.md"])
        let stamped = try String(contentsOfFile: root + "/t.walk.md", encoding: .utf8)
        #expect(stamped.hasPrefix("---\ncreated: ") && stamped.contains("commit: ") && stamped
            .contains("@code Pricing.Tax #"))
        #expect(trim(["walk", "stamp", "t.walk.md"], in: root).out == ["nothing to stamp"])
        #expect(trim(["walk", "check", "t.walk.md"], in: root).out.last == "ok: 1 steps, 1 anchors")
        try "public class Pricing\n{\n    public int Tax() => 2;\n}\n".write(
            toFile: root + "/src/Pricing.cs",
            atomically: true,
            encoding: .utf8
        )
        #expect(trim(["walk", "check", "t.walk.md"], in: root).out
            .contains { $0.contains("warning: Pricing.Tax changed since") })
    }

    @Test(
        "list finds private and tracked walkthroughs; open asks the app through trim://walkthrough; the skill is installed"
    )
    func rest() throws {
        let root = try repo()
        defer { try? FileManager.default.removeItem(atPath: root) }
        _ = trim(["walk", "new", "Private one"], in: root)
        try "# Tracked\n## Step\n@code Pricing.Tax".write(
            toFile: root + "/docs.walk.md",
            atomically: true,
            encoding: .utf8
        )
        _ = Git.run(["add", "docs.walk.md"], in: root)
        let listed = trim(["walk", "list"], in: root).out
        #expect(listed.count == 2 && listed
            .contains { $0.hasPrefix(".trim/walkthroughs/private-one.walk.md") } && listed
            .contains { $0.hasPrefix("docs.walk.md") })
        let opened = trim(["walk", "open", "docs.walk.md"], in: root).opened
        #expect(opened.first?.scheme == "trim" && opened.first?.host == "walkthrough" && opened.first?.absoluteString
            .contains("docs.walk.md") == true)
        let skills = root + "/skills"
        #expect(trim(["skill", "install", "--dir", skills], in: root).code == 0)
        let installed = try String(contentsOfFile: skills + "/trim-walkthrough/SKILL.md", encoding: .utf8)
        #expect(installed.hasPrefix("---\nname: trim-walkthrough") && installed == WalkSkill.text)
        #expect(trim(["walk", "format"], in: root).out.first == WalkSkill.text)
        #expect(trim(["nonsense"], in: root).code == 2)
    }
}
