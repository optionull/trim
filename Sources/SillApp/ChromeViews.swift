import AppKit
import SillCore

/// The title bar under the traffic lights: the project and branch, centred, and Run.
final class TitleBarView: NSView {
    static let height: CGFloat = 40
    var title = "" {
        didSet { if title != oldValue { needsDisplay = true } }
    }

    var onRun: (() -> Void)?
    private let run = PillButton(title: "Run")

    override init(frame: NSRect) {
        super.init(frame: frame)
        run.target = self
        run.action = #selector(runClicked)
        addSubview(run)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    @objc private func runClicked() { onRun?() }

    override func layout() {
        super.layout()
        let size = run.intrinsicContentSize
        run.frame = NSRect(
            x: bounds.width - size.width - 12, y: (bounds.height - size.height) / 2, width: size.width,
            height: size.height
        )
    }

    override func draw(_: NSRect) {
        Design.chrome.setFill()
        bounds.fill()
        Design.border.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        let text = NSAttributedString(
            string: title,
            attributes: [.font: Design.ui(13), .foregroundColor: Design.textMuted]
        )
        let size = text.size()
        text.draw(at: NSPoint(
            x: ((bounds.width - size.width) / 2).rounded(),
            y: ((bounds.height - size.height) / 2).rounded()
        ))
    }
}

/// A mint button with dark text, as board 1's Run and Send all to agent.
final class PillButton: NSButton {
    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        focusRingType = .none
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize {
        let size = NSAttributedString(string: title, attributes: [.font: Design.ui(13, weight: .semibold)]).size()
        return NSSize(width: ceil(size.width) + 24, height: 26)
    }

