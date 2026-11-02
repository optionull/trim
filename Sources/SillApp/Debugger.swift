import AppKit
import MessagePack
import SillCore
import SillEditor
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

    private weak var app: Workspace?
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
    private var sent: [String: [Screen.Breakpoint]] = [:]
    private var sentFunctions: [String]?
    /// The exceptions that stop the program: `user-unhandled` (as a person debugging expects), `all`, or none.
    private(set) var exceptionFilters = ["user-unhandled"]
    /// The exception the program stopped on, while it is paused there.
    private(set) var exception: Dap.ExceptionInfo?
    /// Expressions evaluated at every pause, with what they were the last time (an error says so).
    private(set) var watches: [(expression: String, value: String)] = []
    /// The last thing `:SillEval` asked, and its answer.
    private(set) var evaluated: (expression: String, value: String)?
    /// Attached to a process sill did not start: stopping detaches and leaves it running.
    private(set) var attached: Int32?
    /// An agent is driving (through sill's MCP tools): the Debug tab says so. The person's own keys still work.
    var drivenByAgent = false {
        didSet { changed() }
    }

    /// The project to start, when an agent named one; else the one near the open file.
    var project: String?
    /// Breakpoints as the adapter answered them (verified or not), for the self-check.
    private(set) var answered: [String: [Dap.Breakpoint]] = [:]
    var onChange: (() -> Void)?
    private var handled = 0
    /// The adapter has its first breakpoints and runs the program: later changes go as they come.
    private var configured = false

    init(app: Workspace, channel: NvimChannel, directory: String) {
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
        if configured, screen.functionBreakpoints != sentFunctions {
            Task { await sendFunctionBreakpoints(screen.functionBreakpoints) }
        }
    }

    func answer(_ ask: String) {
        // Asks with an argument: an expression, a process, which exceptions.
        let parts = ask.split(separator: " ", maxSplits: 1)
        let action = parts.first.map(String.init) ?? ask
        let argument = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        switch action {
        case "eval": return evaluate(argument)
        case "watch": return watch(argument)
        case "unwatch":
            watches.removeAll { $0.expression == argument }
            return changed()
        case "exceptions": return exceptions(argument)
        case "attach" where state == .idle:
            if let pid = Int32(argument) { return attach(pid) }
            return pickProcess()
        default: break
        }
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

    /// Debugs `project` (a project file's path), from the Run pane.
    func debug(project chosen: String) {
        guard state == .idle else { return say("A debug session is on: Shift-F5 stops it.") }
        project = chosen
        start()
    }

    private func start() {
        lastExit = nil
        guard let app, let sidecar = app.sidecar else {
            return say("The .NET sidecar is not running, so there is no debugger.", warn: true)
        }
        guard let project = project ?? DotnetProjects.pick(in: directory, near: app.tools.screen.buffer.path) else {
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
        listen(client)
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
            // The breakpoints and which exceptions stop it, then the program starts.
            sent = [:]
            sentFunctions = nil
            await sendBreakpoints(app?.tools.screen.breakpoints ?? [:])
            await sendFunctionBreakpoints(app?.tools.screen.functionBreakpoints ?? [])
            await sendExceptionFilters()
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
                lastExit = exited.exitCode
                say("\(program ?? "The program") ended with exit code \(exited.exitCode).")
            }
        case "terminated":
            stop()
        default:
            break
        }
    }

    private func sendBreakpoints(_ all: [String: [Screen.Breakpoint]]) async {
        guard let client else { return }
        // Files whose breakpoints changed, those that lost them all included.
        for path in Set(all.keys).union(sent.keys) where all[path] != sent[path] {
            let breakpoints = all[path] ?? []
            sent[path] = breakpoints
            let answer = try? await client.request("setBreakpoints", Dap.Arguments([
                "source": .object(["path": .string(path)]),
                "breakpoints": .array(breakpoints.map { breakpoint in
                    var fields: [String: Dap.Value] = ["line": .int(breakpoint.line)]
                    if let condition = breakpoint.condition { fields["condition"] = .string(condition) }
                    if let hit = breakpoint.hit { fields["hitCondition"] = .string(hit) }
                    if let log = breakpoint.log { fields["logMessage"] = .string(log) }
                    return .object(fields)
                }),
            ]), as: Dap.Breakpoints.self)
            answered[path] = answer?.breakpoints ?? []
            // A breakpoint the adapter would not take says why; one waiting for the program to load its code is not
            // refused.
            for refused in answered[path] ?? []
                where !refused.verified && refused.message?.contains("not been processed") != true
            {
                if let message = refused
                    .message { say("Breakpoint at line \(refused.line ?? 0): \(message)", warn: true) }
            }
        }
    }

    /// Function breakpoints as answered, for the self-check.
    private(set) var answeredFunctions: [Dap.Breakpoint] = []

    private func sendFunctionBreakpoints(_ names: [String]) async {
        guard let client else { return }
        sentFunctions = names
        let answer = try? await client.request("setFunctionBreakpoints", Dap.Arguments([
            "breakpoints": .array(names.map { .object(["name": .string($0)]) }),
        ]), as: Dap.Breakpoints.self)
        answeredFunctions = answer?.breakpoints ?? []
    }

    private func sendExceptionFilters() async {
        _ = try? await client?.request("setExceptionBreakpoints", Dap.Arguments([
            "filters": .array(exceptionFilters.map { .string($0) }),
        ]))
    }

    /// `:SillDebug exceptions all|unhandled|none`: which exceptions stop the program, now and in later sessions.
    private func exceptions(_ which: String) {
        switch which {
        case "all": exceptionFilters = ["all"]
        case "unhandled", "": exceptionFilters = ["user-unhandled"]
        case "none": exceptionFilters = []
        default: return say("exceptions: all, unhandled or none", warn: true)
        }
        say(exceptionFilters.isEmpty ? "No exception stops the program." :
            exceptionFilters == ["all"] ? "Every exception thrown stops the program." :
            "Exceptions your code does not handle stop the program.")
        if configured { Task { await sendExceptionFilters() } }
    }

    private func paused(_ stopped: Dap.Stopped) async {
        guard let client else { return }
        let thread = stopped.threadId ?? thread ?? 0
        self.thread = thread
        let trace = try? await client.request("stackTrace", Dap.Arguments([
            "threadId": .int(thread), "levels": 40,
        ]), as: Dap.StackTrace.self)
        pauseRead = false
        frames = trace?.stackFrames ?? []
        exception = nil
        if stopped.reason == "exception" {
            exception = try? await client.request(
                "exceptionInfo", Dap.Arguments(["threadId": .int(thread)]), as: Dap.ExceptionInfo.self
            )
            if let exception {
                say(
                    "\(exception.exceptionId): \(exception.details?.message ?? exception.description ?? "")",
                    warn: true
                )
            }
        }
        state = .paused(reason: stopped.reason)
        await select(frames.firstIndex { $0.source?.path != nil } ?? 0)
        pauseRead = true
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
        await evaluateWatches()
        changed()
    }

    // MARK: For an agent

    /// Waits until the program pauses or the session ends (or `timeout` passes): what a tool that runs it answers
    /// after.
    func settle(timeout: Duration = .seconds(60)) async {
        let end = ContinuousClock.now + timeout
        // A step or continue just sent: give the adapter a moment to say it runs.
        try? await Task.sleep(for: .milliseconds(150))
        while ContinuousClock.now < end {
            switch state {
            case .paused:
                // Its stack, variables and watches read too.
                if pauseRead { return }
            case .idle: return
            default: break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// The session as an agent reads it: where it paused and why, the exception, the stack, the variables and watches.
    func summary() -> String {
        switch state {
        case .idle: return "Not debugging." + (lastExit.map { " The program ended with exit code \($0)." } ?? "")
        case .building: return "Building the program to debug."
        case .running: return "\(program ?? "The program") is running (no breakpoint hit yet)."
        case let .paused(reason):
            var lines: [String] = []
            if let frame = frames.first(where: { $0.source?.path != nil }) ?? frames.first {
                lines
                    .append("paused (\(reason)) at \(frame.source?.path ?? "no source"):\(frame.line) in \(frame.name)")
            }
            if let exception {
                lines
                    .append(
                        "exception: \(exception.exceptionId): \(exception.details?.message ?? exception.description ?? "")"
                    )
            }
            lines.append("stack:")
            for frame in frames.prefix(12) {
                lines.append("  \(frame.name)" + (frame.source?.path.map { " at \($0):\(frame.line)" } ?? ""))
            }
            let locals = scopeReference.flatMap { variables[$0] } ?? []
            if !locals.isEmpty {
                lines.append("locals:")
                for variable in locals.prefix(30) {
                    lines.append("  \(variable.name) = \(variable.value)" + (variable.type.map { " (\($0))" } ?? ""))
                }
            }
            if !watches.isEmpty {
                lines.append("watches:")
                for watch in watches {
                    lines.append("  \(watch.expression) = \(watch.value)")
                }
            }
            return lines.joined(separator: "\n")
        }
    }

    /// The pause's frame, variables and watches are read: what `settle` waits for.
    private var pauseRead = false

    /// How the last program ended, for the summary.
    private(set) var lastExit: Int?

    // MARK: Expressions

    /// The selected frame's id, while paused.
    private var frameID: Int? {
        guard case .paused = state, frames.indices.contains(selectedFrame) else { return nil }
        return frames[selectedFrame].id
    }

    /// An expression's value in the selected frame: its result, or why it has none.
    func value(of expression: String, context: String = "repl") async -> String? {
        guard let client, let frame = frameID else { return nil }
        do {
            let answer = try await client.request("evaluate", Dap.Arguments([
                "expression": .string(expression), "frameId": .int(frame), "context": .string(context),
            ]), as: Dap.Evaluated.self)
            return answer.result
        } catch let DapClient.Failure.refused(_, message) {
            return "error: \(message)"
        } catch {
            return nil
        }
    }

    /// `:SillEval`: the answer in the Debug tab and as a message.
    private func evaluate(_ expression: String) {
        guard frameID != nil else { return say("Evaluating needs the program paused (F9 sets a breakpoint).") }
        Task {
            let value = await value(of: expression) ?? "no answer"
            evaluated = (expression, value)
            say("\(expression) = \(value)")
            changed()
        }
    }

    /// `:SillWatch`: evaluated now if paused, and at every pause after.
    private func watch(_ expression: String) {
        guard !expression.isEmpty, !watches.contains(where: { $0.expression == expression }) else { return }
        watches.append((expression, ""))
        Task {
            await evaluateWatches()
            changed()
        }
    }

    private func evaluateWatches() async {
        for index in watches.indices {
            let expression = watches[index].expression
            let value = await value(of: expression) ?? ""
            if watches.indices.contains(index), watches[index].expression == expression { watches[index].value = value }
        }
    }

    // MARK: Attaching

    /// The .NET processes running as this user: each opens a diagnostics socket in the temporary folder
    /// (`dotnet-diagnostic-<pid>-<time>-socket`), which is how dotnet's own tools find them. sill's own (the sidecar,
    /// the language server, the debug adapter) are left out.
    nonisolated static func dotnetProcesses(excluding own: Set<Int32> = []) -> [(pid: Int32, name: String)] {
        let folder = NSTemporaryDirectory()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        var found: [(Int32, String)] = []
        for name in names where name.hasPrefix("dotnet-diagnostic-") && name.hasSuffix("-socket") {
            let parts = name.split(separator: "-")
            guard parts.count >= 4, let pid = Int32(parts[2]), !own.contains(pid), kill(pid, 0) == 0,
                  !found.contains(where: { $0.0 == pid }) else { continue }
            found.append((pid, commandLine(of: pid)))
        }
        return found.sorted { $0.0 > $1.0 }
    }

    /// A process's command line, as `ps` shows it.
    nonisolated static func commandLine(of pid: Int32) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "command=", "-p", String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "process \(pid)" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let line = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? "process \(pid)" : String(line.prefix(120))
    }

    /// `:SillDebug attach`: nvim asks which process.
    private func pickProcess() {
        let own = Set([ProcessInfo.processInfo.processIdentifier])
        Task.detached {
            let found = Self.dotnetProcesses(excluding: own).filter {
                !$0.name.contains("Sill.Sidecar") && !$0.name.contains("Sill.DebugAdapter") &&
                    !$0.name.contains("roslyn-language-server") && !$0.name
                    .contains("Microsoft.CodeAnalysis.LanguageServer")
            }
            await MainActor.run {
                guard !found.isEmpty else { return self.say("No .NET process is running to attach to.") }
                Nvim.lua(self.channel, "require'sill.debug'.pick_process(...)", [.array(found.map {
                    .array([.int(Int64($0.pid)), .string($0.name)])
                })])
            }
        }
    }

    /// Attaches to a running .NET process: its breakpoints set, and stopping leaves it running.
    func attach(_ pid: Int32) {
        guard let app, let sidecar = app.sidecar else {
            return say("The .NET sidecar is not running, so there is no debugger.", warn: true)
        }
        state = .building
        changed()
        Task {
            do {
                let dbgshim = try await sidecar.dbgshim()
                let client = DapClient()
                try await client.start(
                    dotnet: Sidecar.findDotnet(),
                    adapter: Self.adapter.path,
                    environment: ["SILL_DBGSHIM": dbgshim.path]
                )
                self.client = client
                attached = pid
                program = "process \(pid)"
                listen(client)
                try await client.request("initialize", Dap.Arguments([
                    "clientID": "sill", "adapterID": "coreclr", "linesStartAt1": true, "columnsStartAt1": true,
                    "pathFormat": "path",
                ]))
                try await client.request("attach", Dap.Arguments(["processId": .int(Int(pid))]))
                state = .running
                say("Attached to process \(pid).")
                changed()
            } catch {
                end()
                say("Could not attach to process \(pid): \(error)", warn: true)
            }
        }
    }

    private func listen(_ client: DapClient) {
        let events = client.events
        Task { [weak self] in
            for await event in events {
                await self?.handle(event)
            }
            await self?.end()
        }
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
        pauseRead = false
        state = .running
        frames = []
        variables = [:]
        exception = nil
        Nvim.lua(channel, "require'sill.debug'.clear()")
        changed()
    }

    func stop() {
        guard let client else { return end() }
        // Read now: `end` below forgets it before the request goes. A process sill attached to goes on running.
        let terminate = attached == nil
        Task {
            _ = try? await client.request("disconnect", Dap.Arguments(["terminateDebuggee": .bool(terminate)]))
            await client.stop()
        }
        end()
    }

    private func end() {
        guard state != .idle || client != nil else { return }
        client = nil
        configured = false
        attached = nil
        drivenByAgent = false
        exception = nil
        sentFunctions = nil
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
    private var metrics: CellMetrics { EditorFont.metrics }
    /// The variable rows as drawn: depth, the variable, where.
    private var rows: [(depth: Int, variable: Dap.Variable, rect: NSRect)] = []
    private var frameRects: [(Int, NSRect)] = []

    init() {
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
        label(debugger.drivenByAgent ? "CALL STACK · AN AGENT IS DEBUGGING" : "CALL STACK", at: NSPoint(x: 16, y: 6))
        let watching = !debugger.watches.isEmpty || debugger.evaluated != nil
        label(watching ? "WATCH" : "VARIABLES", at: NSPoint(x: split + 16, y: 6))
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
        // The exception it stopped on, then what is watched and the last thing evaluated, over the variables.
        let x = split + 16, width = bounds.width - split - 28
        if let exception = debugger.exception {
            let text = NSMutableAttributedString(string: exception.exceptionId, attributes: [
                .font: metrics.regular, .foregroundColor: Design.error,
            ])
            if let message = exception.details?.message ?? exception.description {
                text.append(NSAttributedString(string: "  " + message, attributes: [
                    .font: Design.ui(12), .foregroundColor: Design.text,
                ]))
            }
            let height = ceil(text.boundingRect(
                with: NSSize(width: width, height: 200),
                options: [.usesLineFragmentOrigin]
            ).height) + 8
            Design.error.withAlphaComponent(0.12).setFill()
            NSRect(x: split + 1, y: y - 2, width: bounds.width - split - 1, height: height + 4).fill()
            text.draw(with: NSRect(x: x, y: y + 2, width: width, height: height), options: [.usesLineFragmentOrigin])
            y += height + 10
        }
        var expressions = debugger.watches.map { ($0.expression, $0.value, true) }
        if let evaluated = debugger.evaluated,
           !debugger.watches.contains(where: { $0.expression == evaluated.expression })
        {
            expressions.append((evaluated.expression, evaluated.value, false))
        }
        if !expressions.isEmpty {
            if debugger.exception != nil {
                label("WATCH", at: NSPoint(x: x, y: y))
                y += 20
            }
            for (expression, value, watched) in expressions {
                let text = NSMutableAttributedString(string: expression, attributes: [
                    .font: metrics.regular, .foregroundColor: watched ? Design.insert : Design.textMuted,
                ])
                text.append(NSAttributedString(string: " = " + value, attributes: [
                    .font: metrics.regular,
                    .foregroundColor: value.hasPrefix("error:") ? Design.error : Design.text,
                ]))
                text.draw(
                    with: NSRect(x: x, y: y + 3, width: width, height: rowHeight),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
                )
                y += rowHeight
            }
            y += 8
            label("VARIABLES", at: NSPoint(x: x, y: y))
            y += 20
        }
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
