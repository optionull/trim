import AppKit
import MessagePack
import SillAgent
import SillCore
import SillNvim

/// The editor's side of the agent loop (M4): sill's tools on its MCP server, the permission broker, and Send to
/// agent, which starts an agent in a terminal pane with sill's MCP server configured and the problems in its prompt.
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
    }

    func stop() {
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

    /// Board 9: an agent in a terminal pane at the bottom, given the problems.
    func send(_ problems: [Diagnostic]) {
        let list = problems
            .map { "- \(relative($0.path)):\($0.line): \($0.code.isEmpty ? "" : $0.code + " ")\($0.message)" }
        let prompt = "Fix these problems without changing public behavior. Use sill's tools: problems to see them, " +
            "read_file to read files as the editor has them, build to check. Then confirm build succeeds.\n" +
            list.joined(separator: "\n")
        app?.run(command: agentCommand(prompt: prompt))
    }
}

/// A string as one word for sh.
func shellQuote(_ string: String) -> String {
    "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
