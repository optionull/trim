@testable import FrameModes
import Testing

@Suite struct ModesTests {
    func normal(_ modes: inout Modes) -> ModeEffect { modes.escape(editorMode: "normal", sidebarVisible: true) }

    @Test func `a fresh editor sends Escape to the tree, and then Escape comes back, again and again`() {
        var modes = Modes()
        #expect(modes.surface == .editor)
        for _ in 0 ..< 3 {
            #expect(normal(&modes) == .focus(.tree))
            #expect(modes.surface == .tree)
            #expect(normal(&modes) == .focus(.editor))
            #expect(modes.surface == .editor)
        }
    }

    @Test func `in the editor's other modes Escape is nvim's`() {
        var modes = Modes()
        for mode in ["insert", "visual", "replace", "cmdline_normal", "operator", "terminal"] {
            #expect(modes.escape(editorMode: mode, sidebarVisible: true) == .pass)
            #expect(modes.surface == .editor)
        }
    }

    @Test func `with no sidebar Escape stays nvim's`() {
        var modes = Modes()
        #expect(modes.escape(editorMode: "normal", sidebarVisible: false) == .pass)
    }

    @Test func `a click into the editor makes Escape nvim's`() {
        var modes = Modes()
        modes.focused(.editor, byClick: true)
        #expect(normal(&modes) == .pass)
    }

    @Test func `handing the keyboard from the tree to the editor makes Escape take it back`() {
        var modes = Modes()
        modes.focused(.editor, byClick: true)
        modes.focused(.tree)
        modes.handedToEditor()
        #expect(modes.surface == .editor)
        #expect(normal(&modes) == .focus(.tree))
    }

    @Test func `a keyboard move that is not a click leaves where Escape goes alone`() {
        var modes = Modes()
        modes.focused(.tree)
        modes.focused(.editor)
        #expect(normal(&modes) == .focus(.tree))
    }

    @Test func `Escape in a filter ends it first and leaves the tree on the next`() {
        var modes = Modes()
        modes.focused(.tree)
        modes.filterChanged(open: true)
        #expect(modes.treeMode == .filter && modes.surface == .tree)
        #expect(normal(&modes) == .closeFilter)
        #expect(modes.treeMode == .normal && modes.surface == .tree)
        #expect(normal(&modes) == .focus(.editor))
    }

    @Test func `opening the filter puts the keyboard in the tree`() {
        var modes = Modes()
        modes.filterChanged(open: true)
        #expect(modes.surface == .tree)
    }

    @Test func `Escape in the switcher goes back to where the keyboard was`() {
        for beneath in [Surface.editor, .tree] {
            var modes = Modes()
            modes.focused(beneath)
            modes.openSwitcher()
            #expect(modes.surface == .switcher)
            #expect(normal(&modes) == .closeSwitcher(restoring: beneath))
            #expect(modes.surface == beneath)
        }
    }

    @Test func `nothing takes the keyboard from the switcher but itself`() {
        var modes = Modes()
        modes.openSwitcher()
        modes.focused(.tree)
        modes.handedToEditor()
        #expect(modes.surface == .switcher)
    }

    @Test func `choosing in the switcher gives the keyboard back too`() {
        var modes = Modes()
        modes.focused(.tree)
        modes.openSwitcher()
        #expect(modes.closeSwitcher() == .tree)
        #expect(modes.surface == .tree)
    }

    @Test func `a switcher opened over a filter gives the tree back, still filtering`() {
        var modes = Modes()
        modes.filterChanged(open: true)
        modes.openSwitcher()
        #expect(normal(&modes) == .closeSwitcher(restoring: .tree))
        #expect(modes.treeMode == .filter)
    }

    @Test func `hiding the sidebar takes the keyboard out of it, and ends what the tree was doing`() {
        var modes = Modes()
        modes.filterChanged(open: true)
        modes.sidebarHidden()
        #expect(modes.surface == .editor && modes.treeMode == .normal)
    }

    @Test func `a new nvim is a fresh editor`() {
        var modes = Modes()
        modes.focused(.editor, byClick: true)
        modes.filterChanged(open: true)
        modes.openSwitcher()
        modes.editorRestarted()
        #expect(modes == Modes())
        #expect(normal(&modes) == .focus(.tree))
    }

    @Test func `the mode as a word is Frame's while the keyboard is outside nvim`() {
        var modes = Modes()
        #expect(modes.label(editorMode: "insert") == "INSERT")
        #expect(modes.label(editorMode: "cmdline_normal") == "COMMAND")
        modes.focused(.tree)
        #expect(modes.label(editorMode: "insert") == "TREE")
        modes.filterChanged(open: true)
        #expect(modes.label(editorMode: "normal") == "FILTER")
        modes.openSwitcher()
        #expect(modes.label(editorMode: "normal") == "SWITCH")
    }
}

