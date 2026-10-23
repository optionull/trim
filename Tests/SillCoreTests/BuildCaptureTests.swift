@testable import SillCore
import Testing

@Suite("build capture")
struct BuildCaptureTests {
    @Test("MSBuild: errors and warnings, the project dropped, repeats kept once")
    func msbuild() {
        let output = """
          Determining projects to restore...
        /src/Orders/Program.cs(15,52): error CS1061: 'CreateOrder' does not contain a definition for 'Lines' [/src/Orders/Orders.csproj]
        /src/Orders/Program.cs(18,5): error CS0103: The name 'OrderMapper' does not exist in the current context [/src/Orders/Orders.csproj]
        /src/Orders/Program.cs(1,1): warning CS8019: Unnecessary using directive. [/src/Orders/Orders.csproj]
        /src/Orders/Program.cs(15,52): error CS1061: 'CreateOrder' does not contain a definition for 'Lines' [/src/Orders/Orders.csproj]
        Build FAILED.
        """
        let found = BuildCapture.diagnostics(in: output, directory: "/src/Orders")
        #expect(found.count == 3)
        #expect(found[0] == Diagnostic(
            severity: 1,
            message: "'CreateOrder' does not contain a definition for 'Lines'",
            source: "dotnet",
            code: "CS1061",
            path: "/src/Orders/Program.cs",
            buffer: 0,
            line: 15,
            col: 52
        ))
        #expect(found[2].severity == 2 && found[2].code == "CS8019")
    }

    @Test("a real path stays real: /private/tmp is not shortened to /tmp, as the language servers name it")
    func realPaths() throws {
        let folder = "/private/tmp/sill-capture-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let file = folder + "/Counter.razor"
        try "x".write(toFile: file, atomically: true, encoding: .utf8)
        let output = "\(folder)/Pages/../Counter.razor(17,9): error CS0029: Cannot convert [\(folder)/App.csproj]"
        let found = BuildCapture.diagnostics(in: output, directory: folder)
        #expect(found.map(\.path) == [file])
    }

    @Test("Swift and Cargo: file:line:col, relative paths from the folder")
    func compilers() {
        let output = """
        Sources/App/main.swift:12:9: error: cannot find 'foo' in scope
        Sources/App/main.swift:3:1: warning: variable 'x' was never used
        src/main.rs:4:5: error[E0425]: cannot find value `y` in this scope
        """
        let found = BuildCapture.diagnostics(in: output, directory: "/work")
        #expect(found.map(\.path) == [
            "/work/Sources/App/main.swift",
            "/work/Sources/App/main.swift",
            "/work/src/main.rs",
        ])
        #expect(found.map(\.severity) == [1, 2, 1])
        #expect(found[2].code == "E0425" && found[2].message == "cannot find value `y` in this scope")
    }

    @Test("tsc")
    func typescript() {
        let found = BuildCapture.diagnostics(
            in: "src/app.ts(3,7): error TS2304: Cannot find name 'foo'.", directory: "/web"
        )
        #expect(found.first?.source == "tsc" && found.first?.line == 3 && found.first?.path == "/web/src/app.ts")
    }

    @Test("lines that are not diagnostics are left alone")
    func noise() {
        let output = "Build succeeded.\n    0 Warning(s)\nCompiling foo v0.1.0 (/x)\nerror: could not compile\n"
        #expect(BuildCapture.diagnostics(in: output, directory: "/").isEmpty)
    }
}

import Foundation

@Suite("build capture against dotnet", .timeLimit(.minutes(2)))
struct DotnetBuildTests {
    @Test("a real dotnet build's error is found, at its file and line, once")
    func realBuild() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sill-build-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func run(_ command: String) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.currentDirectoryURL = folder
            var environment = ProcessInfo.processInfo.environment
            environment["DOTNET_CLI_TELEMETRY_OPTOUT"] = "1"
            environment["DOTNET_NOLOGO"] = "1"
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }
        _ = try run("dotnet new console -n Orders -o . --force")
        let program = folder.appendingPathComponent("Program.cs")
        try "var order = 1;\nConsole.WriteLine(order.Lines);\n".write(to: program, atomically: true, encoding: .utf8)
        let command = try #require(BuildCapture.command(in: folder.path))
        #expect(command.hasPrefix("dotnet build"))
        let output = try run(command)
        let found = BuildCapture.diagnostics(in: output, directory: folder.path)
        let error = try #require(found.first { $0.severity == 1 }, "\(output)")
        #expect(error.code == "CS1061" && error.line == 2)
        #expect(error.path.hasSuffix("/Program.cs"))
        #expect(found.count(where: { $0.code == "CS1061" }) == 1)
    }
}
