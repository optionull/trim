import Foundation

/// An nvim config sill can run: nvim finds a config by its `NVIM_APPNAME`, a folder of that name under
/// `$XDG_CONFIG_HOME` (with its own plugins and lockfile, so configs never share state), or sill's own built in.
public struct NvimConfig: Equatable, Sendable, Identifiable {
    public var appName: String
    public var isBuiltIn: Bool

    public var id: String { appName }
    public var title: String { isBuiltIn ? "sill (built in)" : appName }

    public init(appName: String, isBuiltIn: Bool = false) {
        self.appName = appName
        self.isBuiltIn = isBuiltIn
    }

    /// sill's own nvim: its colours, completion and finding, nothing to set up.
    public static let builtIn = NvimConfig(appName: "sill", isBuiltIn: true)

    /// How nvim starts with it, as `EditorSession.startup` would for the same config.
    public var startup: EditorSession.Startup {
        EditorSession.Startup(appName: appName, arguments: EditorSession.baseArguments, userConfig: !isBuiltIn)
    }
}

public enum NvimConfigs {
    /// `$XDG_CONFIG_HOME`, else `~/.config`.
    public static func configHome(environment: [String: String]) -> String {
        let home = environment["HOME"] ?? NSHomeDirectory()
        return environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(home)/.config"
    }

    /// The configs there are to switch to: sill's own first, then every folder in the config home holding an
    /// init.lua or init.vim (symlinked folders too, as dotfiles managers make them), `nvim` first, the rest by name.
    /// `sill` itself is the built-in config's folder (its settings and additions), not another one.
    public static func discover(environment: [String: String]) -> [NvimConfig] {
        let home = configHome(environment: environment)
        let fileManager = FileManager.default
        let names = ((try? fileManager.contentsOfDirectory(atPath: home)) ?? []).filter { name in
            guard !name.hasPrefix("."), name != NvimConfig.builtIn.appName else { return false }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: "\(home)/\(name)", isDirectory: &isDirectory), isDirectory.boolValue
            else { return false }
            return ["init.lua", "init.vim"].contains { fileManager.fileExists(atPath: "\(home)/\(name)/\($0)") }
        }
        let sorted = names.sorted { a, b in
            if (a == "nvim") != (b == "nvim") { return a == "nvim" }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
        return [.builtIn] + sorted.map { NvimConfig(appName: $0) }
    }
}
