import AppKit
import SillAgent
import SillCore
import SillNvim

/// Agent hooks (Claude Code's): what an agent does, told to sill as it happens rather than guessed. A prompt is a
/// review baseline, the end of a turn another; the files its tools edit are followed as its; planning is noticed as it
/// starts, a plan presented for approval opens as a notebook with the code it names, and an approved plan is a
/// baseline. Every event goes to the session's log in `.sill/sessions`.
///
/// The hooks reach sill through a socket of this worktree's; they are given to the agents sill starts (`--settings`)
/// and, by `:SillHooks install`, to every agent in the project (`.claude/settings.local.json`, backed up first).
@MainActor
final class Hooks {
    private weak var app: Workspace?
    private let channel: NvimChannel
    private let directory: String
    private(set) var server: HookServer?
    /// What every hook command of sill's has in it.
    static let marker = "sill-hooks-"
    /// Sessions planning now.
    private(set) var planning: Set<String> = []
    /// The events seen, by name, and the last plan's notebook: for the self-check.
    private(set) var seen: [String] = []
    private(set) var lastPlan: String?
    /// Each session's plan notebook, from its first draft until it is approved.
    private var plans: [String: String] = [:]
    private var handled = 0

    init(app: Workspace, channel: NvimChannel, directory: String) {
        self.app = app
        self.channel = channel
        self.directory = directory
    }

    private var root: String { SillFolder.worktreeRoot(for: directory) ?? directory }

    /// This worktree's socket: the same for every sill opened on it, so installed hooks find it.
    var socketPath: String {
        (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("\(Self.marker)\(BasketFile.fingerprint([root])).sock")
    }

    /// The settings sill passes to the agents it starts.
    var settingsPath: String {
        (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("sill-settings-\(ProcessInfo.processInfo.processIdentifier).json")
    }

    func start() {
        let server = HookServer(path: socketPath) { [weak self] data in
            await self?.handle(data) ?? Data()
        }
        do {
            try server.start()
            self.server = server
            let settings = HookSettings.installing(server.command, marker: Self.marker, in: [:])
            try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: settingsPath))
        } catch {
            NSLog("sill: the hook socket did not start: \(error)")
        }
    }

    func stop() {
        server?.stop()
        try? FileManager.default.removeItem(atPath: settingsPath)
    }

    /// nvim's asks: `:SillHooks install|remove|status`.
    func update(_ screen: Screen) {
        guard screen.hooksAsks.count > handled else { return }
        for ask in screen.hooksAsks[handled...] {
            switch ask {
            case "install": install()
            case "remove": remove()
            default: say(installed ? "sill's hooks are in \(localSettings)" : "sill's hooks are not installed here")
            }
        }
        handled = screen.hooksAsks.count
    }

    // MARK: Events

