import CryptoKit
import Foundation
import SillCore
import SillNvim

/// A native program's profile (M7): a Rust one recorded with samply, a Swift one with xctrace (Instruments' Time
/// Profiler), each built in release with line tables first, in a folder of its own so the person's own release build is
/// left alone. The recording runs until Stop (the program interrupted, as Ctrl-C would) or the program's end, then is
/// read into the profile document the profile pane draws.
@MainActor
final class NativeRecorder {
    enum Kind: String {
        case rust, swift

        var engine: String { self == .rust ? "Rust · samply" : "Swift · xctrace" }
    }

    /// The kind of program in a folder: a Cargo package, else a Swift package.
    nonisolated static func kind(in directory: String) -> Kind? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        if names.contains("Cargo.toml") { return .rust }
        if names.contains("Package.swift") { return .swift }
        return nil
    }

    let kind: Kind
    private let directory: String
    private let onOutput: @MainActor @Sendable (String) -> Void
    private let onRunning: @MainActor @Sendable (String) -> Void
    private var recorder: Process?
    private var stopped = false
    private let work: String

    init(
        kind: Kind, directory: String, onOutput: @escaping @MainActor @Sendable (String) -> Void,
        onRunning: @escaping @MainActor @Sendable (String) -> Void
    ) {
        self.kind = kind
        self.directory = directory
        self.onOutput = onOutput
        self.onRunning = onRunning
        work = (NSTemporaryDirectory() as NSString).appendingPathComponent("sill-profiles/\(UUID().uuidString)")
    }

    /// Builds, records until stopped or ended, and reads the profile.
    func record() async throws -> ProfileDocument {
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        let program = try await build()
        let name = (program as NSString).lastPathComponent
        guard !stopped else { throw RecordFailure.stopped }
        switch kind {
        case .rust:
            let samply = try await Self.samply()
            let output = (work as NSString).appendingPathComponent("profile.json")
            let exit = try await run(samply, [
                "record",
                "--save-only",
                "--unstable-presymbolicate",
                "-o",
                output,
                "--",
                program,
            ], recording: name)
            let symbols = (work as NSString).appendingPathComponent("profile.syms.json")
            let profile = try Data(contentsOf: URL(fileURLWithPath: output))
            let known = try? Data(contentsOf: URL(fileURLWithPath: symbols))
            let ended = !stopped
            return try await Task.detached {
                try SamplyProfile.document(profile: profile, symbols: known, name: name, exited: ended && exit == 0)
            }.value
        case .swift:
            let trace = (work as NSString).appendingPathComponent("profile.trace")
            _ = try await run("/usr/bin/xcrun", [
                "xctrace",
                "record",
                "--template",
                "Time Profiler",
                "--output",
                trace,
                "--target-stdout",
                "-",
                "--launch",
                "--",
                program,
            ], recording: name)
            onOutput("Reading the trace…\n")
            let xml = (work as NSString).appendingPathComponent("time-profile.xml")
            let exported = try await Self.capture("/usr/bin/xcrun", [
                "xctrace", "export", "--input", trace, "--xpath",
                "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"time-profile\"]",
            ], in: work)
            guard exported.code == 0
            else { throw RecordFailure.failed("xctrace export: \(exported.output.suffix(300))") }
            try exported.data.write(to: URL(fileURLWithPath: xml))
            let ended = !stopped
            return try await Task.detached {
                try XctraceProfile.document(xml: exported.data, name: name, exited: ended)
            }.value
        }
    }

    /// Ends the recording: the program is interrupted (samply waits for it), or xctrace is (it ends the program).
    func stop() {
        stopped = true
        guard let recorder, recorder.isRunning else { return }
        switch kind {
        case .rust:
            for child in Self.children(of: recorder.processIdentifier) {
                kill(child, SIGINT)
            }
        case .swift:
            kill(recorder.processIdentifier, SIGINT)
        }
    }

    // MARK: Building

    /// The program built in release with line tables: its path.
    private func build() async throws -> String {
        switch kind {
        case .rust:
            onOutput("cargo build (profile sill-profile: release with line tables)\n")
            let result = try await Self.capture("/usr/bin/env", [
                "cargo", "build", "--profile", "sill-profile", "--config", "profile.sill-profile.inherits=\"release\"",
                "--config", "profile.sill-profile.debug=\"line-tables-only\"",
                "--message-format=json-render-diagnostics",
            ], in: directory, errors: onOutput)
            guard result.code == 0 else { throw RecordFailure.failed("cargo build failed") }
            // The executables the build made, from its messages.
            let executables = result.output.split(separator: "\n").compactMap { line -> String? in
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      object["reason"] as? String == "compiler-artifact" else { return nil }
                return object["executable"] as? String
            }
            guard let program = executables.last else { throw RecordFailure.failed("the package has no program") }
            return program
        case .swift:
            onOutput("swift build -c release -g (in .build/sill-profile)\n")
            let scratch = ".build/sill-profile"
            let built = try await Self.capture("/usr/bin/env", [
                "swift", "build", "-c", "release", "--scratch-path", scratch, "-Xswiftc", "-g",
            ], in: directory, errors: onOutput)
            onOutput(built.output.suffix(2000) + "")
            guard built.code == 0 else { throw RecordFailure.failed("swift build failed") }
            let bin = try await Self.capture("/usr/bin/env", [
                "swift", "build", "-c", "release", "--scratch-path", scratch, "--show-bin-path",
            ], in: directory)
            let described = try await Self.capture(
                "/usr/bin/env",
                ["swift", "package", "describe", "--type", "json"],
                in: directory
            )
            let products = ((try? JSONSerialization.jsonObject(with: described.data)) as? [String: Any])?["products"]
                as? [[String: Any]] ?? []
            let executable = products.first { product in
                (product["type"] as? [String: Any])?["executable"] != nil
            }?["name"] as? String
            guard let executable else { throw RecordFailure.failed("the package has no executable product") }
            return (bin.output.trimmingCharacters(in: .whitespacesAndNewlines) as NSString)
                .appendingPathComponent(executable)
        }
    }

    // MARK: Running

    /// Runs the recorder, its output (and the program's) streamed, until it ends.
    private func run(_ tool: String, _ arguments: [String], recording name: String) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = Self.environment(directory)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let output = onOutput
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in output(text) }
        }
        recorder = process
        try process.run()
        onRunning(name)
        // Stopped while it was starting: stop it now it can be.
        if stopped { Task { try? await Task.sleep(for: .seconds(1)); stop() } }
        let code = await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        recorder = nil
        return code
    }

    nonisolated static func environment(_ directory: String) -> [String: String] {
        var environment = NvimProcess.cachedEnv
        environment["PWD"] = directory
        environment["TERM"] = "dumb"
        return environment
    }

    /// A command's whole output, off the main thread; its standard error streamed to `errors` when given. Nothing
    /// blocks a thread while it runs; one that outlives `timeout` is killed and fails, so a command that hangs (or
    /// leaves
    /// something behind holding its output open) never holds up what waits on it.
    nonisolated static func capture(
        _ tool: String, _ arguments: [String], in directory: String, timeout: Duration = .seconds(600),
        errors: (@MainActor @Sendable (String) -> Void)? = nil
    ) async throws -> (code: Int32, output: String, data: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = environment(directory)
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        let collected = Collected()
        out.fileHandleForReading.readabilityHandler = { handle in collected.append(handle.availableData) }
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let errors else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in errors(text) }
        }
        let code: Int32 = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            process.terminationHandler = { ended in
                once.run { continuation.resume(returning: ended.terminationStatus) }
            }
            do {
                try process.run()
            } catch {
                once.run { continuation.resume(throwing: error) }
                return
            }
            Task.detached {
                try? await Task.sleep(for: timeout)
                once.run {
                    process.terminate()
                    continuation.resume(throwing: RecordFailure.failed(
                        "\((tool as NSString).lastPathComponent) \(arguments.prefix(2).joined(separator: " ")) " +
                            "did not finish in \(timeout)"
                    ))
                }
            }
        }
        // What is still in the pipe once it ended, then no more reading: a child left holding it changes nothing.
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        if let rest = try? out.fileHandleForReading.read(upToCount: 1 << 24) { collected.append(rest) }
        let data = collected.data
        return (code, String(decoding: data, as: UTF8.self), data)
    }

    /// A pipe's bytes as they come, from whichever thread reads them.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()

        func append(_ data: Data) { lock.withLock { bytes.append(data) } }
        var data: Data { lock.withLock { bytes } }
    }

    /// Runs its work the first time only: the process's end or its timeout, whichever comes first.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        func run(_ work: () -> Void) {
            let first = lock.withLock { () -> Bool in
                defer { done = true }
                return !done
            }
            if first { work() }
        }
    }

    /// A process's children.
    nonisolated static func children(of pid: pid_t) -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 64)
        let count = proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return count > 0 ? Array(pids.prefix(Int(count))) : []
    }

    // MARK: samply

    /// samply, pinned: the person's own when it is on their PATH, else sill's, downloaded once from its release into
    /// sill's cache, its checksum checked.
    nonisolated static let samplyVersion = "0.13.1"
    private nonisolated static let samplySums = [
        "aarch64": "7597239aa3769e75058be5ed359dbfe067f5e7714a5f052c45dd81d509aec17f",
        "x86_64": "a57f05f9162d06c36df6d51425d976ac774a8cd6dbd84050e6303fa8bf813998",
    ]

    nonisolated static func samply() async throws -> String {
        let found = try? await capture("/usr/bin/env", ["which", "samply"], in: NSHomeDirectory())
        if let found, found.code == 0 {
            let path = found.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { return path }
        }
        #if arch(arm64)
            let arch = "aarch64"
        #else
            let arch = "x86_64"
        #endif
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sill/tools/samply-\(samplyVersion)")
        let binary = cache.appendingPathComponent("samply").path
        if FileManager.default.isExecutableFile(atPath: binary) { return binary }
        let name = "samply-\(arch)-apple-darwin"
        let url =
            URL(string: "https://github.com/mstange/samply/releases/download/samply-v\(samplyVersion)/\(name).tar.xz")!
        let (download, _) = try await URLSession.shared.download(from: url)
        let data = try Data(contentsOf: download)
        let sum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard sum == samplySums[arch] else {
            throw RecordFailure.failed("samply's download does not match its checksum")
        }
        let staging = cache.path + ".part"
        try? FileManager.default.removeItem(atPath: staging)
        try FileManager.default.createDirectory(atPath: staging, withIntermediateDirectories: true)
        let archive = (staging as NSString).appendingPathComponent("samply.tar.xz")
        try data.write(to: URL(fileURLWithPath: archive))
        let untar = try await capture(
            "/usr/bin/tar",
            ["xf", archive, "-C", staging, "--strip-components", "1"],
            in: staging
        )
        guard untar.code == 0, FileManager.default.isExecutableFile(atPath: staging + "/samply") else {
            throw RecordFailure.failed("samply's archive did not unpack")
        }
        try? FileManager.default.removeItem(atPath: archive)
        try? FileManager.default.removeItem(at: cache)
        try FileManager.default.createDirectory(
            at: cache.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(atPath: staging, toPath: cache.path)
        return binary
    }

    enum RecordFailure: Error, CustomStringConvertible {
        case failed(String)
        case stopped

        var description: String {
            switch self {
            case let .failed(why): why
            case .stopped: "stopped before it ran"
            }
        }
    }
}
