import Foundation
import SillInput

/// sill's settings: `~/.config/sill/settings.toml` (or under `$XDG_CONFIG_HOME`), edited by hand or through the
/// settings window, which changes one value in place and leaves the rest of the file alone. What nvim already has a
/// setting for stays in the nvim config; these are what only sill has. Each one stands for an environment variable
/// sill has always read, and a variable set when sill starts wins over the file (the checks rely on that).
public struct SillSettings: Equatable, Sendable {
    public enum NvimConfig: String, Sendable, CaseIterable {
        /// The user's own nvim config (`~/.config/nvim`), after sill's base settings.
        case yours
        /// sill's base settings alone.
        case sill
    }

    public var font = "JetBrains Mono"
    public var size: Double = 13
    public var lineHeight: Double = 1.2
    public var smoothScroll = true
    /// The explorer, editor windows and panel as rounded islands on a darker canvas.
    public var islands = true
    /// The shell's window with its title bar (its buttons); without it the window moves by its margin.
    public var shellTitleBar = false
    public var nvimConfig = NvimConfig.sill
    public var dotnet = ""
    /// The folders whose git checkouts Home lists (asked for when sill first starts).
    public var roots: [String] = []
    /// Other keys for sill's own panes' commands, by the command's name (`[keys]`, `review.keep = "Y"`).
    public var keyBindings: [String: [String]] = [:]

    public static let `default` = SillSettings()

    public init() {}

    /// The environment variables these stand for; an empty path is no variable.
    public var environment: [String: String] {
        var environment = [
            "SILL_SMOOTH_SCROLL": smoothScroll ? "1" : "0",
            "SILL_NVIM_CONFIG": nvimConfig == .yours ? "1" : "0",
        ]
        if !dotnet.isEmpty { environment["SILL_DOTNET"] = dotnet }
        if !roots.isEmpty { environment["SILL_ROOTS"] = roots.joined(separator: ":") }
        return environment
    }

    /// Each setting: where it is in the file and the variable it stands for, in the window's order.
    public static let keys: [(path: [String], variable: String?)] = [
        (["editor", "font"], nil), (["editor", "size"], nil), (["editor", "line_height"], nil),
        (["editor", "smooth_scroll"], "SILL_SMOOTH_SCROLL"),
        (["window", "islands"], nil), (["shell", "title_bar"], nil),
        (["nvim", "config"], "SILL_NVIM_CONFIG"), (["home", "roots"], "SILL_ROOTS"),
        (["dotnet", "path"], "SILL_DOTNET"),
    ]
}

/// A setting that could not be used: the file's line for a syntax error (then nothing in the file is used), else the
/// key, which keeps its default.
public struct SettingsProblem: Equatable, Sendable, CustomStringConvertible {
    public var path: String
    public var message: String
    public var description: String { path.isEmpty ? message : "\(path): \(message)" }
}

public enum SettingsLoader {
    /// `$XDG_CONFIG_HOME/sill/settings.toml`, else `~/.config/sill/settings.toml`.
    public static func defaultFile(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("sill/settings.toml")
    }

    /// The settings a source says, from the defaults: a key that does not decode keeps its default and is a problem;
    /// a syntax error gives no settings (the caller keeps what it had).
    public static func decode(_ source: String) -> (settings: SillSettings?, problems: [SettingsProblem]) {
        let document: TOMLDocument
        do {
            document = try TOMLDocument(source)
        } catch {
            return (nil, [SettingsProblem(path: "", message: "line \(error.line): \(error.message)")])
        }
        var settings = SillSettings.default
        var problems: [SettingsProblem] = []
        func value(_ path: [String]) -> TOMLValue? { document.root.value(at: path) }
        func problem(_ path: [String], _ message: String) {
            problems.append(SettingsProblem(path: path.joined(separator: "."), message: message))
        }
        func string(_ path: [String], _ apply: (String) -> Void) {
            guard let found = value(path) else { return }
            if let text = found.string { apply(text) } else { problem(path, "should be a string, in quotes") }
        }
        func bool(_ path: [String], _ apply: (Bool) -> Void) {
            guard let found = value(path) else { return }
            if let flag = found.bool { apply(flag) } else { problem(path, "should be true or false") }
        }
        func number(_ path: [String], _ range: ClosedRange<Double>, _ apply: (Double) -> Void) {
            guard let found = value(path) else { return }
            let number: Double? = switch found {
            case let .integer(value): Double(value)
            case let .float(value): value
            default: nil
            }
            guard let number else { return problem(path, "should be a number") }
            guard range.contains(number) else {
                return problem(path, "should be from \(format(range.lowerBound)) to \(format(range.upperBound))")
            }
            apply(number)
        }

        string(["editor", "font"]) { settings.font = $0 }
        number(["editor", "size"], 6 ... 72) { settings.size = $0 }
        number(["editor", "line_height"], 1 ... 2) { settings.lineHeight = $0 }
        bool(["editor", "smooth_scroll"]) { settings.smoothScroll = $0 }
        bool(["window", "islands"]) { settings.islands = $0 }
        bool(["shell", "title_bar"]) { settings.shellTitleBar = $0 }
        string(["nvim", "config"]) { text in
            if let config = SillSettings.NvimConfig(rawValue: text) {
                settings.nvimConfig = config
            } else {
                problem(["nvim", "config"], "should be \"yours\" or \"sill\"")
            }
        }
        if let found = value(["home", "roots"]) {
            if let items = found.array, items.allSatisfy({ $0.string != nil }) {
                settings.roots = items.compactMap(\.string)
            } else {
                problem(["home", "roots"], "should be a list of folders, like [\"~/Projects\"]")
            }
        }
        string(["dotnet", "path"]) { settings.dotnet = $0 }

        // `[keys]`: a command's name, its pane and its verb (`review.keep`, so `[keys.review]` and `keep` too), and a key
        // or a list of them in nvim's notation.
        if let found = value(["keys"]) {
            if let panes = found.table {
                let names = Set(Keymaps.names)
                func bind(_ path: [String], _ name: String, _ value: TOMLValue?) {
                    guard names.contains(name)
                    else { return problem(path, "is not a command (? in a pane lists them)") }
                    let keys: [String]? = switch value {
                    case let .string(key)?: [key]
                    case let .array(items)?: items.allSatisfy { $0.string != nil } ? items.compactMap(\.string) : nil
                    default: nil
                    }
                    guard let keys, !keys.isEmpty, keys.allSatisfy({ !$0.isEmpty }) else {
                        return problem(path, "should be a key, like \"Y\", or a list of them")
                    }
                    settings.keyBindings[name] = keys
                }
                for pane in panes.keys {
                    // `"review.keep" = "Y"`, quoted: the name as one key.
                    guard let verbs = panes[pane]?.table else {
                        bind(["keys", pane], pane, panes[pane])
                        continue
                    }
                    for verb in verbs.keys {
                        bind(["keys", pane, verb], "\(pane).\(verb)", verbs[verb])
                    }
                }
            } else {
                problem(["keys"], "should be a table, [keys]")
            }
        }

        // A key sill does not know is most likely a typo: say so rather than ignore it.
        let known = Set(SillSettings.keys.map(\.path))
        for table in document.root.keys where table != "keys" {
            guard let inner = document.root[table]?.table else {
                problem([table], "is not a setting (settings are in tables, like [editor])")
                continue
            }
            for key in inner.keys where !known.contains([table, key]) {
                problem([table, key], "is not a setting")
            }
        }
        return (settings, problems)
    }

