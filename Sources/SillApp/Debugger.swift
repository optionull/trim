import AppKit
import MessagePack
import SillCore
import SillNvim
import SillRender
import SillSidecar

/// A debug session from the editor (M8): the project's .NET program built in Debug and launched by sill's debug adapter
/// (vendored from Passenger, run on the person's dotnet, with dbgshim the sidecar downloaded), nvim's breakpoints set
/// as
/// they change, and where the program pauses shown: the line marked in the editor, the call stack and the variables in
/// the panel's Debug tab. F5 starts or continues, F10, F11 and Shift-F11 step, Shift-F5 stops.
@MainActor
final class Debugger {
    enum State: Equatable {
        case idle, building, running, paused(reason: String)
    }

    private weak var app: AppDelegate?
    private let channel: NvimChannel
    private let directory: String
    private(set) var state: State = .idle
    private var client: DapClient?
    private(set) var program: String?
    /// The thread that paused, and its stack.
    private(set) var thread: Int?
    private(set) var frames: [Dap.StackFrame] = []
    /// The selected frame's variables, and those opened under them, by reference.
    private(set) var variables: [Int: [Dap.Variable]] = [:]
    private(set) var scopeReference: Int?
    /// The breakpoints the adapter has, by file: sent again only where they changed.
    private var sent: [String: [Int]] = [:]
    /// Breakpoints as the adapter answered them (verified or not), for the self-check.
    private(set) var answered: [String: [Dap.Breakpoint]] = [:]
    var onChange: (() -> Void)?
    private var handled = 0
    /// The adapter has its first breakpoints and runs the program: later changes go as they come.
    private var configured = false

    init(app: AppDelegate, channel: NvimChannel, directory: String) {
        self.app = app
        self.channel = channel
        self.directory = directory
    }

