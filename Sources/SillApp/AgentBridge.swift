import AppKit
import MessagePack
import SillAgent
import SillCore
import SillEditor
import SillNvim

/// The editor's side of the agent loop: sill's tools on its MCP server, the permission broker (M4), and Send to
/// agent. With heed running, Send to agent starts the agent there, sill's MCP server configured and the problems in
/// its prompt, and the Agents sidebar follows heed's sessions (M5); without heed, the agent runs in a terminal pane.
@MainActor
final class AgentBridge {
    let server: McpServer
    /// The MCP config file agents are started with.
    let configPath: String
    private weak var app: AppDelegate?
    private let channel: NvimChannel
    private let directory: String
    /// Tools the person allowed for the rest of the session ("Always").
    private var allowed: Set<String>
    /// Calls so far, for the self-check.
    private(set) var calls: [String] = []
    /// heed's control socket, and its sessions (nil while heed is not running).
    let heed = Heed(path: Heed.socketPath(Settings.shared.environment))
    private(set) var sessions: [HeedSession]?
    /// What the last Send to agent did, for the self-check: the heed session it went to, or nil for the pane.
    private(set) var lastSent: (session: String?, error: String?)?
    /// The last prompt sent, for the self-check.
    private(set) var lastPrompt: String?

    init(app: AppDelegate, channel: NvimChannel, directory: String) {
        self.app = app
        self.channel = channel
        self.directory = directory
        let temporary = NSTemporaryDirectory()
        let pid = ProcessInfo.processInfo.processIdentifier
        configPath = (temporary as NSString).appendingPathComponent("sill-mcp-\(pid).json")
        allowed = Set((Settings.shared.value("SILL_MCP_ALLOW") ?? "").split(separator: ",")
            .map(String.init))
        server = McpServer(
            path: (temporary as NSString).appendingPathComponent("sill-\(pid).sock"), tools: [],
            instructions: ""
        )
    }

    private var running: McpServer?

    func start() {
        let server = McpServer(path: server.path, tools: tools(), instructions: """
        sill is the editor the person is using. Its tools see what the editor sees: problems (build errors and \
        language server diagnostics), files as they are open (unsaved changes included), and a build of the \
        project. Edit files with your own tools; sill reloads them. After fixing problems, call build to check.
        """)
        do {
            try server.start()
            running = server
            let config = try JSONSerialization.data(withJSONObject: server.clientConfig, options: [.prettyPrinted])
            try config.write(to: URL(fileURLWithPath: configPath))
        } catch {
            NSLog("sill: the MCP server did not start: \(error)")
        }
        heed.watch { [weak self] sessions in
            Task { @MainActor in self?.heedChanged(sessions) }
        }
    }

    func stop() {
        heed.stopWatching()
        running?.stop()
        try? FileManager.default.removeItem(atPath: configPath)
    }

    var socketPath: String? { running?.path }

    // MARK: Tools

    private struct PathArguments: Decodable {
        var path: String
        var line: Int?
    }

    private static let problemsHelp = "The problems the editor shows: build errors and warnings, and language " +
        "server diagnostics, each as path:line:col, severity, code and message."
    private static let buildHelp = "Builds the project as the editor does (dotnet build, swift build, cargo build, " +
        "tsc) and returns whether it succeeded and its errors. The person may be asked to allow it."
    private static let readHelp = "A file as it is open in the editor, unsaved changes included, with line numbers. " +
        "The path is absolute or relative to the project."
    private static let openHelp = "Shows a file to the person in the editor, at a line."