    /// An event's JSON in, the hook's output out: mostly nothing (sill listens, it does not decide), a prompt's
    /// editor context, an edit's reminder during an investigation.
    func handle(_ data: Data) async -> Data {
        guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return Data() }
        handle(event)
        if event["hook_event_name"] as? String == "UserPromptSubmit", Settings.shared.current.editorContext,
           let context = await editorContext(session: event["session_id"] as? String ?? "session")
        {
            return (try? JSONSerialization.data(withJSONObject: ["hookSpecificOutput": [
                "hookEventName": "UserPromptSubmit", "additionalContext": context,
            ]])) ?? Data()
        }
        // An edit about to happen while an investigation is open: a reminder, not a refusal.
        if event["hook_event_name"] as? String == "PreToolUse",
           Self.edits.contains(event["tool_name"] as? String ?? ""),
           let basket = app?.baskets?.investigating
        {
            let reminder = "sill: the investigation in basket \((basket as NSString).lastPathComponent) is meant to " +
                "be read-only. If this edit is needed, it is noted in the basket; else leave the code as it is and " +
                "conclude with basket_conclude first."
            return (try? JSONSerialization.data(withJSONObject: ["hookSpecificOutput": [
                "hookEventName": "PreToolUse", "additionalContext": reminder,
            ]])) ?? Data()
        }
        return Data()
    }

    /// The editor context each session was told last: only what changed is told again.
    private var told: [String: EditorContext] = [:]
    /// A selection older than this is not what a prompt is about.
    static let selectionAge = 600

    /// What the editor shows, as the agent's prompt gets it: nil when nothing changed since the session's last.
    private func editorContext(session: String) async -> String? {
        // Nothing open is an empty table, which comes as an array: the basket and the pull request are still told.
        let map = await (try? channel.lua("return require'sill'.editor_context()"))?.dictionaryValue ?? [:]
        func relative(_ path: String?) -> String? { path.map { SillFolder.relative($0, in: root) } }
        var context = EditorContext(
            path: relative(map[.string("path")]?.stringValue),
            line: map[.string("line")]?.integerValue.map { Int($0) },
            basket: app?.baskets?.current.map { ($0 as NSString).lastPathComponent },
            pullRequest: app?.pulls?.summary
        )
        if let selection = map[.string("selection")]?.dictionaryValue,
           Int(selection[.string("age")]?.integerValue ?? .max) < Self.selectionAge,
           let path = relative(selection[.string("path")]?.stringValue),
           let from = selection[.string("from")]?.integerValue, let to = selection[.string("to")]?.integerValue
        {
            context.selection = .init(
                path: path, from: Int(from), to: Int(to), text: selection[.string("text")]?.stringValue ?? ""
            )
        }
        defer { told[session] = context }
        return context.text(after: told[session])
    }

    /// The tools that edit files.
    static let edits: Set = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    private func handle(_ event: [String: Any]) {
        let name = event["hook_event_name"] as? String ?? ""
        let session = event["session_id"] as? String ?? "session"
        let mode = event["permission_mode"] as? String
        let tool = event["tool_name"] as? String
        let input = event["tool_input"] as? [String: Any] ?? [:]
        seen.append(name)
        log(event, session: session)
        // Planning: from the first event in plan mode until one in another mode.
        if mode == "plan", !planning.contains(session) {
            planning.insert(session)
            say("The agent is planning")
        } else if let mode, mode != "plan" {
            planning.remove(session)
        }
        switch name {
        case "UserPromptSubmit":
            let prompt = (event["prompt"] as? String ?? "").replacingOccurrences(of: "\n", with: " ")
            app?.reviewer?
                .mark("prompt: " + (prompt.count > 40 ? prompt.prefix(40) + "…" : prompt)) { [weak self] tree in
                    self?.log(tree: tree, of: name, session: session)
                }
        case "PreToolUse" where tool == "ExitPlanMode":
            if let plan = input["plan"] as? String { showPlan(plan, session: session, status: "presented") }
        case "PostToolUse" where tool == "ExitPlanMode":
            let response = event["tool_response"] as? [String: Any]
            approved((response?["plan"] as? String) ?? (input["plan"] as? String), session: session)
        case "PostToolUse" where Self.edits.contains(tool ?? ""):
            guard let path = (input["file_path"] ?? input["notebook_path"]) as? String else { break }
            let absolute = path.hasPrefix("/") ? path : (root as NSString).appendingPathComponent(path)
            // Planning, Claude writes its plan to ~/.claude/plans: shown as it is drafted.
            if absolute.contains("/.claude/plans/"), absolute.hasSuffix(".md") {
                if let draft = try? String(contentsOfFile: absolute, encoding: .utf8) {
                    showPlan(draft, session: session, status: "drafting")
                }
                break
            }
            // What is outside this worktree is no one's change here.
            let real = realpath(absolute, nil).map { String(cString: $0) } ?? absolute
            guard real.hasPrefix(root + "/") || absolute.hasPrefix(root + "/") else { break }
            app?.follower?.agentWrote(absolute)
            app?.baskets?.editedWhileInvestigating(absolute, tool: tool ?? "")
        case "Stop":
            app?.reviewer?.mark("turn ended") { [weak self] tree in self?.log(tree: tree, of: name, session: session) }
            app?.baskets?.turnEnded()
            // The turn may have pushed: the pull request read again once its checks have started.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                self?.app?.pulls?.refresh()
            }
        default: break
        }
    }

    /// A session's plan as a notebook in `.sill/plans` (drafting as it is written, presented for approval): one
    /// notebook per plan, written again as it changes, shown.
    private func showPlan(_ plan: String, session: String, status: String) {
        let folder = SillFolder.path(for: directory) + "/plans"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let source = PlanFile.notebook(plan, root: root, status: status)
        let path = plans[session] ?? folder + "/" + PlanFile.fileName(title: Walkthrough(source).title, at: Date())
        try? source.write(toFile: path, atomically: true, encoding: .utf8)
        plans[session] = path
        lastPlan = path
        if app?.walker?.path == path { Task { await app?.walker?.read() } } else { app?.walker?.open(path) }
    }

    /// The plan approved: its notebook says so, and the worktree now is a baseline named after it.
    private func approved(_ plan: String?, session: String) {
        if plans[session] == nil, let plan { showPlan(plan, session: session, status: "presented") }
        defer { plans[session] = nil }
        guard let path = plans[session], let source = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        try? BasketFile.setting(source, "status", to: "approved").write(toFile: path, atomically: true, encoding: .utf8)
        app?.reviewer?.mark("plan approved: " + Walkthrough(source).title, joining: true)
        if app?.walker?.path == path { Task { await app?.walker?.read() } }
    }

    /// The session's log: one line per event, the parts that tell what happened.
    /// The worktree's tree at a prompt or a turn's end, in the session's log: what its replay diffs.
    private func log(tree: String, of event: String, session: String) {
        log(["at": ISO8601DateFormatter().string(from: Date()), "tree": tree, "of": event], session: session, raw: true)
    }

    private func log(_ event: [String: Any], session: String, raw: Bool = false) {
        let folder = SillFolder.path(for: directory) + "/sessions"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        var line: [String: Any] = raw ? event : ["at": ISO8601DateFormatter().string(from: Date())]
        for key in ["hook_event_name", "permission_mode", "tool_name", "prompt_id"] {
            line[key] = event[key]
        }
        if let prompt = event["prompt"] as? String { line["prompt"] = String(prompt.prefix(2000)) }
        if let input = event["tool_input"] as? [String: Any] {
            for key in ["file_path", "notebook_path", "command", "pattern", "description"] {
                line[key] = input[key]
            }
        }
        guard var data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        let path = folder + "/" + session.replacingOccurrences(of: "/", with: "_") + ".jsonl"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    // MARK: Installing

    /// The project's own settings, never committed.
    var localSettings: String { root + "/.claude/settings.local.json" }

    private func readSettings() -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: localSettings) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    var installed: Bool { HookSettings.installed(marker: Self.marker, in: readSettings()) }

    /// sill's hooks into the project's local settings, beside what is there; the file as it was is kept beside it.
    func install() {
        guard let server else { return say("sill's hook socket is not running") }
        // Never committed, nor its backup: where git would see them, this clone ignores them.
        let names = [".claude/settings.local.json", ".claude/settings.local.json.before-sill"]
        if names.contains(where: { Review.git(["check-ignore", "-q", $0], in: root) == nil }),
           let main = SillFolder.mainRoot(for: root)
        {
            let exclude = main + "/.git/info/exclude"
            let text = (try? String(contentsOfFile: exclude, encoding: .utf8)) ?? ""
            if !text.contains("/.claude/settings.local.json*") {
                try? (text + (text.hasSuffix("\n") || text.isEmpty ? "" : "\n") + "/.claude/settings.local.json*\n")
                    .write(toFile: exclude, atomically: true, encoding: .utf8)
            }
        }
        // Written once git ignores them, so the follower never takes them for anyone's change.
        write(HookSettings.installing(server.command, marker: Self.marker, in: readSettings()))
        say("sill's hooks are in \(localSettings): agents here tell sill what they do")
    }

    func remove() {
        write(HookSettings.removing(marker: Self.marker, from: readSettings()))
        say("sill's hooks are out of \(localSettings)")
    }

    private func write(_ settings: [String: Any]) {
        let manager = FileManager.default
        try? manager.createDirectory(
            atPath: (localSettings as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        // The person's file as it was before sill first touched it.
        let backup = localSettings + ".before-sill"
        if manager.fileExists(atPath: localSettings), !manager.fileExists(atPath: backup) {
            try? manager.copyItem(atPath: localSettings, toPath: backup)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: URL(fileURLWithPath: localSettings))
    }

    private func say(_ text: String) {
        Nvim.lua(channel, "vim.notify(...)", [.string(text), .int(2)])
    }
}
