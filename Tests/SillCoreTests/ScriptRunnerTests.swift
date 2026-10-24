import SillCore
import Testing

@Suite("script runner")
struct ScriptRunnerTests {
    @Test("each language's runner, in the script's folder")
    func commands() throws {
        let cs = try ScriptRunner.command(for: "/r/examples/total.cs", scratch: "/s", has: { _ in true })
        #expect(cs.arguments == ["dotnet", "run", "/r/examples/total.cs"] && cs.directory == "/r/examples")
        #expect(try ScriptRunner.command(for: "/r/a.ts", scratch: "/s", has: { _ in true }).arguments == [
            "node",
            "/r/a.ts",
        ])
        #expect(try ScriptRunner.command(for: "/r/a.py", scratch: "/s", has: { _ in true }).arguments.prefix(2) == [
            "uv",
            "run",
        ])
        #expect(try ScriptRunner.command(for: "/r/a.py", scratch: "/s", has: { _ in false }).arguments == [
            "python3",
            "/r/a.py",
        ])
        #expect(throws: ScriptRunner.Failure.self) { try ScriptRunner.command(
            for: "/r/a.zig",
            scratch: "/s",
            has: { _ in true }
        ) }
        #expect(ScriptRunner.language(of: "x.cs") == "C#" && ScriptRunner.language(of: "x.rs") == "Rust")
    }

    @Test("cargo's script format: the manifest and the code apart")
    func cargoScript() {
        let (manifest, code) = ScriptRunner.cargoScript("""
        #!/usr/bin/env cargo
        ---cargo
        [dependencies]
        orders = { path = "../" }
        ---
        fn main() { println!("{}", orders::total(4)); }
        """)
        #expect(manifest == "[dependencies]\norders = { path = \"../\" }\n")
        #expect(code
            .trimmingCharacters(in: .whitespacesAndNewlines) == "fn main() { println!(\"{}\", orders::total(4)); }")
        #expect(ScriptRunner.cargoScript("fn main() {}").manifest.isEmpty)
    }
}
