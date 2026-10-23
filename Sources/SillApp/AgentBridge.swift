import AppKit
import MessagePack
import SillAgent
import SillCore
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
    let heed = Heed()
    private(set) var sessions: [HeedSession]?
    /// What the last Send to agent did, for the self-check: the heed session it went to, or nil for the pane.
    private(set) var lastSent: (session: String?, error: String?)?

    init(app: AppDelegate, channel: NvimChannel, directory: String) {
        self.app = app
        self.channel = channel
        self.directory = directory
        let temporary = NSTemporaryDirectory()
        let pid = ProcessInfo.processInfo.processIdentifier
        configPath = (temporary as NSString).appendingPathComponent("sill-mcp-\(pid).json")
        allowed = Set((ProcessInfo.processInfo.environment["SILL_MCP_ALLOW"] ?? "").split(separator: ",")
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
        let agent = ProcessInfo.processInfo.environment["SILL_AGENT"] ?? "claude"
        return "\(agent) --mcp-config \(shellQuote(configPath)) \(shellQuote(prompt))"
    }

    /// The prompt Send to agent gives: the problems, and how to use sill's tools on them.
    func prompt(_ problems: [Diagnostic]) -> String {
        let list = problems
            .map { "- \(relative($0.path)):\($0.line): \($0.code.isEmpty ? "" : $0.code + " ")\($0.message)" }
        return Self.headline(problems) + "\n" +
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
        let prompt = prompt(problems)
        guard sessions != nil else {
            lastSent = (nil, nil)
            app?.run(command: agentCommand(prompt: prompt))
            return
        }
        Task { await sendToHeed(prompt) }
    }

    /// heed's name for the agent sill starts (`SILL_HEED_AGENT`, else claude).
    private var heedAgent: String { ProcessInfo.processInfo.environment["SILL_HEED_AGENT"] ?? "claude" }

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
