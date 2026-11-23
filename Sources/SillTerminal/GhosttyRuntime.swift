// From heed (Sources/HeedTerminal, heed-build/heed main), with sill's names.
import AppKit
import GhosttyKit

/// The one libghostty app instance. Owns the Ghostty config and the runtime callbacks; surfaces are created from it.
///
/// libghostty calls `wakeup` from its own threads when it has work; we answer with a tick on the main thread. Every
/// other callback arrives on the main thread during a tick. Rendering happens on Ghostty's renderer thread, so none
/// of this blocks the UI.
@MainActor
public final class GhosttyRuntime {
    public static let shared = GhosttyRuntime()

    let app: ghostty_app_t?
    private var config: ghostty_config_t?
    private var tickScheduled = false

    /// The panes' font: sill's grid font, set before the first pane (the runtime starts with it) and changed by
    /// `setFont`.
    public static var font: (family: String, size: Double) = ("JetBrains Mono", 12)
    /// Whether the runtime has started (a pane was made): before that, a font change only waits for it.
    public private(set) static var started = false

    /// Called when a surface's process ends and Ghostty asks to close it (`processAlive` false), or the user closed it.
    public var onSurfaceClosed: ((GhosttySurfaceView, _ processAlive: Bool) -> Void)?

    private init() {
        if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
            NSLog("sill: ghostty_init failed")
        }
        let config = Self.makeConfig()
        self.config = config
        Self.started = true

