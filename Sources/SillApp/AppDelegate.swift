import AppKit
import SillCore
import SillNvim
import SillRender

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private let session = EditorSession()
    private var editor: EditorView!
    private var panes: TerminalPanes!
    private var check: SelfCheck?

    func applicationDidFinishLaunching(_: Notification) {
        if ProcessInfo.processInfo.environment["SILL_BENCH"] == "1" {
            Bench.run()
            return
        }
        buildMenu()
        let directory = ProcessInfo.processInfo.environment["SILL_CWD"] ?? FileManager.default.currentDirectoryPath
        let workingDirectory = directory == "/" ? NSHomeDirectory() : directory

        editor = EditorView(channel: session.channel, metrics: CellMetrics())
        panes = TerminalPanes(editor: editor, channel: session.channel, directory: workingDirectory)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
        )
        window.title = "sill"
        window.contentView = editor
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
        NSApp.activate()

        let session = session
        editor.onResize = { cols, rows in Task { await session.resize(cols: cols, rows: rows) } }
        editor.onFocus = { [weak self] in self?.panes.focusEditor() }

        if ProcessInfo.processInfo.environment["SILL_CHECK"] == "1" {
            check = SelfCheck(window: window, editor: editor, panes: panes, session: session)
        }
        let updates = session.updates
        Task { [weak self] in
            for await update in updates {
                self?.editor.show(update.screen)
                self?.panes.update(update)
                self?.check?.observe(update)
            }
            // nvim exited (:qa).
            if self?.check == nil { NSApp.terminate(nil) }
        }
        let (cols, rows) = editor.gridSize
        Task { [weak self] in
            do {
                // Arguments after the binary are nvim's (files to open); `open` adds -psn and -NS ones of its own.
                let arguments = CommandLine.arguments.dropFirst()
                    .filter { !$0.hasPrefix("-psn") && !$0.hasPrefix("-NS") }
                try await session.start(
                    runtime: Runtime.directory, cols: cols, rows: rows, cwd: workingDirectory,
                    extraArgs: Array(arguments)
                )
                await self?.check?.run()
            } catch {
                self?.fail(error)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }

    func applicationWillTerminate(_: Notification) {
        let session = session
        Task { await session.stop() }
    }

    private func fail(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = "sill could not start nvim"
        alert.runModal()
        NSApp.terminate(nil)
    }

    private func buildMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit sill", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = menu
    }
}

/// Where sill's runtime (the nvim plugin that defines terminal panes) is: in the app bundle's Resources, or, for a
/// `swift run` build, in the source tree.
enum Runtime {
    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["SILL_RUNTIME"] {
            return URL(fileURLWithPath: override)
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("runtime"),
           FileManager.default.fileExists(atPath: bundled.appendingPathComponent("plugin/sill.lua").path)
        {
            return bundled
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("runtime")
    }
}
