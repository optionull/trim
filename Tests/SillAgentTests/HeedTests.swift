import Foundation
@testable import SillAgent
import Testing

/// A stand-in for heed's control socket: answers each request with `reply`, and after a watch sends `events`.
private final class FakeHeed: @unchecked Sendable {
    let path = "/tmp/sill-heed-\(UUID().uuidString.prefix(8)).sock"
    private var listener: Int32 = -1
    private(set) var requests: [HeedRequest] = []
    private let lock = NSLock()

    init(reply: @escaping @Sendable (HeedRequest) -> String, events: [String] = []) throws {
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 8) == 0 else { throw HeedError.broken("bind") }
        let listener = listener
        Thread {
            while true {
                let fd = accept(listener, nil, nil)
                guard fd >= 0 else { return }
                Thread {
                    let connection = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                    var pending = Data()
                    while true {
                        let chunk = connection.availableData
                        guard !chunk.isEmpty else { return }
                        pending.append(chunk)
                        while let newline = pending.firstIndex(of: 0x0A) {
                            let line = pending[pending.startIndex ..< newline]
                            pending.removeSubrange(pending.startIndex ... newline)
                            guard let request = try? JSONDecoder().decode(HeedRequest.self, from: Data(line))
                            else { continue }
                            self.lock.withLock { self.requests.append(request) }
                            var out = reply(request)
                            if request.method == "watch" { out += events.joined() }
                            connection.write(Data(out.utf8))
                        }
                    }
                }.start()
            }
        }.start()
    }

    var seen: [HeedRequest] { lock.withLock { requests } }

    func stop() {
        shutdown(listener, SHUT_RDWR)
        close(listener)
        unlink(path)
    }
}

struct HeedTests {
    private static let asking = """
    {"id":1,"ok":true,"sessions":[{"id":"s1","title":"Fix the build","agent":"claude","state":"asking",\
    "needsYou":true,"group":"Needs you","directory":"/w","lastActivity":"2026-10-23T15:42:18Z"}]}

    """

    @Test func aStartCarriesTheMcpArguments() async throws {
        let heed = try FakeHeed { _ in "{\"id\":1,\"ok\":true,\"session\":\"new\"}\n" }
        defer { heed.stop() }
        let reply = try await Heed(path: heed.path).call(.start(
            directory: "/w", prompt: "fix", agent: "claude", arguments: ["--mcp-config", "/tmp/m.json"]
        ))
        #expect(reply.session == "new")
        #expect(heed.seen.first?.arguments == ["--mcp-config", "/tmp/m.json"])
        #expect(heed.seen.first?.method == "start")
    }

    @Test func aRefusalThrowsWithItsSession() async throws {
        let heed = try FakeHeed { _ in
            "{\"id\":1,\"ok\":false,\"error\":\"Fix already works there\",\"session\":\"s1\"}\n"
        }
        defer { heed.stop() }
        await #expect(throws: HeedError.refused("Fix already works there", session: "s1")) {
            try await Heed(path: heed.path).call(.send("s1", "hi"))
        }
    }

    @Test func notRunningIsSaidPlainly() async {
        await #expect(throws: HeedError.notRunning) {
            try await Heed(path: "/tmp/sill-no-heed-\(UUID().uuidString.prefix(6)).sock").call(.show("x", focus: true))
        }
    }

    @Test func aWatchReportsTheListAndItsChanges() async throws {
        let working = Self.asking.replacingOccurrences(of: "\"id\":1,", with: "\"event\":\"sessions\",")
            .replacingOccurrences(of: "\"asking\"", with: "\"working\"")
            .replacingOccurrences(of: "\"needsYou\":true", with: "\"needsYou\":false")
        let heed = try FakeHeed(reply: { _ in Self.asking }, events: [working])
        defer { heed.stop() }
        let client = Heed(path: heed.path)
        let lists = try await withThrowingTaskGroup(of: [[HeedSession]?].self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    let seen = Seen()
                    client.watch { sessions in
                        if let all = seen.add(sessions), all.count == 2 { continuation.resume(returning: all) }
                    }
                }
            }
            let result = try await group.next() ?? []
            client.stopWatching()
            return result
        }
        #expect(lists.first??.first?.needsYou == true)
        #expect(lists.last??.first?.state == "working")
    }

    @Test func aWatchSaysWhenHeedIsNotThere() async {
        let client = Heed(path: "/tmp/sill-no-heed-\(UUID().uuidString.prefix(6)).sock")
        let first: [HeedSession]?? = await withCheckedContinuation { continuation in
            let once = Seen()
            client.watch(retry: 0.05) { sessions in
                if let all = once.add(sessions), all.count == 1 { continuation.resume(returning: sessions) }
            }
        }
        client.stopWatching()
        #expect(first == .some(nil))
    }
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var lists: [[HeedSession]?] = []

    /// Adds a list and returns all so far.
    func add(_ list: [HeedSession]?) -> [[HeedSession]?]? {
        lock.withLock {
            lists.append(list)
            return lists
        }
    }
}
