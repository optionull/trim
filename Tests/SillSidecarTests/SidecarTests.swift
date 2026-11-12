import Foundation
@testable import SillSidecar
import Testing

/// The C# sidecar, built once for the run.
enum BuiltSidecar {
    static let project = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("sidecar/Sill.Sidecar")

    static let dll: URL = {
        let output = project.appendingPathComponent("bin/Release/net11.0/Sill.Sidecar.dll")
        // A build that does not run leaves the dll missing, and the tests that start it say so.
        guard let dotnet = try? Sidecar.findDotnet() else { return output }
        let build = Process()
        build.executableURL = dotnet
        build.arguments = ["build", project.path, "-c", "Release", "-nologo", "-v", "q"]
        build.standardOutput = FileHandle.nullDevice
        guard (try? build.run()) != nil else { return output }
        build.waitUntilExit()
        return output
    }()

    static func start() async throws -> (Sidecar, SidecarReady) {
        let sidecar = Sidecar()
        let ready = try await sidecar.start(dll: dll)
        return (sidecar, ready)
    }
}

struct Text: Codable, Equatable {
    var text: String
}

struct CountTo: Encodable {
    var to: Int
    var delayMilliseconds: Int
}

struct Number: Decodable, Equatable {
    var number: Int
}

struct Info: Decodable {
    var runtime: String
    var runtimeDirectory: String
    var processId: Int
}

struct Empty: Encodable {}

@Suite("the .NET sidecar", .serialized, .timeLimit(.minutes(1)))
struct SidecarTests {
    @Test("handshake: the first line says the protocol and the runtime")
    func handshake() async throws {
        let (sidecar, ready) = try await BuiltSidecar.start()
        defer { Task { await sidecar.stop() } }
        #expect(ready.protocol == Sidecar.protocolVersion)
        #expect(ready.runtime.hasPrefix(".NET "))
        #expect(ready.processId > 0)
        let info = try await sidecar.request("info", Empty(), as: Info.self)
        #expect(info.processId == ready.processId)
        #expect(FileManager.default.fileExists(atPath: info.runtimeDirectory))
    }

    @Test("a round trip keeps the text, newlines and all")
    func ping() async throws {
        let (sidecar, _) = try await BuiltSidecar.start()
        defer { Task { await sidecar.stop() } }
        for text in ["hello", "two\nlines", "日本語 and \"quotes\" and \\backslashes", ""] {
            #expect(try await sidecar.request("ping", Text(text: text), as: Text.self) == Text(text: text))
        }
    }

    @Test("replies find their requests, however many run at once")
    func concurrent() async throws {
        let (sidecar, _) = try await BuiltSidecar.start()
        defer { Task { await sidecar.stop() } }
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for index in 0 ..< 200 {
                group.addTask {
                    try await sidecar.request("ping", Text(text: "n\(index)"), as: Text.self).text == "n\(index)"
                }
            }
            for try await matched in group {
                #expect(matched)
            }
        }
    }

    @Test("an unknown method fails that request, and the sidecar goes on")
    func unknownMethod() async throws {
        let (sidecar, _) = try await BuiltSidecar.start()
        defer { Task { await sidecar.stop() } }
        await #expect(throws: SidecarError.failed(method: "nope", message: "the sidecar has no method nope")) {
            try await sidecar.request("nope", Empty(), as: Text.self)
        }
        #expect(try await sidecar.request("ping", Text(text: "still here"), as: Text.self).text == "still here")
    }

    @Test("partial results come in order before the result")
    func partials() async throws {
        let (sidecar, _) = try await BuiltSidecar.start()
        defer { Task { await sidecar.stop() } }
        let seen = Seen()
        let last = try await sidecar.request("count", CountTo(to: 6, delayMilliseconds: 5), as: Number.self) { data in
            if let number = try? JSONDecoder().decode(Number.self, from: data) { seen.add(number.number) }
        }
        #expect(seen.numbers == [1, 2, 3, 4, 5])
        #expect(last.number == 6)
    }

    @Test("a running request can be cancelled")
    func cancel() async throws {
        let (sidecar, _) = try await BuiltSidecar.start()
        defer { Task { await sidecar.stop() } }
        let id = try await sidecar.send("count", CountTo(to: 10000, delayMilliseconds: 10))
        try await Task.sleep(for: .milliseconds(50))
        try await sidecar.cancel(id)
        await #expect(throws: SidecarError.failed(method: "count", message: "cancelled")) {
            try await sidecar.reply(to: id)
        }
    }

    @Test("when the sidecar dies, waiting requests fail and new ones are refused")
    func dies() async throws {
        let (sidecar, ready) = try await BuiltSidecar.start()
        let id = try await sidecar.send("count", CountTo(to: 10000, delayMilliseconds: 10))
        kill(pid_t(ready.processId), SIGKILL)
        // Waited for apart, so a reply that never comes fails the test instead of hanging it.
        let outcome = Outcome()
        Task {
            do {
                _ = try await sidecar.reply(to: id)
                outcome.set("answered")
            } catch let SidecarError.exited(status, _) {
                outcome.set(status != 0 ? "exited" : "exited 0")
            } catch {
                outcome.set("\(error)")
            }
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while outcome.value == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(outcome.value == "exited", "the waiting request: \(outcome.value ?? "never answered")")
        // Refused with the reason: the exit, not just that nothing runs.
        do {
            _ = try await sidecar.request("ping", Text(text: "x"), as: Text.self)
            Issue.record("a request was sent to a sidecar that had exited")
        } catch let SidecarError.exited(status, _) {
            #expect(status != 0)
        }
    }

    /// A stand-in for dotnet: a script that writes `line` (if any) and then waits.
    private func fakeDotnet(_ line: String?) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sill-fake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("dotnet")
        let say = line.map { "printf '%s\\n' '\($0)'\n" } ?? ""
        try "#!/bin/sh\n\(say)exec cat >/dev/null\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    @Test("a sidecar speaking another protocol is refused")
    func protocolVersion() async throws {
        let dotnet = try fakeDotnet(#"{"id":0,"result":{"protocol":2,"runtime":"fake","processId":1}}"#)
        await #expect(throws: SidecarError.protocolVersion(2)) {
            try await Sidecar().start(dll: BuiltSidecar.dll, dotnet: dotnet)
        }
    }

    @Test("a sidecar that never says it is ready times out")
    func silent() async throws {
        let dotnet = try fakeDotnet(nil)
        await #expect(throws: SidecarError.timedOut("say it was ready")) {
            try await Sidecar().start(dll: BuiltSidecar.dll, dotnet: dotnet, timeout: .milliseconds(300))
        }
    }

    @Test("SILL_DOTNET picks the dotnet; a missing sidecar says where it looked")
    func locating() async throws {
        let dotnet = try Sidecar.findDotnet()
        #expect(try Sidecar.findDotnet(environment: ["SILL_DOTNET": dotnet.path]) == dotnet)
        await #expect(throws: SidecarError.noSidecar("/nowhere/Sill.Sidecar.dll")) {
            try await Sidecar().start(dll: URL(fileURLWithPath: "/nowhere/Sill.Sidecar.dll"))
        }
    }
}

final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    var numbers: [Int] { lock.withLock { values } }
    func add(_ number: Int) { lock.withLock { values.append(number) } }
}

final class Outcome: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    var value: String? { lock.withLock { stored } }
    func set(_ value: String) { lock.withLock { stored = value } }
}
