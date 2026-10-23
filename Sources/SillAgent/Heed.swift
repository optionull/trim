import Foundation

/// A session as heed's control socket describes it.
public struct HeedSession: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var agent: String
    /// working, idle, blocked, asking, done, limited, exited.
    public var state: String
    public var reason: String?
    public var needsYou: Bool
    /// heed's sidebar group ("Needs you", "Working", "Chats", ...).
    public var group: String
    public var directory: String?
    public var repo: String?
    public var branch: String?
    public var activity: String?
    public var lastActivity: Date?

    public init(
        id: String, title: String, agent: String, state: String, reason: String? = nil, needsYou: Bool = false,
        group: String = "", directory: String? = nil, repo: String? = nil, branch: String? = nil,
        activity: String? = nil, lastActivity: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.agent = agent
        self.state = state
        self.reason = reason
        self.needsYou = needsYou
        self.group = group
        self.directory = directory
        self.repo = repo
        self.branch = branch
        self.activity = activity
        self.lastActivity = lastActivity
    }
}

/// A request to heed: `sessions`, `watch`, `start`, `send` or `show`.
public struct HeedRequest: Codable, Equatable, Sendable {
    public var id: Int?
    public var method: String
    public var session: String?
    public var directory: String?
    public var agent: String?
    public var prompt: String?
    public var arguments: [String]?
    public var text: String?
    public var focus: Bool?

    public init(
        method: String, session: String? = nil, directory: String? = nil, agent: String? = nil,
        prompt: String? = nil, arguments: [String]? = nil, text: String? = nil, focus: Bool? = nil
    ) {
        self.method = method
        self.session = session
        self.directory = directory
        self.agent = agent
        self.prompt = prompt
        self.arguments = arguments
        self.text = text
        self.focus = focus
    }

    public static func start(directory: String, prompt: String, agent: String?, arguments: [String]) -> HeedRequest {
        HeedRequest(method: "start", directory: directory, agent: agent, prompt: prompt, arguments: arguments)
    }

    public static func send(_ session: String, _ text: String) -> HeedRequest {
        HeedRequest(method: "send", session: session, text: text)
    }

    public static func show(_ session: String, focus: Bool) -> HeedRequest {
        HeedRequest(method: "show", session: session, focus: focus)
    }
}

public struct HeedReply: Codable, Equatable, Sendable {
    public var id: Int?
    public var ok: Bool
    public var error: String?
    public var session: String?
    public var sessions: [HeedSession]?
    public var event: String?
}

public enum HeedError: Error, CustomStringConvertible, Equatable {
    case notRunning
    case refused(String, session: String?)
    case broken(String)

    public var description: String {
        switch self {
        case .notRunning: "heed is not running"
        case let .refused(message, _): message
        case let .broken(message): "heed: \(message)"
        }
    }
}

/// heed's control socket (heed owns agent sessions; sill shows a thin view over them, plan §7): one-shot requests,
/// and a watch that keeps the session list current and reconnects when heed comes and goes. Blocking socket work
/// runs on threads of its own, never the caller's.
public final class Heed: @unchecked Sendable {
    /// `HEED_CONTROL`, else `~/Library/Application Support/Heed/control.sock`.
    public static func socketPath(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let path = environment["HEED_CONTROL"], !path.isEmpty { return path }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Heed/control.sock").path
    }

    public let path: String
    private let lock = NSLock()
    private var watching = false
    private var watchFD: Int32 = -1

    public init(path: String = Heed.socketPath()) {
        self.path = path
    }

    deinit { stopWatching() }

    /// Sends one request on a connection of its own and returns heed's reply; a refusal throws `.refused`.
    public func call(_ request: HeedRequest, timeout: TimeInterval = 10) async throws -> HeedReply {
        let path = path
        // On a thread of its own: a blocking read in the cooperative pool can starve the tasks it waits on.
        let reply: HeedReply = try await withCheckedThrowingContinuation { continuation in
            Thread {
                continuation.resume(with: Result {
                    let connection = try Connection(path: path, timeout: timeout)
                    var request = request
                    request.id = 1
                    try connection.write(request)
                    while true {
                        let reply = try connection.next()
                        if reply.id == 1 { return reply }
                    }
                })
            }.start()
        }
        guard reply.ok else { throw HeedError.refused(reply.error ?? "heed said no", session: reply.session) }
        return reply
    }

    /// Calls `onChange` with the session list now and whenever it changes, and with nil while heed is not running
    /// (it tries again every `retry` seconds). Callbacks come on a background thread.
    public func watch(retry: TimeInterval = 3, _ onChange: @escaping @Sendable ([HeedSession]?) -> Void) {
        lock.withLock { watching = true }
        let thread = Thread { [weak self] in
            // nil until the first attempt: the first failure is reported, then only a connection that went away.
            var connected: Bool?
            while let self, lock.withLock({ self.watching }) {
                do {
                    let connection = try Connection(path: path, timeout: nil)
                    lock.withLock { self.watchFD = connection.fd }
                    var request = HeedRequest(method: "watch")
                    request.id = 1
                    try connection.write(request)
                    while true {
                        let reply = try connection.next()
                        if let sessions = reply.sessions {
                            connected = true
                            onChange(sessions)
                        }
                    }
                } catch {
                    lock.withLock { self.watchFD = -1 }
                    if connected != false {
                        connected = false
                        onChange(nil)
                    }
                }
                Thread.sleep(forTimeInterval: retry)
            }
        }
        thread.name = "sill.heed.watch"
        thread.start()
    }

    public func stopWatching() {
        lock.withLock {
            watching = false
            if watchFD >= 0 { shutdown(watchFD, SHUT_RDWR) }
        }
    }
}

/// One blocking connection to the socket, one JSON object a line each way.
final class Connection {
    let fd: Int32
    private var pending = Data()

    init(path: String, timeout: TimeInterval?) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HeedError.broken("socket: \(String(cString: strerror(errno)))") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else {
            close(fd)
            throw HeedError.broken("socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            throw HeedError.notRunning
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        if let timeout {
            var limit = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000))
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        }
        self.fd = fd
    }

    deinit { close(fd) }

    func write(_ request: HeedRequest) throws {
        var data = try JSONEncoder().encode(request)
        data.append(0x0A)
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard written == data.count else { throw HeedError.broken("write failed") }
    }

    func next() throws -> HeedReply {
        while true {
            if let newline = pending.firstIndex(of: 0x0A) {
                let line = Data(pending[pending.startIndex ..< newline])
                pending.removeSubrange(pending.startIndex ... newline)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                do {
                    return try decoder.decode(HeedReply.self, from: line)
                } catch {
                    throw HeedError.broken("unreadable reply: \(String(decoding: line.prefix(120), as: UTF8.self))")
                }
            }
            var buffer = [UInt8](repeating: 0, count: 65536)
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN { throw HeedError.broken("no reply in time") }
            guard count > 0 else { throw HeedError.broken("heed closed the connection") }
            pending.append(contentsOf: buffer[0 ..< count])
        }
    }
}
