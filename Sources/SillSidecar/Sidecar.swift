import Foundation
import SillNvim

/// The sidecar's first line: the protocol version and what it runs on.
public struct SidecarReady: Decodable, Sendable, Equatable {
    public var `protocol`: Int
    public var runtime: String
    public var processId: Int

    public init(protocol: Int, runtime: String, processId: Int) {
        self.protocol = `protocol`
        self.runtime = runtime
        self.processId = processId
    }
}

public enum SidecarError: Error, CustomStringConvertible, Equatable {
    /// No `dotnet` was found; sill runs its sidecar on the user's own .NET.
    case noDotnet(searched: [String])
    case noSidecar(String)
    case protocolVersion(Int)
    case timedOut(String)
    /// The sidecar exited; what it last wrote to standard error.
    case exited(status: Int32, stderr: String)
    /// The request failed on the sidecar's side.
    case failed(method: String, message: String)
    case notRunning

    public var description: String {
        switch self {
        case let .noDotnet(searched):
            "sill runs its .NET sidecar on your dotnet, and none was found (looked in \(searched.joined(separator: ", "))). " +
                "Install the .NET SDK, or set SILL_DOTNET to the dotnet to use."
        case let .noSidecar(path): "the sidecar is missing: \(path)"
        case let .protocolVersion(version): "the sidecar speaks protocol \(version); sill speaks \(Sidecar.protocolVersion)"
        case let .timedOut(what): "the sidecar did not \(what) in time"
        case let .exited(status, stderr): "the sidecar exited (\(status)): \(stderr)"
        case let .failed(method, message): "\(method) failed in the sidecar: \(message)"
        case .notRunning: "the sidecar is not running"
        }
    }
}

