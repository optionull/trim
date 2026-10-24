import Foundation
@testable import SillSidecar
import Testing

/// The debug adapter, built once for the run.
enum BuiltAdapter {
    static let project = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("sidecar/Sill.DebugAdapter")

    static let dll: URL = {
        let output = project.appendingPathComponent("bin/Release/net10.0/Sill.DebugAdapter.dll")
        guard let dotnet = try? Sidecar.findDotnet() else { return output }
        let build = Process()
        build.executableURL = dotnet
        build.arguments = ["build", project.path, "-c", "Release", "-nologo", "-v", "q"]
        build.standardOutput = FileHandle.nullDevice
        guard (try? build.run()) != nil else { return output }
        build.waitUntilExit()
        return output
    }()
}

/// The debugger end to end on the sample (`Fixtures/Sample`): a breakpoint in its loop hit, the stack and locals read,
/// a step, a continue to the breakpoint's next hit.
@Suite("the debugger", .serialized, .timeLimit(.minutes(3)))
struct DebuggerTests {
    /// The next event named `name`, skipping the rest.
    private func next(_ name: String, in events: AsyncStream<DapClient.Event>.AsyncIterator, seconds: Double = 60)
        async throws -> (DapClient.Event, AsyncStream<DapClient.Event>.AsyncIterator)
    {
        var events = events
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, let event = await events.next() {
            if event.event == name { return (event, events) }
        }
        throw CancellationError()
    }

    @Test("a breakpoint hit, the stack and locals, a step, and the next hit")
    func session() async throws {
        let (sidecar, _) = try await BuiltSidecar.start()
        defer { Task { await sidecar.stop() } }
        let dbgshim = try await sidecar.dbgshim()
        #expect(FileManager.default.fileExists(atPath: dbgshim.path))

        let project = try ProfilerTests.copy()
        defer { try? FileManager.default.removeItem(at: project) }
        let build = Process()
        build.executableURL = try Sidecar.findDotnet()
        build.arguments = ["build", project.path, "-nologo", "-v", "q"]
        build.standardOutput = FileHandle.nullDevice
        try build.run()
        build.waitUntilExit()
        let program = project.appendingPathComponent("bin/Debug/net10.0/Sample.dll").path
        let source = project.appendingPathComponent("Program.cs").path
        #expect(FileManager.default.fileExists(atPath: program))

        let client = DapClient()
        try await client.start(
            dotnet: Sidecar.findDotnet(),
            adapter: BuiltAdapter.dll.path,
            environment: ["SILL_DBGSHIM": dbgshim.path]
        )
        var events = client.events.makeAsyncIterator()
        try await client.request("initialize", Dap.Arguments([
            "adapterID": "coreclr", "linesStartAt1": true, "columnsStartAt1": true, "pathFormat": "path",
        ]))
        try await client.request("launch", Dap.Arguments([
            "program": .string(program), "cwd": .string(project.path), "args": .array(["20"]),
        ]))
        (_, events) = try await next("initialized", in: events)
        let set = try await client.request("setBreakpoints", Dap.Arguments([
            "source": .object(["path": .string(source)]), "breakpoints": .array([.object(["line": 5])]),
        ]), as: Dap.Breakpoints.self)
        #expect(set.breakpoints.count == 1)
        try await client.request("configurationDone", Dap.Arguments())

        var stopped: DapClient.Event
        (stopped, events) = try await next("stopped", in: events)
        let hit = try stopped.decode(Dap.Stopped.self)
        #expect(hit.reason == "breakpoint")
        let thread = try #require(hit.threadId)
        func top() async throws -> Dap.StackFrame {
            try #require(try await client.request("stackTrace", Dap.Arguments([
                "threadId": .int(thread), "levels": 1,
            ]), as: Dap.StackTrace.self).stackFrames.first)
        }
        func locals(_ frame: Dap.StackFrame) async throws -> [String: String] {
            let scopes = try await client.request(
                "scopes",
                Dap.Arguments(["frameId": .int(frame.id)]),
                as: Dap.Scopes.self
            ).scopes
            let scope = try #require(scopes.first)
            let variables = try await client.request("variables", Dap.Arguments([
                "variablesReference": .int(scope.variablesReference),
            ]), as: Dap.Variables.self).variables
            return Dictionary(variables.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first })
        }
        let frame = try await top()
        #expect(frame.line == 5)
        #expect(frame.source?.path?.hasSuffix("Program.cs") == true)
        #expect(try await locals(frame)["i"] == "0")

        try await client.request("next", Dap.Arguments(["threadId": .int(thread)]))
        (stopped, events) = try await next("stopped", in: events)
        #expect(try stopped.decode(Dap.Stopped.self).reason == "step")

        try await client.request("continue", Dap.Arguments(["threadId": .int(thread)]))
        (stopped, events) = try await next("stopped", in: events)
        #expect(try stopped.decode(Dap.Stopped.self).reason == "breakpoint")
        #expect(try await locals(top())["i"] == "2000", "the loop went round once more")

        try await client.request("disconnect", Dap.Arguments(["terminateDebuggee": true]))
        await client.stop()
    }
}
