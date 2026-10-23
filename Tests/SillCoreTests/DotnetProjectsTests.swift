import Foundation
@testable import SillCore
import Testing

@Suite("runnable .NET projects")
struct DotnetProjectsTests {
    @Test("programs and web apps are runnable; libraries, tests and build output are not")
    func runnable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sill-projects-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func project(_ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try project("src/Api/Api.csproj", "<Project Sdk=\"Microsoft.NET.Sdk.Web\"></Project>")
        try project(
            "src/Tool/Tool.csproj",
            "<Project><PropertyGroup><OutputType>Exe</OutputType></PropertyGroup></Project>"
        )
        try project("src/Core/Core.csproj", "<Project Sdk=\"Microsoft.NET.Sdk\"></Project>")
        try project(
            "tests/Api.Tests/Api.Tests.csproj",
            "<Project><PropertyGroup><OutputType>Exe</OutputType></PropertyGroup>" +
                "<PackageReference Include=\"Microsoft.NET.Test.Sdk\" /></Project>"
        )
        try project("src/Tool/bin/Copy/Copy.csproj", "<OutputType>Exe</OutputType>")
        let found = DotnetProjects.runnable(in: root.path).map { String($0.dropFirst(root.path.count + 1)) }
        #expect(found == ["src/Api/Api.csproj", "src/Tool/Tool.csproj"])
        #expect(DotnetProjects.pick(in: root.path, near: root.path + "/src/Tool/Program.cs")?
            .hasSuffix("Tool.csproj") == true)
        #expect(DotnetProjects.pick(in: root.path)?.hasSuffix("Api.csproj") == true)
    }
}
