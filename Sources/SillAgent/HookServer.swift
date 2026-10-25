import Foundation

/// Where agent hooks reach sill: a unix socket taking one event per connection, as the hook command sends it (the
/// hook's JSON on one line), answered with the hook's output (JSON) and closed. The hook command is `nc` with a short
/// timeout and `|| true`, so an agent never waits on, or fails for, a sill that is not running.
public final class HookServer: @unchecked Sendable {
    public let path: String
    /// The event's JSON in, the hook's output (JSON) out.
    private let handle: @Sendable (Data) async -> Data
    private var listener: Int32 = -1

    public init(path: String, handle: @escaping @Sendable (Data) async -> Data) {
        self.path = path
        self.handle = handle
    }

    /// The command a hook runs: its input, on one line, to the socket; the answer, printed; nothing when sill is
    /// not there.
    public var command: String {
        "{ tr -d '\\n'; echo; } | /usr/bin/nc -U -w 2 '\(path)' 2>/dev/null || true"
    }

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
        guard bound == 0, listen(socket, 16) == 0 else {
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
            Thread.detachNewThread { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while !buffer.contains(0x0A) {
            let count = read(client, &chunk, chunk.count)
            guard count > 0 else { break }
            buffer.append(contentsOf: chunk[0 ..< count])
        }
        let line = Data(buffer.split(separator: 0x0A, maxSplits: 1, omittingEmptySubsequences: true).first ?? Data())
        let handle = handle
        let done = DispatchSemaphore(value: 0)
        let reply = Reply()
        Task {
            if !line.isEmpty { reply.value = await handle(line) }
            done.signal()
        }
        // An answer within the hook's own patience; else none (an empty object is no decision).
        _ = done.wait(timeout: .now() + 1.5)
        var data = reply.value.isEmpty ? Data("{}".utf8) : reply.value
        data.append(0x0A)
        _ = data.withUnsafeBytes { write(client, $0.baseAddress, data.count) }
        close(client)
    }

    private final class Reply: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = Data()
        var value: Data {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }
}
