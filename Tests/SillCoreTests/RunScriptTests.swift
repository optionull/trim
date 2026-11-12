import Foundation
import SillCore
import Testing

@Suite("a run's script")
struct RunScriptTests {
    /// Runs the script for `command` with sh, as the terminal does; returns what it printed and how it ended.
    func run(_ command: String, folder: String = "") throws -> (output: String, result: RunScript.Result?) {
        let runs = NSTemporaryDirectory() + "sill-runs-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: runs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: runs) }
        let (script, result) = RunScript.paths(name: "hello", directory: folder, in: runs)
        try RunScript.script(command: command, folder: folder, result: result)
            .write(toFile: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", RunScript.line(script: script)]
        process.currentDirectoryURL = URL(fileURLWithPath: runs)
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), RunScript.result(result))
    }

    @Test("it shows the command, runs it, and writes how it ended")
    func passes() throws {
        let (output, result) = try run("echo 'it ran'")
        #expect(output.contains("$ echo 'it ran'") && output.contains("it ran\n"))
        #expect(result?.code == 0 && result?.passed == true)
        #expect(abs((result?.at ?? .distantPast).timeIntervalSinceNow) < 10)
    }

    @Test("a failing command: its exit code kept")
    func fails() throws {
        let (_, result) = try run("sh -c 'exit 3'")
        #expect(result?.code == 3 && result?.passed == false)
    }

    @Test("from its folder, with a space in its name")
    func folder() throws {
        let folder = NSTemporaryDirectory() + "sill run " + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let (output, result) = try run("pwd", folder: folder)
        #expect(output.contains(URL(fileURLWithPath: folder).lastPathComponent))
        #expect(result?.code == 0)
    }

    @Test("no result file, or a torn one: no result")
    func missing() {
        #expect(RunScript.result("/nonexistent/x.result") == nil)
    }
}
