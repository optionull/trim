import Foundation
import SillCore
import Testing

@Suite struct RunnablesTests {
    /// A checkout with one of each: a .NET program with two launch profiles, a library, a test project, a Swift
    /// package, a Cargo package, a package.json with a pnpm lockfile, mise tasks and a justfile.
    func fixture() throws -> String {
        let root = realPath(NSTemporaryDirectory()) + "/sill-runnables-\(UUID().uuidString)"
        func write(_ path: String, _ text: String) throws {
            let file = root + "/" + path
            try FileManager.default.createDirectory(
                atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true
            )
            try text.write(toFile: file, atomically: true, encoding: .utf8)
        }
        try write(
            "src/Shop/Shop.csproj",
            #"<Project Sdk="Microsoft.NET.Sdk.Web"><PropertyGroup></PropertyGroup></Project>"#
        )
        try write("src/Shop/Properties/launchSettings.json", #"""
        {"profiles": {"http": {"commandName": "Project"}, "https": {"commandName": "Project"},
                      "IIS Express": {"commandName": "IISExpress"}}}
        """#)
        try write("src/Lib/Lib.csproj", #"<Project Sdk="Microsoft.NET.Sdk"></Project>"#)
        try write("tests/Shop.Tests/Shop.Tests.csproj", #"""
        <Project Sdk="Microsoft.NET.Sdk"><ItemGroup><PackageReference Include="Microsoft.NET.Test.Sdk" /></ItemGroup></Project>
        """#)
        try write("tool/Package.swift", #"""
        let package = Package(name: "Tool", targets: [
            .executableTarget(name: "tool"), .target(name: "Core"), .testTarget(name: "CoreTests"),
        ])
        """#)
        try write("rust/Cargo.toml", "[package]\nname = \"crab\"\nversion = \"0.1.0\"\n")
        try write("rust/src/main.rs", "fn main() {}\n")
        try write("web/package.json", #"{"scripts": {"dev": "vite", "test": "vitest"}}"#)
        try write("web/pnpm-lock.yaml", "lockfileVersion: 9\n")
        try write("mise.toml", "[tools]\nnode = \"24\"\n\n[tasks.build]\nrun = \"x\"\n\n[tasks.test]\nrun = \"y\"\n")
        try write(
            "justfile",
            "set shell := [\"bash\"]\nversion := \"1\"\n\nserve port=\"8080\":\n  echo\n\n@lint:\n  echo\n"
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "init", "-q"]
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        try process.run()
        process.waitUntilExit()
        return root
    }

    @Test func eachEcosystemsRunnables() throws {
        let found = try Runnables.find(in: fixture())
        let byName = Dictionary(found.map { ($0.name, $0) }) { first, _ in first }
        #expect(found.map(\.name) == [
            "Shop (http)", "Shop (https)", "crab", "tool",
            "CoreTests", "Shop.Tests", "crab tests", "test", "test",
            "build", "dev", "lint", "serve",
        ])
        #expect(byName["Shop (https)"]?.command == "dotnet run --project src/Shop/Shop.csproj --launch-profile https")
        #expect(byName["Shop (https)"]?.debuggable == true && byName["Shop (https)"]?.profilable == true)
        #expect(byName["Shop.Tests"]?.command == "dotnet test tests/Shop.Tests/Shop.Tests.csproj")
        #expect(byName["Shop.Tests"]?.debuggable == false)
        #expect(byName["tool"].map { ($0.command, $0.directory) } ?? ("", "") == ("swift run tool", "tool"))
        #expect(byName["CoreTests"]?.command == "swift test --filter CoreTests")
        #expect(byName["crab"]?.command == "cargo run --bin crab" && byName["crab tests"]?.command == "cargo test")
        #expect(byName["dev"]?.command == "pnpm run dev" && byName["dev"]?.directory == "web")
        #expect(byName["build"]?.command == "mise run build")
        #expect(byName["serve"]?.command == "just serve" && byName["lint"]?.command == "just lint")
        #expect(byName["Lib"] == nil)
    }

    @Test func touchedByFilesInTheirFolder() {
        let app = Runnable(name: "Shop", kind: .app, tool: "dotnet", command: "", project: "src/Shop/Shop.csproj")
        #expect(app.touched(by: ["src/Shop/Cart.cs"]))
        #expect(!app.touched(by: ["src/Lib/Price.cs", "src/ShopX/A.cs"]))
        #expect(Runnable(name: "build", kind: .script, tool: "mise", command: "").touched(by: ["any.txt"]))
    }

    @Test func configurationsRemembered() {
        var configurations = RunConfigurations()
        configurations.ran(.init(
            name: "Shop",
            command: "dotnet run",
            directory: "",
            lastRun: Date(timeIntervalSince1970: 1)
        ))
        configurations.ran(.init(
            name: "dev",
            command: "pnpm run dev",
            directory: "web",
            lastRun: Date(timeIntervalSince1970: 2)
        ))
        configurations.ran(.init(
            name: "Shop",
            command: "dotnet run -- --port 9",
            directory: "",
            lastRun: Date(timeIntervalSince1970: 3)
        ))
        #expect(configurations.configurations.map(\.command) == ["dotnet run -- --port 9", "pnpm run dev"])
        #expect(configurations.last?.name == "Shop")
        let file = NSTemporaryDirectory() + "sill-run-\(UUID().uuidString)/run.json"
        configurations.save(file)
        #expect(RunConfigurations.load(file) == configurations)
        #expect(Runnables.quoted("it's here") == "'it'\\''s here'" && Runnables.quoted("a/b.csproj") == "a/b.csproj")
    }
}
