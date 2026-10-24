import Foundation

/// The Debug Adapter Protocol's client end (M8): a debug adapter run as a process (`dotnet Sill.DebugAdapter.dll`),
/// its messages framed with Content-Length on its standard input and output. Requests are answered by sequence number;
/// events stream out in order; a request from the adapter (runInTerminal) is refused, so it keeps the program's output
/// as
/// events.
public actor DapClient {
    public struct Event: Sendable {
        public var event: String
        /// The event's body as JSON (`{}` when it has none).
        public var body: Data

        public func decode<T: Decodable>(_: T.Type) throws -> T { try JSONDecoder().decode(T.self, from: body) }
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case refused(command: String, message: String)
        case ended

        public var description: String {
            switch self {
            case let .refused(command, message): "\(command): \(message)"
            case .ended: "the debug adapter ended"
            }
        }
    }

    public nonisolated let events: AsyncStream<Event>
    private let eventSink: AsyncStream<Event>.Continuation
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var sequence = 0
    private var waiting: [Int: CheckedContinuation<Data, Error>] = [:]
    private var ended = false

    public init() {
        (events, eventSink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    /// Starts the adapter: `dotnet` running `adapter`, with `environment` over the process's own.
    public func start(dotnet: URL, adapter: String, environment: [String: String]) throws {
        let process = Process()
        process.executableURL = dotnet
        process.arguments = [adapter, "--interpreter=vscode"]
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            Task { await self.received(data) }
        }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            Task { await self.exited() }
        }
        try process.run()
        self.process = process
        input = stdin.fileHandleForWriting
    }

    /// Sends a request and waits for its response's body (`{}` when it has none); a failed one throws `.refused`.
    @discardableResult
    public func request(_ command: String, _ arguments: some Encodable & Sendable) async throws -> Data {
        guard !ended, let input else { throw Failure.ended }
        sequence += 1
        let id = sequence
        let message = Request(seq: id, command: command, arguments: arguments)
        let body = try JSONEncoder().encode(message)
        return try await withCheckedThrowingContinuation { continuation in
            waiting[id] = continuation
            do {
                try input.write(contentsOf: Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body)
            } catch {
                waiting[id] = nil
                continuation.resume(throwing: error)
            }
        }
    }

    public func request<T: Decodable & Sendable>(
        _ command: String, _ arguments: some Encodable & Sendable, as _: T.Type
    ) async throws -> T {
        try await JSONDecoder().decode(T.self, from: request(command, arguments))
    }

    /// Ends the adapter (and with it a program it launched).
    public func stop() {
        process?.terminate()
    }

    private struct Request<Arguments: Encodable>: Encodable {
        var seq: Int
        var type = "request"
        var command: String
        var arguments: Arguments
    }

    private func received(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let header = buffer.range(of: Data("\r\n\r\n".utf8)) {
            let head = String(decoding: buffer[buffer.startIndex ..< header.lowerBound], as: UTF8.self)
            guard let length = head.split(separator: "\r\n").compactMap({ line -> Int? in
                let parts = line.split(separator: ":", maxSplits: 1)
                return parts.count == 2 && parts[0].lowercased() == "content-length"
                    ? Int(parts[1].trimmingCharacters(in: .whitespaces)) : nil
            }).first else {
                buffer.removeSubrange(buffer.startIndex ..< header.upperBound)
                continue
            }
            guard buffer.distance(from: header.upperBound, to: buffer.endIndex) >= length else { return }
            let end = buffer.index(header.upperBound, offsetBy: length)
            let message = Data(buffer[header.upperBound ..< end])
            buffer.removeSubrange(buffer.startIndex ..< end)
            handle(message)
        }
    }

    private func handle(_ message: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
              let type = object["type"] as? String else { return }
        let body = object["body"].flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data("{}".utf8)
        switch type {
        case "response":
            guard let id = object["request_seq"] as? Int, let continuation = waiting.removeValue(forKey: id) else {
                return
            }
            if object["success"] as? Bool == true {
                continuation.resume(returning: body)
            } else {
                continuation.resume(throwing: Failure.refused(
                    command: object["command"] as? String ?? "?",
                    message: object["message"] as? String ?? "failed"
                ))
            }
        case "event":
            eventSink.yield(Event(event: object["event"] as? String ?? "?", body: body))
        case "request":
            // runInTerminal and the like: the program runs with its output as events instead.
            if let seq = object["seq"] as? Int, let input {
                sequence += 1
                let reply: [String: Any] = [
                    "seq": sequence, "type": "response", "request_seq": seq, "success": false,
                    "command": object["command"] as? String ?? "?",
                    "message": "sill does not run programs in a terminal",
                ]
                if let data = try? JSONSerialization.data(withJSONObject: reply) {
                    try? input.write(contentsOf: Data("Content-Length: \(data.count)\r\n\r\n".utf8) + data)
                }
            }
        default:
            break
        }
    }

    private func exited() {
        ended = true
        for continuation in waiting.values {
            continuation.resume(throwing: Failure.ended)
        }
        waiting = [:]
        eventSink.finish()
    }
}

/// The protocol's shapes sill reads.
public enum Dap {
    public struct Source: Codable, Sendable, Equatable {
        public var path: String?
        public var name: String?

        public init(path: String?, name: String? = nil) {
            self.path = path
            self.name = name
        }
    }

    public struct StackFrame: Decodable, Sendable, Equatable {
        public var id: Int
        public var name: String
        public var source: Source?
        public var line: Int
        public var column: Int?
    }

    public struct StackTrace: Decodable, Sendable { public var stackFrames: [StackFrame] }

    public struct Scope: Decodable, Sendable, Equatable {
        public var name: String
        public var variablesReference: Int
    }

    public struct Scopes: Decodable, Sendable { public var scopes: [Scope] }

    public struct Variable: Decodable, Sendable, Equatable {
        public var name: String
        public var value: String
        public var type: String?
        public var variablesReference: Int
    }

    public struct Variables: Decodable, Sendable { public var variables: [Variable] }

    public struct Breakpoint: Decodable, Sendable, Equatable {
        public var id: Int?
        public var verified: Bool
        public var line: Int?
        public var message: String?
    }

    public struct Breakpoints: Decodable, Sendable { public var breakpoints: [Breakpoint] }

    public struct Stopped: Decodable, Sendable, Equatable {
        public var reason: String
        public var threadId: Int?
        public var description: String?
        public var text: String?
    }

    public struct Output: Decodable, Sendable {
        public var category: String?
        public var output: String
    }

    public struct Exited: Decodable, Sendable { public var exitCode: Int }

    public struct Thread: Decodable, Sendable { public var id: Int; public var name: String }

    public struct Threads: Decodable, Sendable { public var threads: [Thread] }

    /// The arguments of most requests: free-form JSON.
    public struct Arguments: Encodable, Sendable {
        private let fields: [String: Value]

        public init(_ fields: [String: Value] = [:]) { self.fields = fields }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(fields)
        }
    }

    public indirect enum Value: Encodable, Sendable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
        ExpressibleByBooleanLiteral
    {
        case string(String), int(Int), bool(Bool), array([Value]), object([String: Value])

        public init(stringLiteral value: String) { self = .string(value) }
        public init(integerLiteral value: Int) { self = .int(value) }
        public init(booleanLiteral value: Bool) { self = .bool(value) }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case let .string(value): try container.encode(value)
            case let .int(value): try container.encode(value)
            case let .bool(value): try container.encode(value)
            case let .array(value): try container.encode(value)
            case let .object(value): try container.encode(value)
            }
        }
    }
}
