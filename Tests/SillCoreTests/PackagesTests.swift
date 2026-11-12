import Foundation
@testable import SillCore
import Testing

@Suite("packages: the SDK's report, how one got here, and updates")
struct PackagesTests {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/Packages")

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Self.fixtures.appendingPathComponent("\(name).json"))
    }

    @Test("the SDK's answers merged: vulnerable, outdated, deprecated, up to date, worst first")
    func report() throws {
        let report = try PackageReport.read(
            all: fixture("all"), vulnerable: fixture("vulnerable"), outdated: fixture("outdated"),
            highestPatch: fixture("patch"), deprecated: fixture("deprecated")
        )
        #expect(report.packages.count == 5)
        #expect(Set(report.vulnerable.map(\.id)) == ["Newtonsoft.Json", "System.Text.Json"])
        let json = try #require(report.packages.first { $0.id == "System.Text.Json" })
        #expect(json.vulnerabilities.count == 2 && json.severity == "High")
        #expect(json.installed == "8.0.3" && json.safeUpdate == "8.0.6")
        #expect(json.projects == ["Pkgs"] && !json.transitive)
        let polly = try #require(report.packages.first { $0.id == "Polly" })
        #expect(polly.change == .major && polly.latest == "8.8.0")
        let versioning = try #require(report.packages.first { $0.id == "Microsoft.AspNetCore.Mvc.Versioning" })
        #expect(versioning.isDeprecated && versioning.alternative == "Asp.Versioning.Mvc")
        #expect(report.attention.first?.isVulnerable == true)
        #expect(
            report.attention.map(\.id).firstIndex(of: "Microsoft.AspNetCore.Mvc.Versioning")! <
                report.attention.map(\.id).firstIndex(of: "Polly")!,
            "deprecated before merely outdated"
        )
    }

    @Test("newest versions from the feed's list: stable for a stable install, the newest patch of its minor")
    func feedVersions() throws {
        let report = try PackageReport.read(
            all: fixture("all"),
            vulnerable: nil,
            outdated: nil,
            highestPatch: nil,
            deprecated: nil
        )
        .with(versions: [
            "polly": ["7.2.0", "7.2.3", "7.2.4", "7.3.0", "8.0.0", "8.8.0", "9.0.0-beta.1"],
            "serilog": ["3.1.0"],
        ])
        let polly = try #require(report.packages.first { $0.id == "Polly" })
        #expect(polly.latest == "8.8.0" && polly.highestPatch == "7.2.4" && polly.change == .major)
        let serilog = try #require(report.packages.first { $0.id == "Serilog" })
        #expect(serilog.latest == nil && serilog.highestPatch == nil && !serilog.isOutdated, "up to date")
        #expect(PackageReport
            .problems(in: Data(#"{"problems": [{"project": "/w/docs/docs.csproj", "text": "No assets"}]}"#.utf8))
            == ["docs.csproj: No assets"])
    }

    @Test("versions: numbers part by part, a prerelease first, and what kind of change")
    func versions() {
        #expect(Version.compare("8.0.10", "8.0.9") == 1)
        #expect(Version.compare("8.0.0-rc.1", "8.0.0") == -1)
        #expect(Version.change(from: "8.0.2", to: "8.0.5") == .patch)
        #expect(Version.change(from: "8.2.0", to: "8.5.0") == .minor)
        #expect(Version.change(from: "12.0.3", to: "13.0.3") == .major)
        #expect(Version.change(from: "2.0.0", to: "1.9.0") == nil)
    }

    @Test("how a transitive package got here: the shortest chain from the project's own")
    func path() throws {
        let assets = """
        {"targets": {"net11.0": {
          "Npgsql.EntityFrameworkCore.PostgreSQL/8.0.4": {"type": "package", "dependencies": {"Npgsql": "8.0.2"}},
          "Npgsql/8.0.2": {"type": "package"}, "Polly/8.2.0": {"type": "package"}}},
         "project": {"frameworks": {"net11.0": {"dependencies": {
          "Npgsql.EntityFrameworkCore.PostgreSQL": {}, "Polly": {}}}}}}
        """
        #expect(PackageGraph.path(to: "npgsql", assets: Data(assets.utf8)) ==
            ["Npgsql.EntityFrameworkCore.PostgreSQL", "Npgsql"])
        #expect(PackageGraph.path(to: "Polly", assets: Data(assets.utf8)) == ["Polly"])
        #expect(PackageGraph.path(to: "Nothing", assets: Data(assets.utf8)) == nil)
    }

    @Test("updates edit what says the version: the reference, the central file, a pin for a transitive one")
    func edits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sill-packages-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let plain = root.appendingPathComponent("plain/App.csproj")
        try FileManager.default.createDirectory(
            at: plain.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        <Project Sdk="Microsoft.NET.Sdk">
          <ItemGroup>
            <PackageReference Include="Polly" Version="7.2.0" />
            <PackageReference Version="12.0.1" Include="Newtonsoft.Json" />
            <PackageReference Include="Serilog">
              <Version>3.1.0</Version>
            </PackageReference>
          </ItemGroup>
        </Project>
        """.write(to: plain, atomically: true, encoding: .utf8)
        func applied(_ changes: [PackageEdit.Change]?) throws -> String {
            let change = try #require(changes?.first)
            return change.text
        }
        #expect(try applied(PackageEdit.update("Polly", to: "7.2.4", in: plain.path)).contains(
            "<PackageReference Include=\"Polly\" Version=\"7.2.4\" />"
        ))
        #expect(try applied(PackageEdit.update("Newtonsoft.Json", to: "13.0.4", in: plain.path)).contains(
            "<PackageReference Version=\"13.0.4\" Include=\"Newtonsoft.Json\" />"
        ))
        #expect(try applied(PackageEdit.update("Serilog", to: "3.1.1", in: plain.path))
            .contains("<Version>3.1.1</Version>"))
        let pinned = try applied(PackageEdit.update("Npgsql", to: "8.0.5", in: plain.path))
        #expect(pinned.contains("<PackageReference Include=\"Npgsql\" Version=\"8.0.5\" />\n  </ItemGroup>"))
        #expect(pinned.contains("<PackageReference Include=\"Polly\" Version=\"7.2.0\" />"), "the rest as it was")

        // Central package management: the version is the central file's.
        let central = root.appendingPathComponent("cpm")
        try FileManager.default.createDirectory(
            at: central.appendingPathComponent("src/Api"),
            withIntermediateDirectories: true
        )
        try """
        <Project>
          <ItemGroup>
            <PackageVersion Include="Polly" Version="7.2.0" />
          </ItemGroup>
        </Project>
        """.write(to: central.appendingPathComponent("Directory.Packages.props"), atomically: true, encoding: .utf8)
        let api = central.appendingPathComponent("src/Api/Api.csproj")
        try """
        <Project Sdk="Microsoft.NET.Sdk">
          <ItemGroup>
            <PackageReference Include="Polly" />
          </ItemGroup>
        </Project>
        """.write(to: api, atomically: true, encoding: .utf8)
        let update = try #require(PackageEdit.update("Polly", to: "8.8.0", in: api.path))
        #expect(update.count == 1 && update[0].path.hasSuffix("Directory.Packages.props"))
        #expect(update[0].text.contains("<PackageVersion Include=\"Polly\" Version=\"8.8.0\" />"))
        let pin = try #require(PackageEdit.update("Npgsql", to: "8.0.5", in: api.path))
        #expect(pin.map { ($0.path as NSString).lastPathComponent } == ["Directory.Packages.props", "Api.csproj"])
        #expect(pin[0].text.contains("<PackageVersion Include=\"Npgsql\" Version=\"8.0.5\" />"))
        #expect(pin[1].text.contains("<PackageReference Include=\"Npgsql\" />"))
    }
}
