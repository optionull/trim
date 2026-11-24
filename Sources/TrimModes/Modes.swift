import Foundation

/// Where the keyboard is in a window of the frame. Like vim's modes, each is entered and left on purpose, and Escape
/// is the one way out of whichever it is in, towards where the person came from.
public enum Surface: Equatable, Sendable {
    /// nvim: it has modes of its own (normal, insert...), which `Modes` only reads.
    case editor
    /// The file tree.
    case tree
    /// The workspace switcher, over everything.
    case switcher
    /// The list of open files the status bar opens, over everything.
    case picker
    /// The terminal pane a run or build goes to (a shell: Escape is its own).
    case terminal
    /// The Run pane: what can be run and the person's own configurations (its own pane, beside the build pane's slot).
    case run
    /// The walkthrough pane: a document read in nvim's own modes (its buffer is a real one), beside the code.
    case walk
    /// A list of choices over everything (the colour schemes, later the packages and the files): its own title says
    /// which.
    case list

    /// A panel over the window that takes the keyboard and gives it back: nothing else moves it meanwhile.
    public var isOverlay: Bool { self == .switcher || self == .picker || self == .list }
}

/// What the tree is doing, as vim has modes. A new one (a diff, a context switch) is a case here, with its own way out
/// in `Modes.escape`.
public enum TreeMode: Equatable, Sendable {
    case normal
    /// A filter is showing, typed into or being walked through.
    case filter
}

/// What the window must do for a key, as `Modes` decides it: the model changes its own state, the window does these.
public enum ModeEffect: Equatable, Sendable {
    /// Not Trim's: the key goes on to nvim (or whoever had it).
    case pass
    /// The keyboard goes to this surface.
    case focus(Surface)
    /// The tree's filter closes (the keyboard stays in the tree).
    case closeFilter
    /// The open files' list closes and the keyboard goes back to this surface.
    case closePicker(restoring: Surface)
    /// The open files' filter ends (the list stays, as it was).
    case endPickerFilter
    /// A list of choices closes, nothing chosen, and the keyboard goes back to this surface.
    case closeList(restoring: Surface)
    /// A list of choices' filter ends.
    case endListFilter
    /// The switcher closes and the keyboard goes back to this surface.
    case closeSwitcher(restoring: Surface)
}

/// The modes of one window: which surface has the keyboard, what the tree is doing, and where Escape goes from the
/// editor. Pure: the window tells it what happened (`focused`, `openSwitcher`...) and asks it what Escape does.
public struct Modes: Equatable, Sendable {
    public private(set) var surface: Surface = .editor
    public private(set) var treeMode: TreeMode = .normal
    /// Where Escape goes from the editor's normal mode: the tree, unless the person went into the editor themselves
    /// (a click). A fresh editor has not been entered from anywhere, so it is the tree.
    public private(set) var editorEscape: Surface? = .tree
    /// Whether the open files' list is being filtered (typed into) and not browsed (j and k move).
    public private(set) var pickerFiltering = false
    /// The list of choices up: what it is called (the mode's word), and whether it is being filtered.
    public private(set) var listTitle = ""
    public private(set) var listFiltering = false
    /// What had the keyboard when the switcher came up, to give it back.
    private var beneathSwitcher: Surface = .editor

    public init() {}

    // MARK: What happened

    /// The keyboard went to `surface`. A click into the editor means the person is in it for its own sake: Escape
    /// there is nvim's. Anything else leaves where Escape goes as it was.
    public mutating func focused(_ surface: Surface, byClick: Bool = false) {
        guard !self.surface.isOverlay || surface == self.surface else { return }
        self.surface = surface
        if surface == .editor, byClick { editorEscape = nil }
    }

    /// The tree gave the keyboard to the editor (Return on a file, Tab, Escape): Escape in the editor's normal mode
    /// takes it back.
    public mutating func handedToEditor() {
        guard !surface.isOverlay else { return }
        surface = .editor
        editorEscape = .tree
    }

    /// The filter opened (the keyboard is in its input) or closed.
    public mutating func filterChanged(open: Bool) {
        treeMode = open ? .filter : .normal
        if open, !surface.isOverlay { surface = .tree }
    }

    public mutating func openSwitcher() { openOverlay(.switcher) }

    /// The status bar's list of open files came up.
    public mutating func openPicker() { openOverlay(.picker) }

    /// A list of choices came up (`title` is its word in the status bar: THEME, PACKAGES...).
    public mutating func openList(title: String) {
        openOverlay(.list)
        if surface == .list {
            listTitle = title
            listFiltering = false
        }
    }

    /// The filter of a list of choices began or ended.
    public mutating func listFilterChanged(open: Bool) {
        if surface == .list { listFiltering = open }
    }

    /// A list of choices is done (one was chosen, say): the surface the keyboard goes back to.
    @discardableResult
    public mutating func closeList() -> Surface {
        guard surface == .list else { return surface }
        surface = beneathSwitcher
        listFiltering = false
        listTitle = ""
        return surface
    }

