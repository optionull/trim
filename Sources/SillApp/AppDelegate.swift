import AppKit
import SillCore
import SillEditor

/// The app: its settings, Home when it started without a folder, and the checkout open in it (a `Workspace`), to which
/// it hands the app's moments: files to open, quitting.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = SettingsController()
    /// Made with the app, as files to open can come before launch is done; started when sill opens a folder.
    private(set) lazy var workspace = Workspace(settings: settings)
    /// Home, when sill started without a folder.
    private(set) var home: HomeController?

    func applicationDidFinishLaunching(_: Notification) {
        // Before anything reads a setting.
        settings.start()
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
            home?.start()
            if environment["SILL_CHECK"] == "home" { Task { await HomeCheck(home: home!).run() } }
            if environment["SILL_CHECK"] == "homeshot" { Task { await HomeCheck(home: home!).shot() } }
            return
        }
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

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        home != nil ? .terminateNow : workspace.shouldTerminate()
    }

    func applicationWillTerminate(_: Notification) {
        if home == nil { workspace.willTerminate() }
    }
}
