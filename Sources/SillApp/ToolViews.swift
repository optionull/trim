import AppKit
import MessagePack
import SillCore
import SillNvim
import SillRender

/// A view sill draws over a pane's placeholder window. While that window is current, keys come here first; a key
/// the view does not take goes to nvim (so <C-w> and : still work).
@MainActor
protocol ToolContent: NSView {
    func handleKey(_ event: NSEvent) -> Bool
}

/// The sidebar and the bottom panel, laid over the placeholder windows nvim keeps for them.
@MainActor
final class ToolPanes {
    let sidebar: SidebarView
    let panel: BottomPanelView
    /// The profiler, made the first time a profile pane opens (the synthetic profile takes a moment to build).
    private(set) var profile: ProfileView?
    private let editor: EditorView
    private(set) var screen = Screen()

    init(editor: EditorView, channel: NvimChannel, directory: String) {
        self.editor = editor
        sidebar = SidebarView(channel: channel, directory: directory, metrics: editor.metrics)
        panel = BottomPanelView(channel: channel, metrics: editor.metrics)
        for view in [sidebar, panel] as [NSView] {
            view.isHidden = true
            editor.addSubview(view)
        }
    }

    /// The grids the tool views cover.
    private(set) var covered: Set<Int> = []

    func update(_ screen: Screen) {
        self.screen = screen
        var covered = Set<Int>()
        for (kind, view) in [("sidebar", sidebar as NSView), ("panel", panel)] {
            if let rect = screen.paneRects.first(where: { $0.kind == kind }) {
                view.frame = editor.rect(row: rect.row, col: rect.col, width: rect.width, height: rect.height)
                view.isHidden = false
                covered.insert(rect.grid)
            } else {
                view.isHidden = true
            }
        }
        if let rect = screen.paneRects.first(where: { $0.kind == "profile" }) {
            let view = profile ?? {
                let view = ProfileView()
                editor.addSubview(view)
                profile = view
                return view
            }()
            view.frame = editor.rect(row: rect.row, col: rect.col, width: rect.width, height: rect.height)
            view.isHidden = false
            covered.insert(rect.grid)
        } else {
            profile?.isHidden = true
        }
        self.covered = covered
        sidebar.focused = screen.currentPaneKind == "sidebar"
        panel.focused = screen.currentPaneKind == "panel"
        panel.show(screen)
    }

    /// Keys for the tool view whose window is current, if one is.
    func handleKey(_ event: NSEvent) -> Bool {
        switch screen.currentPaneKind {
        case "sidebar": sidebar.handleKey(event)
        case "panel": panel.handleKey(event)
        case "profile": profile?.handleKey(event) ?? false
        default: false
        }
    }
}

/// Runs Lua in nvim without waiting: what the chrome asks nvim to do.
enum Nvim {
    static func lua(_ channel: NvimChannel, _ code: String, _ args: [MessagePackValue] = []) {
        Task { _ = try? await channel.lua(code, args: args) }
    }
}

/// The sidebar: a header naming the activity, and the activity's view.
final class SidebarView: NSView {
    static let header: CGFloat = 36
    private(set) var activity: Activity = .explorer
    private let channel: NvimChannel
    let explorer: ExplorerView
    let sourceControl: SourceControlView
    private var content: NSView & ToolContent
    var focused = false {
        didSet { if focused != oldValue { needsDisplay = true; content.needsDisplay = true } }
    }

    init(channel: NvimChannel, directory: String, metrics: CellMetrics) {
        self.channel = channel
        explorer = ExplorerView(channel: channel, root: directory, metrics: metrics)
        sourceControl = SourceControlView(channel: channel, root: directory)
        content = explorer
        super.init(frame: .zero)
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func show(_ activity: Activity) {
        guard activity != self.activity else { return }
        self.activity = activity
        content.removeFromSuperview()
        content = switch activity {
        case .explorer: explorer
        case .sourceControl: sourceControl
        case .agents: EmptyStateView(
                symbol: "sparkles", title: "Agents",
                body: "heed's sessions show here once heed has its control socket (M5). Until then, run an agent in a " +
                    "terminal pane: :SillTerminal."
            )
        case .packages: EmptyStateView(
                symbol: "shippingbox", title: "Packages",
                body: "Vulnerable, outdated and deprecated packages of the open solution (board 3, M9)."
            )
        case .profiler: EmptyStateView(
                symbol: "chart.bar.xaxis", title: "Profiler",
                body: "CPU and memory profiles of a run (boards 7 and 8) come with M6. :SillProfile opens the flame graph " +
                    "on a synthetic 11.8M-sample profile."
            )
        }
        if activity == .sourceControl { sourceControl.refresh() }
        addSubview(content)
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        content.frame = NSRect(x: 0, y: Self.header, width: bounds.width - 1, height: bounds.height - Self.header)
    }

    override func draw(_: NSRect) {
        Design.chrome.setFill()
        bounds.fill()
        Design.border.setFill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
        let title = NSAttributedString(string: activity.title.uppercased(), attributes: [
            .font: Design.ui(11, weight: .semibold), .foregroundColor: focused ? Design.text : Design.textMuted,
            .kern: 0.8,
        ])
        title.draw(at: NSPoint(x: 16, y: (Self.header - title.size().height) / 2))
    }

    func handleKey(_ event: NSEvent) -> Bool {
        content.handleKey(event)
    }
}

/// A view not built yet: what it will be, and where in the plan.
final class EmptyStateView: NSView, ToolContent {
    private let symbol: String
    private let title: String
    private let body: String