    private func tools() -> [Tool] {
        let gone = ToolResult("sill is gone", isError: true)
        return [
            Tool(name: "problems", description: Self.problemsHelp) { [weak self] _ in
                await self?.call("problems") { $0.problemsText() } ?? gone
            },
            Tool(name: "build", description: Self.buildHelp) { [weak self] _ in
                await self?.callBuild() ?? gone
            },
            Tool(
                name: "read_file",
                description: Self.readHelp,
                properties: ["path": ["type": "string"]],
                required: ["path"]
            ) { [weak self] arguments in
                await self?.callRead(arguments) ?? gone
            },
            Tool(
                name: "open_file",
                description: Self.openHelp,
                properties: ["path": ["type": "string"], "line": ["type": "integer"]],
                required: ["path"]
            ) { [weak self] arguments in
                await self?.callOpen(arguments) ?? gone
            },
        ] + debugTools(gone) + profileTools(gone) + walkTools(gone) + telemetryTools(gone) + [
            Tool(
                name: "annotate",
                description: "Shows your answer to the person beside the code it is about, under " +
                    "a line of a file in the editor (as a question asked with :SillAsk names it).",
                properties: ["path": ["type": "string"], "line": ["type": "integer"], "text": ["type": "string"]],
                required: ["path", "line", "text"]
            ) { [weak self] data in
                await self?.call("annotate") { bridge in
                    let asked = Self.walkArguments(data)
                    let text = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["text"] as? String
                    guard let path = asked.path.map(bridge.absolute), let line = asked.line, let text else {
                        return ToolResult("annotate needs a path, a line and the text", isError: true)
                    }
                    _ = try? await bridge.channel.lua(
                        "require'sill.ask'.annotate(...)",
                        args: [.string(path), .int(Int64(line)), .string(text)]
                    )
                    return ToolResult("Shown under \((path as NSString).lastPathComponent):\(line).")
                } ?? gone
            },
        ]
    }

    private struct TelemetryArguments: Decodable {
        var pid: Int?
        var level: String?
        var contains: String?
        var last: Int?
        var slowest: Int?
        var name: String?
    }

    private nonisolated static func telemetryArguments(_ data: Data) -> TelemetryArguments {
        (try? JSONDecoder().decode(TelemetryArguments.self, from: data)) ?? TelemetryArguments()
    }

    private func telemetryTools(_ gone: ToolResult) -> [Tool] {
        let notWatching = ToolResult(
            "No program is watched: telemetry_watch with a pid, or :SillTelemetry in sill.",
            isError: true
        )
        return [
            Tool(
                name: "telemetry_watch",
                description: "Starts reading a running .NET program's logs, traces and " +
                    "metrics (by its pid) without changing it; the person sees them in sill's telemetry pane.",
                properties: ["pid": ["type": "integer"]],
                required: ["pid"]
            ) { [weak self] data in
                await self?.call("telemetry_watch") { bridge in
                    guard let pid = Self.telemetryArguments(data).pid,
                          let watch = bridge.app?.telemetry else { return gone }
                    watch.watch(Int32(pid))
                    // A moment for the first batches.
                    try? await Task.sleep(for: .seconds(2))
                    return ToolResult(
                        watch.run != nil ? "Watching \(watch.name) (pid \(pid)): \(watch.store.logs.count) " +
                            "logs, \(watch.store.spans.count) spans so far." : "Could not watch pid \(pid).",
                        isError: watch.run == nil
                    )
                } ?? gone
            },
            Tool(
                name: "telemetry_logs",
                description: "The watched program's newest logs: level (information, " +
                    "warning, error) or worse, containing a text, the last n (default 50).",
                properties: [
                    "level": ["type": "string"],
                    "contains": ["type": "string"],
                    "last": ["type": "integer"],
                ]
            ) { [weak self] data in
                await self?.call("telemetry_logs") { bridge in
                    guard let watch = bridge.app?.telemetry, watch.processId != nil else { return notWatching }
                    let asked = Self.telemetryArguments(data)
                    let level = [
                        "trace": 0,
                        "debug": 1,
                        "information": 2,
                        "info": 2,
                        "warning": 3,
                        "error": 4,
                        "critical": 5,
                    ][asked.level?.lowercased() ?? ""] ?? 0
                    return ToolResult(watch.store.logText(
                        level: level,
                        containing: asked.contains,
                        last: asked.last ?? 50
                    ))
                } ?? gone
            },
            Tool(
                name: "telemetry_traces",
                description: "The watched program's slowest traces (default 5), or those " +
                    "whose root is named like a text, each as its spans with durations and tags.",
                properties: ["slowest": ["type": "integer"], "name": ["type": "string"]]
            ) { [weak self] data in
                await self?.call("telemetry_traces") { bridge in
                    guard let watch = bridge.app?.telemetry, watch.processId != nil else { return notWatching }
                    let asked = Self.telemetryArguments(data)
                    bridge.app?.tools.telemetry?.select(tab: .traces)
                    return ToolResult(watch.store.traceText(slowest: asked.slowest ?? 5, named: asked.name))
                } ?? gone
            },
            Tool(
                name: "telemetry_metrics",
                description: "The watched program's metrics: each series' latest value " +
                    "and its range, those named like a text when given.",
                properties: ["name": ["type": "string"]]
            ) { [weak self] data in
                await self?.call("telemetry_metrics") { bridge in
                    guard let watch = bridge.app?.telemetry, watch.processId != nil else { return notWatching }
                    return ToolResult(watch.store.metricText(named: Self.telemetryArguments(data).name))
                } ?? gone
            },
        ]
    }

