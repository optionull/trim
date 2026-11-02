import AppKit
import SillCore
import SillEditor

/// sill started without a folder (from the Dock, at login): Home's window, and a menu bar item saying how many agents
/// are working and what they prepared that is not seen yet. The folders it watches are asked for the first time.
@MainActor
final class HomeController: NSObject {
    private let settings: SettingsController
    private(set) var model: HomeModel!
    private(set) var window: NSWindow!
    private(set) var view: HomeView!
    private var status: NSStatusItem?

    init(settings: SettingsController) {
        self.settings = settings
    }

    func start() {
        buildMenu()
        let roots = Settings.shared.value("SILL_ROOTS").map { $0.split(separator: ":").map(String.init) } ??
            Settings.shared.current.roots
        model = HomeModel(roots: roots)
        view = HomeView(model: model)
        model.onChange = { [weak self] in
            self?.view.changed()
            self?.updateStatus()
        }
        view.onRoots = { [weak self] in self?.askForRoots() }
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered,
            defer: false
        )
        window.title = "sill"
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = Design.editor
        window.contentView = view
        if ProcessInfo.processInfo.environment["SILL_OFFSCREEN"] == "1" {
            window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            view.frame = NSRect(x: 0, y: 0, width: 980, height: 760)
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        window.makeFirstResponder(view)
        addStatusItem()
        if roots.isEmpty, ProcessInfo.processInfo.environment["SILL_CHECK"] == nil {
            askForRoots()
        } else {
            model.start()
        }
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    // MARK: The folders watched

    /// Asks for the folders with the checkouts, more than one if wanted. A folder that is itself a checkout asks
    /// whether its parent folder is meant (every checkout there) or only it.
    func askForRoots() {
        let panel = NSOpenPanel()
        panel.message = "Choose the folders that hold your git checkouts. Home lists every one in them, most recently active first."
        panel.prompt = "Watch"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        guard panel.runModal() == .OK else {
            if model.roots.isEmpty { model.start() }
            return
        }
        var roots: [String] = []
        for url in panel.urls {
            let path = url.path
            if FileManager.default.fileExists(atPath: path + "/.git") {
                let parent = (path as NSString).deletingLastPathComponent
                let alert = NSAlert()
                alert.messageText = "\((path as NSString).lastPathComponent) is a git checkout"
                alert
                    .informativeText = "Watch every checkout in \((parent as NSString).abbreviatingWithTildeInPath), " +
                    "or only this one?"
                alert.addButton(withTitle: "Every checkout in \((parent as NSString).lastPathComponent)")
                alert.addButton(withTitle: "Only \((path as NSString).lastPathComponent)")
                roots.append(alert.runModal() == .alertFirstButtonReturn ? parent : path)
            } else {
                roots.append(path)
            }
        }
        let written = Array(Set(roots)).sorted().map { ($0 as NSString).abbreviatingWithTildeInPath }
        settings.set(["home", "roots"], to: .array(written.map { .string($0) }))
        model.set(roots: written)
        if model.readAt == nil { model.start() }
    }

    // MARK: The menu bar

    private func addStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "sill")
        item.button?.imagePosition = .imageLeading
        item.menu = NSMenu()
        item.menu?.delegate = self
        status = item
    }

    private func updateStatus() {
        let working = model.working
        status?.button?.title = working > 0 ? " \(working)" : ""
    }

    // MARK: The app's menu

    private static func item(_ title: String, key: String, _ action: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureItem(title: title, action: action)
        item.keyEquivalent = key
        return item
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "About sill",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(Self.item("Settings…", key: ",") { [weak self] in self?.settings.show() })
        appMenu.addItem(ClosureItem(title: "Folders Watched…") { [weak self] in self?.askForRoots() })
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide sill", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit sill", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(Self.item("Home", key: "0") { [weak self] in self?.show() })
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }
}

extension HomeController: NSMenuDelegate {
    /// The menu bar item's menu, made as it opens: the agents working, what is new from them, Home.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let working = model.rows.filter { $0.state.agent?.working == true }
        let header = NSMenuItem(
            title: working.isEmpty ? "No agent working" :
                "\(working.count) agent\(working.count == 1 ? "" : "s") working",
            action: nil,
            keyEquivalent: ""
        )
        header.isEnabled = false
        menu.addItem(header)
        for row in working.prefix(8) {
            menu.addItem(ClosureItem(title: "   " + HomeView.name(row.checkout)) { [weak self] in
                self?.model.open(row.checkout)
            })
        }
        let unseen = model.unseen
        if !unseen.isEmpty {
            menu.addItem(.separator())
            let title = NSMenuItem(title: "New from agents", action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            for item in unseen.prefix(10) {
                let title = "   \(item.prepared.title) — \(HomeView.name(item.checkout))"
                menu.addItem(ClosureItem(title: title) { [weak self] in
                    self?.model.open(item.checkout, walkthrough: item.prepared.path)
                })
            }
        }
        menu.addItem(.separator())
        menu.addItem(ClosureItem(title: "Open Home") { [weak self] in self?.show() })
        menu.addItem(withTitle: "Quit sill", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
    }
}