@Suite struct StatusLineTests {
    @Test func `where the window is in the buffer, as vim says it`() {
        #expect(StatusLine.percent(line: 1, lines: 10, firstVisible: 1, lastVisible: 10) == "All")
        #expect(StatusLine.percent(line: 3, lines: 100, firstVisible: 1, lastVisible: 40) == "Top")
        #expect(StatusLine.percent(line: 95, lines: 100, firstVisible: 60, lastVisible: 100) == "Bot")
        #expect(StatusLine.percent(line: 50, lines: 100, firstVisible: 30, lastVisible: 70) == "50%")
        #expect(StatusLine.percent(line: 0, lines: 0) == "All")
    }

    @Test func `a path is relative inside the workspace, else with the home folder as a tilde`() {
        #expect(StatusLine.displayPath("/w/proj/src/a.swift", root: "/w/proj", home: "/Users/me") == "src/a.swift")
        #expect(StatusLine.displayPath("/Users/me/notes/x.md", root: "/w/proj", home: "/Users/me") == "~/notes/x.md")
        #expect(StatusLine.displayPath("/etc/hosts", root: "/w/proj", home: "/Users/me") == "/etc/hosts")
        #expect(StatusLine
            .displayPath("/w/projects/a.swift", root: "/w/proj", home: "/Users/me") == "/w/projects/a.swift")
        #expect(StatusLine.displayPath("", root: "/w/proj") == "")
    }

    @Test func `only the diagnostics there are`() {
        let counts = StatusLine.counts(errors: 2, warnings: 0, infos: 0, hints: 1)
        #expect(counts.map(\.kind) == ["error", "hint"] && counts.map(\.count) == [2, 1])
        #expect(StatusLine.counts(errors: 0, warnings: 0, infos: 0, hints: 0).isEmpty)
    }
}

@Suite struct TabsTests {
    func tab(_ id: Int, _ path: String, edited: Bool = false, modified: Bool = false) -> FrameTab {
        FrameTab(id: id, path: path, modified: modified, edited: edited)
    }

    @Test func `a tab says its file's name`() {
        let tabs = [tab(1, "/w/a/one.swift"), tab(2, "/w/a/two.swift")]
        #expect(Tabs.labels(tabs) == [1: "one.swift", 2: "two.swift"])
    }

    @Test func `the same name says where, with as few folders as tell them apart`() {
        let tabs = [tab(1, "/w/a/index.ts"), tab(2, "/w/b/index.ts"), tab(3, "/w/x/other.ts")]
        let labels = Tabs.labels(tabs)
        #expect(labels[1] == "index.ts · a" && labels[2] == "index.ts · b" && labels[3] == "other.ts")
        let deep = Tabs.labels([tab(1, "/w/a/src/index.ts"), tab(2, "/w/b/src/index.ts")])
        #expect(deep[1] == "index.ts · a/src" && deep[2] == "index.ts · b/src")
    }

    @Test func `a preview is a tab nobody edited`() {
        #expect(tab(1, "/a").isPreview)
        #expect(!tab(1, "/a", edited: true).isPreview)
        #expect(!tab(1, "/a", modified: true).isPreview)
    }

    @Test func `the next and previous tab go round`() {
        let tabs = [tab(5, "/a"), tab(7, "/b"), tab(9, "/c")]
        #expect(Tabs.neighbor(of: 5, in: tabs, by: 1) == 7)
        #expect(Tabs.neighbor(of: 9, in: tabs, by: 1) == 5)
        #expect(Tabs.neighbor(of: 5, in: tabs, by: -1) == 9)
        #expect(Tabs.neighbor(of: nil, in: tabs, by: 1) == 5)
        #expect(Tabs.neighbor(of: 7, in: [], by: 1) == nil)
        #expect(Tabs.neighbor(of: 7, in: [tab(7, "/b")], by: 1) == 7)
    }

    @Test func `a numbered tab, the ninth being the last`() {
        let tabs = [tab(5, "/a"), tab(7, "/b"), tab(9, "/c")]
        #expect(Tabs.numbered(1, in: tabs) == 5 && Tabs.numbered(3, in: tabs) == 9)
        #expect(Tabs.numbered(4, in: tabs) == nil && Tabs.numbered(9, in: tabs) == 9 && Tabs
            .numbered(0, in: tabs) == nil)
    }

    @Test func `the placements say whether they are a strip`() {
        #expect(TabsPlacement.top.isStrip && TabsPlacement.bottom.isStrip)
        #expect(!TabsPlacement.right.isStrip && !TabsPlacement.hidden.isStrip)
        #expect(TabsPlacement(rawValue: "right") == .right && TabsPlacement(rawValue: "tree") == nil)
    }

    @Test func `tabs show only when there is more than one file, and not when hidden`() {
        #expect(!Tabs.isShown(count: 0, placement: .top) && !Tabs.isShown(count: 1, placement: .top))
        #expect(Tabs.isShown(count: 2, placement: .top) && Tabs.isShown(count: 5, placement: .right))
        #expect(!Tabs.isShown(count: 5, placement: .hidden))
    }
}