    static var adapter: URL {
        if let override = ProcessInfo.processInfo.environment["SILL_DEBUG_ADAPTER"] {
            return URL(fileURLWithPath: override)
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("debugger/Sill.DebugAdapter.dll"),
           FileManager.default.fileExists(atPath: bundled.path)
        {
            return bundled
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("sidecar/Sill.DebugAdapter/bin/Release/net10.0/Sill.DebugAdapter.dll")
    }

    /// nvim's asks that are new, and its breakpoints as they are now.
    func update(_ screen: Screen) {
        if screen.debugAsks.count > handled {
            let new = screen.debugAsks[handled...]
            handled = screen.debugAsks.count
            for action in new {
                answer(action)
            }
        }
        if configured, screen.breakpoints != sent { Task { await sendBreakpoints(screen.breakpoints) } }
    }

    func answer(_ action: String) {
        switch (action, state) {
        case ("start", .idle), ("continue", .idle): start()
        case ("continue", .paused): resume("continue")
        case ("next", .paused): resume("next")
        case ("in", .paused): resume("stepIn")
        case ("out", .paused): resume("stepOut")
        case ("pause", .running): Task { try? await client?.request(
                "pause",
                Dap.Arguments(["threadId": .int(thread ?? 0)])
            ) }
        case ("stop", _): stop()
        case (_, .idle): say("Not debugging: F5 (:SillDebug) starts.")
        case (_, .building): say("Building for the debugger…")
        default: say("The program is running: F5 continues once it pauses, Shift-F5 stops it.")
        }
    }

    // MARK: A session

    private func start() {
        guard let app, let sidecar = app.sidecar else {
            return say("The .NET sidecar is not running, so there is no debugger.", warn: true)
        }
        guard let project = DotnetProjects.pick(in: directory, near: app.tools.screen.buffer.path) else {
            return say(
                "No runnable .NET project here to debug (a program or web app, not a library or tests).",
                warn: true
            )
        }
        state = .building
        changed()
        let directory = directory
        Task {
            do {
                say("Building \(((project as NSString).lastPathComponent as NSString).deletingPathExtension) to debug…")
                let built = try await NativeRecorder.capture(
                    "/usr/bin/env", ["dotnet", "build", project, "-nologo", "-v", "q"], in: directory
                )
                guard built.code == 0 else {
                    app.tools.panel.startOutput("dotnet build \(project)")
                    app.tools.panel.appendOutput(built.output)
                    app.tools.panel.select(.output)
                    throw DebugFailure("the build failed: the log is in Output")
                }
                let target = try await NativeRecorder.capture(
                    "/usr/bin/env", ["dotnet", "msbuild", project, "-nologo", "-getProperty:TargetPath"], in: directory
                )
                let program = target.output.trimmingCharacters(in: .whitespacesAndNewlines)
                guard FileManager.default.fileExists(atPath: program) else {
                    throw DebugFailure("the build made no program to run (\(program))")
                }
                let dbgshim = try await sidecar.dbgshim()
                try await launch(
                    program,
                    dbgshim: dbgshim.path,
                    folder: (project as NSString).deletingLastPathComponent
                )
            } catch {
                end()
                say("The debugger did not start: \(error)", warn: true)
            }
        }
    }

    private func launch(_ program: String, dbgshim: String, folder: String) async throws {
        let client = DapClient()
        try await client.start(
            dotnet: Sidecar.findDotnet(),
            adapter: Self.adapter.path,
            environment: ["SILL_DBGSHIM": dbgshim]
        )
        self.client = client
        self.program = ((program as NSString).lastPathComponent as NSString).deletingPathExtension
        app?.tools.panel.startOutput("\(self.program ?? "the program") under the debugger")
        let events = client.events
        Task { [weak self] in
            for await event in events {
                await self?.handle(event)
            }
            await self?.end()
        }
        try await client.request("initialize", Dap.Arguments([
            "clientID": "sill", "adapterID": "coreclr", "linesStartAt1": true, "columnsStartAt1": true,
            "pathFormat": "path",
        ]))
        try await client.request("launch", Dap.Arguments([
            "program": .string(program), "cwd": .string(folder), "console": "internalConsole",
        ]))
        state = .running
        changed()
    }

    private func handle(_ event: DapClient.Event) async {
        switch event.event {
        case "initialized":
            // The breakpoints, then the program starts.
            sent = [:]
            await sendBreakpoints(app?.tools.screen.breakpoints ?? [:])
            try? await client?.request("configurationDone", Dap.Arguments())
            configured = true
        case "stopped":
            guard let stopped = try? event.decode(Dap.Stopped.self) else { return }
            await paused(stopped)
        case "continued":
            running()
        case "output":
            guard let output = try? event.decode(Dap.Output.self), output.category != "telemetry" else { return }
            app?.tools.panel.appendOutput(output.output)
        case "exited":
            if let exited = try? event.decode(Dap.Exited.self) {
                say("\(program ?? "The program") ended with exit code \(exited.exitCode).")
            }
        case "terminated":
            stop()
        default:
            break
        }
    }

    private func sendBreakpoints(_ all: [String: [Int]]) async {
        guard let client else { return }
        // Files whose breakpoints changed, those that lost them all included.
        for path in Set(all.keys).union(sent.keys) where all[path] != sent[path] {
            let lines = all[path] ?? []
            sent[path] = lines
            let answer = try? await client.request("setBreakpoints", Dap.Arguments([
                "source": .object(["path": .string(path)]),
                "breakpoints": .array(lines.map { .object(["line": .int($0)]) }),
            ]), as: Dap.Breakpoints.self)
            answered[path] = answer?.breakpoints ?? []
        }
    }

    private func paused(_ stopped: Dap.Stopped) async {
        guard let client else { return }
        let thread = stopped.threadId ?? thread ?? 0
        self.thread = thread
        let trace = try? await client.request("stackTrace", Dap.Arguments([
            "threadId": .int(thread), "levels": 40,
        ]), as: Dap.StackTrace.self)
        frames = trace?.stackFrames ?? []
        state = .paused(reason: stopped.reason)
        await select(frames.firstIndex { $0.source?.path != nil } ?? 0)
        app?.tools.panel.select(.debug)
    }

    /// Shows a frame: its line in the editor, its variables in the panel.
    func select(_ index: Int) async {
        guard let client, frames.indices.contains(index) else { return changed() }
        let frame = frames[index]
        selectedFrame = index
        if let path = frame.source?.path {
            Nvim.lua(channel, "require'sill.debug'.at(...)", [.string(path), .int(Int64(frame.line))])
        }
        variables = [:]
        let scopes = try? await client.request(
            "scopes",
            Dap.Arguments(["frameId": .int(frame.id)]),
            as: Dap.Scopes.self
        )
        scopeReference = scopes?.scopes.first?.variablesReference
        if let reference = scopeReference { await open(reference) }
        changed()
    }

    private(set) var selectedFrame = 0

    /// A variable's children, read when it is opened.
    func open(_ reference: Int) async {
        guard let client, reference > 0, variables[reference] == nil else { return }
        let read = try? await client.request(
            "variables",
            Dap.Arguments(["variablesReference": .int(reference)]),
            as: Dap.Variables.self
        )
        variables[reference] = read?.variables ?? []
        changed()
    }

    func close(_ reference: Int) {
        variables[reference] = nil
        changed()
    }

    private func resume(_ command: String) {
        guard let client, let thread else { return }
        running()
        Task {
            do {
                try await client.request(command, Dap.Arguments(["threadId": .int(thread)]))
            } catch {
                say("\(command): \(error)", warn: true)
            }
        }
    }

    private func running() {
        state = .running
        frames = []
        variables = [:]
        Nvim.lua(channel, "require'sill.debug'.clear()")
        changed()
    }

    func stop() {
        guard let client else { return end() }
        Task {
            _ = try? await client.request("disconnect", Dap.Arguments(["terminateDebuggee": true]))
            await client.stop()
        }
        end()
    }

    private func end() {
        guard state != .idle || client != nil else { return }
        client = nil
        configured = false
        state = .idle
        frames = []
        variables = [:]
        sent = [:]
        Nvim.lua(channel, "require'sill.debug'.clear()")
        changed()
    }

    private func changed() {
        onChange?()
    }

    /// What the status bar says.
    var status: String? {
        switch state {
        case .idle: nil
        case .building: "building to debug"
        case .running: "debugging \(program ?? "")"
        case .paused:
            frames.first(where: { $0.source?.path != nil }).map {
                "paused at \((($0.source?.path ?? "") as NSString).lastPathComponent):\($0.line)"
            } ?? "paused"
        }
    }

    private func say(_ text: String, warn: Bool = false) {
        Nvim.lua(channel, "vim.notify(...)", [.string(text), .int(warn ? 3 : 2)])
    }

    struct DebugFailure: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }
}

/// The Debug tab: the paused program's call stack on the left (Return or a click shows a frame), the selected frame's
/// variables on the right, opened as they are clicked.
final class DebugPanelView: NSView {
    weak var debugger: Debugger?
    private let metrics: CellMetrics
    /// The variable rows as drawn: depth, the variable, where.
    private var rows: [(depth: Int, variable: Dap.Variable, rect: NSRect)] = []
    private var frameRects: [(Int, NSRect)] = []

