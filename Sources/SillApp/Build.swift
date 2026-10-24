import AppKit
import MessagePack
import SillCore
import SillEditor
import SillNvim

/// Build (⌘B): the project's build command, run with the login shell's environment, its output streamed to the
/// panel's Output tab and its diagnostics given to nvim (the Problems panel, signs, the files).
@MainActor
final class BuildRunner {
    private let directory: String
    private let channel: NvimChannel
    private let panel: BottomPanelView
    private(set) var running: Process?
    /// The last build's result: whether it succeeded, and its diagnostics.
    private(set) var last: (succeeded: Bool, diagnostics: [Diagnostic])?
    var onFinish: ((Bool, [Diagnostic]) -> Void)?

    init(directory: String, channel: NvimChannel, panel: BottomPanelView) {
        self.directory = directory
        self.channel = channel
        self.panel = panel
    }

    func build() {
        guard running == nil else { return }
        guard let command = BuildCapture.command(in: directory) else {
            Nvim.lua(channel, "vim.notify(...)", [.string(
                "Nothing to build here: no solution or project, Package.swift, Cargo.toml or tsconfig.json."
            )])
            return
        }
        // Unsaved changes would not be built: save first.
        Nvim.lua(channel, "vim.cmd('silent! wall')")
        panel.startOutput(command)
        panel.select(.output)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var environment = NvimProcess.cachedEnv
        environment["DOTNET_CLI_TELEMETRY_OPTOUT"] = "1"
        environment["DOTNET_NOLOGO"] = "1"
        environment["TERM"] = "dumb"
        // The shell keeps an inherited PWD that names this folder another way (/tmp for /private/tmp), and the build's
        // paths follow it: they must be the folder's real ones, as the language servers' are.
        environment["PWD"] = directory
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let collected = Collected()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            collected.append(data)
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { self?.panel.appendOutput(text) }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            DispatchQueue.main.async {
                pipe.fileHandleForReading.readabilityHandler = nil
                self?.finished(status: status, output: String(decoding: collected.data, as: UTF8.self))
            }
        }
        do {
            try process.run()
            running = process
        } catch {
            panel.appendOutput("Could not run \(command): \(error)\n")
        }
    }

    private func finished(status: Int32, output: String) {
        running = nil
        let diagnostics = BuildCapture.diagnostics(in: output, directory: directory)
        let succeeded = status == 0
        last = (succeeded, diagnostics)
        panel.appendOutput(succeeded ? "\nBuild succeeded.\n" : "\nBuild failed (exit \(status)).\n")
        let list: [MessagePackValue] = diagnostics.map { diagnostic in
            .map([
                "path": .string(diagnostic.path), "line": .int(Int64(diagnostic.line)),
                "col": .int(Int64(diagnostic.col)), "severity": .int(Int64(diagnostic.severity)),
                "code": .string(diagnostic.code), "message": .string(diagnostic.message),
            ])
        }
        Nvim.lua(channel, "require'sill'.build_result(...)", [.array(list)])
        let errors = diagnostics.count(where: { $0.severity == 1 })
        if !succeeded || errors > 0 { panel.select(.problems) }
        let summary = succeeded ? "Build succeeded" + (diagnostics.isEmpty ? "" : ", \(diagnostics.count) warnings") :
            "Build failed: \(errors) error" + (errors == 1 ? "" : "s")
        Nvim.lua(channel, "vim.notify(...)", [.string(summary), .int(succeeded ? 2 : 4)])
        onFinish?(succeeded, diagnostics)
    }
}

/// Bytes gathered from a pipe on any thread.
final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data) { lock.withLock { bytes.append(data) } }
    var data: Data { lock.withLock { bytes } }
}
