import Foundation

/// Every key sill's own panes take, in one place, so a key means one thing wherever it means anything: `a` hands
/// something to the agent, `r` reads again, `x` takes away or stops, `m` marks seen, `w` is a walkthrough, `v` a
/// review, `J`/`K` step through what a pane holds inside its rows, `↵` does what the pane is for. `g` then a letter
/// goes somewhere, `?` lists the keys and `f` puts a label on everything that can be clicked, in every pane; `q`
/// (nvim's, in the pane's buffer) goes back to the code and `:` is nvim's command line.
///
/// A command's name is its pane and its verb (`review.keep`); `:SillKey review.keep` runs it, and the settings'
/// `[keys]` give it other keys (`review.keep = "Y"`).
public enum Keymaps {
    private static func down(_ pane: String) -> [PaneKey] {
        [
            PaneKey("\(pane).down", ["j", "<Down>"], "down", footer: false),
            PaneKey("\(pane).up", ["k", "<Up>"], "up", footer: false),
        ]
    }

    /// In every pane, after its own.
    public static let global: [PaneKey] = [
        PaneKey("go.home", ["gh"], "Home"),
        PaneKey("go.summary", ["gs"], "the summary"),
        PaneKey("go.walkthrough", ["gw"], "the newest walkthrough"),
        PaneKey("go.review", ["gv"], "the review"),
        PaneKey("go.run", ["gr"], "Run"),
        PaneKey("go.map", ["gm"], "the code map"),
        PaneKey("go.pr", ["gp"], "the pull request"),
        PaneKey("go.baskets", ["gb"], "the baskets"),
        PaneKey("go.explorer", ["ge"], "the explorer"),
        PaneKey("go.changes", ["gc"], "the changes"),
        PaneKey("go.agents", ["ga"], "the agents"),
        PaneKey("keys.help", ["?"], "all keys"),
        PaneKey("keys.hints", ["f"], "hints: click by key"),
    ]

    public static let summary = Keymap(pane: "summary", own: [
        PaneKey("summary.walkthrough", ["w"], "the newest walkthrough"),
        PaneKey("summary.review", ["v"], "review the branch"),
        PaneKey("summary.reviewSince", ["V"], "review since you looked"),
        PaneKey("summary.refresh", ["r"], "read again"),
    ])

    public static let run = Keymap(pane: "run", own: down("run") + [
        PaneKey("run.run", ["<CR>"], "run"),
        PaneKey("run.edit", ["e"], "change the command, then run"),
        PaneKey("run.debug", ["d"], "debug"),
        PaneKey("run.profile", ["p"], "profile"),
        PaneKey("run.refresh", ["r"], "read again", footer: false),
    ])

    public static let review = Keymap(pane: "review", own: [
        PaneKey("review.down", ["j"], "next file", footer: false),
        PaneKey("review.up", ["k"], "previous file", footer: false),
        PaneKey("review.next", ["J"], "next change"),
        PaneKey("review.previous", ["K"], "previous change", footer: false),
        PaneKey("review.keep", ["y"], "keep"),
        PaneKey("review.takeBack", ["x"], "take back"),
        PaneKey("review.comment", ["c"], "comment"),
        PaneKey("review.seen", ["m"], "seen"),
        PaneKey("review.areaSeen", ["M"], "area seen"),
        PaneKey("review.agent", ["a"], "send the comments"),
        PaneKey("review.walkthrough", ["w"], "walkthrough"),
        PaneKey("review.side", ["<CR>"], "side by side"),
        PaneKey("review.refresh", ["r"], "read again", footer: false),
        PaneKey("review.baseline", ["1", "2", "3", "4", "5", "6", "7", "8", "9"], "the n-th baseline", footer: false),
    ])

    public static let pr = Keymap(pane: "pr", own: [
        PaneKey("pr.agent", ["a"], "send to the agent"),
        PaneKey("pr.review", ["v"], "review its changes"),
        PaneKey("pr.walkthrough", ["w"], "walkthrough"),
        PaneKey("pr.browser", ["gB"], "open on GitHub"),
        PaneKey("pr.refresh", ["r"], "read again"),
    ])

    public static let map = Keymap(pane: "map", own: [
        PaneKey("map.down", ["j"], "next project", footer: false),
        PaneKey("map.up", ["k"], "previous project", footer: false),
        PaneKey("map.open", ["<CR>"], "open"),
        PaneKey("map.agent", ["a"], "ask for a summary"),
        PaneKey("map.walkthrough", ["w"], "walkthrough"),
        PaneKey("map.refresh", ["r"], "read again"),
    ])

    public static let trace = Keymap(pane: "trace", own: down("trace") + [
        PaneKey("trace.expand", ["l", "<Right>"], "open a level"),
        PaneKey("trace.collapse", ["h", "<Left>"], "close a level", footer: false),
        PaneKey("trace.open", ["<CR>"], "go to the call"),
        PaneKey("trace.turn", ["t"], "callers ⇄ callees"),
        PaneKey("trace.agent", ["a"], "explain the path"),
        PaneKey("trace.basket", ["b"], "to the basket"),
    ])

    public static let replay = Keymap(pane: "replay", own: [
        PaneKey("replay.down", ["j"], "next prompt", footer: false),
        PaneKey("replay.up", ["k"], "previous prompt", footer: false),
        PaneKey("replay.next", ["J"], "next file"),
        PaneKey("replay.previous", ["K"], "previous file", footer: false),
        PaneKey("replay.open", ["<CR>"], "open the file"),
        PaneKey("replay.refresh", ["r"], "read again"),
    ])

