import AppKit
import SillCore
import SillEditor
import SillNvim
import SillSidecar

/// A profiling run from the editor (M6): the project's .NET program built and run under the sidecar's profiler, heap
/// snapshots taken as it goes, and its CPU profile once stopped, all shown in the profile pane. One run at a time.
@MainActor
final class Profiler {
    private weak var app: AppDelegate?
    private let channel: NvimChannel
    private let directory: String
    /// The run in progress: its request id with the sidecar.
    private(set) var run: Int?
    /// The last .NET run that ended: the sidecar still answers for a stretch of it and for its last heap.
    private(set) var finishedRun: Int?
    /// The project being profiled, for Profile again.
    private(set) var project: String?

    init(app: AppDelegate, channel: NvimChannel, directory: String) {
        self.app = app
        self.channel = channel
        self.directory = directory
    }

    /// Hooks the view's buttons up.
    func attach(_ view: ProfileView) {
        view.onSnapshot = { [weak self] in self?.snapshot() }
        view.onStop = { [weak self] in self?.stop() }
        view.onAgain = { [weak self] in self?.start(project: self?.project) }
        view.onSendToAgent = { [weak self] headline, prompt in self?.app?.agents.send(headline: headline, prompt) }
        view.onOpenSource = { [weak self] file, line in
            guard let self else { return }
            Nvim.lua(channel, "require'sill'.open(...)", [.string(file), .int(Int64(line))])
        }
        view.onWithin = { [weak self, weak view] from, to in
            guard let self, let view, let whole = view.whole ?? view.document else { return }
            Task {
                // A native profile carries its samples' times; the sidecar answers for a .NET one.
                let part: ProfileDocument? = if whole.sampleTimes != nil {
                    await Task.detached { whole.within(from: from, to: to) }.value
                } else if let run = self.finishedRun, let sidecar = self.app?.sidecar {
                    try? await sidecar.profileWithin(run: run, from: from, to: to)
                } else {
                    nil
                }
                guard let part else {
                    view.busy = nil
                    return self.say("That stretch of the run could not be read.", warn: true)
                }
                view.showStretch(part, from: from, to: to)
            }
        }
        view.onRetainers = { [weak self, weak view] type in
            guard let self, let run = run ?? finishedRun, let sidecar = app?.sidecar else { return }
            Task {
                let paths = await (try? sidecar.retainers(run: run, type: type)) ?? []
                view?.show(retainers: paths, for: type)
            }
        }
    }

    private var view: ProfileView? { app?.tools.profileView() }

    func answer(_ action: String) {
        switch action {
        case "synthetic": view?.showSynthetic()
        case "snapshot": snapshot()
        case "stop": stop()
        default: start(project: nil)
        }
    }

    /// Profiles `project`, else the project the current file is in, else the folder's first runnable one.
    /// A native program being recorded (Rust, Swift).
    private(set) var native: NativeRecorder?

    func start(project chosen: String?) {
        guard run == nil, native == nil else {
            return say("A profile is already recording: :SillProfile stop ends it.")
        }
        guard let app else { return }
        // A .NET program when there is one; else the folder's Cargo or Swift package.
        if chosen == nil, DotnetProjects.pick(in: directory, near: app.tools.screen.buffer.path) == nil,
           let kind = NativeRecorder.kind(in: directory)
        {
            return startNative(kind)
        }
        guard let sidecar = app.sidecar else {
            view?.failed("the .NET sidecar is not running")
            return say("The .NET sidecar is not running, so there is no profiler.", warn: true)
        }
        guard let project = chosen ?? DotnetProjects.pick(in: directory, near: app.tools.screen.buffer.path) else {
            view?.failed("no runnable .NET project in this folder")
            return say(
                "No runnable .NET project here to profile (a program or web app, not a library or tests).",
                warn: true
            )
        }
        self.project = project
        let name = ((project as NSString).lastPathComponent as NSString).deletingPathExtension
        view?.begin(name, engine: ".NET · EventPipe", snapshots: true)
        Task {
            do {
                let id = try await sidecar.startProfile(project: project) { [weak self] partial in
                    Task { @MainActor in self?.progress(partial) }
                }
                run = id
                let document = try await sidecar.profileResult(run: id)
                run = nil
                finishedRun = id
                finished(document)
            } catch {
                run = nil
                view?.failed("\(error)".replacingOccurrences(of: "profile failed in the sidecar: ", with: ""))
            }
        }
    }

    /// A Rust program under samply, a Swift one under xctrace.
    private func startNative(_ kind: NativeRecorder.Kind) {
        let recorder = NativeRecorder(kind: kind, directory: directory, onOutput: { [weak self] text in
            self?.view?.append(output: text)
        }, onRunning: { [weak self] name in
            self?.view?.running(name)
        })
        native = recorder
        view?.begin((directory as NSString).lastPathComponent, engine: kind.engine, snapshots: false)
        Task {
            do {
                let document = try await recorder.record()
                native = nil
                finished(document)
            } catch {
                native = nil
                view?.failed("\(error)")
            }
        }
    }

    /// The program's previous profile, for the next one to be compared with.
    private(set) var previous: ProfileDocument?

    /// A run's CPU profile shown, compared with the program's previous one.
    private func finished(_ document: ProfileDocument) {
        guard let view else { return }
        view.comparison = previous
            .flatMap { $0.name == document.name ? ProfileComparison(before: $0, after: document) : nil }
        previous = document
        view.finish(document)
    }

