import AppKit
import SillAgent
import SillCore
import SillEditor

/// Agents in the sidebar: heed's sessions, a thin view over its control socket (plan §7). Those that need you come
/// first, then this project's, then the rest by when they last did something. Return (or a click) opens one in heed.
/// heed keeps the sessions; sill never rebuilds its UI.
final class AgentsView: NSView, ToolContent {
    /// nil while heed is not running.
    var sessions: [HeedSession]? {
        didSet {
            guard sessions != oldValue else { return }
            ordered = Self.order(sessions ?? [], here: root)
            selected = min(selected, max(ordered.count - 1, 0))
            needsDisplay = true
        }
    }

    var onOpen: ((HeedSession) -> Void)?
    private(set) var ordered: [HeedSession] = []
    private(set) var selected = 0
    private let root: String

    init(root: String) {
        self.root = root
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    private let rowHeight: CGFloat = 44
    private let listTop: CGFloat = 34

    static func order(_ sessions: [HeedSession], here: String) -> [HeedSession] {
        func rank(_ session: HeedSession) -> Int {
            if session.needsYou { return 0 }
            return isHere(session, here) ? 1 : 2
        }
        return sessions.sorted {
            (rank($0), -($0.lastActivity?.timeIntervalSince1970 ?? 0)) <
                (rank($1), -($1.lastActivity?.timeIntervalSince1970 ?? 0))
        }
    }

    /// Whether a session works in this folder, or in one inside it or around it. Compared as the file system names
    /// them: heed may say /tmp where sill says /private/tmp.
    static func isHere(_ session: HeedSession, _ here: String) -> Bool {
        guard let directory = session.directory.map(realPath) else { return false }
        let here = realPath(here)
        return directory == here || directory.hasPrefix(here + "/") || here.hasPrefix(directory + "/")
    }

    /// What needs you, for the activity bar's badge.
    var waiting: Int { (sessions ?? []).count { $0.needsYou } }

    static func color(_ session: HeedSession) -> NSColor {
        if session.needsYou { return Design.modified }
        switch session.state {
        case "working": return Design.accent
        case "done": return Design.insert
        case "limited", "exited": return Design.error
        default: return Design.textFaint
        }
    }

    override func draw(_: NSRect) {
        Design.chrome.setFill()
        bounds.fill()
        guard let sessions else {
            return note(
                "heed is not running. Send to agent runs the agent in a terminal pane here instead; with heed " +
                    "open, it starts there and its session shows here."
            )
        }
        let heading = sessions.isEmpty ? "No sessions in heed" :
            [
                waiting > 0 ? "\(waiting) need\(waiting == 1 ? "s" : "") you" : nil,
                "\(sessions.count) session\(sessions.count == 1 ? "" : "s")",
            ].compactMap(\.self).joined(separator: " · ")
        NSAttributedString(string: heading, attributes: [
            .font: Design.ui(12), .foregroundColor: waiting > 0 ? Design.modified : Design.textMuted,
        ]).draw(at: NSPoint(x: 16, y: 8))
        let focused = (superview as? SidebarView)?.focused ?? false
        for (index, session) in ordered.enumerated() {
            let rect = NSRect(x: 0, y: listTop + CGFloat(index) * rowHeight, width: bounds.width, height: rowHeight)
            guard rect.minY < bounds.height else { break }
            if index == selected, focused {
                Design.selection.setFill()
                rect.fill()
            }
            Self.color(session).setFill()
            NSBezierPath(ovalIn: NSRect(x: 16, y: rect.minY + 11, width: 8, height: 8)).fill()
            let width = max(bounds.width - 48, 0)
            NSAttributedString(string: session.title, attributes: [
                .font: Design.ui(13), .foregroundColor: Design.text,
            ]).draw(
                with: NSRect(x: 32, y: rect.minY + 6, width: width, height: 18),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
            )
            let what = session.needsYou ? (session.reason.map { "needs you · \($0)" } ?? "needs you") :
                (session.activity.flatMap { $0.isEmpty ? nil : $0 } ?? session.state)
            let place = session.directory
                .map { Self.isHere(session, root) ? "here" : ($0 as NSString).lastPathComponent }
            NSAttributedString(
                string: [session.agent, what, place].compactMap(\.self).joined(separator: " · "),
                attributes: [.font: Design.ui(11), .foregroundColor: Design.textFaint]
            ).draw(
                with: NSRect(x: 32, y: rect.minY + 24, width: width, height: 16),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
            )
        }
    }

    private func note(_ text: String) {
        NSAttributedString(string: text, attributes: [
            .font: Design.ui(12), .foregroundColor: Design.textMuted,
        ]).draw(
            with: NSRect(x: 16, y: 12, width: max(bounds.width - 32, 0), height: 200),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = Int((point.y - listTop) / rowHeight)
        guard point.y >= listTop, ordered.indices.contains(index) else { return }
        selected = index
        needsDisplay = true
        onOpen?(ordered[index])
    }

    var keyKind: String { "agents" }

    func perform(_ command: String, key _: String) -> Bool {
        switch command {
        case "agents.down": selected = min(selected + 1, max(ordered.count - 1, 0))
        case "agents.up": selected = max(selected - 1, 0)
        case "agents.open": if ordered.indices.contains(selected) { onOpen?(ordered[selected]) }
        default: return false
        }
        needsDisplay = true
        return true
    }
}