    public static let telemetry = Keymap(pane: "telemetry", own: down("telemetry") + [
        PaneKey("telemetry.tab", ["1", "2", "3"], "logs, traces, metrics"),
        PaneKey("telemetry.level", ["L"], "all ⇢ warnings ⇢ errors"),
        PaneKey("telemetry.stop", ["x"], "stop watching"),
    ])

    public static let profile = Keymap(pane: "profile", own: down("profile") + [
        PaneKey("profile.tab", ["1", "2", "3", "4", "5"], "the n-th tab", footer: false),
        PaneKey("profile.open", ["<CR>"], "go to the code"),
        PaneKey("profile.snapshot", ["s"], "heap snapshot"),
        PaneKey("profile.stop", ["x"], "stop"),
        PaneKey("profile.agent", ["a"], "send to the agent"),
        PaneKey("profile.all", ["0"], "all of the run"),
        PaneKey("profile.clear", ["<Esc>"], "clear the selection", footer: false),
    ])

    public static let packages = Keymap(pane: "packages", own: down("packages") + [
        PaneKey("packages.filter", ["1", "2", "3", "4", "5"], "filter"),
        PaneKey("packages.update", ["u"], "update"),
        PaneKey("packages.agent", ["a"], "ask the agent"),
        PaneKey("packages.refresh", ["r"], "read again"),
    ])

    public static let walk = Keymap(pane: "walk", own: down("walk") + [
        PaneKey("walk.next", ["J"], "next step"),
        PaneKey("walk.previous", ["K"], "previous step"),
        PaneKey("walk.open", ["<CR>", "o"], "open the code"),
        PaneKey("walk.agent", ["a"], "ask about this step"),
        PaneKey("walk.examples", ["R"], "run its examples"),
        PaneKey("walk.refresh", ["r"], "read again", footer: false),
    ])

    public static let basket = Keymap(pane: "basket", own: down("basket") + [
        PaneKey("basket.next", ["J"], "next piece", footer: false),
        PaneKey("basket.previous", ["K"], "previous piece", footer: false),
        PaneKey("basket.open", ["<CR>", "o"], "open the code", footer: false),
        PaneKey("basket.agent", ["a"], "send to the agent"),
        PaneKey("basket.findings", ["A"], "ask for findings"),
        PaneKey("basket.details", ["i"], "details"),
        PaneKey("basket.remove", ["x"], "remove the piece"),
        PaneKey("basket.side", ["<Tab>"], "outline ⇢ files ⇢ context"),
        PaneKey("basket.refresh", ["r"], "read again", footer: false),
    ])

    public static let explorer = Keymap(pane: "explorer", own: down("explorer") + [
        PaneKey("explorer.top", ["gg"], "the top", footer: false),
        PaneKey("explorer.bottom", ["G"], "the bottom", footer: false),
        PaneKey("explorer.open", ["<CR>", "o"], "open"),
        PaneKey("explorer.expand", ["l", "<Right>"], "open a folder", footer: false),
        PaneKey("explorer.collapse", ["h", "<Left>"], "close a folder", footer: false),
        PaneKey("explorer.side", ["<Tab>"], "next tab"),
        PaneKey("explorer.filter", ["/"], "filter"),
        PaneKey("explorer.ignored", ["I"], "show ignored"),
        PaneKey("explorer.refresh", ["r"], "read again", footer: false),
    ])

    public static let changes = Keymap(pane: "changes", own: down("changes") + [
        PaneKey("changes.open", ["<CR>", "o"], "open"),
        PaneKey("changes.refresh", ["r"], "read again"),
    ])

    public static let agents = Keymap(pane: "agents", own: down("agents") + [
        PaneKey("agents.open", ["<CR>", "o"], "open in heed"),
    ])

    public static let problems = Keymap(pane: "problems", own: down("problems") + [
        PaneKey("problems.open", ["<CR>"], "go to it"),
        PaneKey("problems.side", ["<Tab>"], "next tab"),
        PaneKey("problems.agent", ["a"], "send all to the agent"),
    ])

    /// Home has no checkout to go to: only the key list and the hints are shared.
    public static let home = Keymap(pane: "home", own: down("home") + [
        PaneKey("home.open", ["<CR>"], "open"),
        PaneKey("home.new", ["n"], "the newest walkthrough"),
        PaneKey("home.refresh", ["r"], "read again"),
        PaneKey("home.folders", ["F"], "folders"),
    ], shared: global.filter { $0.pane == "keys" })

    public static let all: [Keymap] = [
        summary, run, review, pr, map, trace, replay, telemetry, profile, packages, walk, basket, explorer, changes,
        agents, problems, home,
    ]

    /// The keymap of a pane by its kind (nvim's `sill_kind` of the pane's window, or the sidebar's view).
    public static func pane(_ kind: String) -> Keymap? { all.first { $0.pane == kind } }

    /// Every command's name, for `:SillKey`'s completion and the settings' `[keys]`.
    public static var names: [String] {
        var seen: Set<String> = []
        return all.flatMap(\.all).map(\.name).filter { seen.insert($0).inserted }
    }

    /// The keys the settings give (`[keys]`), set when the settings are read.
    public nonisolated(unsafe) static var overrides: [String: [String]] = [:]

    /// A pane's keys as the settings have them.
    public static func current(_ kind: String) -> Keymap? { pane(kind)?.applying(overrides) }
}