    // MARK: For an agent

    /// Starts a run as an agent asks and waits until it records (or fails): what it says is the tool's answer.
    func startForAgent(project: String?) async -> (text: String, failed: Bool) {
        guard run == nil, native == nil else { return ("A profile is already recording: profile_stop ends it.", true) }
        // Shown as it happens: the profile's tab opened where the person sees it.
        _ = try? await channel.lua("require'sill'.show_profile()")
        view?.drivenByAgent = true
        start(project: project)
        let end = ContinuousClock.now + .seconds(300)
        while ContinuousClock.now < end {
            guard let view else { break }
            if view.isRecording { return ("Recording \(view.title) (\(view.engine)).", false) }
            if case let .failed(why) = view.phase { return ("The profile did not start: \(why)", true) }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return ("The program did not start recording in time.", true)
    }

    /// A heap snapshot as an agent asks: its size, how it changed since the last one, and what keeps the type that
    /// grew most alive.
    func snapshotForAgent() async -> (text: String, failed: Bool) {
        guard run != nil, let view else { return ("No .NET profile is recording: profile_start first.", true) }
        let count = view.heaps.count
        snapshot()
        let end = ContinuousClock.now + .seconds(120)
        while ContinuousClock.now < end, view.heaps.count == count {
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard let heap = view.heaps.last, view.heaps.count > count else { return ("The snapshot failed.", true) }
        var lines = ["snapshot #\(heap.number): \(heap.objects.formatted()) objects, \(heap.bytes.formatted()) bytes"]
        if let comparison = heap.comparison {
            lines
                .append(
                    "since the last: \(comparison.newObjects.formatted()) new, \(comparison.deadObjects.formatted()) died"
                )
            for delta in comparison.types.filter({ $0.bytesDelta > 0 }).prefix(8) {
                lines
                    .append(
                        "  \(delta.name): +\(delta.bytesDelta.formatted()) bytes, \(delta.newObjects.formatted()) new"
                    )
            }
            if let top = comparison.types.first(where: { $0.bytesDelta > 0 })?.name {
                view.select(type: top)
                let readBy = ContinuousClock.now + .seconds(60)
                while ContinuousClock.now < readBy, view.retainers[top] == nil {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                if let path = view.retainers[top]?.first {
                    lines.append("what keeps \(top) alive: " + ([path.root] + path.steps).joined(separator: " → "))
                }
            }
        } else {
            lines.append("largest types:")
            for type in heap.types.prefix(8) {
                lines.append("  \(type.name): \(type.count.formatted()) objects, \(type.bytes.formatted()) bytes")
            }
        }
        return (lines.joined(separator: "\n"), false)
    }

    /// Stops the recording as an agent asks and waits for the CPU profile: its hottest functions, and how it compares
    /// with the program's previous run.
    func stopForAgent() async -> (text: String, failed: Bool) {
        guard run != nil || native != nil, let view else { return ("No profile is recording.", true) }
        stop()
        let end = ContinuousClock.now + .seconds(300)
        while ContinuousClock.now < end, view.phase != .done {
            if case let .failed(why) = view.phase { return ("The profile failed: \(why)", true) }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard let document = view.document,
              view.phase == .done else { return ("The profile did not come in time.", true) }
        return (
            Self.summary(document) + (view.comparison.map { "\ncompared with the previous run:\n" + $0.text } ?? ""),
            false
        )
    }

    /// A CPU profile as an agent reads it: how much was sampled, and the hottest functions with where they are.
    static func summary(_ document: ProfileDocument) -> String {
        var lines = [String(
            format: "%@: %d samples over %.1f s",
            document.name,
            document.samples,
            document.durationMs / 1000
        )]
        lines.append("hottest (own time, then total):")
        for hot in document.hotSpots.prefix(10) {
            let own = 100 * Double(hot.selfSamples) / Double(max(document.samples, 1))
            let total = 100 * Double(hot.total) / Double(max(document.samples, 1))
            lines.append(String(format: "  %@ %.1f%% / %.1f%%", hot.name, own, total) +
                (hot.file.map { " at \($0):\(hot.line ?? 0)" } ?? ""))
        }
        return lines.joined(separator: "\n")
    }

    private func progress(_ partial: ProfilePartial) {
        switch partial.stage {
        case "running": view?.running(partial.name ?? "the program")
        case "output": view?.append(output: partial.text ?? "")
        case "reading": view?.reading()
        default: break
        }
    }

    func snapshot() {
        if native != nil { return say("Heap snapshots are for .NET programs; a native profile is the CPU's.") }
        guard let run, let sidecar = app?.sidecar, let view else { return say("No profile is recording.") }
        view.busy = "taking snapshot #\(view.heaps.count + 1)…"
        Task {
            do {
                try await view.add(sidecar.heapSnapshot(run: run))
            } catch {
                view.busy = nil
                say("The snapshot failed: \(error)", warn: true)
            }
        }
    }

    func stop() {
        if let native {
            view?.reading()
            return native.stop()
        }
        guard let run, let sidecar = app?.sidecar else { return say("No profile is recording.") }
        view?.reading()
        Task { _ = try? await sidecar.stopProfile(run: run) }
    }

    private func say(_ text: String, warn: Bool = false) {
        Nvim.lua(channel, "vim.notify(...)", [.string(text), .int(warn ? 3 : 2)])
    }
}
