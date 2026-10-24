import AppKit
import MessagePack
import SillCore
import SillNvim
import SillSidecar

/// A running .NET program's logs, traces and metrics in sill (after M9), through the sidecar's EventPipe session:
/// `:SillTelemetry` picks the program (or names its pid), the telemetry pane shows what it does, and an agent asks
/// through `telemetry_logs`, `telemetry_traces` and `telemetry_metrics`.
@MainActor
final class TelemetryWatch {
    private weak var app: AppDelegate?
    private let channel: NvimChannel
    private(set) var store = TelemetryStore()
    private(set) var run: Int?
    private(set) var processId: Int32?
    private(set) var name = ""
    /// Batches read, for the self-check.
    private(set) var batches = 0
    var onChange: (() -> Void)?
    private var handled = 0
    private var pending = false
    /// Between asking the sidecar and its run's id.
    private(set) var starting = false

    init(app: AppDelegate, channel: NvimChannel) {
        self.app = app
        self.channel = channel
    }

    /// nvim's asks: `:SillTelemetry [pid]`, `:SillTelemetry stop`.
    func update(_ screen: Screen) {
        guard screen.telemetryAsks.count > handled else { return }
        for ask in screen.telemetryAsks[handled...] {
            if ask == "stop" { stop() } else if let pid = Int32(ask) { watch(pid) } else { pick() }
        }
        handled = screen.telemetryAsks.count
    }

    /// The .NET programs running (not sill's own): one is watched at once, more are asked about.
    func pick() {
        let own = Set([ProcessInfo.processInfo.processIdentifier])
        Task.detached {
            let found = Debugger.dotnetProcesses(excluding: own).filter {
                !$0.name.contains("Sill.Sidecar") && !$0.name.contains("Sill.DebugAdapter") &&
                    !$0.name.contains("roslyn-language-server") && !$0.name
                    .contains("Microsoft.CodeAnalysis.LanguageServer")
            }
            await MainActor.run {
                if found.count == 1 { return self.watch(found[0].pid) }
                guard !found.isEmpty else {
                    return Nvim.lua(
                        self.channel,
                        "vim.notify(...)",
                        [.string("No .NET program is running to watch."), .int(2)]
                    )
                }
                Nvim.lua(self.channel, "require'sill.debug'.pick_process(...)", [.array(found.map {
                    .array([.int(Int64($0.pid)), .string($0.name)])
                }), .string("SillTelemetry")])
            }
        }
    }

    /// Starts watching a program: its telemetry streams in until it ends or `stop`.
    func watch(_ pid: Int32) {
        guard let sidecar = app?.sidecar else {
            return Nvim.lua(channel, "vim.notify(...)", [.string("The .NET sidecar is not running."), .int(3)])
        }
        stop()
        store = TelemetryStore()
        processId = pid
        // The program: the .dll dotnet runs, else the executable.
        let words = Debugger.commandLine(of: pid).split(separator: " ").map(String.init)
        name = ((words.first { $0.hasSuffix(".dll") } ?? words.first ?? "process \(pid)") as NSString).lastPathComponent
        Nvim.lua(channel, "require'sill'.show_pane('telemetry')")
        starting = true
        Task {
            do {
                let id = try await sidecar.startTelemetry(processId: Int(pid)) { [weak self] batch in
                    Task { @MainActor in self?.received(batch) }
                }
                run = id
                starting = false
                changed()
                _ = try? await sidecar.reply(to: id)
                if run == id { run = nil }
                changed()
            } catch {
                starting = false
                Nvim.lua(channel, "vim.notify(...)", [.string("Telemetry did not start: \(error)"), .int(3)])
            }
        }
        changed()
    }

    func stop() {
        guard let run, let sidecar = app?.sidecar else { return }
        self.run = nil
        Task { _ = try? await sidecar.stopTelemetry(run: run) }
        changed()
    }

    private func received(_ batch: TelemetryBatch) {
        store.add(batch)
        batches += 1
        // A redraw at most four times a second.
        guard !pending else { return }
        pending = true
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            pending = false
            changed()
        }
    }

    private func changed() { onChange?() }
}