    private static func format(_ number: Double) -> String {
        number == number.rounded() ? String(Int(number)) : String(number)
    }

    /// The file written the first time: every setting at its default, commented out, with what it does.
    public static let defaultSource = """
    # sill's settings. A line starting with # is a comment: remove the # to change a setting. The settings window
    # (⌘,) edits this file too, and keeps your comments. What nvim has an option for stays in your nvim config.
    # An environment variable named below, set when sill starts, wins over this file.

    [editor]
    # The grid's font, a monospaced one installed on this Mac.
    # font = "JetBrains Mono"
    # Its size in points, 6 to 72. ⌘+ and ⌘- change it for a session, ⌘0 comes back to this.
    # size = 13
    # A line's height as a multiple of the font's, 1 to 2.
    # line_height = 1.2
    # Scroll by pixels as the trackpad moves, not a line at a time. (SILL_SMOOTH_SCROLL)
    # smooth_scroll = true

    [window]
    # The explorer, each editor window and the panel as rounded islands on a darker canvas; false is flat panels.
    # islands = true

    [shell]
    # The shell (nvim alone in a window) with its title bar and buttons; without, it moves by its margin.
    # title_bar = false

    [nvim]
    # "sill" (the default) runs sill's own nvim: its colours, completion and finding, nothing to set up; your
    # additions go in ~/.config/sill/init.lua. "yours" loads your nvim config (~/.config/nvim) instead, with what sill
    # draws itself (explorer, messages, start screen) turned off in it.
    # (SILL_NVIM_CONFIG)
    # config = "sill"

    [home]
    # The folders whose git checkouts Home lists, most recently active first; asked for when sill first starts.
    # (SILL_ROOTS, separated by colons)
    # roots = ["~/Projects"]

    [dotnet]
    # The dotnet to use; empty finds it (DOTNET_ROOT, your shell's PATH, the usual places). (SILL_DOTNET)
    # path = ""

    [keys]
    # Other keys for the commands of sill's own panes (Home, the summary, the review, Run, …), by the command's
    # name: ? in a pane lists them, with their keys. A key in nvim's notation, or a list of them.
    # review.keep = "Y"
    # run.debug = ["d", "<F5>"]

    """
}

/// The settings sill runs with, read from any thread: the file's, under the environment sill started with.
public final class Settings: @unchecked Sendable {
    public static let shared = Settings()

    private let lock = NSLock()
    private var _current = SillSettings.default
    private var _problems: [SettingsProblem] = []
    /// The environment as sill started: what it sets wins over the file.
    public let launchEnvironment: [String: String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        launchEnvironment = environment
    }

    public var current: SillSettings { lock.withLock { _current } }
    public var problems: [SettingsProblem] { lock.withLock { _problems } }

    /// Reads a source: its settings when it parses (a key that does not keeps its default), the last good ones when
    /// it does not. Returns whether anything changed.
    @discardableResult
    public func load(_ source: String) -> Bool {
        let (settings, problems) = SettingsLoader.decode(source)
        return lock.withLock {
            let before = (_current, _problems)
            if let settings { _current = settings }
            _problems = problems
            return before.0 != _current || before.1 != _problems
        }
    }

    /// A variable's value: the environment's when sill started with it, else what the settings say.
    public func value(_ variable: String) -> String? {
        launchEnvironment[variable] ?? current.environment[variable]
    }

    /// Whether the environment sill started with sets this variable (so the file's value is not in effect).
    public func overridden(_ variable: String) -> Bool { launchEnvironment[variable] != nil }

    /// The environment with the settings under it, for code that takes a whole environment.
    public var environment: [String: String] {
        current.environment.merging(launchEnvironment) { _, launch in launch }
    }
}
