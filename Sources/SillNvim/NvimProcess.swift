// Lifted from Veil (https://github.com/0x1b2c/Veil, MIT, a29c3d0); see THIRD_PARTY_NOTICES.md.
import Foundation

public final nonisolated class NvimProcess: @unchecked Sendable {
    public let stdinPipe = Pipe()
    public let stdoutPipe = Pipe()
    public let stderrPipe = Pipe()

    private nonisolated(unsafe) var _process: Process?
    private let _processLock = NSLock()
    private let nvimPath: String
    public private(set) var resolvedNvimPath: String = ""
    private let cwd: String
    private let appName: String
    private let customEnv: [String: String]?
    private let additionalEnv: [String: String]
    private let extraArgs: [String]

    public var isRunning: Bool {
        _processLock.lock()
        defer { _processLock.unlock() }
        return _process?.isRunning ?? false
    }

    public init(
        nvimPath: String = "",
        cwd: String = NSHomeDirectory(),
        appName: String = "nvim",
        customEnv: [String: String]? = nil,
        additionalEnv: [String: String] = [:],
        extraArgs: [String] = []
    ) {
        self.nvimPath = nvimPath
        self.cwd = cwd
        self.appName = appName
        self.customEnv = customEnv
        self.additionalEnv = additionalEnv
        self.extraArgs = extraArgs
    }

    public func start() throws {
        let process = Process()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.qualityOfService = .userInteractive
        let binary = try resolveNvimBinary()
        resolvedNvimPath = binary
        process.executableURL = URL(fileURLWithPath: binary)
        var env = customEnv ?? Self.cachedEnv
        env["NVIM_APPNAME"] = appName
        env.merge(additionalEnv) { _, new in new }
        process.environment = env
        process.arguments = ["--embed"] + extraArgs
        try process.run()
        _processLock.lock()
        _process = process
        _processLock.unlock()
    }

    /// nvim's exit status once it has ended (`:cquit` makes it 1); nil while it runs.
    public func exitStatus() async -> Int32? {
        guard let process = _processLock.withLock({ _process }) else { return nil }
        // The stream ends when nvim closes its output, a moment before the process is reaped.
        for _ in 0 ..< 100 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return process.isRunning ? nil : process.terminationStatus
    }

    public func stop() {
        _processLock.lock()
        let process = _process
        _processLock.unlock()
        guard let process, process.isRunning else { return }
        stdinPipe.fileHandleForWriting.closeFile()
        DispatchQueue.global().async {
            process.waitUntilExit()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { process.terminate() }
        }
    }

    // MARK: - Login shell environment

    //
    // When launched from Spotlight/Dock, the app inherits launchd's minimal
    // PATH which lacks Homebrew, nvm, cargo, etc. We spawn the user's login
    // shell once to capture their full environment (especially PATH), so nvim
    // and its plugins (e.g. Copilot.lua needing Node.js) can find their tools.
    // The result is cached — subsequent windows reuse it with no overhead.

    // Guarded by envLock.
    private nonisolated(unsafe) static var _cachedEnv: [String: String]?
    private static let envLock = NSLock()

    /// The login shell's environment, captured once: an app started from the Dock has launchd's bare PATH.
    public static var cachedEnv: [String: String] {
        envLock.lock()
        if let env = _cachedEnv {
            envLock.unlock()
            return env
        }
        envLock.unlock()
        // Capture outside lock — this spawns a shell process and may take seconds
        let env = captureLoginShellEnvironment()
        envLock.lock()
        if _cachedEnv == nil { _cachedEnv = env }
        let result = _cachedEnv!
        envLock.unlock()
        return result
    }

    public static func updateCachedEnv(from cliEnv: [String: String]) {
        envLock.lock()
        _cachedEnv = cliEnv
        _cachedEnv?.removeValue(forKey: "NVIM_APPNAME")
        envLock.unlock()
    }

    /// Trigger eager loading of cachedEnv in background.
    public static func warmUpEnvironment() { _ = cachedEnv }

    private static func captureLoginShellEnvironment() -> [String: String] {
        captureShellEnvironment(shellArgs: ["-l"])
    }

    private static func captureInteractiveShellEnvironment() -> [String: String] {
        captureShellEnvironment(shellArgs: ["-l", "-i"])
    }

    static func captureShellEnvironment(
        shellArgs: [String], shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    ) -> [String: String] {
        let shellPath = shell
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        let marker = UUID().uuidString
        // `+m` disables job control. Without it, an interactive shell tries to
        // take terminal foreground via tcsetpgrp and stops on SIGTTOU when we've
        // inherited a terminal session we can't claim (CLI cold-start). POSIX
        // shells (zsh, bash, ksh, dash) all accept this flag; non-POSIX shells
        // hit the timeout fallback below.
        process.arguments = shellArgs + ["+m", "-c", "echo \(marker) && env"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        do {
            try process.run()
        } catch {
            return ProcessInfo.processInfo.environment
        }
        // Bounded, both ways. The shell's interactive startup can hang (zsh's job control on a CLI cold start), and a
        // process the shell's profile starts can keep its output open after the shell is gone, so reading to the end
        // would never return (sill: seen hanging a test run for minutes). The output is gathered as it comes; after
        // 5 s the shell is killed and whatever arrived is used.
        let output = OutputBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            output.append(handle.availableData)
        }
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        if done.wait(timeout: .now() + 5) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = done.wait(timeout: .now() + 1)
        }
        // What the shell wrote just before it exited may still be in the pipe.
        Thread.sleep(forTimeInterval: 0.05)
        pipe.fileHandleForReading.readabilityHandler = nil
        let data = output.data
        guard let output = String(data: data, encoding: .utf8),
              let markerRange = output.range(of: marker)
        else {
            return ProcessInfo.processInfo.environment
        }
        let envString = output[markerRange.upperBound...].trimmingCharacters(
            in: .whitespacesAndNewlines)
        var env: [String: String] = [:]
        for line in envString.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { env[String(parts[0])] = String(parts[1]) }
        }
        return env.isEmpty ? ProcessInfo.processInfo.environment : env
    }

    // MARK: - Binary resolution

    private static let nvimPathDefaultsKey = "SillNvimPath"

    /// Resolve the nvim binary path with a layered strategy that balances
    /// reliability and performance:
    ///
    /// 1. UserDefaults cache — zero overhead on subsequent launches. Verified
    ///    on each launch (executable check); stale entries trigger re-detection.
    /// 2. Login shell (-l) — fast, covers Homebrew/Nix/Cargo users who
    ///    configure PATH in .zprofile or .zshenv.
    /// 3. Interactive login shell (-l -i) — slow, but picks up tools like mise
    ///    and nvm that only activate in .zshrc. The cost is paid once; the
    ///    result is cached for all future launches.
    /// 4. Well-known paths — last resort if both shells fail (e.g. broken
    ///    shell config). Checks Homebrew (ARM/Intel) and MacPorts locations.
    private func resolveNvimBinary() throws -> String {
        // Explicit path from caller
        if !nvimPath.isEmpty, FileManager.default.isExecutableFile(atPath: nvimPath) {
            return nvimPath
        }

        // Cached path from previous detection
        if let cached = UserDefaults.standard.string(forKey: Self.nvimPathDefaultsKey),
           FileManager.default.isExecutableFile(atPath: cached)
        {
            return cached
        }

        // Phase 1 (fast): cachedEnv lazily spawns a login shell (-l) on first access,
        // covers users who set PATH in .zprofile
        let loginEnv = Self.cachedEnv
        if let path = Self.findInPath("nvim", in: loginEnv["PATH"]) {
            Self.cacheNvimPath(path)
            return path
        }

        // Phase 2: interactive login shell (slow, covers mise/nvm in .zshrc)
        let interactiveEnv = Self.captureInteractiveShellEnvironment()
        if let path = Self.findInPath("nvim", in: interactiveEnv["PATH"]) {
            Self.envLock.lock()
            Self._cachedEnv = interactiveEnv
            Self.envLock.unlock()
            Self.cacheNvimPath(path)
            return path
        }

        // Well-known candidates
        for candidate in ["/opt/homebrew/bin/nvim", "/usr/local/bin/nvim", "/opt/local/bin/nvim"]
            where FileManager.default.isExecutableFile(atPath: candidate)
        {
            Self.cacheNvimPath(candidate)
            return candidate
        }
        throw NvimProcessError.binaryNotFound
    }

    private static func cacheNvimPath(_ path: String) {
        UserDefaults.standard.set(path, forKey: nvimPathDefaultsKey)
    }

    public static func findInPath(_ binary: String, in pathString: String?) -> String? {
        guard let pathString else { return nil }
        for dir in pathString.split(separator: ":") {
            let candidate = "\(dir)/\(binary)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

public nonisolated enum NvimProcessError: Error, LocalizedError {
    case binaryNotFound

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound: "Neovim not found"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .binaryNotFound:
            """
            Couldn't find `nvim` in your shell PATH or the standard install locations.

            Install Neovim with `brew install neovim`, or set `nvim_path` in sill's settings to point to an existing installation.
            """
        }
    }
}

/// Bytes gathered from a pipe's readability handler, on any thread.
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()

    func append(_ data: Data) {
        lock.withLock { bytes.append(data) }
    }

    var data: Data { lock.withLock { bytes } }
}
