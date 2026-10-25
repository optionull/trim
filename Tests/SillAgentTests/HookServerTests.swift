import Foundation
@testable import SillAgent
import Testing

@Suite("hook server")
struct HookServerTests {
    final class Seen: @unchecked Sendable {
        let lock = NSLock()
        var events: [[String: Any]] = []
    }

    /// The hook command as an agent runs it: the event on stdin, through sh.
    func run(_ command: String, input: String) throws -> (output: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (output, process.terminationStatus)
    }

    @Test("an event, pretty-printed or not, reaches sill and its answer comes back")
    func roundTrip() throws {
        let seen = Seen()
        let path = NSTemporaryDirectory() + "sill-hook-test-\(UUID().uuidString.prefix(8)).sock"
        let server = HookServer(path: path) { data in
            let event = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            seen.lock.withLock { seen.events.append(event) }
            return event["hook_event_name"] as? String == "PreToolUse" ?
                Data(#"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"}}"#.utf8) :
                Data()
        }
        try server.start()
        defer { server.stop() }
        let pre = try run(server.command, input: """
        {
          "hook_event_name": "PreToolUse",
          "tool_name": "Edit",
          "tool_input": { "file_path": "/r/a.cs", "new_string": "line\\nnext" }
        }
        """)
        #expect(pre.status == 0 && pre.output.contains("\"permissionDecision\":\"deny\""), "\(pre)")
        let stop = try run(server.command, input: #"{"hook_event_name":"Stop"}"#)
        #expect(stop.status == 0 && stop.output.trimmingCharacters(in: .whitespacesAndNewlines) == "{}")
        let events = seen.lock.withLock { seen.events }
        #expect(events.count == 2)
        #expect(
            (events.first?["tool_input"] as? [String: Any])?["new_string"] as? String == "line\nnext",
            "a newline inside a string survives"
        )
    }

    @Test("no sill: the hook says nothing and succeeds")
    func absent() throws {
        let server = HookServer(path: NSTemporaryDirectory() + "sill-hook-absent.sock") { _ in Data() }
        let started = Date()
        let result = try run(server.command, input: #"{"hook_event_name":"Stop"}"#)
        #expect(result.status == 0 && result.output.isEmpty)
        #expect(Date().timeIntervalSince(started) < 1, "at once, not after the timeout")
    }
}