    override func draw(_: NSRect) {
        (isHighlighted ? Design.accent.blended(withFraction: 0.2, of: .black) ?? Design.accent : Design.accent)
            .setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        let text = NSAttributedString(string: title, attributes: [
            .font: Design.ui(13, weight: .semibold), .foregroundColor: Design.onAccent,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

/// What the activity bar switches the sidebar between.
enum Activity: String, CaseIterable {
    case explorer, sourceControl, agents, packages, profiler

    var symbol: String {
        switch self {
        case .explorer: "folder"
        case .sourceControl: "arrow.triangle.branch"
        case .agents: "sparkles"
        case .packages: "shippingbox"
        case .profiler: "chart.bar.xaxis"
        }
    }

    var title: String {
        switch self {
        case .explorer: "Explorer"
        case .sourceControl: "Source Control"
        case .agents: "Agents"
        case .packages: "Packages"
        case .profiler: "Profiler"
        }
    }
}

/// The activity bar: an icon per sidebar view. The selected one has a mint strip; selecting it again hides the
/// sidebar.
final class ActivityBarView: NSView {
    static let width: CGFloat = 48
    var selected: Activity? = .explorer {
        didSet { if selected != oldValue { needsDisplay = true } }
    }

    /// A count on an icon: the agents that need you.
    var badges: [Activity: Int] = [:] {
        didSet { if badges != oldValue { needsDisplay = true } }
    }

    var onSelect: ((Activity) -> Void)?
    private var hovered: Activity?

    override var isFlipped: Bool { true }

    private func rect(_ activity: Activity) -> NSRect {
        let index = CGFloat(Activity.allCases.firstIndex(of: activity) ?? 0)
        return NSRect(x: 0, y: 8 + index * 44, width: bounds.width, height: 44)
    }

    override func draw(_: NSRect) {
        Design.rail.setFill()
        bounds.fill()
        Design.border.setFill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
        for activity in Activity.allCases {
            let rect = rect(activity)
            let active = activity == selected
            if active {
                Design.selection.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 6, dy: 4), xRadius: 6, yRadius: 6).fill()
                Design.accent.setFill()
                NSRect(x: 0, y: rect.minY + 8, width: 2, height: rect.height - 16).fill()
            }
            let configuration = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
            guard let image = NSImage(systemSymbolName: activity.symbol, accessibilityDescription: activity.title)?
                .withSymbolConfiguration(configuration) else { continue }
            let tinted = image.tinted(active ? Design.accent : hovered == activity ? Design.text : Design.textMuted)
            let size = tinted.size
            tinted.draw(in: NSRect(
                x: (rect.midX - size.width / 2).rounded(), y: (rect.midY - size.height / 2).rounded(),
                width: size.width,
                height: size.height
            ))
            if let count = badges[activity], count > 0 {
                let text = NSAttributedString(string: "\(count)", attributes: [
                    .font: Design.ui(9, weight: .bold), .foregroundColor: Design.onAccent,
                ])
                let width = max(ceil(text.size().width) + 6, 14)
                let badge = NSRect(x: rect.midX + 3, y: rect.minY + 7, width: width, height: 14)
                Design.modified.setFill()
                NSBezierPath(roundedRect: badge, xRadius: 7, yRadius: 7).fill()
                text.draw(at: NSPoint(
                    x: badge.midX - text.size().width / 2, y: badge.midY - text.size().height / 2
                ))
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let activity = Activity.allCases.first(where: { rect($0).contains(point) }) { onSelect?(activity) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow], owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let now = Activity.allCases.first { rect($0).contains(point) }
        if now != hovered {
            hovered = now
            needsDisplay = true
        }
    }

    override func mouseExited(with _: NSEvent) {
        hovered = nil
        needsDisplay = true
    }
}

/// The status bar: the mode, the branch and what nvim says about keys and recording on the left; the sidecar and
/// language servers, the file type and the cursor on the right.
final class StatusBarView: NSView {
    static let height: CGFloat = 26

    struct State: Equatable {
        var mode = "normal"
        var branch = ""
        var pending = "" // showcmd, recording
        var services: [(name: String, ready: Bool)] = []
        var filetype = ""
        var position: (line: Int, column: Int)?
        var modified = false
        /// A merge: conflicts left, and the current one.
        var merge: (left: Int, current: Int)?

        static func == (lhs: State, rhs: State) -> Bool {
            lhs.mode == rhs.mode && lhs.branch == rhs.branch && lhs.pending == rhs.pending &&
                lhs.services.map(\.name) == rhs.services.map(\.name) &&
                lhs.services.map(\.ready) == rhs.services.map(\.ready) && lhs.filetype == rhs.filetype &&
                lhs.position?.line == rhs.position?.line && lhs.position?.column == rhs.position?.column &&
                lhs.modified == rhs.modified && lhs.merge?.left == rhs.merge?.left &&
                lhs.merge?.current == rhs.merge?.current
        }
    }

    var state = State() {
        didSet { if state != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    /// The mode as the badge says it, and the badge's colour.
    static func badge(_ mode: String) -> (text: String, color: NSColor) {
        switch mode {
        case let mode where mode.hasPrefix("insert"): ("INSERT", Design.insert)
        case let mode where mode.hasPrefix("visual") || mode.hasPrefix("select"): ("VISUAL", Design.visual)
        case let mode where mode.hasPrefix("replace"): ("REPLACE", Design.error)
        case let mode where mode.hasPrefix("cmdline"): ("COMMAND", Design.textMuted)
        case "terminal": ("TERMINAL", Design.modified)
        case "operator": ("PENDING", Design.accent)
        default: ("NORMAL", Design.accent)
        }
    }

    override func draw(_: NSRect) {
        Design.chrome.setFill()
        bounds.fill()
        Design.border.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()

        let (label, color) = state.merge != nil && state.mode == "normal" ? ("MERGE", Design.modified) :
            Self.badge(state.mode)
        let badgeText = NSAttributedString(string: label, attributes: [
            .font: Design.ui(11, weight: .bold), .foregroundColor: Design.onAccent,
        ])
        let badge = NSRect(x: 8, y: 4, width: ceil(badgeText.size().width) + 16, height: bounds.height - 7)
        color.setFill()
        NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4).fill()
        badgeText.draw(at: NSPoint(x: badge.minX + 8, y: badge.midY - badgeText.size().height / 2))

        var x = badge.maxX + 14
        func left(_ text: String, color: NSColor = Design.textMuted) {
            guard !text.isEmpty else { return }
            let string = NSAttributedString(string: text, attributes: [.font: Design.ui(12), .foregroundColor: color])
            string.draw(at: NSPoint(x: x, y: (bounds.height - string.size().height) / 2))
            x += string.size().width + 16
        }
        if let merge = state.merge {
            left(
                merge.left == 0 ? "All conflicts resolved: :w to save, :qa to finish" :
                    (merge
                        .current > 0 ? "Conflict \(merge.current) of \(merge.left)" : "\(merge.left) conflicts left") +
                    "   ]x next · \\o ours · \\t theirs · \\b both",
                color: merge.left == 0 ? Design.accent : Design.text
            )
        }
        left(state.branch.isEmpty ? "" : state.branch)
        left(state.pending, color: Design.modified)

        var right = bounds.width - 12
        func place(_ text: String, color: NSColor = Design.textMuted, dot: NSColor? = nil, hollow: Bool = false) {
            guard !text.isEmpty else { return }
            let string = NSAttributedString(string: text, attributes: [.font: Design.ui(12), .foregroundColor: color])
            right -= string.size().width
            string.draw(at: NSPoint(x: right, y: (bounds.height - string.size().height) / 2))
            if let dot {
                right -= 12
                let circle = NSBezierPath(ovalIn: NSRect(x: right, y: bounds.height / 2 - 3.5, width: 7, height: 7))
                if hollow {
                    dot.setStroke()
                    circle.lineWidth = 1.2
                    circle.stroke()
                } else {
                    dot.setFill()
                    circle.fill()
                }
            }
            right -= 18
        }
        if let position = state.position { place("Ln \(position.line), Col \(position.column)") }
        place(Self.displayName(state.filetype))
        for service in state.services.reversed() {
            // "X ready" when it is; else the name says its state ("Roslyn downloading 40%"), or "starting".
            let label = service.ready ? service.name + " ready" :
                service.name.contains(" ") ? service.name : service.name + " starting"
            place(label, dot: service.ready ? Design.accent : Design.textFaint, hollow: !service.ready)
        }
        if state.modified { place("●", color: Design.modified) }
    }

    /// File types as people name them.
    static func displayName(_ filetype: String) -> String {
        let names = [
            "cs": "C#", "razor": "Razor", "rust": "Rust", "swift": "Swift", "markdown": "Markdown", "html": "HTML",
            "css": "CSS", "json": "JSON", "typescript": "TypeScript", "javascript": "JavaScript", "lua": "Lua",
            "fsharp": "F#", "xml": "XML", "yaml": "YAML", "toml": "TOML", "sh": "Shell", "vim": "Vim script",
        ]
        if filetype.hasPrefix("sill") { return "" }
        return names[filetype] ?? filetype.capitalized
    }
}

extension NSImage {
    /// A template image (an SF Symbol) in a colour.
    func tinted(_ color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return image
    }
}