        var runtime = Self.runtimeConfig()
        app = withUnsafeMutablePointer(to: &runtime) { ghostty_app_new($0, config) }
        if app == nil { NSLog("sill: ghostty_app_new failed") }
    }

    /// The user's own Ghostty config, then sill's pane look on top so panes match the window.
    private static func makeConfig() -> ghostty_config_t? {
        let config = ghostty_config_new()
        ghostty_config_load_default_files(config)
        if let overrides = writeOverrides() { ghostty_config_load_file(config, overrides) }
        ghostty_config_finalize(config)
        return config
    }

    /// The panes in a new font: the config made again and handed to the app and to every pane.
    public func setFont(family: String, size: Double) {
        guard Self.font != (family, size) else { return }
        Self.font = (family, size)
        guard let app, let config = Self.makeConfig() else { return }
        ghostty_app_update_config(app, config)
        for view in GhosttySurfaceView.live.allObjects {
            if let surface = view.surface { ghostty_surface_update_config(surface, config) }
        }
        // The one it replaces stays: libghostty may still read it while the panes take the new one.
        self.config = config
    }

    /// The panes' padding, in points: the grid's cells start inside it.
    public static let padding = CGPoint(x: 14, y: 10)

    /// Pane settings that keep a terminal in step with the design: the pane background, padding and the mono face.
    static var overrides: String { """
    background = 0c0d0f
    foreground = cfd3d8
    font-family = \(font.family)
    font-size = \(font.size == font.size.rounded() ? String(Int(font.size)) : String(font.size))
    window-padding-x = \(Int(padding.x))
    window-padding-y = \(Int(padding.y))
    window-padding-balance = false
    cursor-style = block
    confirm-close-surface = false
    wait-after-command = false
    """
    }

    private static func writeOverrides() -> String? {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sill")
        let file = support.appendingPathComponent("ghostty-panes.conf")
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            try overrides.write(to: file, atomically: true, encoding: .utf8)
            return file.path
        } catch {
            NSLog("sill: could not write \(file.path): \(error)")
            return nil
        }
    }

    /// The C callbacks. Built outside the main actor on purpose: closures written in a main-actor context are
    /// main-actor isolated, and Swift checks that at entry, but libghostty calls `wakeup` from its renderer thread.
    private nonisolated static func runtimeConfig() -> ghostty_runtime_config_s {
        ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: { _ in GhosttyRuntime.wakeup() },
            action_cb: { _, target, action in GhosttyRuntime.action(target, action) },
            read_clipboard_cb: { userdata, location, state, mimes, count, _ in
                GhosttyRuntime.readClipboard(userdata, location: location, state: state, mimes: mimes, count: count)
            },
            confirm_read_clipboard_cb: { userdata, _, state, _ in
                // Clipboard reads that need confirmation (OSC 52 from a program) are denied rather than prompted.
                let userdata = RawPointer(userdata), state = RawPointer(state)
                MainActor.assumeIsolated {
                    guard let surface = GhosttyRuntime.surface(userdata.value)?.surface else { return }
                    ghostty_surface_deny_clipboard_request(surface, state.value)
                }
            },
            write_clipboard_cb: { _, location, content, count, _ in
                GhosttyRuntime.writeClipboard(location: location, content: content, count: count)
            },
            close_surface_cb: { userdata, processAlive in
                GhosttyRuntime.closeSurface(userdata, processAlive: processAlive)
            }
        )
    }

    func tick() {
        tickScheduled = false
        if let app { ghostty_app_tick(app) }
    }

    public func setFocus(_ focused: Bool) {
        if let app { ghostty_app_set_focus(app, focused) }
    }

    // MARK: Callbacks (C function pointers: no captures, may arrive off the main thread)

    private nonisolated static func wakeup() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let runtime = GhosttyRuntime.shared
                guard !runtime.tickScheduled else { return }
                runtime.tickScheduled = true
                runtime.tick()
            }
        }
    }

    /// The actions a pane acts on: a URL to open (a link ⌘-clicked), and where its shell is. The rest are Ghostty's
    /// window chrome, which sill does not have.
    private nonisolated static func action(_ target: ghostty_target_s, _ action: ghostty_action_s) -> Bool {
        guard target.tag == GHOSTTY_TARGET_SURFACE, let handle = target.target.surface else { return false }
        let userdata = RawPointer(ghostty_surface_userdata(handle))
        switch action.tag {
        case GHOSTTY_ACTION_OPEN_URL:
            guard let pointer = action.action.open_url.url else { return false }
            let text = String(
                decoding: UnsafeRawBufferPointer(start: pointer, count: Int(action.action.open_url.len)),
                as: UTF8.self
            )
            guard let url = URL(string: text) ?? (text.hasPrefix("/") ? URL(fileURLWithPath: text) : nil) else {
                return false
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if alive(userdata.value)?.onOpenURL?(url) != true { NSWorkspace.shared.open(url) }
                }
            }
            return true
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            let code = Int(action.action.child_exited.exit_code)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { alive(userdata.value)?.onChildExit?(code) }
            }
            return true
        case GHOSTTY_ACTION_PWD:
            guard let pointer = action.action.pwd.pwd else { return false }
            let directory = String(cString: pointer)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { alive(userdata.value)?.workingDirectory = directory }
            }
            return true
        default:
            return false
        }
    }

    /// The pane `userdata` names if it is still open: for work that runs later, when it may have closed.
    static func alive(_ userdata: UnsafeMutableRawPointer?) -> GhosttySurfaceView? {
        GhosttySurfaceView.live.allObjects.first { Unmanaged.passUnretained($0).toOpaque() == userdata }
    }

    nonisolated static func surface(_ userdata: UnsafeMutableRawPointer?) -> GhosttySurfaceView? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    }

    /// Serves plain-text reads (paste) from the general pasteboard; other MIME types are reported unavailable.
    private nonisolated static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?, location: ghostty_clipboard_e, state: UnsafeMutableRawPointer?,
        mimes: UnsafePointer<UnsafePointer<CChar>?>?, count: Int
    ) -> ghostty_clipboard_read_result_e {
        let requested = (0 ..< count).compactMap { mimes?[$0].map { String(cString: $0) } }
        let userdata = RawPointer(userdata), state = RawPointer(state)
        return MainActor.assumeIsolated {
            guard location == GHOSTTY_CLIPBOARD_STANDARD, let surface = surface(userdata.value)?.surface else {
                return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
            }
            guard let mime = requested.first(where: { $0.hasPrefix("text/plain") }),
                  let text = NSPasteboard.general.string(forType: .string)
            else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
            let bytes = Array(text.utf8)
            mime.withCString { mimePointer in
                bytes.withUnsafeBufferPointer { buffer in
                    buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: max(bytes.count, 1)) { data in
                        var content = ghostty_clipboard_content_s(mime: mimePointer, data: data, len: bytes.count)
                        withUnsafePointer(to: &content) { contentPointer in
                            var complete = ghostty_clipboard_complete_s(
                                contents: contentPointer, contents_len: 1, available: nil, available_len: 0,
                                confirmed: false, remember: false
                            )
                            ghostty_surface_complete_clipboard_request(surface, &complete, state.value)
                        }
                    }
                }
            }
            return GHOSTTY_CLIPBOARD_READ_STARTED
        }
    }

    /// Copies the plain-text representation of a write (copy, OSC 52) to the general pasteboard.
    private nonisolated static func writeClipboard(
        location: ghostty_clipboard_e, content: UnsafePointer<ghostty_clipboard_content_s>?, count: Int
    ) {
        guard location == GHOSTTY_CLIPBOARD_STANDARD, let content else { return }
        for index in 0 ..< count {
            let item = content[index]
            guard let mime = item.mime, String(cString: mime).hasPrefix("text/plain"), let data = item.data else {
                continue
            }
            let text = String(decoding: UnsafeRawBufferPointer(start: data, count: item.len), as: UTF8.self)
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            return
        }
    }

    private nonisolated static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
        let userdata = RawPointer(userdata)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let view = surface(userdata.value) else { return }
                GhosttyRuntime.shared.onSurfaceClosed?(view, processAlive)
            }
        }
    }
}

/// A C pointer handed to the main actor. libghostty's callback pointers are only dereferenced there.
struct RawPointer: @unchecked Sendable {
    let value: UnsafeMutableRawPointer?
    init(_ value: UnsafeMutableRawPointer?) { self.value = value }
}
