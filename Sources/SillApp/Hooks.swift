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
    private weak var app: AppDelegate?
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
    private var handled = 0

    init(app: AppDelegate, channel: NvimChannel, directory: String) {
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

    /// An event's JSON in, the hook's output out (nothing yet: sill listens, it does not decide).
    func handle(_ data: Data) -> Data {
        guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return Data() }
        handle(event)
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
            app?.reviewer?.mark("prompt: " + (prompt.count > 40 ? prompt.prefix(40) + "…" : prompt))
        case "PreToolUse" where tool == "ExitPlanMode":
            if let plan = input["plan"] as? String { presented(plan) }
        case "PostToolUse" where tool == "ExitPlanMode":
            let response = event["tool_response"] as? [String: Any]
            approved((response?["plan"] as? String) ?? (input["plan"] as? String))
        case "PostToolUse" where Self.edits.contains(tool ?? ""):
            if let path = (input["file_path"] ?? input["notebook_path"]) as? String {
                let absolute = path.hasPrefix("/") ? path : (root as NSString).appendingPathComponent(path)
                app?.follower?.agentWrote(absolute)
                app?.baskets?.editedWhileInvestigating(absolute, tool: tool ?? "")
            }
        case "Stop":
            app?.reviewer?.mark("turn ended")
            app?.baskets?.turnEnded()
        default: break
        }
    }

    /// A plan presented for approval: a notebook in `.sill/plans`, shown.
    private func presented(_ plan: String) {
        let folder = SillFolder.path(for: directory) + "/plans"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let source = PlanFile.notebook(plan, root: root)
        let path = folder + "/" + PlanFile.fileName(title: Walkthrough(source).title, at: Date())
        try? source.write(toFile: path, atomically: true, encoding: .utf8)
        lastPlan = path
        app?.walker?.open(path)
    }

    /// The plan approved: its notebook says so, and the worktree now is a baseline named after it.
    private func approved(_ plan: String?) {
        if lastPlan == nil, let plan { presented(plan) }
        guard let path = lastPlan, let source = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        try? BasketFile.setting(source, "status", to: "approved").write(toFile: path, atomically: true, encoding: .utf8)
        app?.reviewer?.mark("plan approved: " + Walkthrough(source).title, joining: true)
        if app?.walker?.path == path { Task { await app?.walker?.read() } }
    }

    /// The session's log: one line per event, the parts that tell what happened.
    private func log(_ event: [String: Any], session: String) {
        let folder = SillFolder.path(for: directory) + "/sessions"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        var line: [String: Any] = ["at": ISO8601DateFormatter().string(from: Date())]
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
        write(HookSettings.installing(server.command, marker: Self.marker, in: readSettings()))
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
