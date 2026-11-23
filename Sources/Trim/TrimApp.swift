import AppKit
import SillAgent
import SillCore
import SillEditor
import SillNvim
import TrimModes
import TrimTree
import TrimWorkspaces

/// The application: the windows of the frame (one per workspace), the menu, the settings and quitting.
@MainActor
final class TrimApp: NSObject, NSApplicationDelegate {
    private(set) var controllers: [TrimWindowController] = []
    private var watcher: SettingsWatcher?
    private var quitting = false
    /// Where the switcher's workspaces come from (the self-check swaps it for a fixture).
    var sources = WorkspaceSources.live
    /// What heed said last time: the titles shown at once, until it is asked again.
    var lastSessions: [HeedSession] = []

    static var checking: Bool { ProcessInfo.processInfo.environment["TRIM_CHECK"] == "1" }

    /// Trim's settings window (one for the app), made when first asked for.
    private(set) var settings: SettingsWindowController?

    func showSettings() {
        let controller = settings ?? SettingsWindowController(app: self)
        settings = controller
        Task { await controller.show() }
    }

    /// The window the person is in.
    var active: TrimWindowController? {
        (NSApp.keyWindow?.delegate as? TrimWindowController) ?? controllers.last
    }

    /// A menu action no responder of the key window took (there is no key window, say) goes to the window the person
    /// was last in.
    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || active?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if let active, active.responds(to: selector) { return active }
        return super.forwardingTarget(for: selector)
    }

    func applicationDidFinishLaunching(_: Notification) {
        // sill's settings: the font, and whether a title bar shows.
        let file = ProcessInfo.processInfo.environment["SILL_SETTINGS"].map { URL(fileURLWithPath: $0) } ??
            SettingsLoader.defaultFile()
        if FileManager.default.fileExists(atPath: file.path) {
            let watcher = SettingsWatcher(file: file) { source in
                Settings.shared.load(source)
                Task { @MainActor [weak self] in self?.controllers.forEach { $0.apply() } }
            }
            Settings.shared.load(watcher.start())
            self.watcher = watcher
        }
        EditorFont.load(TrimSettings.fontSettings(over: Settings.shared.current))
        EditorFont.onChange = { [weak self] in self?.controllers.forEach { $0.fontChanged() } }
        buildMenu()
        installTabKeys()
        let (folder, arguments) = Self.startingFolder()
        open(folder: folder, arguments: arguments)
    }

    /// Where the first window starts: a folder given as the first argument (`open -n Trim.app --args ~/Projects/x`),
    /// else the folder the app was started in, else (from the Dock that is /) the home folder; the self-check starts
    /// in a folder of its own so the tree never reads one that is not. The arguments left go to nvim.
    static func startingFolder() -> (String, [String]) {
        if checking {
            let folder = NSTemporaryDirectory() + "trim-check-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            return (folder, Array(CommandLine.arguments.dropFirst()))
        }
        var arguments = Array(CommandLine.arguments.dropFirst()
            .filter { !$0.hasPrefix("-psn") && !$0.hasPrefix("-NS") })
        var folder = FileManager.default.currentDirectoryPath
        if folder == "/" { folder = NSHomeDirectory() }
        var isFolder: ObjCBool = false
        if let first = arguments.first, FileManager.default.fileExists(atPath: first, isDirectory: &isFolder),
           isFolder.boolValue
        {
            folder = RealPath.of(first)
            arguments.removeFirst()
        }
        return (folder, arguments)
    }

    /// A window on a folder: the one already on it comes forward, else a new one opens (its own nvim, its own tree).
    @discardableResult
    func open(folder: String, arguments: [String] = []) -> TrimWindowController {
        let real = RealPath.of(folder)
        if let known = controllers.first(where: { ($0.tree?.rootPath ?? $0.workspace) == real }) {
            known.window.makeKeyAndOrderFront(nil)
            return known
        }
        if !Self.checking { WorkspaceHistory.touch(real) }
        let controller = TrimWindowController(
            app: self, folder: real, arguments: arguments, isFirst: controllers.isEmpty
        )
        controllers.append(controller)
        controller.start()
        return controller
    }

    // MARK: Links in

    /// A link into the app, or a file handed over (`open -a Trim file.cs`, Finder's Open With): the file at its place
    /// in
    /// the window that is on its folder, else in a window of its own on its repository; a folder in a window.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard let link = TrimLink.parse(url) else { return false }
        // Brought forward, as a link is for (not in the self-check: a tiling window manager moves a window that is).
        func forward(_ controller: TrimWindowController) {
            guard !Self.checking else { return }
            controller.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        switch link {
        case let .workspace(path):
            forward(open(folder: path))
        case let .file(path, line, column):
            let real = RealPath.of(path)
            let known = controllers.filter { real.hasPrefix(($0.tree?.rootPath ?? $0.workspace) + "/") }
                .max { ($0.tree?.rootPath ?? $0.workspace).count < ($1.tree?.rootPath ?? $1.workspace).count }
            let controller = known ?? open(folder: TrimLink.workspace(for: real))
            forward(controller)
            controller.open(file: real, toEditor: true, line: line, column: column)
        }
        return true
    }

    func application(_: NSApplication, open urls: [URL]) {
        urls.forEach { handle($0) }
    }

    // MARK: Control-Tab

    private var keyMonitor: Any?

    /// Control-Tab and Control-Shift-Tab, taken before anything else sees them: a menu's key equivalent for Tab does
    /// not
    /// get there (the window and nvim's grid take Tab first).
    private func installTabKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.tabKey(event) == true }
            return handled ? nil : event
        }
    }

    /// Whether `event` is Control-Tab or Control-Shift-Tab, which then go to the next or previous tab of the window the
    /// person is in (not while the switcher has the keyboard).
    func tabKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.control, .command, .option, .shift])
        guard event.keyCode == 48, modifiers.contains(.control), modifiers.isDisjoint(with: [.command, .option]),
              let active, active.switcher == nil else { return false }
        if modifiers.contains(.shift) { active.previousTab(nil) } else { active.nextTab(nil) }
        return true
    }

    /// A workspace chosen in `controller`'s switcher: a window that is on it comes forward; otherwise it opens in this
    /// window, or in a new one when asked.
    func go(to folder: String, from controller: TrimWindowController, newWindow: Bool) {
        let real = RealPath.of(folder)
        if let known = controllers.first(where: { ($0.tree?.rootPath ?? $0.workspace) == real }) {
            if known !== controller { known.window.makeKeyAndOrderFront(nil) }
            return
        }
        if newWindow { open(folder: real) } else { controller.move(to: real) }
    }

    /// A window is done (closed, or its nvim ended): it goes, and the last one going quits.
    func close(_ controller: TrimWindowController) {
        guard controllers.contains(where: { $0 === controller }) else { return }
        controllers.removeAll { $0 === controller }
        if controllers.isEmpty {
            NSApp.terminate(nil)
            return
        }
        Task { await controller.shutDown() }
    }

    /// The tabs' options as they are now: remembered between starts (not in the self-check), and the same in every
    /// window.
    var tabsMax = TrimApp.checking ? 10 : PaneLayout.tabsMax
    var tabsAutoclose = TrimApp.checking ? true : PaneLayout.tabsAutoclose
    /// Where the tabs were before they were hidden, for "show" to go back to.
    var tabsLastShown = TrimApp.checking ? TabsPlacement.statusbar : PaneLayout.tabsLastShown

    /// Where the tabs are, in every window; hiding them remembers where they were.
    func setTabs(placement: TabsPlacement) {
        if placement != .hidden { tabsLastShown = placement }
        if !Self.checking {
            PaneLayout.tabsLastShown = tabsLastShown
            PaneLayout.tabsPlacement = placement
        }
        for controller in controllers {
            controller.view?.tabsPlacement = placement
            controller.configureTabs()
            controller.refreshStatus()
        }
    }

    func setTabsMax(_ limit: Int) {
        tabsMax = limit
        if !Self.checking { PaneLayout.tabsMax = limit }
        controllers.forEach { $0.configureTabs() }
    }

    func setTabsAutoclose(_ on: Bool) {
        tabsAutoclose = on
        if !Self.checking { PaneLayout.tabsAutoclose = on }
        controllers.forEach { $0.configureTabs() }
    }

    /// Where the status bar sits, in every window, and for the next start.
    func setStatusPlacement(_ placement: StatusPlacement) {
        for controller in controllers {
            controller.view?.statusPlacement = placement
            controller.refreshStatus()
        }
        if !Self.checking { PaneLayout.statusPlacement = placement }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { !Self.checking }

    /// Quitting with unsaved changes asks first, window by window, as nvim's :qa would refuse.
    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting, !Self.checking else { return .terminateNow }
        let asking = controllers.filter { !$0.ended }
        guard !asking.isEmpty else { return .terminateNow }
        Task {
            var proceed = true
            for controller in asking {
                // The window it is about comes forward, so the question is of something the person can see.
                if asking.count > 1 { controller.window.makeKeyAndOrderFront(nil) }
                let outcome = await controller.resolveUnsaved()
                if outcome == .discarded { quitting = true }
                if outcome == .cancelled {
                    proceed = false
                    break
                }
            }
            NSApp.reply(toApplicationShouldTerminate: proceed)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_: Notification) {
        let all = controllers
        Task { for controller in all {
            await controller.stop()
        } }
    }

    // MARK: Menu

    /// Every action but quitting has no target: it goes to the window the person is in, through the responder chain.
    private func buildMenu() {
        typealias Window = TrimWindowController
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(Window.openSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        menu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editItem.submenu = editMenu
        let goItem = NSMenuItem()
        menu.addItem(goItem)
        let goMenu = NSMenu(title: "Go")
        goMenu.addItem(
            withTitle: "Switch Workspace…",
            action: #selector(Window.switchWorkspace(_:)),
            keyEquivalent: "o"
        )
        .keyEquivalentModifierMask = [.command, .shift]
        goMenu.addItem(.separator())
        let openFiles = goMenu.addItem(
            withTitle: "Open Files…",
            action: #selector(Window.showOpenFiles(_:)),
            keyEquivalent: "e"
        )
        openFiles.keyEquivalentModifierMask = [.command, .option]
        goMenu.addItem(withTitle: "Find File…", action: #selector(Window.showFinder(_:)), keyEquivalent: "p")
        let grepItem = goMenu.addItem(
            withTitle: "Find in Files…", action: #selector(Window.showGrep(_:)), keyEquivalent: "f"
        )
        grepItem.keyEquivalentModifierMask = [.command, .shift]
        // Control-Tab, as browsers and editors have it; the macOS pair too.
        goMenu.addItem(withTitle: "Next Tab", action: #selector(Window.nextTab(_:)), keyEquivalent: "\t")
            .keyEquivalentModifierMask = [.control]
        goMenu.addItem(withTitle: "Previous Tab", action: #selector(Window.previousTab(_:)), keyEquivalent: "\t")
            .keyEquivalentModifierMask = [.control, .shift]
        // On a real keyboard Shift-Tab is the back-tab character.
        let backTab = goMenu.addItem(
            withTitle: "Previous Tab",
            action: #selector(Window.previousTab(_:)),
            keyEquivalent: "\u{19}"
        )
        backTab.keyEquivalentModifierMask = [.control, .shift]
        backTab.isHidden = true
        backTab.allowsKeyEquivalentWhenHidden = true
        let nextAlternate = goMenu.addItem(
            withTitle: "Next Tab",
            action: #selector(Window.nextTab(_:)),
            keyEquivalent: "]"
        )
        nextAlternate.keyEquivalentModifierMask = [.command, .shift]
        nextAlternate.isHidden = true
        nextAlternate.allowsKeyEquivalentWhenHidden = true
        let previousAlternate = goMenu.addItem(
            withTitle: "Previous Tab", action: #selector(Window.previousTab(_:)), keyEquivalent: "["
        )
        previousAlternate.keyEquivalentModifierMask = [.command, .shift]
        previousAlternate.isHidden = true
        previousAlternate.allowsKeyEquivalentWhenHidden = true
        goMenu.addItem(withTitle: "Close Tab", action: #selector(Window.closeCurrentTab(_:)), keyEquivalent: "w")
        goItem.submenu = goMenu
        let runItem = NSMenuItem()
        menu.addItem(runItem)
        let runMenu = NSMenu(title: "Run")
        let f5 = String(UnicodeScalar(NSF5FunctionKey)!)
        let runDefault = runMenu.addItem(withTitle: "Run", action: #selector(Window.runDefault(_:)), keyEquivalent: f5)
        runDefault.keyEquivalentModifierMask = []
        let build = runMenu.addItem(withTitle: "Build", action: #selector(Window.buildDefault(_:)), keyEquivalent: "b")
        build.keyEquivalentModifierMask = [.command, .shift]
        let choose = runMenu.addItem(
            withTitle: "Choose What to Run…", action: #selector(Window.showRunPicker(_:)), keyEquivalent: "r"
        )
        choose.keyEquivalentModifierMask = [.command, .shift]
        let problems = runMenu.addItem(
            withTitle: "Problems from the Terminal…", action: #selector(Window.showProblems(_:)), keyEquivalent: "m"
        )
        problems.keyEquivalentModifierMask = [.command, .shift]
        runMenu.addItem(.separator())
        runMenu.addItem(withTitle: "Terminal", action: #selector(Window.toggleTerminal(_:)), keyEquivalent: "j")
        let closeTerminal = runMenu.addItem(
            withTitle: "Close Terminal", action: #selector(Window.closeTerminal(_:)), keyEquivalent: "j"
        )
        closeTerminal.keyEquivalentModifierMask = [.command, .shift]
        runItem.submenu = runMenu
        let viewItem = NSMenuItem()
        menu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(Window.toggleSidebar(_:)), keyEquivalent: "b")
        let zenItem = viewMenu.addItem(
            withTitle: "Zen Mode",
            action: #selector(Window.toggleZen(_:)),
            keyEquivalent: "z"
        )
        zenItem.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(
            withTitle: "Status Bar Across Window", action: #selector(Window.toggleStatusAcrossWindow(_:)),
            keyEquivalent: ""
        )
        let tabsItem = viewMenu.addItem(withTitle: "Tabs", action: nil, keyEquivalent: "")
        let tabsMenu = NSMenu(title: "Tabs")
        for placement in TabsPlacement.allCases {
            let item = tabsMenu.addItem(
                withTitle: placement.title, action: #selector(Window.chooseTabsPlacement(_:)), keyEquivalent: ""
            )
            item.representedObject = placement.rawValue
        }
        tabsMenu.addItem(.separator())
        tabsMenu.addItem(
            withTitle: "Close Unedited Tabs Past the Maximum", action: #selector(Window.toggleTabsAutoclose(_:)),
            keyEquivalent: ""
        )
        let maxItem = tabsMenu.addItem(withTitle: "Maximum Tabs", action: nil, keyEquivalent: "")
        let maxMenu = NSMenu(title: "Maximum Tabs")
        for limit in [5, 8, 10, 15, 20, 0] {
            let item = maxMenu.addItem(
                withTitle: limit == 0 ? "No Limit" : String(limit), action: #selector(Window.chooseTabsMax(_:)),
                keyEquivalent: ""
            )
            item.representedObject = limit
        }
        maxItem.submenu = maxMenu
        tabsItem.submenu = tabsMenu
        viewMenu.addItem(withTitle: "Packages…", action: #selector(Window.showPackages(_:)), keyEquivalent: "")
        let themeItem = viewMenu.addItem(
            withTitle: "Colour Scheme…", action: #selector(Window.showThemePicker(_:)), keyEquivalent: "t"
        )
        themeItem.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(withTitle: "Font…", action: #selector(Window.showFontPicker(_:)), keyEquivalent: "")
        viewMenu.addItem(withTitle: "Filter Files", action: #selector(Window.filterTree(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .option]
        let ignoredItem = viewMenu.addItem(
            withTitle: "Show Ignored Files", action: #selector(Window.toggleIgnoredFiles(_:)), keyEquivalent: "."
        )
        ignoredItem.keyEquivalentModifierMask = [.command, .shift, .option]
        viewMenu.addItem(withTitle: "Show Dotfiles", action: #selector(Window.toggleDotfiles(_:)), keyEquivalent: ".")
            .keyEquivalentModifierMask = [.command, .shift]
        let focus = viewMenu.addItem(
            withTitle: "Focus Sidebar", action: #selector(Window.focusSidebar(_:)), keyEquivalent: "e"
        )
        focus.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Bigger", action: #selector(Window.bigger(_:)), keyEquivalent: "+")
        let bigger = viewMenu.addItem(withTitle: "Bigger", action: #selector(Window.bigger(_:)), keyEquivalent: "=")
        bigger.isHidden = true
        bigger.allowsKeyEquivalentWhenHidden = true
        viewMenu.addItem(withTitle: "Smaller", action: #selector(Window.smaller(_:)), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Actual Size", action: #selector(Window.actual(_:)), keyEquivalent: "0")
        viewItem.submenu = viewMenu
        NSApp.mainMenu = menu
    }
}

extension NSAlert {
    /// Runs the dialog. In the self-check nobody answers, so a dialog is a failure that says what it asked, never a
    /// hang.
    @MainActor @discardableResult
    func runOrFail() -> NSApplication.ModalResponse {
        if TrimApp.checking {
            print("trim check: FAILED: an alert came up: \(messageText) \(informativeText)")
            fflush(stdout)
            exit(1)
        }
        return runModal()
    }
}