    init(metrics: CellMetrics) {
        self.metrics = metrics
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    private var rowHeight: CGFloat { metrics.height + 6 }

    override func draw(_: NSRect) {
        Design.chrome.setFill()
        bounds.fill()
        rows = []
        frameRects = []
        guard let debugger, case .paused = debugger.state else {
            let text = switch debugger?.state {
            case .building?: "Building the program to debug…"
            case .running?: "\(debugger?.program ?? "The program") is running. F9 sets a breakpoint; Shift-F5 stops."
            default: "Not debugging. F9 sets a breakpoint on the line, F5 starts the project's program under the " +
                "debugger; F10 steps over, F11 in, Shift-F11 out."
            }
            NSAttributedString(string: text, attributes: [.font: Design.ui(12), .foregroundColor: Design.textMuted])
                .draw(
                    with: NSRect(x: 16, y: 10, width: bounds.width - 32, height: 40),
                    options: [.usesLineFragmentOrigin]
                )
            return
        }
        let split = (bounds.width * 0.42).rounded()
        label("CALL STACK", at: NSPoint(x: 16, y: 6))
        label("VARIABLES", at: NSPoint(x: split + 16, y: 6))
        Design.border.setFill()
        NSRect(x: split, y: 0, width: 1, height: bounds.height).fill()
        var y: CGFloat = 26
        for (index, frame) in debugger.frames.enumerated() {
            guard y < bounds.height else { break }
            let rect = NSRect(x: 0, y: y, width: split, height: rowHeight)
            if index == debugger.selectedFrame {
                Design.selection.setFill()
                rect.fill()
            }
            let place = frame.source?.path.map { "\(($0 as NSString).lastPathComponent):\(frame.line)" } ?? "no source"
            let text = NSMutableAttributedString(string: frame.name, attributes: [
                .font: metrics.regular, .foregroundColor: frame.source == nil ? Design.textFaint : Design.text,
            ])
            text.append(NSAttributedString(string: "  " + place, attributes: [
                .font: Design.ui(11), .foregroundColor: Design.textFaint,
            ]))
            text.draw(with: rect.insetBy(dx: 16, dy: 3), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            frameRects.append((index, rect))
            y += rowHeight
        }
        y = 26
        func walk(_ reference: Int, _ depth: Int) {
            for variable in debugger.variables[reference] ?? [] {
                guard y < bounds.height else { return }
                let rect = NSRect(x: split, y: y, width: bounds.width - split, height: rowHeight)
                let x = split + 16 + CGFloat(depth) * 14
                if variable.variablesReference > 0 {
                    let open = debugger.variables[variable.variablesReference] != nil
                    NSAttributedString(string: open ? "▾" : "▸", attributes: [
                        .font: Design.ui(10), .foregroundColor: Design.textFaint,
                    ]).draw(at: NSPoint(x: x - 12, y: rect.minY + 4))
                }
                let text = NSMutableAttributedString(string: variable.name, attributes: [
                    .font: metrics.regular, .foregroundColor: Design.insert,
                ])
                text.append(NSAttributedString(string: " = " + variable.value, attributes: [
                    .font: metrics.regular, .foregroundColor: Design.text,
                ]))
                if let type = variable.type, !type.isEmpty {
                    text.append(NSAttributedString(string: "  " + type, attributes: [
                        .font: Design.ui(11), .foregroundColor: Design.textFaint,
                    ]))
                }
                text.draw(
                    with: NSRect(x: x, y: rect.minY + 3, width: rect.maxX - x - 12, height: rowHeight),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
                )
                rows.append((depth, variable, rect))
                y += rowHeight
                if variable.variablesReference > 0, debugger.variables[variable.variablesReference] != nil {
                    walk(variable.variablesReference, depth + 1)
                }
            }
        }
        if let scope = debugger.scopeReference { walk(scope, 0) }
    }

    private func label(_ text: String, at point: NSPoint) {
        NSAttributedString(string: text, attributes: [
            .font: Design.ui(11, weight: .semibold), .foregroundColor: Design.textMuted,
        ]).draw(at: point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let (index, _) = frameRects.first(where: { $0.1.contains(point) }) {
            Task { await debugger?.select(index) }
            return
        }
        if let row = rows.first(where: { $0.rect.contains(point) }), row.variable.variablesReference > 0 {
            let reference = row.variable.variablesReference
            if debugger?.variables[reference] != nil {
                debugger?.close(reference)
            } else {
                Task { await debugger?.open(reference) }
            }
        }
    }
}
