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
