import AppKit
import SillCore
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
                view?.finish(document)
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
                view?.finish(document)
            } catch {
                native = nil
                view?.failed("\(error)")
            }
        }
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