    init(symbol: String, title: String, body: String) {
        self.symbol = symbol
        self.title = title
        self.body = body
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func handleKey(_: NSEvent) -> Bool { false }

    override func draw(_: NSRect) {
        let width = min(bounds.width - 32, 260)
        var y = max(bounds.height * 0.25, 24)
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 28, weight: .light))?.tinted(Design.textFaint)
        {
            image.draw(in: NSRect(
                x: (bounds.width - image.size.width) / 2,
                y: y,
                width: image.size.width,
                height: image.size.height
            ))
            y += image.size.height + 14
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let heading = NSAttributedString(string: title, attributes: [
            .font: Design.ui(13, weight: .semibold), .foregroundColor: Design.text, .paragraphStyle: paragraph,
        ])
        heading.draw(in: NSRect(x: (bounds.width - width) / 2, y: y, width: width, height: 20))
        y += 24
        NSAttributedString(string: body, attributes: [
            .font: Design.ui(12), .foregroundColor: Design.textMuted, .paragraphStyle: paragraph,
        ]).draw(
            with: NSRect(x: (bounds.width - width) / 2, y: y, width: width, height: 200),
            options: [.usesLineFragmentOrigin]
        )
    }
}

/// The bottom panel: Problems (nvim's diagnostics), Tests and Output, and Send all to agent.
final class BottomPanelView: NSView {
    static let header: CGFloat = 36
    enum Tab: String, CaseIterable { case problems = "Problems", tests = "Tests", output = "Output" }

    private let channel: NvimChannel
    private let metrics: CellMetrics
    private(set) var tab: Tab = .problems
    private(set) var problems: [Diagnostic] = []
    private(set) var selected = 0
    private var tabFrames: [(Tab, NSRect)] = []
    private let send = PillButton(title: "Send all to agent")
    private let empty = EmptyStateView(symbol: "", title: "", body: "")
    var focused = false {
        didSet { if focused != oldValue { needsDisplay = true } }
    }