/// sill's .NET sidecar: `dotnet Sill.Sidecar.dll` on the user's own dotnet, one JSON object a line each way.
///
/// Requests go out with an id; replies come back by id, in any order, as partial results and then a result or an
/// error. The protocol is adapted from Passenger's project host; the C# side is `sidecar/Sill.Sidecar`.
public actor Sidecar {
    public static let protocolVersion = 1

    private var process: Process?
    private var input: FileHandle?
    private var nextId = 1
    /// Each request from when it is written until its reply is taken: the reply may come before anyone waits for it.
    private var slots: [Int: Slot] = [:]
    private var partials: [Int: @Sendable (Data) -> Void] = [:]
    private var readyWaiter: CheckedContinuation<Data, Error>?
    private var buffer = Data()
    private var stderrTail = ""
    private var exitError: SidecarError?

    public init() {}

    /// The dotnet to run the sidecar on: `SILL_DOTNET`, `DOTNET_ROOT`, the login shell's PATH, then the usual places.
    public static func findDotnet(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        var searched: [String] = []
        func usable(_ path: String) -> URL? {
            searched.append(path)
            return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        if let explicit = environment["SILL_DOTNET"], let found = usable(explicit) { return found }
        if let root = environment["DOTNET_ROOT"], let found = usable("\(root)/dotnet") { return found }
        if let path = NvimProcess.findInPath("dotnet", in: NvimProcess.cachedEnv["PATH"]) {
            return URL(fileURLWithPath: path)
        }
        searched.append("the login shell's PATH")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for candidate in ["/usr/local/share/dotnet/dotnet", "/opt/homebrew/bin/dotnet", "\(home)/.dotnet/dotnet"] {
            if let found = usable(candidate) { return found }
        }
        throw SidecarError.noDotnet(searched: searched)
    }

    /// Starts the sidecar and waits for its first line.
    @discardableResult
    public func start(dll: URL, dotnet: URL? = nil, timeout: Duration = .seconds(15)) async throws -> SidecarReady {
        guard FileManager.default.fileExists(atPath: dll.path) else { throw SidecarError.noSidecar(dll.path) }
        let dotnet = try dotnet ?? Self.findDotnet()
        let process = Process()
        process.executableURL = dotnet
        process.arguments = [dll.path]
        var environment = NvimProcess.cachedEnv
        environment["DOTNET_CLI_TELEMETRY_OPTOUT"] = "1"
        environment["DOTNET_NOLOGO"] = "1"
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        // One task reads each pipe, in order; a task per chunk could run out of order and tear a line. The exit is
        // handled after standard output's last line, so replies written just before it are not lost.
        let (lines, linesIn) = AsyncStream<Data>.makeStream()
        let (errors, errorsIn) = AsyncStream<Data>.makeStream()
        let (exits, exitsIn) = AsyncStream<Int32>.makeStream()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                linesIn.finish()
            } else {
                linesIn.yield(data)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                errorsIn.finish()
            } else {
                errorsIn.yield(data)
            }
        }
        process.terminationHandler = { process in
            exitsIn.yield(process.terminationStatus)
            exitsIn.finish()
        }
        Task { [weak self] in
            for await data in errors {
                await self?.receivedError(data)
            }
        }
        Task { [weak self] in
            for await data in lines {
                await self?.received(data)
            }
            var status: Int32 = -1
            for await code in exits {
                status = code
            }
            await self?.exited(status)
        }
        try process.run()
        self.process = process
        input = stdin.fileHandleForWriting

        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.failReady(.timedOut("say it was ready"))
        }
        defer { timer.cancel() }
        let data = try await withCheckedThrowingContinuation { readyWaiter = $0 }
        let ready = try JSONDecoder().decode(SidecarReady.self, from: data)
        guard ready.protocol == Self.protocolVersion else {
            stop()
            throw SidecarError.protocolVersion(ready.protocol)
        }
        return ready
    }

    private struct Slot {
        var method: String
        var waiting: CheckedContinuation<Data, Error>?
        var reply: Result<Data, Error>?
    }

    /// Sends a request and waits for its result. `onPartial` gets each partial result as it comes, in order.
    public func request<Result: Decodable>(
        _ method: String, _ params: some Encodable, as _: Result.Type = Result.self,
        onPartial: (@Sendable (Data) -> Void)? = nil
    ) async throws -> Result {
        let id = try send(method, params, onPartial: onPartial)
        return try await JSONDecoder().decode(Result.self, from: reply(to: id))
    }

    /// Sends a request and returns its id at once, so it can be cancelled; `reply(to:)` waits for its result.
    public func send(_ method: String, _ params: some Encodable, onPartial: (@Sendable (Data) -> Void)? = nil) throws
        -> Int
    {
        if let exitError { throw exitError }
        guard let input else { throw SidecarError.notRunning }
        let id = nextId
        nextId += 1
        let line = try Self.line(id: id, method: method, params: params)
        slots[id] = Slot(method: method)
        if let onPartial { partials[id] = onPartial }
        do {
            try input.write(contentsOf: line)
        } catch {
            slots[id] = nil
            partials[id] = nil
            throw error
        }
        return id
    }

    /// The raw result of a request sent with `send`.
    public func reply(to id: Int) async throws -> Data {
        guard let slot = slots[id] else { throw SidecarError.notRunning }
        if let reply = slot.reply {
            slots[id] = nil
            return try reply.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            slots[id]?.waiting = continuation
        }
    }

    /// Asks the sidecar to end a running request; it then answers that request with `cancelled`.
    public func cancel(_ id: Int) async throws {
        struct Params: Encodable { var request: Int }
        _ = try await request("cancel", Params(request: id), as: Bool.self)
    }

    /// Closes the sidecar's input, which ends it.
    public func stop() {
        try? input?.close()
        input = nil
        let process = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process?.isRunning == true { process?.terminate() }
        }
    }

    static func line(id: Int, method: String, params: some Encodable) throws -> Data {
        var data = try JSONEncoder().encode(SidecarRequest(id: id, method: method, params: params))
        data.append(0x0A)
        return data
    }

    // MARK: Replies

    private func received(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex ..< newline]
            buffer = Data(buffer[buffer.index(after: newline)...])
            if !line.isEmpty { handle(Data(line)) }
        }
    }

    /// One reply: `{id, partial}`, `{id, result}` or `{id, error}`. Id 0 is the ready line.
    private func handle(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let id = object["id"] as? Int else { return }
        if id == 0 {
            let result = object["result"].flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
            readyWaiter?.resume(returning: result)
            readyWaiter = nil
            return
        }
        if let partial = object["partial"], let data = try? Self.json(partial) {
            partials[id]?(data)
            return
        }
        guard let slot = slots[id] else { return }
        partials[id] = nil
        let reply: Result<Data, Error> = if let error = object["error"] as? String {
            .failure(SidecarError.failed(method: slot.method, message: error))
        } else {
            .success((try? Self.json(object["result"] ?? NSNull())) ?? Data("null".utf8))
        }
        settle(id, reply)
    }

    private static func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
    }

    private func receivedError(_ data: Data) {
        stderrTail = String((stderrTail + String(decoding: data, as: UTF8.self)).suffix(2000))
    }

    private func exited(_ status: Int32) {
        let error = SidecarError.exited(
            status: status,
            stderr: stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        exitError = error
        input = nil
        failReady(error)
        for id in slots.keys {
            settle(id, .failure(error))
        }
        partials.removeAll()
    }

    /// A reply for request `id`: to whoever waits for it, or kept until someone does.
    private func settle(_ id: Int, _ reply: Result<Data, Error>) {
        guard let slot = slots[id], slot.reply == nil else { return }
        if let waiting = slot.waiting {
            slots[id] = nil
            waiting.resume(with: reply)
        } else {
            slots[id]?.reply = reply
        }
    }

    private func failReady(_ error: SidecarError) {
        readyWaiter?.resume(throwing: error)
        readyWaiter = nil
    }
}

/// One request line: `{id, method, params}`.
struct SidecarRequest<Params: Encodable>: Encodable {
    var id: Int
    var method: String
    var params: Params
}
