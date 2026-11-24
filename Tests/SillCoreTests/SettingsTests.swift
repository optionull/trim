import Foundation
import SillCore
import Testing

@Suite("settings")
struct SettingsTests {
    @Test("the default file means the defaults, and stands for the variables sill always had")
    func defaults() {
        let (settings, problems) = SettingsLoader.decode(SettingsLoader.defaultSource)
        #expect(problems.isEmpty && settings == .default)
        let environment = SillSettings.default.environment
        #expect(environment["SILL_SMOOTH_SCROLL"] == "1" && environment["SILL_AGENT"] == nil)
        #expect(environment["SILL_NVIM_CONFIG"] == "0" && environment["SILL_DOTNET"] == nil)
    }

    @Test("values are read; a bad one keeps its default and says why; a typo is reported")
    func values() throws {
        let (settings, problems) = SettingsLoader.decode("""
        [editor]
        font = "Berkeley Mono"
        size = 15
        line_height = 3
        [nvim]
        config = "sill"
        [agents]
        command = "claude"
        [editor2]
        comand = "x"
        """)
        let read = try #require(settings)
        #expect(read.font == "Berkeley Mono" && read.size == 15 && read.nvimConfig == .sill)
        #expect(read.lineHeight == 1.2, "out of range keeps the default")
        #expect(problems.map(\.description) == [
            "editor.line_height: should be from 1 to 2", "agents.command: is not a setting",
            "editor2.comand: is not a setting",
        ])
    }

    @Test("[keys] gives a command other keys, by its name; a name that is no command is reported")
    func keys() throws {
        let (settings, problems) = SettingsLoader.decode("""
        [keys]
        review.keep = "Y"
        "run.debug" = ["d", "<F5>"]
        review.kepe = "Y"
        run.edit = 3
        [keys.summary]
        review = "R"
        """)
        let read = try #require(settings)
        #expect(read.keyBindings == ["review.keep": ["Y"], "run.debug": ["d", "<F5>"], "summary.review": ["R"]])
        #expect(problems.map(\.description) == [
            "keys.review.kepe: is not a command (? in a pane lists them)",
            "keys.run.edit: should be a key, like \"Y\", or a list of them",
        ])
    }

    @Test("a syntax error keeps the last good settings")
    func syntax() {
        let store = Settings(environment: [:])
        store.load("[editor]\nsize = 16\n")
        store.load("[editor\nsize = 20\n")
        #expect(store.current.size == 16 && store.problems.first?.description.hasPrefix("line 1") == true)
    }

    @Test("the environment sill started with wins over the file")
    func environment() {
        let store = Settings(environment: ["SILL_SMOOTH_SCROLL": "1"])
        store.load("[editor]\nsmooth_scroll = false\n[home]\nroots = [\"/a\"]\n")
        #expect(store.value("SILL_SMOOTH_SCROLL") == "1" && store.overridden("SILL_SMOOTH_SCROLL"))
        #expect(store.value("SILL_ROOTS") == "/a" && !store.overridden("SILL_ROOTS"))
    }

    @Test("setting a value: in place, else on its commented-out line, else added; comments kept")
    func edit() throws {
        let set = try SettingsEdit.setting(["editor", "size"], to: .integer(15), in: SettingsLoader.defaultSource)
        #expect(set.contains("⌘0 comes back to this.\nsize = 15\n"))
        #expect(!set.contains("# size = 13"))
        let again = try SettingsEdit.setting(["editor", "size"], to: .integer(16), in: set)
        #expect(again.contains("size = 16\n") && SettingsLoader.decode(again).settings?.size == 16)
        let added = try SettingsEdit.setting(["agents", "command"], to: .string("codex"), in: "# mine\n")
        #expect(added == "# mine\n\n[agents]\ncommand = \"codex\"\n")
        let font = try SettingsEdit.setting(["editor", "font"], to: .string("Menlo"), in: again)
        #expect(SettingsLoader.decode(font).settings?.font == "Menlo" && SettingsLoader.decode(font).problems.isEmpty)
    }
}
