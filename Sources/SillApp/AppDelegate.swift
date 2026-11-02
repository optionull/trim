import AppKit
import SillCore
import SillEditor

/// The app: its settings, Home when it started without a folder, and the checkouts open in it (each a `Workspace`, in a
/// window of its own), to which it hands the app's moments: files to open, a change of settings or font, quitting.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = SettingsController()
    /// The folder sill was started on: made with the app, as files to open can come before launch is done; started
    /// when sill opens a folder (not with Home).
    private(set) lazy var workspace = Workspace(settings: settings)
    /// The checkouts opened from Home.
    private(set) var opened: [Workspace] = []
    /// Home, when sill started without a folder.
    private(set) var home: HomeController?

    /// Every checkout open.
    var workspaces: [Workspace] { (home == nil ? [workspace] : []) + opened }

    func applicationDidFinishLaunching(_: Notification) {
        // Before anything reads a setting.
        settings.start()
        settings.onApplied = { [weak self] in self?.workspaces.forEach { $0.settingsApplied() } }
        EditorFont.onChange = { [weak self] in self?.workspaces.forEach { $0.fontChanged() } }
        let environment = ProcessInfo.processInfo.environment
        if environment["SILL_BENCH"] == "1" {
            Bench.run()
            return
        }
        // Started without a folder (the Dock, Finder, at login): Home, the checkouts under the folders watched; each
        // opens in a sill of its own. SILL_HOME=1 asks for it (the checks).
        if environment["SILL_HOME"] == "1" || (
            environment["SILL_CWD"] == nil && environment["SILL_CHECK"] == nil && environment["SILL_PROBE"] == nil &&
                environment["SILL_SHOWCASE"] == nil && FileManager.default.currentDirectoryPath == "/" &&
                workspace.launchedFor == nil
        ) {
            home = HomeController(settings: settings)
            workspace.home = home
            home?.onOpen = { [weak self] folder, walkthrough in self?.open(folder: folder, walkthrough: walkthrough) }
            home?.start()
            if environment["SILL_CHECK"] == "home" { Task { await HomeCheck(home: home!).run() } }
            if environment["SILL_CHECK"] == "homeshot" { Task { await HomeCheck(home: home!).shot() } }
            return
        }
        workspace.start()
    }

    /// A checkout opened from Home: in a window of its own, or its window brought to the front when it is open (on
    /// the walkthrough asked for).
    func open(folder: String, walkthrough: String? = nil) {
        let folder = realPath(folder)
        if let open = opened.first(where: { $0.workingDirectory == folder }) {
            open.bringToFront(walkthrough: walkthrough)
            return
        }
        let workspace = Workspace(settings: settings, folder: folder, walkthrough: walkthrough)
        workspace.home = home
        workspace.onClosed = { [weak self, weak workspace] in self?.opened.removeAll { $0 === workspace } }
        opened.append(workspace)
        workspace.start()
    }

    /// Files from Finder or `open -a Sill`, and `sill://open?…` links.
    func application(_: NSApplication, open urls: [URL]) {
        workspace.open(urls: urls)
    }

    /// An editor ends with its window; Home keeps running in the background, its window back from the Dock.
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { home == nil }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { home?.show() }
        return true
    }

    /// With Home: one question for the unsaved files of every checkout open.
    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        guard home != nil else { return workspace.shouldTerminate() }
        guard !opened.isEmpty, ProcessInfo.processInfo.environment["SILL_CHECK"] == nil else { return .terminateNow }
        let open = opened
        Task {
            var modified: [String] = []
            for workspace in open {
                modified += await workspace.unsavedFiles()
            }
            await NSApp.reply(toApplicationShouldTerminate: Workspace.confirm(modified, channels: open.map(\.channel)))
        }
        return .terminateLater
    }

    func applicationWillTerminate(_: Notification) {
        workspaces.forEach { $0.willTerminate() }
        Task { await SharedSidecar.shared.stop() }
    }
}
