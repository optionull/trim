import Foundation
@testable import SillAgent
import Testing

/// An agent's end of the bridge: `nc -U <socket>`, as the MCP config tells agents to run it.
final class Bridge: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var lines: [[String: Any]] = []
    private var buffer = Data()

    init(_ path: String) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        process.arguments = ["-U", path]
        process.standardInput = input
        process.standardOutput = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.received(handle.availableData)
        }
        try process.run()
    }

    private func received(_ data: Data) {
        lock.withLock {
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex ..< newline]
                buffer = Data(buffer[buffer.index(after: newline)...])
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { lines.append(object) }
            }
        }
    }

    func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    /// The reply to request `id`.
    func reply(_ id: Int, timeout: TimeInterval = 5) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let found = lock.withLock({ lines.first { ($0["id"] as? Int) == id } }) { return found }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw McpError.socket(-1)
    }

    var received: [[String: Any]] { lock.withLock { lines } }

    func close() { process.terminate() }
}

@Suite("sill's MCP server", .serialized, .timeLimit(.minutes(1)))
struct McpServerTests {
    private func server(_ tools: [Tool]) throws -> McpServer {
        let path = "/tmp/sill-test-\(UUID().uuidString.prefix(8)).sock"
        let server = McpServer(path: path, tools: tools, instructions: "sill's tools")
        try server.start()
        return server
    }

    private let echo = Tool(
        name: "echo",
        description: "Says it back",
        properties: ["text": ["type": "string"]],
        required: ["text"]
    ) { arguments in
        struct Arguments: Decodable { var text: String }
        guard let decoded = try? JSONDecoder().decode(Arguments.self, from: arguments) else {
            return ToolResult("no text", isError: true)
        }
        return ToolResult(decoded.text)
    }

    @Test("initialize, list the tools, call one, through nc -U")
    func handshake() async throws {
        let server = try server([echo])
        defer { server.stop() }
        let bridge = try Bridge(server.path)
        defer { bridge.close() }

        try bridge.send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
            "protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "test", "version": "1"],
        ]])
        let initialized = try await bridge.reply(1)["result"] as? [String: Any]
        #expect(initialized?["protocolVersion"] as? String == "2025-06-18")
        #expect((initialized?["serverInfo"] as? [String: Any])?["name"] as? String == "sill")
        try bridge.send(["jsonrpc": "2.0", "method": "notifications/initialized"])

        try bridge.send(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let tools = try await bridge.reply(2)["result"] as? [String: Any]
        let listed = (tools?["tools"] as? [[String: Any]])?.first
        #expect(listed?["name"] as? String == "echo")
        #expect(((listed?["inputSchema"] as? [String: Any])?["required"] as? [String]) == ["text"])

        try bridge.send(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": [
            "name": "echo",
            "arguments": ["text": "héllo"],
        ]])
        let called = try await bridge.reply(3)["result"] as? [String: Any]
        #expect(((called?["content"] as? [[String: Any]])?.first?["text"] as? String) == "héllo")
        #expect(called?["isError"] as? Bool == false)
        #expect(bridge.received.count == 3, "the notification got no reply")
    }

    @Test("an unknown tool or method is an error, and the server goes on")
    func errors() async throws {
        let server = try server([echo])
        defer { server.stop() }
        let bridge = try Bridge(server.path)
        defer { bridge.close() }
        try bridge.send(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "nope"]])
        #expect(try await ((bridge.reply(1))["error"] as? [String: Any])?["code"] as? Int == -32602)
        try bridge.send(["jsonrpc": "2.0", "id": 2, "method": "resources/list"])
        #expect(try await ((bridge.reply(2))["error"] as? [String: Any])?["code"] as? Int == -32601)
        try bridge.send(["jsonrpc": "2.0", "id": 3, "method": "ping"])
        #expect(try await bridge.reply(3)["result"] != nil)
    }

    @Test("a slow tool does not hold up a fast one")
    func concurrent() async throws {
        let slow = Tool(name: "slow", description: "Takes a while") { _ in
            try? await Task.sleep(for: .seconds(2))
            return ToolResult("slow done")
        }
        let server = try server([slow, echo])
        defer { server.stop() }
        let bridge = try Bridge(server.path)
        defer { bridge.close() }
        try bridge.send(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "slow"]])
        try bridge.send(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": [
            "name": "echo",
            "arguments": ["text": "fast"],
        ]])
        let started = Date()
        _ = try await bridge.reply(2)
        #expect(Date().timeIntervalSince(started) < 1, "the fast answer came first")
        _ = try await bridge.reply(1, timeout: 5)
    }

    @Test("only this user can open the socket")
    func permissions() throws {
        let server = try server([echo])
        defer { server.stop() }
        let mode = try FileManager.default.attributesOfItem(atPath: server.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }
}
