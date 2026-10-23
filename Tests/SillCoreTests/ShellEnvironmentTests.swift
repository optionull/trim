import Foundation
@testable import SillNvim
import Testing

@Suite("the login shell's environment")
struct ShellEnvironmentTests {
    /// A "shell" that writes the marker and its environment, then leaves a process holding its output open, as a
    /// profile starting a daemon does.
    private func shell(_ body: String) throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("sill-shell-\(UUID().uuidString)").path
        try "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    @Test("a process left holding the shell's output does not hang the capture")
    func heldOutput() throws {
        // The capture runs `shell -l +m -c "echo <marker> && env"`: $4 is that command.
        let path = try shell("( sleep 30 ) &\neval \"$4\"")
        let started = Date()
        let environment = NvimProcess.captureShellEnvironment(shellArgs: ["-l"], shell: path)
        #expect(Date().timeIntervalSince(started) < 4, "returned without waiting for the held output")
        #expect(environment["PATH"] != nil)
    }

    @Test("a shell that never finishes is cut off after a few seconds")
    func stuckShell() throws {
        let path = try shell("sleep 60")
        let started = Date()
        let environment = NvimProcess.captureShellEnvironment(shellArgs: ["-l"], shell: path)
        #expect(Date().timeIntervalSince(started) < 8)
        #expect(environment == ProcessInfo.processInfo.environment, "falls back to the app's own")
    }
}