    /// `:SillAsk`: a question about lines of a file, to the agent working here, the code with it; the answer is to
    /// come back through `annotate`, under the lines.
    func ask(path: String, from: Int, to: Int, lines: [String], question: String) {
        let place = "\(relative(path)):\(from)" + (to > from ? "-\(to)" : "")
        let prompt = """
        \(question)

        About \(place):
        \(lines.enumerated().map { "\(from + $0.offset)\t\($0.element)" }.joined(separator: "\n"))

        Answer in a few sentences, then call sill's annotate tool with path "\(path)", line \(to) and your answer, so
        it shows under the code.
        """
        send(headline: "Question on \(place)", prompt)
    }

    // MARK: Walkthroughs

    private struct WalkArguments: Decodable {
        var path: String?
        var step: Int?
        var line: Int?
        var answer: String?
    }

    private nonisolated static func walkArguments(_ data: Data) -> WalkArguments {
        (try? JSONDecoder().decode(WalkArguments.self, from: data)) ?? WalkArguments()
    }

    private func walkTools(_ gone: ToolResult) -> [Tool] {
        [
            Tool(
                name: "walkthrough_check",
                description: "Reads a walkthrough (*.walk.md) as sill does and finds each " +
                    "@code anchor in the code; answers with the anchors not found. Check one after writing it.",
                properties: ["path": ["type": "string"]],
                required: ["path"]
            ) { [weak self] data in
                await self?.call("walkthrough_check") { bridge in
                    guard let path = Self.walkArguments(data).path.map(bridge.absolute),
                          let walker = bridge.app?.walker
                    else {
                        return ToolResult("walkthrough_check needs a path", isError: true)
                    }
                    guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
                        return ToolResult("No file at \(path)", isError: true)
                    }
                    let walk = Walkthrough(source)
                    let shown = walker.path
                    walker.open(path)
                    let problems = await walker.read()
                    if let shown, shown != path { walker.open(shown) }
                    let anchors = walk.steps.flatMap(\.blocks)
                        .count(where: { if case .code = $0 { true } else { false } })
                    return problems.isEmpty ?
                        ToolResult("\(walk.steps.count) steps, \(anchors) anchors, all found.") :
                        ToolResult(
                            "\(problems.count) of \(anchors) anchors not found:\n" +
                                problems.joined(separator: "\n"),
                            isError: true
                        )
                } ?? gone
            },
            Tool(
                name: "walkthrough_open",
                description: "Opens a walkthrough in sill for the person, at a step " +
                    "(1-based), to walk them through it.",
                properties: ["path": ["type": "string"], "step": ["type": "integer"]],
                required: ["path"]
            ) { [weak self] data in
                await self?.call("walkthrough_open") { bridge in
                    let asked = Self.walkArguments(data)
                    guard let path = asked.path.map(bridge.absolute), let walker = bridge.app?.walker else {
                        return ToolResult("walkthrough_open needs a path", isError: true)
                    }
                    walker.open(path, step: max((asked.step ?? 1) - 1, 0))
                    return ToolResult("Opened \(path) at step \(asked.step ?? 1).")
                } ?? gone
            },
            Tool(
                name: "walkthrough_answer",
                description: "Writes your answer under a question in a walkthrough: " +
                    "the path and the question's line, as the request named them.",
                properties: ["path": ["type": "string"], "line": ["type": "integer"], "answer": ["type": "string"]],
                required: ["path", "line", "answer"]
            ) { [weak self] data in
                await self?.call("walkthrough_answer") { bridge in
                    let asked = Self.walkArguments(data)
                    guard let path = asked.path.map(bridge.absolute), let line = asked.line,
                          let answer = asked.answer,
                          let walker = bridge.app?.walker
                    else {
                        return ToolResult("walkthrough_answer needs a path, a line and an answer", isError: true)
                    }
                    return await walker.answer(path: path, line: line, answer) ?
                        ToolResult("Written under line \(line).") : ToolResult("No file at \(path)", isError: true)
                } ?? gone
            },
        ]
    }

    // MARK: Debugging and profiling, seen live in sill

    private struct DebugArguments: Decodable {
        var project: String?
        var pid: Int?
        var path: String?
        var line: Int?
        var condition: String?
        var hit_count: String?
        var log_message: String?
        var remove: Bool?
        var action: String?
        var expression: String?
        var wait_seconds: Int?
    }

    private func decode(_ data: Data) -> DebugArguments {
        (try? JSONDecoder().decode(DebugArguments.self, from: data)) ?? DebugArguments()
    }

    private func absolute(_ path: String) -> String {
        path.hasPrefix("/") ? path : (directory as NSString).appendingPathComponent(path)
    }

    private func debugTools(_ gone: ToolResult) -> [Tool] {
        let wait = ["type": "integer", "description": "How long to wait for it to pause or end (seconds, default 60)"]
        return [
            Tool(
                name: "debug_start",
                description: "Builds the project's .NET program in Debug and runs it under " +
                    "sill's debugger, with the breakpoints set in sill; waits until it pauses or ends and says where. " +
                    "The person watches it in sill and may be asked to allow it.",
                properties: ["project": ["type": "string"], "wait_seconds": wait]
            ) { [weak self] data in
                await self?.call("debug_start") { bridge in
                    let asked = bridge.decode(data)
                    guard let debugger = bridge.app?.debugger else { return gone }
                    guard debugger.state == .idle else {
                        return ToolResult("Already debugging: debug_stop first.", isError: true)
                    }
                    guard await bridge.permit("debug", "build and run the program under the debugger") else {
                        return ToolResult("The person did not allow it.", isError: true)
                    }
                    debugger.project = asked.project.map(bridge.absolute)
                    debugger.drivenByAgent = true
                    debugger.answer("start")
                    await debugger.settle(timeout: .seconds(asked.wait_seconds ?? 60))
                    return ToolResult(debugger.summary())
                } ?? gone
            },
            Tool(
                name: "debug_attach",
                description: "Attaches sill's debugger to a running .NET process by its " +
                    "pid; stopping detaches and leaves it running. May ask the person.",
                properties: ["pid": ["type": "integer"], "wait_seconds": wait],
                required: ["pid"]
            ) { [weak self] data in
                await self?.call("debug_attach") { bridge in
                    let asked = bridge.decode(data)
                    guard let debugger = bridge.app?.debugger, let pid = asked.pid else { return gone }
                    guard await bridge.permit("debug", "attach the debugger to process \(pid)") else {
                        return ToolResult("The person did not allow it.", isError: true)
                    }
                    debugger.drivenByAgent = true
                    debugger.attach(Int32(pid))
                    await debugger.settle(timeout: .seconds(asked.wait_seconds ?? 10))
                    return ToolResult(debugger.summary())
                } ?? gone
            },
            Tool(
                name: "debug_breakpoint",
                description: "Sets a breakpoint at path:line, shown in sill as the " +
                    "person's would be: with a condition (C#, true to stop), a hit count (5, >=5, %5) or a log message " +
                    "({expressions} in braces, which logs and goes on); remove: true takes it away.",
                properties: [
                    "path": ["type": "string"], "line": ["type": "integer"], "condition": ["type": "string"],
                    "hit_count": ["type": "string"], "log_message": ["type": "string"], "remove": ["type": "boolean"],
                ],
                required: ["path", "line"]
            ) { [weak self] data in
                await self?.call("debug_breakpoint") { bridge in
                    let asked = bridge.decode(data)
                    guard let path = asked.path, let line = asked.line else {
                        return ToolResult("debug_breakpoint needs a path and a line", isError: true)
                    }
                    var extra: [MessagePackValue: MessagePackValue] = [:]
                    if let condition = asked.condition { extra[.string("condition")] = .string(condition) }
                    if let hit = asked.hit_count { extra[.string("hit")] = .string(hit) }
                    if let log = asked.log_message { extra[.string("log")] = .string(log) }
                    _ = try? await bridge.channel.lua("require'sill.debug'.set(...)", args: [
                        .string(bridge.absolute(path)), .int(Int64(line)), .map(extra),
                        .bool(asked.remove ?? false),
                    ])
                    return ToolResult((asked.remove ?? false) ? "No breakpoint at \(path):\(line)." :
                        "Breakpoint at \(path):\(line)" +
                        (extra.isEmpty ? "." : " with \(extra.count) setting(s)."))
                } ?? gone
            },
            Tool(
                name: "debug_step",
                description: "Resumes the paused program: continue (to the next breakpoint), " +
                    "next (over), in or out; waits until it pauses again or ends and says where.",
                properties: [
                    "action": ["type": "string", "description": "continue, next, in or out"], "wait_seconds": wait,
                ],
                required: ["action"]
            ) { [weak self] data in
                await self?.call("debug_step") { bridge in
                    let asked = bridge.decode(data)
                    guard let debugger = bridge.app?.debugger else { return gone }
                    guard case .paused = debugger.state else {
                        return ToolResult("The program is not paused. " + debugger.summary(), isError: true)
                    }
                    let action = asked.action ?? "continue"
                    guard ["continue", "next", "in", "out"].contains(action) else {
                        return ToolResult("action: continue, next, in or out", isError: true)
                    }
                    debugger.drivenByAgent = true
                    debugger.answer(action)
                    await debugger.settle(timeout: .seconds(asked.wait_seconds ?? 60))
                    return ToolResult(debugger.summary())
                } ?? gone
            },
            Tool(
                name: "debug_state",
                description: "Where the program is: paused (where, why, the exception, the " +
                    "stack, the locals and watches), running, or not debugged."
            ) { [weak self] _ in
                await self?.call("debug_state") { bridge in
                    ToolResult(bridge.app?.debugger.summary() ?? "sill is gone")
                } ?? gone
            },
            Tool(
                name: "debug_evaluate",
                description: "Evaluates a C# expression in the paused program's selected " +
                    "frame and shows the answer in sill's Debug tab.",
                properties: ["expression": ["type": "string"]],
                required: ["expression"]
            ) { [weak self] data in
                await self?.call("debug_evaluate") { bridge in
                    let asked = bridge.decode(data)
                    guard let debugger = bridge.app?.debugger,
                          let expression = asked.expression else { return gone }
                    guard let value = await debugger.value(of: expression) else {
                        return ToolResult("Evaluating needs the program paused.", isError: true)
                    }
                    debugger.answer("eval " + expression)
                    return ToolResult("\(expression) = \(value)", isError: value.hasPrefix("error:"))
                } ?? gone
            },
            Tool(
                name: "debug_stop",
                description: "Ends the debug session: a program sill started ends, one it " +
                    "attached to goes on running."
            ) { [weak self] _ in
                await self?.call("debug_stop") { bridge in
                    guard let debugger = bridge.app?.debugger else { return gone }
                    debugger.stop()
                    debugger.drivenByAgent = false
                    return ToolResult("Stopped.")
                } ?? gone
            },
        ]
    }

    private nonisolated static func answer(_ result: (text: String, failed: Bool)) -> ToolResult {
        ToolResult(result.text, isError: result.failed)
    }

    private func profileTools(_ gone: ToolResult) -> [Tool] {
        [
            Tool(
                name: "profile_start",
                description: "Builds the project in Release and runs it under sill's " +
                    "profiler (.NET: EventPipe; Rust: samply; Swift: xctrace), shown live in sill; profile_snapshot " +
                    "takes heap snapshots (.NET), profile_stop ends it and answers with the CPU profile. May ask the " +
                    "person.",
                properties: ["project": ["type": "string"]]
            ) { [weak self] data in
                await self?.call("profile_start") { bridge in
                    guard let profiler = bridge.app?.profiler else { return gone }
                    guard await bridge.permit("profile", "build and run the program under the profiler") else {
                        return ToolResult("The person did not allow it.", isError: true)
                    }
                    return await Self
                        .answer(profiler.startForAgent(project: bridge.decode(data).project.map(bridge.absolute)))
                } ?? gone
            },
            Tool(
                name: "profile_snapshot",
                description: "A heap snapshot of the .NET program being profiled: how " +
                    "the heap changed since the last one, and what keeps the type that grew most alive."
            ) { [weak self] _ in
                await self?.call("profile_snapshot") { bridge in
                    guard let profiler = bridge.app?.profiler else { return gone }
                    return await Self.answer(profiler.snapshotForAgent())
                } ?? gone
            },
            Tool(
                name: "profile_stop",
                description: "Ends the recording and answers with the CPU profile: the " +
                    "hottest functions and where they are written, and how they compare with the program's previous " +
                    "run (profile before a change and after it)."
            ) { [weak self] _ in
                await self?.call("profile_stop") { bridge in
                    guard let profiler = bridge.app?.profiler else { return gone }
                    return await Self.answer(profiler.stopForAgent())
                } ?? gone
            },
            Tool(
                name: "profile_compare",
                description: "The last profile against the program's previous one: each " +
                    "function's time before and after, the biggest change first."
            ) { [weak self] _ in
                await self?.call("profile_compare") { bridge in
                    guard let comparison = bridge.app?.tools.profile?.comparison else {
                        return ToolResult("Nothing to compare: profile the program twice.", isError: true)
                    }
                    bridge.app?.tools.profile?.select(tab: .compare)
                    return ToolResult(comparison.text)
                } ?? gone
            },
        ]
    }

    /// Every call: noted, and files an agent changed on disk read again first.
    private func call(_ name: String, _ body: @MainActor (AgentBridge) async -> ToolResult) async -> ToolResult {
        calls.append(name)
        _ = try? await channel.lua("vim.cmd('silent! checktime')")
        return await body(self)
    }

    private func relative(_ path: String) -> String {
        path.hasPrefix(directory + "/") ? String(path.dropFirst(directory.count + 1)) : path
    }

    func problemsText() -> ToolResult {
        let problems = app?.tools.screen.diagnostics ?? []
        guard !problems.isEmpty else { return ToolResult("No problems.") }
        let lines = problems.map { problem in
            let severity = ["", "error", "warning", "info", "hint"][min(max(problem.severity, 0), 4)]
            return "\(relative(problem.path)):\(problem.line):\(problem.col): \(severity)" +
                (problem.code.isEmpty ? "" : " \(problem.code)") + ": \(problem.message) [\(problem.source)]"
        }
        return ToolResult("\(problems.count) problem\(problems.count == 1 ? "" : "s"):\n" + lines
            .joined(separator: "\n"))
    }

    private func callBuild() async -> ToolResult {
        await call("build") { bridge in
            guard await bridge.permit(
                "build",
                "run the project's build (\(BuildCapture.command(in: bridge.directory) ?? "nothing to build"))"
            )
            else { return ToolResult("The person did not allow the build.", isError: true) }
            guard let builds = bridge.app?.builds else { return ToolResult("sill is gone", isError: true) }
            let result = await withCheckedContinuation { continuation in
                builds.onFinish = { succeeded, diagnostics in
                    builds.onFinish = nil
                    continuation.resume(returning: (succeeded, diagnostics))
                }
                builds.build()
            }
            let errors = result.1.filter { $0.severity == 1 }
            if result.0 {
                return ToolResult("Build succeeded" + (result.1.isEmpty ? "." : ", \(result.1.count) warnings."))
            }
            let lines = errors.map { "\(bridge.relative($0.path)):\($0.line):\($0.col): \($0.code): \($0.message)" }
            return ToolResult(
                "Build failed, \(errors.count) error\(errors.count == 1 ? "" : "s"):\n" +
                    lines.joined(separator: "\n"),
                isError: false
            )
        }
    }

    private func callRead(_ arguments: Data) async -> ToolResult {
        await call("read_file") { bridge in
            guard let asked = try? JSONDecoder().decode(PathArguments.self, from: arguments) else {
                return ToolResult("read_file needs a path", isError: true)
            }
            let path = asked.path.hasPrefix("/") ? asked.path : (bridge.directory as NSString)
                .appendingPathComponent(asked.path)
            bridge.app?.follower?.read(path)
            let lines = try? await bridge.channel.lua("""
            local path = ...
            local buf = vim.fn.bufnr(path)
            if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
              return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
            end
            local ok, lines = pcall(vim.fn.readfile, path)
            return ok and lines or vim.NIL
            """, args: [.string(path)])
            guard let text = lines?.arrayValue?.compactMap(\.stringValue) else {
                return ToolResult("No such file: \(asked.path)", isError: true)
            }
            let numbered = text.enumerated().map { "\($0.offset + 1)\t\($0.element)" }
            return ToolResult(numbered.joined(separator: "\n"))
        }
    }

    private func callOpen(_ arguments: Data) async -> ToolResult {
        await call("open_file") { bridge in
            guard let asked = try? JSONDecoder().decode(PathArguments.self, from: arguments) else {
                return ToolResult("open_file needs a path", isError: true)
            }
            let path = asked.path.hasPrefix("/") ? asked.path : (bridge.directory as NSString)
                .appendingPathComponent(asked.path)
            Nvim.lua(bridge.channel, "require'sill'.open(...)", [.string(path), .int(Int64(asked.line ?? 1))])
            return ToolResult("Opened \(asked.path).")
        }
    }

    // MARK: Permission broker

    /// Asks the person whether an agent may `what` (once, always this session, or not), unless already allowed.
    private func permit(_ tool: String, _ what: String) async -> Bool {
        if allowed.contains(tool) || allowed.contains("all") { return true }
        let alert = NSAlert()
        alert.messageText = "An agent asks to \(what)"
        alert.informativeText = "From sill's MCP server. Always allows it for the rest of this session."
        alert.addButton(withTitle: "Allow Once")
        alert.addButton(withTitle: "Always")
        alert.addButton(withTitle: "Deny")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return true
        case .alertSecondButtonReturn:
            allowed.insert(tool)
            return true
        default: return false
        }
    }

    // MARK: Send to agent

    /// The agent command line: `claude` with sill's MCP server and the prompt (`SILL_AGENT` names another command).
    func agentCommand(prompt: String) -> String {
        let agent = Settings.shared.value("SILL_AGENT") ?? "claude"
        return "\(agent) --mcp-config \(shellQuote(configPath)) \(shellQuote(prompt))"
    }

    /// The prompt Send to agent gives: the problems, and how to use sill's tools on them.
    func prompt(_ problems: [Diagnostic], headline: Bool = true) -> String {
        let list = problems
            .map { "- \(relative($0.path)):\($0.line): \($0.code.isEmpty ? "" : $0.code + " ")\($0.message)" }
        return (headline ? Self.headline(problems) + "\n" : "") +
            "Fix these problems without changing public behavior. Use sill's tools: problems to see them, " +
            "read_file to read files as the editor has them, build to check. Then confirm build succeeds.\n" +
            list.joined(separator: "\n")
    }

    /// The prompt's first line, which heed titles the session with (up to its first full stop, so no file names):
    /// "Fix CS1061", "Fix 3 problems: CS1061, CS0103".
    static func headline(_ problems: [Diagnostic]) -> String {
        var codes: [String] = []
        for problem in problems where !problem.code.isEmpty && !codes.contains(problem.code) {
            codes.append(problem.code)
        }
        if problems.count == 1 { return "Fix " + (codes.first ?? "a problem") }
        let named = codes.prefix(3).joined(separator: ", ") + (codes.count > 3 ? " and more" : "")
        return "Fix \(problems.count) problems" + (named.isEmpty ? "" : ": " + named)
    }

    /// Board 9: the agent given the problems. In heed when it runs (a new session in this folder, or the one that
    /// already works here), else in a terminal pane at the bottom.
    func send(_ problems: [Diagnostic]) {
        send(headline: Self.headline(problems), prompt(problems, headline: false))
    }

    /// An ask from the editor (problems, a profile): to heed when it runs, else a terminal pane. `headline` is the
    /// prompt's first line, which heed titles the session with.
    func send(headline: String, _ body: String) {
        // What the agent does from here is reviewed against the worktree as it is now.
        app?.reviewer?.mark("when sent to an agent")
        let prompt = headline + "\n" + body
        lastPrompt = prompt
        guard sessions != nil else {
            lastSent = (nil, nil)
            app?.run(command: agentCommand(prompt: prompt))
            return
        }
        Task { await sendToHeed(prompt) }
    }

    /// heed's name for the agent sill starts (`SILL_HEED_AGENT`, else claude).
    private var heedAgent: String { Settings.shared.value("SILL_HEED_AGENT") ?? "claude" }

    /// The words that give an agent sill's MCP server, for the agents sill knows how to tell.
    func mcpArguments(agent: String) -> [String] {
        switch agent {
        case "claude": return ["--mcp-config", configPath]
        case "codex":
            guard let path = socketPath else { return [] }
            return [
                "-c",
                "mcp_servers.sill.command=\"/usr/bin/nc\"",
                "-c",
                "mcp_servers.sill.args=[\"-U\",\"\(path)\"]",
            ]
        default: return []
        }
    }

    /// The session that already works in this folder, if one is still alive: Send to agent goes to it.
    var sessionHere: HeedSession? {
        sessions?.filter { AgentsView.isHere($0, directory) && $0.state != "exited" }
            .max { ($0.lastActivity ?? .distantPast) < ($1.lastActivity ?? .distantPast) }
    }

    private func sendToHeed(_ prompt: String) async {
        let agent = heedAgent
        if let here = sessionHere { return await sendTo(here.id, prompt) }
        do {
            let reply = try await heed.call(.start(
                directory: directory, prompt: prompt, agent: agent, arguments: mcpArguments(agent: agent)
            ))
            lastSent = (reply.session, nil)
            say("Sent to heed: \(agent) started on the problems. It is in Agents.")
        } catch let HeedError.refused(_, session?) {
            // A session heed knows works in this worktree: the problems go to it.
            await sendTo(session, prompt)
        } catch {
            lastSent = (nil, "\(error)")
            say("heed: \(error)", warn: true)
        }
    }

    private func sendTo(_ session: String, _ prompt: String) async {
        do {
            _ = try await heed.call(.send(session, prompt))
            lastSent = (session, nil)
            say("Sent to \(title(of: session)) in heed.")
        } catch {
            lastSent = (session, "\(error)")
            say("\(title(of: session)) in heed: \(error). Return on it in Agents opens it there.", warn: true)
        }
    }

    private func title(of session: String) -> String {
        sessions?.first { $0.id == session }?.title ?? "the session"
    }

    private func say(_ text: String, warn: Bool = false) {
        Nvim.lua(channel, "vim.notify(...)", [.string(text), .int(warn ? 3 : 2)])
    }

    // MARK: heed's sessions

    private func heedChanged(_ sessions: [HeedSession]?) {
        self.sessions = sessions
        app?.agentsChanged(sessions)
    }

    /// Opens a session in heed, heed in front.
    func open(_ session: HeedSession) {
        Task {
            do { _ = try await heed.call(.show(session.id, focus: true)) } catch {
                say("heed: \(error)", warn: true)
            }
        }
    }

    /// `<leader>a`: the next session that needs you, after the one opened last, in heed.
    private var lastOpened: String?

    func openNextWaiting() {
        guard let sessions else { return say("heed is not running: no agents to go to.") }
        let waiting = AgentsView.order(sessions, here: directory).filter(\.needsYou)
        guard !waiting.isEmpty else { return say("No agent needs you.") }
        let index = waiting.firstIndex { $0.id == lastOpened }.map { ($0 + 1) % waiting.count } ?? 0
        lastOpened = waiting[index].id
        open(waiting[index])
    }
}

/// A string as one word for sh.
func shellQuote(_ string: String) -> String {
    "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
