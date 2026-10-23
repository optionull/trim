import Foundation

/// A tool's answer: text for the agent, and whether the call failed.
public struct ToolResult: Sendable, Equatable {
    public var text: String
    public var isError: Bool

    public init(_ text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }
}

/// A tool an agent can call: its name, what it does, the JSON schema of its arguments, and what runs. The handler
/// gets the arguments as JSON.
public struct Tool: Sendable {
    public var name: String
    public var description: String
    public var schema: [String: any Sendable]
    public var handler: @Sendable (Data) async -> ToolResult

    public init(
        name: String, description: String, properties: [String: [String: String]] = [:], required: [String] = [],
        handler: @escaping @Sendable (Data) async -> ToolResult
    ) {
        self.name = name
        self.description = description
        schema = ["type": "object", "properties": properties, "required": required]
        self.handler = handler
    }
}

/// sill's MCP server (plan §7): JSON-RPC, one message a line, on a Unix socket. An agent reaches it as an ordinary
/// stdio MCP server through `nc -U <socket>`, so nothing needs installing. Each connection is read on a thread of its
/// own and each call runs as it comes, so one agent's long build does not hold up another's question.
public final class McpServer: @unchecked Sendable {
    public let path: String
    private let tools: [String: Tool]
    private let order: [String]
    private let instructions: String
    private var listener: Int32 = -1
    private let lock = NSLock()
    private var connections = 0

    public init(path: String, tools: [Tool], instructions: String) {
        self.path = path
        self.tools = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        order = tools.map(\.name)
        self.instructions = instructions
    }

    /// The MCP config an agent CLI takes (`claude --mcp-config <file>`): the server as `nc -U <socket>`.
    public var clientConfig: [String: Any] {
        ["mcpServers": ["sill": ["command": "/usr/bin/nc", "args": ["-U", path]]]]
    }

    public var connectionCount: Int { lock.withLock { connections } }

    public func start() throws {
        unlink(path)
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { throw McpError.socket(errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw McpError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes.map { UInt8(bitPattern: $0) })
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(socket, 8) == 0 else {
            close(socket)
            throw McpError.socket(errno)
        }
        // Only this user may connect.
        chmod(path, 0o600)
        listener = socket
        Thread.detachNewThread { [weak self] in self?.accept() }
    }

    public func stop() {
        if listener >= 0 { close(listener) }
        listener = -1
        unlink(path)
    }

    private func accept() {
        while listener >= 0 {
            let client = Darwin.accept(listener, nil, nil)
            guard client >= 0 else { return }
            lock.withLock { connections += 1 }
            Thread.detachNewThread { [weak self] in
                self?.serve(client)
                close(client)
                self?.lock.withLock { self?.connections -= 1 }
            }
        }
    }

    private func serve(_ client: Int32) {
        let writer = LineWriter(client)
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(client, &chunk, chunk.count)
            guard count > 0 else { return }
            buffer.append(contentsOf: chunk[0 ..< count])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex ..< newline]
                buffer = Data(buffer[buffer.index(after: newline)...])
                guard !line.isEmpty, let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
                else { continue }
                let id = message["id"].map(JSONValue.init)
                let method = message["method"] as? String ?? ""
                let params = message["params"] as? [String: Any] ?? [:]
                let arguments = (try? JSONSerialization.data(withJSONObject: params["arguments"] ?? [String: Any]())) ??
                    Data("{}".utf8)
                let requested = params["protocolVersion"] as? String
                let toolName = params["name"] as? String
                Task { [weak self] in
                    guard let self, let id else { return } // A notification (initialized, cancelled) needs no answer.
                    let reply = await answer(
                        method: method,
                        protocolVersion: requested,
                        tool: toolName,
                        arguments: arguments
                    )
                    var response: [String: Any] = ["jsonrpc": "2.0", "id": id.value]
                    switch reply {
                    case let .success(result): response["result"] = result
                    case let .failure(error): response["error"] = ["code": error.code, "message": error.message]
                    }
                    writer.write(response)
                }
            }
        }
    }

    private struct RpcError: Error {
        var code: Int
        var message: String
    }

    private func answer(method: String, protocolVersion: String?, tool: String?, arguments: Data) async
        -> Result<Any, RpcError>
    {
        switch method {
        case "initialize":
            return .success([
                "protocolVersion": protocolVersion ?? "2025-06-18",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "sill", "version": "0.1"],
                "instructions": instructions,
            ])
        case "ping":
            return .success([String: Any]())
        case "tools/list":
            return .success(["tools": order.compactMap { tools[$0] }.map { tool in
                ["name": tool.name, "description": tool.description, "inputSchema": tool.schema] as [String: Any]
            }])
        case "tools/call":
            guard let name = tool, let found = tools[name] else {
                return .failure(RpcError(code: -32602, message: "sill has no tool \(tool ?? "")"))
            }
            let result = await found.handler(arguments)
            return .success(["content": [["type": "text", "text": result.text]], "isError": result.isError])
        default:
            return .failure(RpcError(code: -32601, message: "sill does not answer \(method)"))
        }
    }
}

public enum McpError: Error, Equatable {
    case socket(Int32)
    case pathTooLong(String)
}

/// A JSON-RPC id, carried back as it came.
private struct JSONValue: @unchecked Sendable {
    let value: Any
    init(_ value: Any) { self.value = value }
}

/// Writes whole lines to a socket, one at a time.
private final class LineWriter: @unchecked Sendable {
    private let socket: Int32
    private let lock = NSLock()

    init(_ socket: Int32) { self.socket = socket }

    func write(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        lock.withLock {
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(socket, raw.baseAddress! + offset, raw.count - offset)
                    if written <= 0 { return }
                    offset += written
                }
            }
        }
    }
}
