import Foundation
@testable import SillCore
import Testing

@Suite("project files and file nesting")
struct ProjectFilesTests {
    @Test("nesting: code behind, a configuration's file, designer and generated code, minified, the lock file")
    func nesting() {
        let names = [
            "Counter.razor", "Counter.razor.cs", "Counter.razor.css", "Index.cshtml", "Index.cshtml.cs",
            "appsettings.json", "appsettings.Development.json", "Form.cs", "Form.Designer.cs", "Api.g.cs", "Api.cs",
            "site.js", "site.min.js", "package.json", "package-lock.json", "Program.cs", "Program.Tests.cs",
            "Orphan.razor.cs", "settings.Development.json",
        ]
        #expect(FileNesting.parents(of: names) == [
            "Counter.razor.cs": "Counter.razor", "Counter.razor.css": "Counter.razor",
            "Index.cshtml.cs": "Index.cshtml", "appsettings.Development.json": "appsettings.json",
            "Form.Designer.cs": "Form.cs", "Api.g.cs": "Api.cs", "site.min.js": "site.js",
            "package-lock.json": "package.json",
        ])
    }

    @Test("a project's DependentUpon nests a file, and wins over the rules")
    func explicit() {
        let parents = FileNesting.parents(
            of: ["Grammar.y", "Grammar.cs", "Counter.razor", "Counter.razor.cs"],
            explicit: ["Grammar.cs": "Grammar.y", "Counter.razor.cs": "Counter.razor"]
        )
        #expect(parents == ["Grammar.cs": "Grammar.y", "Counter.razor.cs": "Counter.razor"])
    }

    @Test("a project file: its kind, what it removes, what it nests")
    func project() {
        let text = """
        <Project Sdk="Microsoft.NET.Sdk.Web">
          <ItemGroup>
            <Compile Remove="Legacy/**" />
            <None Remove="scratch/*.txt;notes.md" />
            <Compile Update="Grammar.cs" DependentUpon="Grammar.y" />
            <None Update="Data\\seed.json">
              <CopyToOutputDirectory>Always</CopyToOutputDirectory>
              <DependentUpon>seed.schema.json</DependentUpon>
            </None>
          </ItemGroup>
        </Project>
        """
        let project = ProjectFile(path: "/w/src/Api/Api.csproj", text: text)
        #expect(project.kind == .web)
        #expect(project.name == "Api")
        #expect(project.removes("/w/src/Api/Legacy/Old/Thing.cs"))
        #expect(project.removes("/w/src/Api/scratch/a.txt"))
        #expect(!project.removes("/w/src/Api/scratch/deeper/a.txt"))
        #expect(project.removes("/w/src/Api/notes.md"))
        #expect(!project.removes("/w/src/Api/Program.cs"))
        #expect(project.dependentUpon == ["Grammar.cs": "Grammar.y", "Data/seed.json": "seed.schema.json"])
        #expect(ProjectFile(path: "/t/T.csproj", text: "<PackageReference Include=\"Microsoft.NET.Test.Sdk\" />")
            .kind == .test)
        #expect(ProjectFile(path: "/l/L.csproj", text: "<Project Sdk=\"Microsoft.NET.Sdk\" />").kind == .library)
    }

    @Test("globs: ** any folders, * a name, ? a character")
    func globs() {
        #expect(Glob.matches("**/*.cs", "a/b/c.cs"))
        #expect(Glob.matches("**/*.cs", "c.cs"))
        #expect(!Glob.matches("*.cs", "a/c.cs"))
        #expect(Glob.matches("bin/**", "bin/Debug/x.dll"))
        #expect(Glob.matches("file?.txt", "file1.txt"))
    }
}
