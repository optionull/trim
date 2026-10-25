import SillCore
import Testing

@Suite("code map")
struct CodeMapTests {
    static let files: [String: String] = [
        "src/Shop.Web/Shop.Web.csproj": """
        <Project Sdk="Microsoft.NET.Sdk.Web">
          <ItemGroup><ProjectReference Include="..\\Shop.Core\\Shop.Core.csproj" /></ItemGroup>
        </Project>
        """,
        "src/Shop.Web/Program.cs": "var builder = WebApplication.CreateBuilder(args);\nvar app = builder.Build();\n" +
            "app.MapGet(\"/\", () => 1);\n",
        "src/Shop.Cli/Shop.Cli.csproj": """
        <Project Sdk="Microsoft.NET.Sdk">
          <PropertyGroup><OutputType>Exe</OutputType></PropertyGroup>
          <ItemGroup><ProjectReference Include="../Shop.Core/Shop.Core.csproj" />
          <ProjectReference Include="../Missing/Missing.csproj" /></ItemGroup>
        </Project>
        """,
        "src/Shop.Cli/Cli.cs": "namespace Shop;\n\nstatic class Cli\n{\n    static async Task<int> Main(string[] a) => 0;\n}\n",
        "src/Shop.Core/Shop.Core.csproj": "<Project Sdk=\"Microsoft.NET.Sdk\"></Project>",
        "src/Shop.Core/Pricing.cs": "class Pricing\n{\n}\n",
        "src/Shop.Core/Orders/Order.cs": "record Order;\n",
        "tests/Shop.Tests/Shop.Tests.csproj": """
        <Project Sdk="Microsoft.NET.Sdk">
          <ItemGroup><PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.0.0" />
          <ProjectReference Include="..\\..\\src\\Shop.Core\\Shop.Core.csproj" /></ItemGroup>
        </Project>
        """,
        "tests/Shop.Tests/PricingTests.cs": "class PricingTests {}\n",
        "tools/Package.swift": """
        let package = Package(name: "tools", targets: [
            .executableTarget(name: "probe", dependencies: ["ProbeKit", .product(name: "Args", package: "args")]),
            .target(name: "ProbeKit", path: "Kit"),
            .testTarget(name: "ProbeKitTests", dependencies: [.target(name: "ProbeKit")]),
        ])
        """,
        "tools/Sources/probe/main.swift": "print(1)\n",
        "tools/Kit/Probe.swift": "struct Probe {}\n",
        "tools/Tests/ProbeKitTests/ProbeTests.swift": "import Testing\n",
        "README.md": "# Shop\n",
        "src/Shop.Ui/Shop.Ui.csproj": "<Project Sdk=\"Microsoft.NET.Sdk.Razor\"></Project>",
        "src/Shop.Ui/package.json": "{ \"name\": \"shop-ui\" }",
        "tests/Shop.Checks/Shop.Checks.csproj": "<Project Sdk=\"Microsoft.NET.Sdk\"></Project>",
        "src/Shop.Core.Specs/Shop.Core.Specs.csproj": "<Project Sdk=\"Microsoft.NET.Sdk\"></Project>",
        "src/Shop.Core/Tax.cs": "class Tax {}\n",
        "src/Shop.Core/Discount.cs": "class Discount {}\n",
    ]

    static func map(changes: [String: Int] = [:]) -> CodeMap {
        CodeMap.build(name: "shop", files: files.keys.sorted(), changes: changes) { files[$0] }
    }

    func project(_ map: CodeMap, _ name: String) throws -> CodeMap.Project {
        try #require(map.projects.first { $0.name == name })
    }