    init(channel: NvimChannel, metrics: CellMetrics) {
        self.channel = channel
        self.metrics = metrics
        super.init(frame: .zero)
        send.target = self
        send.action = #selector(sendAll)
        addSubview(send)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    var onSendToAgent: (([Diagnostic]) -> Void)?

    @objc private func sendAll() { onSendToAgent?(problems) }

    func show(_ screen: Screen) {
        let sorted = screen.diagnostics.sorted { ($0.severity, $0.path, $0.line) < ($1.severity, $1.path, $1.line) }
        guard sorted != problems else { return }
        problems = sorted
        selected = min(selected, max(problems.count - 1, 0))
        needsDisplay = true
    }

    func select(_ tab: Tab) {
        self.tab = tab
        needsDisplay = true
    }

    private var rowHeight: CGFloat { metrics.height + 6 }

    override func layout() {
        super.layout()
        let size = send.intrinsicContentSize
        send.frame = NSRect(
            x: bounds.width - size.width - 12,
            y: (Self.header - size.height) / 2,
            width: size.width,
            height: size.height
        )
        send.isHidden = tab != .problems || problems.isEmpty
    }

    override func draw(_: NSRect) {
        Design.editor.setFill()
        bounds.fill()
        Design.border.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()

        tabFrames = []
        var x: CGFloat = 16
        for tab in Tab.allCases {
            let active = tab == self.tab
            let label = NSAttributedString(string: tab.rawValue, attributes: [
                .font: Design.ui(13, weight: active ? .semibold : .regular),
                .foregroundColor: active ? Design.text : Design.textMuted,
            ])
            let y = (Self.header - label.size().height) / 2
            label.draw(at: NSPoint(x: x, y: y))
            var width = label.size().width
            if tab == .problems, !problems.isEmpty {
                let count = NSAttributedString(string: "\(problems.count)", attributes: [
                    .font: Design.ui(11, weight: .semibold), .foregroundColor: Design.error,
                ])
                let pill = NSRect(
                    x: x + width + 6,
                    y: y + 1,
                    width: count.size().width + 10,
                    height: label.size().height - 2
                )
                Design.error.withAlphaComponent(0.15).setFill()
                NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
                count.draw(at: NSPoint(x: pill.minX + 5, y: pill.midY - count.size().height / 2))
                width += pill.width + 6
            }
            if active {
                Design.accent.setFill()
                NSRect(x: x, y: Self.header - 2, width: width, height: 2).fill()
            }
            tabFrames.append((tab, NSRect(x: x - 8, y: 0, width: width + 16, height: Self.header)))
            x += width + 28
        }
        send.isHidden = tab != .problems || problems.isEmpty

        let list = NSRect(x: 0, y: Self.header, width: bounds.width, height: bounds.height - Self.header)
        switch tab {
        case .problems where problems.isEmpty:
            drawEmpty(
                "No problems",
                "nvim's diagnostics show here: language servers' errors and warnings, and build " +
                    "errors once build capture comes (M3).",
                in: list
            )
        case .problems:
            drawProblems(in: list)
        case .tests:
            drawEmpty("No test run yet", "Test results come with build capture (M3).", in: list)
        case .output:
            drawEmpty("No output", "Build and run output appears here (M3).", in: list)
        }
    }

    private func drawEmpty(_ title: String, _ body: String, in rect: NSRect) {
        let text = NSMutableAttributedString(string: title + "  ", attributes: [
            .font: Design.ui(12, weight: .semibold), .foregroundColor: Design.textMuted,
        ])
        text.append(NSAttributedString(
            string: body,
            attributes: [.font: Design.ui(12), .foregroundColor: Design.textFaint]
        ))
        text.draw(with: rect.insetBy(dx: 16, dy: 10), options: [.usesLineFragmentOrigin])
    }

    private func drawProblems(in rect: NSRect) {
        let visible = max(Int(rect.height / rowHeight), 1)
        let first = min(max(selected - visible + 1, 0), max(problems.count - visible, 0))
        for (offset, problem) in problems.dropFirst(first).prefix(visible).enumerated() {
            let index = first + offset
            let row = NSRect(x: 0, y: rect.minY + CGFloat(offset) * rowHeight, width: bounds.width, height: rowHeight)
            if index == selected, focused {
                Design.selection.setFill()
                row.fill()
            }
            let color = problem.severity == 1 ? Design.error : problem.severity == 2 ? Design.modified : Design
                .textMuted
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 18, y: row.midY - 4, width: 8, height: 8)).fill()
            let message = (problem.code.isEmpty ? "" : problem.code + " ") + problem.message
                .replacingOccurrences(of: "\n", with: " ")
            let location = NSAttributedString(
                string: "\(problem.path.isEmpty ? "[No Name]" : (problem.path as NSString).lastPathComponent):\(problem.line)",
                attributes: [.font: Design.ui(12), .foregroundColor: Design.textFaint]
            )
            let locationX = bounds.width - 16 - location.size().width
            NSAttributedString(string: message, attributes: [.font: Design.ui(13), .foregroundColor: Design.text])
                .draw(
                    with: NSRect(x: 36, y: row.minY + 4, width: locationX - 48, height: rowHeight - 4),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
                )
            location.draw(at: NSPoint(x: locationX, y: row.midY - location.size().height / 2))
        }
    }

    private func open(_ index: Int) {
        guard problems.indices.contains(index) else { return }
        let problem = problems[index]
        Nvim.lua(channel, "require'sill'.goto(...)", [
            .int(Int64(problem.buffer)),
            .int(Int64(problem.line)),
            .int(Int64(problem.col)),
        ])
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let (tab, _) = tabFrames.first(where: { $0.1.contains(point) }) {
            select(tab)
            return
        }
        guard tab == .problems, point.y > Self.header else { return }
        let index = Int((point.y - Self.header) / rowHeight)
        selected = min(index, max(problems.count - 1, 0))
        needsDisplay = true
        if event.clickCount >= 2 || !focused { open(selected) }
    }

    /// j/k (or the arrows) move, Return opens, Tab goes to the next tab.
    func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { return false }
        switch event.charactersIgnoringModifiers {
        case "j", String(UnicodeScalar(NSDownArrowFunctionKey)!):
            selected = min(selected + 1, max(problems.count - 1, 0))
        case "k", String(UnicodeScalar(NSUpArrowFunctionKey)!):
            selected = max(selected - 1, 0)
        case "\r":
            open(selected)
        case "\t":
            let all = Tab.allCases
            select(all[(all.firstIndex(of: tab)! + 1) % all.count])
        default:
            return false
        }
        needsDisplay = true
        return true
    }
}
