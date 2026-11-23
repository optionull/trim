import Foundation
@testable import SillCore
import Testing

@Suite("nvim configs to switch between")
struct NvimConfigsTests {
    /// A config home holding the folders given: each name with the files in it.
    private func home(_ folders: [String: [String]]) throws -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sill-configs-\(UUID().uuidString)")
        for (name, files) in folders {
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for file in files {
                try "".write(to: folder.appendingPathComponent(file), atomically: true, encoding: .utf8)
            }
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.path
    }

    @Test("sill's own first, then nvim, then the other folders with an init by name")
    func discovers() throws {
        let root = try home([
            "nvim": ["init.lua"], "kickstart": ["init.lua"], "astro": ["init.vim"], "lazy10": ["init.lua"],
            "lazy2": ["init.lua"], "fish": ["config.fish"], "empty": [], ".hidden": ["init.lua"],
        ])
        let configs = NvimConfigs.discover(environment: ["XDG_CONFIG_HOME": root])
        #expect(configs.map(\.appName) == ["sill", "nvim", "astro", "kickstart", "lazy2", "lazy10"])
        #expect(configs.map(\.isBuiltIn) == [true, false, false, false, false, false])
    }

    @Test("a folder named sill is the built-in config's settings, not another config")
    func sillFolder() throws {
        let root = try home(["sill": ["init.lua"]])
        #expect(NvimConfigs.discover(environment: ["XDG_CONFIG_HOME": root]) == [.builtIn])
    }

    @Test("a symlinked folder counts, a file does not, and an empty home has only the built-in one")
    func symlinks() throws {
        let root = try home(["real": ["init.lua"]])
        try FileManager.default.createSymbolicLink(atPath: "\(root)/linked", withDestinationPath: "\(root)/real")
        try "".write(toFile: "\(root)/afile", atomically: true, encoding: .utf8)
        #expect(NvimConfigs.discover(environment: ["XDG_CONFIG_HOME": root]).map(\.appName) == [
            "sill",
            "linked",
            "real",
        ])
        #expect(NvimConfigs
            .discover(environment: ["XDG_CONFIG_HOME": "/nonexistent-\(UUID().uuidString)"]) == [.builtIn])
    }

    @Test("a config starts nvim as EditorSession.startup does for it")
    func startups() throws {
        let root = try home(["mine": ["init.lua"]])
        let environment = ["XDG_CONFIG_HOME": root, "NVIM_APPNAME": "mine"]
        #expect(NvimConfig(appName: "mine").startup == EditorSession.startup(environment: environment, own: false))
        #expect(NvimConfig.builtIn.startup == EditorSession.startup(environment: environment, own: true))
    }
}