    @Test(".NET projects: their kind, references and files; Swift targets alike")
    func projects() throws {
        let map = Self.map()
        #expect(map.projects.map(\.name) == [
            "ProbeKit", "ProbeKitTests", "Shop.Checks", "Shop.Cli", "Shop.Core", "Shop.Core.Specs", "Shop.Tests",
            "Shop.Ui", "Shop.Web", "probe",
        ], "shop-ui's package.json holds no files of its own")
        let web = try project(map, "Shop.Web"), cli = try project(map, "Shop.Cli"), core = try project(map, "Shop.Core")
        let tests = try project(map, "Shop.Tests"), kitTests = try project(map, "ProbeKitTests")
        #expect(web.kind == .web && cli.kind == .app && core.kind == .library && tests.kind == .test)
        #expect(try project(map, "Shop.Ui").kind == .library, "a Razor class library")
        #expect(try project(map, "Shop.Checks").kind == .test, "a test project by its folder")
        #expect(try project(map, "Shop.Core.Specs").kind == .test, "a test project by its name")
        #expect(
            web.references == ["Shop.Core"] && cli.references == ["Shop.Core"],
            "a reference to no project is dropped"
        )
        #expect(tests.references == ["Shop.Core"])
        #expect(core.files == 5 && core.lines == 6 && core.folder == "src/Shop.Core")
        let probe = try project(map, "probe"), kit = try project(map, "ProbeKit")
        #expect(probe.kind == .app && probe.references == ["ProbeKit"] && kit.folder == "tools/Kit" && kit.files == 1)
        #expect(kitTests.kind == .test && kitTests.references == ["ProbeKit"])
        #expect(map.otherFiles == 2, "README.md and Package.swift are in no project")
    }

    @Test("the order git lists files in does not matter: a project file wins its folder over a manifest")
    func order() {
        let reversed = CodeMap.build(name: "shop", files: Self.files.keys.sorted().reversed()) { Self.files[$0] }
        #expect(reversed == Self.map())
    }

    @Test("entry points: Main, a web host, a main.swift")
    func entryPoints() throws {
        let map = Self.map()
        let web = try project(map, "Shop.Web"), cli = try project(map, "Shop.Cli"), probe = try project(map, "probe")
        #expect(web.entryPoints == [.init(path: "src/Shop.Web/Program.cs", line: 1, label: "web host")])
        #expect(cli.entryPoints == [.init(path: "src/Shop.Cli/Cli.cs", line: 5, label: "Main")])
        #expect(probe.entryPoints == [.init(path: "tools/Sources/probe/main.swift", line: 1, label: "main.swift")])
        #expect(try project(map, "Shop.Core").entryPoints.isEmpty == true)
    }

    @Test("rows: each project above what it references, tests last")
    func layers() {
        let map = Self.map()
        let rows = map.layers.map { $0.map { map.projects[$0].name } }
        #expect(rows == [
            ["Shop.Cli", "Shop.Web", "probe"], ["ProbeKit", "Shop.Core", "Shop.Ui"],
            ["ProbeKitTests", "Shop.Checks", "Shop.Core.Specs", "Shop.Tests"],
        ])
    }

    @Test("hot files: the three changed most, per project; the map as text")
    func hotAndText() throws {
        let changes = [
            "src/Shop.Core/Pricing.cs": 9, "src/Shop.Core/Orders/Order.cs": 2, "src/Shop.Core/Shop.Core.csproj": 4,
            "src/Shop.Core/Tax.cs": 1, "src/Shop.Core/Discount.cs": 1,
            "src/Shop.Web/Program.cs": 1, "README.md": 30,
        ]
        let map = Self.map(changes: changes)
        let core = try project(map, "Shop.Core")
        let reversed = CodeMap.build(name: "shop", files: Self.files.keys.sorted().reversed(), changes: changes) {
            Self.files[$0]
        }
        #expect(reversed == map, "the same whatever order git lists files in")
        #expect(core.hot.map(\.path) == [
            "src/Shop.Core/Pricing.cs", "src/Shop.Core/Orders/Order.cs", "src/Shop.Core/Discount.cs",
        ], "source files only, three, the most first and then by name")
        let text = map.text
        #expect(text.hasPrefix("Code map of shop: 10 projects, 20 files."))
        #expect(text.contains("""
        - Shop.Web [web, C#] src/Shop.Web/Shop.Web.csproj: 2 files, 3 lines; references Shop.Core
          starts: src/Shop.Web/Program.cs:1 (web host)
          changes most: src/Shop.Web/Program.cs (1)
        """))
        #expect(text.contains(
            "  changes most: src/Shop.Core/Pricing.cs (9), src/Shop.Core/Orders/Order.cs (2), src/Shop.Core/Discount.cs (1)"
        ))
        #expect(text.range(of: "- Shop.Web")!.lowerBound < text.range(of: "- Shop.Core [")!.lowerBound)
        #expect(text.range(of: "- Shop.Core [")!.lowerBound < text.range(of: "- Shop.Tests")!.lowerBound)
    }
}