    private mutating func openOverlay(_ overlay: Surface) {
        guard !surface.isOverlay else { return }
        beneathSwitcher = surface
        surface = overlay
        pickerFiltering = false
    }

    /// The filter of the open files' list began or ended.
    public mutating func pickerFilterChanged(open: Bool) {
        if surface == .picker { pickerFiltering = open }
    }

    /// The switcher is done (a workspace was chosen, say): the surface the keyboard goes back to.
    @discardableResult
    public mutating func closeSwitcher() -> Surface {
        guard surface == .switcher else { return surface }
        surface = beneathSwitcher
        return surface
    }

    /// The list of open files is done: the surface the keyboard goes back to.
    @discardableResult
    public mutating func closePicker() -> Surface {
        guard surface == .picker else { return surface }
        surface = beneathSwitcher
        pickerFiltering = false
        return surface
    }

    /// The terminal pane went away: the keyboard cannot be in it.
    public mutating func terminalHidden() {
        if surface == .terminal { surface = .editor }
        if surface.isOverlay, beneathSwitcher == .terminal { beneathSwitcher = .editor }
    }

    /// The Run pane went away: the keyboard cannot be in it.
    public mutating func walkHidden() {
        if surface == .walk { surface = .editor }
        if surface.isOverlay, beneathSwitcher == .walk { beneathSwitcher = .editor }
        walkMode = "normal"
    }

    /// The mode nvim is in inside the walkthrough (`normal`, `insert`, `visual`, `cmdline_normal`...): Escape is its
    /// own
    /// anywhere but normal, and the label says it.
    public var walkMode = "normal"

    public mutating func runHidden() {
        if surface == .run { surface = .editor }
        if surface.isOverlay, beneathSwitcher == .run { beneathSwitcher = .editor }
    }

    /// The sidebar went away: the keyboard cannot be in it.
    public mutating func sidebarHidden() {
        if surface == .tree { surface = .editor }
        if surface.isOverlay, beneathSwitcher == .tree { beneathSwitcher = .editor }
        treeMode = .normal
    }

    /// A new nvim in the window (a switch of config or of workspace): the editor, not yet entered from anywhere.
    public mutating func editorRestarted() {
        surface = .editor
        treeMode = .normal
        pickerFiltering = false
        listFiltering = false
        listTitle = ""
        editorEscape = .tree
        beneathSwitcher = .editor
    }

    // MARK: Escape

    /// What Escape does now, and the change of mode it makes. Out of the switcher, back to where it came from; in the
    /// tree, out of what it is doing, and from plain tree to the editor; in the editor's normal mode, to the tree when
    /// that is where it came from and the sidebar shows; anywhere else it is nvim's.
    public mutating func escape(editorMode: String, sidebarVisible: Bool) -> ModeEffect {
        switch surface {
        case .switcher:
            return .closeSwitcher(restoring: closeSwitcher())
        case .list:
            if listFiltering {
                listFiltering = false
                return .endListFilter
            }
            return .closeList(restoring: closeList())
        case .picker:
            if pickerFiltering {
                pickerFiltering = false
                return .endPickerFilter
            }
            return .closePicker(restoring: closePicker())
        case .tree:
            if treeMode != .normal {
                treeMode = .normal
                return .closeFilter
            }
            handedToEditor()
            return .focus(.editor)
        case .terminal, .run:
            return .pass
        case .walk:
            // In normal mode Escape leaves the walkthrough for the code; in any other it is nvim's (it ends the mode).
            guard walkMode == "normal" else { return .pass }
            surface = .editor
            return .focus(.editor)
        case .editor:
            guard let target = editorEscape, sidebarVisible, editorMode == "normal" else { return .pass }
            surface = target
            editorEscape = nil
            return .focus(target)
        }
    }

    // MARK: How it is called

    /// The mode as a short word: Trim's own while the keyboard is outside nvim, else nvim's (`mode` as nvim's
    /// `mode_change` gives it: "normal", "insert", "visual", "cmdline_normal"...).
    public func label(editorMode: String) -> String {
        switch surface {
        case .switcher: "SWITCH"
        case .picker: pickerFiltering ? "FILTER" : "TABS"
        case .list: listFiltering ? "FILTER" : listTitle.uppercased()
        case .tree: treeMode == .filter ? "FILTER" : "TREE"
        case .terminal: "BUILD"
        case .run: "RUN"
        case .walk: walkMode == "normal" ? "WALK" : "WALK " + Self.name(ofEditorMode: walkMode)
        case .editor: Self.name(ofEditorMode: editorMode)
        }
    }

    /// nvim's mode as a word to show.
    public static func name(ofEditorMode mode: String) -> String {
        switch mode {
        case "normal": "NORMAL"
        case "insert": "INSERT"
        case "replace": "REPLACE"
        case "visual": "VISUAL"
        case "visual_select", "select": "SELECT"
        case "operator": "OP"
        case let mode where mode.hasPrefix("cmdline"): "COMMAND"
        case "terminal": "TERMINAL"
        default: mode.uppercased()
        }
    }
}
