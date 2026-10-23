import Foundation
@testable import SillCore
import Testing

@Suite("the .slnx: drift from the disk, and sync")
struct SlnxTests {
    /// A repo on disk: two projects, a config file, a readme at the root.
    private func repo() throws -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sill-slnx-\(UUID().uuidString)").path
        for file in [
            "src/Api/Api.csproj", "src/tooling/Cli/Cli.csproj", "config/navigation.yml", "CONTRIBUTING.md", "build.sh",
        ] {
            let path = (root as NSString).appendingPathComponent(file)
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
            )
            try "x".write(toFile: path, atomically: true, encoding: .utf8)
        }
        return root
    }

    private let solution = """
    <Solution>
      <Configurations>
        <Platform Name="Any CPU" />
      </Configurations>
      <Folder Name="/root/">
        <File Path="CONTRIBUTING.MD" />
        <File Path="build.sh" />
      </Folder>
      <Folder Name="/src/">
        <Project Path="src/Api/Api.csproj" />
        <Project Path="src/tooling/Cli/Cli.csproj">
          <Build Project="false" />
        </Project>
        <File Path="config/navigation.yml" />
      </Folder>
      <!-- gone -->
      <Folder Name="/old/">
        <File Path="old/notes.md" />
      </Folder>
    </Solution>

    """

    @Test("drift: a case that differs, a project and a file in the wrong folder, a file not on disk")
    func drift() throws {
        let root = try repo()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let found = try Slnx(text: solution).drift(in: root)
        #expect(found == [
            .init(path: "CONTRIBUTING.MD", kind: .caseDiffers(actual: "CONTRIBUTING.md")),
            .init(path: "src/tooling/Cli/Cli.csproj", kind: .misplaced(from: "/src/", to: "/src/tooling/")),
            .init(path: "config/navigation.yml", kind: .misplaced(from: "/src/", to: "/config/")),
            .init(path: "old/notes.md", kind: .missing),
        ])
        #expect(Slnx.line(of: "config/navigation.yml", in: solution) == 14)
    }

    @Test("sync: each in its folder, the rest where it was, comments kept, nothing added")
    func sync() throws {
        let root = try repo()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let synced = try Slnx(text: solution).synced(in: root)
        #expect(synced.text == """
        <Solution>
          <Configurations>
            <Platform Name="Any CPU" />
          </Configurations>
          <Folder Name="/config/">
            <File Path="config/navigation.yml" />
          </Folder>
          <Folder Name="/root/">
            <File Path="CONTRIBUTING.md" />
            <File Path="build.sh" />
          </Folder>
          <Folder Name="/src/">
            <Project Path="src/Api/Api.csproj" />
          </Folder>
          <Folder Name="/src/tooling/">
            <Project Path="src/tooling/Cli/Cli.csproj">
              <Build Project="false" />
            </Project>
          </Folder>
          <!-- gone -->
          <Folder Name="/old/">
            <File Path="old/notes.md" />
          </Folder>
        </Solution>

        """)
        #expect(synced.drift(in: root) == [.init(path: "old/notes.md", kind: .missing)])
        #expect(try Slnx(text: synced.text) == synced, "it reads back as written")
        #expect(synced.synced(in: root) == synced, "a synced solution stays as it is")
    }

    @Test("the rule: a project in its directory's parent folder, a file in its own, the root's in /root/")
    func rule() {
        #expect(Slnx.folder(for: "src/tooling/docs-builder/docs-builder.csproj", isProject: true) == "/src/tooling/")
        #expect(Slnx.folder(for: "App/App.csproj", isProject: true) == nil)
        #expect(Slnx.folder(for: "config/navigation.yml", isProject: false) == "/config/")
        #expect(Slnx.folder(for: "global.json", isProject: false) == "/root/")
        #expect(Slnx.folder(for: "src\\Api\\Api.csproj", isProject: true) == "/src/")
    }

    @Test("an unreadable solution says why")
    func unreadable() {
        #expect(throws: SlnxError.self) { try Slnx(text: "<Solution><Folder>") }
    }
}
