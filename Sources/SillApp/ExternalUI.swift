import AppKit
import SillCore
import SillNvim
import SillRender

/// What nvim hands the UI to draw (`ext_cmdline`, `ext_messages`, `ext_popupmenu`), drawn natively over the editor:
/// the command line as a floating panel, completion as a popup under the word, short messages as notifications that
/// fade, and listings and `:messages` in an output panel that the next key dismisses.
@MainActor
final class ExternalUI {
    let overlay = OverlayLayer()
    private let editor: EditorView
    private let commandLine: CmdlineView
    private let popup: PopupMenuView
    private let output: OutputPanel
    private var toasts: [Int: ToastView] = [:]
    private var screen = Screen()
    /// When each message was first seen, by serial, so it fades on time however often the screen changes.
    private var seen: [Int: Date] = [:]
    /// Output up to this serial has been read (a key was pressed after it).
    private var outputDismissed = 0
    private var expiry: Timer?

    init(editor: EditorView) {
        self.editor = editor
        commandLine = CmdlineView(metrics: editor.metrics)
        popup = PopupMenuView(metrics: editor.metrics)
        output = OutputPanel(metrics: editor.metrics)
        for view in [output, commandLine, popup] as [NSView] {
            view.isHidden = true
            overlay.addSubview(view)
        }
    }

    var commandLineView: NSView { commandLine }
    var popupView: NSView { popup }
    var outputView: NSView { output }
    var toastViews: [NSView] { toasts.values.sorted { $0.frame.minY > $1.frame.minY } }

    func update(_ screen: Screen) {
        self.screen = screen
        layOut()
    }

    /// A key was pressed: output on screen has been read.
    func keyPressed() {
        guard !output.isHidden else { return }
        outputDismissed = max(screen.messages.map(\.serial).max() ?? 0, screen.messageHistory?.map(\.serial).max() ?? 0)
        layOut()
    }

    func layOut() {
        let bounds = overlay.bounds
        // The command line, a third of the way from the top.
        if let line = screen.commandLine {
            commandLine.show(line, block: screen.commandLineBlock, screen: screen)
            let width = min(max(bounds.width * 0.6, 360), min(760, bounds.width - 24))
            let height = commandLine.height
            commandLine.frame = NSRect(
                x: ((bounds.width - width) / 2).rounded(), y: (bounds.height * 0.18).rounded(), width: width,
                height: height
            )
            commandLine.isHidden = false
        } else {
            commandLine.isHidden = true
        }

        layOutPopup(in: bounds)
        layOutMessages(in: bounds)
    }

    private func layOutPopup(in bounds: NSRect) {
        guard let menu = screen.popupMenu, !menu.items.isEmpty else {
            popup.isHidden = true
            return
        }
        popup.show(menu)
        let size = popup.size
        var origin: NSPoint
        if menu.grid == -1, !commandLine.isHidden {
            // Under the command line, at the column where the completed word starts.
            origin = NSPoint(x: commandLine.frame.minX + commandLine.x(ofByte: menu.col), y: commandLine.frame.maxY + 4)
        } else {
            let placement = screen.placements[menu.grid]
            let row = (placement?.row ?? 0) + menu.row, col = (placement?.col ?? 0) + menu.col
            let cell = editor.rect(row: row, col: col, width: 1, height: 1)
            origin = NSPoint(x: cell.minX - PopupMenuView.padding, y: cell.maxY + 2)
            // No room below: above the word instead.
            if origin.y + size.height > bounds.maxY, cell.minY - size.height - 2 >= 0 {
                origin.y = cell.minY - size.height - 2
            }
        }
        origin.x = min(max(origin.x, 4), max(bounds.maxX - size.width - 4, 4))
        popup.frame = NSRect(origin: origin, size: size)
        popup.isHidden = false
    }

    private func layOutMessages(in bounds: NSRect) {
        let now = Date()
        for message in screen.messages where seen[message.serial] == nil {
            seen[message.serial] = now
        }

        // Output (listings, long messages, :messages) in the panel at the bottom, until a key is pressed.
        let history = screen.messageHistory ?? []
        let outputs = history + screen.messages.filter(\.isOutput)
        if let newest = outputs.map(\.serial).max(), newest > outputDismissed {
            output.show(outputs, screen: screen)
            let height = min(output.contentHeight, bounds.height * 0.45)
            output.frame = NSRect(x: 0, y: bounds.maxY - height, width: bounds.width, height: height)
            output.isHidden = false
        } else {
            output.isHidden = true
        }

        // Short messages as notifications, newest at the bottom, each until it has been shown long enough.
        let live = screen.messages.filter { message in
            guard !message.isOutput, let first = seen[message.serial] else { return false }
            return now.timeIntervalSince(first) < Self.lifetime(message)
        }
        let liveSerials = Set(live.map(\.serial))
        for (serial, view) in toasts where !liveSerials.contains(serial) {
            view.removeFromSuperview()
            toasts[serial] = nil
        }
        var bottom = (output.isHidden ? bounds.maxY : output.frame.minY) - 12
        for message in live.reversed() {
            let view = toasts[message.serial] ?? {
                let view = ToastView(metrics: editor.metrics)
                overlay.addSubview(view, positioned: .below, relativeTo: commandLine)
                toasts[message.serial] = view
                return view
            }()
            view.show(message, screen: screen, maxWidth: min(520, bounds.width - 24))
            let size = view.size
            bottom -= size.height
            view.frame = NSRect(x: bounds.maxX - size.width - 12, y: bottom, width: size.width, height: size.height)
            bottom -= 8
        }

        // Come back when the next notification is due to go.
        expiry?.invalidate()
        let next = live.compactMap { message in seen[message.serial].map { $0 + Self.lifetime(message) } }.min()
        if let next {
            let delay = max(next.timeIntervalSince(now), 0.05)
            expiry = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.layOut() }
            }
        }
        seen = seen.filter { serial, _ in screen.messages.contains { $0.serial == serial } }
    }

    static func lifetime(_ message: Message) -> TimeInterval {
        message.isError ? 8 : message.isWarning ? 6 : 4
    }
}

/// A layer over the editor that only takes clicks on what is drawn in it.
final class OverlayLayer: NSView {
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// A rounded panel in the popup colour, with a hairline border.
class PanelView: NSView {
    override var isFlipped: Bool { true }

    func drawPanel() {
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: Design.radius,
            yRadius: Design.radius
        )
        Design.popup.setFill()
        path.fill()
        Design.border.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// The command line: `:`, `/` or a prompt, then what is typed with nvim's highlights, and the cursor.
final class CmdlineView: PanelView {
    static let padding: CGFloat = 12
    private let metrics: CellMetrics
    private var line: Cmdline?
    private var block: [[StyledChunk]] = []
    private var screen = Screen()

    init(metrics: CellMetrics) {
        self.metrics = metrics
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    func show(_ line: Cmdline, block: [[StyledChunk]], screen: Screen) {
        self.line = line
        self.block = block
        self.screen = screen
        needsDisplay = true
    }

    var height: CGFloat { CGFloat(block.count + 1) * metrics.height + 2 * Self.padding }

    private var lead: NSAttributedString {
        guard let line else { return NSAttributedString() }
        let label = line.firstc.isEmpty ? line.prompt : line.firstc + " "
        return NSAttributedString(string: label, attributes: [.font: metrics.regular, .foregroundColor: Design.accent])
    }

    private func typed(_ line: Cmdline) -> NSAttributedString {
        let indent = NSAttributedString(
            string: String(repeating: " ", count: line.indent),
            attributes: [.font: metrics.regular]
        )
        let text = NSMutableAttributedString(attributedString: indent)
        text.append(screen.attributed(line.content, font: metrics.regular))
        return text
    }

    /// Where a byte offset into the typed text is, from the panel's left edge.
    func x(ofByte offset: Int) -> CGFloat {
        guard let line else { return Self.padding }
        let bytes = Array(line.text.utf8)
        let prefix = String(decoding: bytes.prefix(min(max(offset, 0), bytes.count)), as: UTF8.self)
        let width = NSAttributedString(
            string: String(repeating: " ", count: line.indent) + prefix, attributes: [.font: metrics.regular]
        ).size().width
        return Self.padding + lead.size().width + width
    }

    override func draw(_: NSRect) {
        drawPanel()
        guard let line else { return }
        var y = Self.padding
        for row in block {
            screen.attributed(row, font: metrics.regular, color: Design.textMuted)
                .draw(at: NSPoint(x: Self.padding + lead.size().width, y: y + metrics.textOffset))
            y += metrics.height
        }
        lead.draw(at: NSPoint(x: Self.padding, y: y + metrics.textOffset))
        typed(line).draw(at: NSPoint(x: Self.padding + lead.size().width, y: y + metrics.textOffset))
        // The cursor: a bar where nvim says it is, or the pending special character.
        let x = x(ofByte: line.pos)
        if let special = line.special {
            NSAttributedString(string: special, attributes: [.font: metrics.regular, .foregroundColor: Design.accent])
                .draw(at: NSPoint(x: x, y: y + metrics.textOffset))
        } else {
            Design.accent.setFill()
            NSRect(x: x, y: y + 2, width: 2, height: metrics.height - 4).fill()
        }
    }
}

/// Completion: the words, with their kind and menu text muted on the right, and the selection.
final class PopupMenuView: PanelView {
    static let padding: CGFloat = 8
    static let maxRows = 12
    private let metrics: CellMetrics
    private var items: PopupMenu?
    /// The first item shown: the list scrolls to keep the selection in view.
    private var top = 0

    init(metrics: CellMetrics) {
        self.metrics = metrics
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    private var rowHeight: CGFloat { metrics.height + 4 }

    func show(_ menu: PopupMenu) {
        items = menu
        let visible = min(menu.items.count, Self.maxRows)
        if menu.selected >= 0 {
            if menu.selected < top { top = menu.selected }
            if menu.selected >= top + visible { top = menu.selected - visible + 1 }
        }
        top = min(max(top, 0), max(menu.items.count - visible, 0))
        needsDisplay = true
    }

    private func detail(_ item: PopupItem) -> String {
        [item.kind, item.menu].filter { !$0.isEmpty }.joined(separator: "  ")
    }

    var size: NSSize {
        guard let menu = items else { return .zero }
        let words = menu.items
            .map { NSAttributedString(string: $0.word, attributes: [.font: metrics.regular]).size().width }
        let details = menu.items
            .map { NSAttributedString(string: detail($0), attributes: [.font: metrics.regular]).size().width }
        let width = (words.max() ?? 0) + ((details.max() ?? 0) > 0 ? 24 + (details.max() ?? 0) : 0) + 2 * Self.padding
        return NSSize(
            width: min(max(width.rounded(.up), 160), 640),
            height: CGFloat(min(menu.items.count, Self.maxRows)) * rowHeight + 8
        )
    }

    override func draw(_: NSRect) {
        drawPanel()
        guard let menu = items else { return }
        let visible = min(menu.items.count, Self.maxRows)
        for row in 0 ..< visible {
            let index = top + row
            let item = menu.items[index]
            let rect = NSRect(x: 4, y: 4 + CGFloat(row) * rowHeight, width: bounds.width - 8, height: rowHeight)
            if index == menu.selected {
                Design.popupSelected.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            }
            let y = rect.minY + 2 + metrics.textOffset
            NSAttributedString(string: item.word, attributes: [.font: metrics.regular, .foregroundColor: Design.text])
                .draw(at: NSPoint(x: Self.padding, y: y))
            let detail = NSAttributedString(
                string: detail(item), attributes: [.font: metrics.regular, .foregroundColor: Design.textMuted]
            )
            detail.draw(at: NSPoint(x: bounds.width - Self.padding - detail.size().width, y: y))
        }
    }
}

/// A short message: a notification with a bar in its kind's colour.
final class ToastView: PanelView {
    private let metrics: CellMetrics
    private var text = NSAttributedString()
    private var bar = Design.textFaint
    private var maxWidth: CGFloat = 520
    private(set) var message: Message?

    init(metrics: CellMetrics) {
        self.metrics = metrics
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    func show(_ message: Message, screen: Screen, maxWidth: CGFloat) {
        self.message = message
        self.maxWidth = maxWidth
        text = screen.attributed(
            message.content,
            font: metrics.regular,
            color: message.isError ? Design.error : Design.text
        )
        bar = message.isError ? Design.error : message.isWarning ? Design.modified : Design.accent
        needsDisplay = true
    }

    var size: NSSize {
        let bounding = text.boundingRect(
            with: NSSize(width: maxWidth - 32, height: 1000), options: [.usesLineFragmentOrigin]
        )
        return NSSize(width: ceil(bounding.width) + 32, height: max(ceil(bounding.height), metrics.height) + 20)
    }

    override func draw(_: NSRect) {
        drawPanel()
        bar.setFill()
        NSBezierPath(roundedRect: NSRect(x: 6, y: 8, width: 3, height: bounds.height - 16), xRadius: 1.5, yRadius: 1.5)
            .fill()
        text.draw(
            with: NSRect(x: 18, y: 10, width: bounds.width - 30, height: bounds.height - 20),
            options: [.usesLineFragmentOrigin]
        )
    }
}

/// Listings and `:messages`: a panel along the bottom, newest last, read until a key is pressed.
final class OutputPanel: NSView {
    private let metrics: CellMetrics
    private var lines: [NSAttributedString] = []

    init(metrics: CellMetrics) {
        self.metrics = metrics
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func show(_ messages: [Message], screen: Screen) {
        lines = messages.flatMap { message -> [NSAttributedString] in
            let text = screen.attributed(
                message.content, font: metrics.regular, color: message.isError ? Design.error : Design.text
            )
            // One attributed line per text line, keeping each line's colours.
            var result: [NSAttributedString] = []
            var start = 0
            let string = text.string as NSString
            for (index, character) in text.string.utf16.enumerated() where character == 0x0A {
                result.append(text.attributedSubstring(from: NSRange(location: start, length: index - start)))
                start = index + 1
            }
            result.append(text.attributedSubstring(from: NSRange(location: start, length: string.length - start)))
            return result
        }
        needsDisplay = true
    }

    var contentHeight: CGFloat { CGFloat(lines.count) * metrics.height + 36 }

    override func draw(_: NSRect) {
        Design.chrome.setFill()
        bounds.fill()
        Design.border.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        // The newest lines, as many as fit, above a hint.
        let fit = max(Int((bounds.height - 36) / metrics.height), 0)
        var y = bounds.height - 28 - CGFloat(min(fit, lines.count)) * metrics.height
        for line in lines.suffix(fit) {
            line.draw(at: NSPoint(x: 16, y: y + metrics.textOffset))
            y += metrics.height
        }
        NSAttributedString(string: "Press any key to continue", attributes: [
            .font: Design.ui(11), .foregroundColor: Design.textFaint,
        ]).draw(at: NSPoint(x: 16, y: bounds.height - 22))
    }
}

/// nvim's tab pages, drawn above the grid when there are two or more (`ext_tabline`).
final class TabBarView: NSView {
    static let height: CGFloat = 34
    var onSelect: ((_ handle: Int) -> Void)?
    private var tabs: [TabpageInfo] = []
    private var current = 0
    private var frames: [(handle: Int, rect: NSRect)] = []

    override var isFlipped: Bool { true }

    func show(_ tabs: [TabpageInfo], current: Int) {
        guard tabs != self.tabs || current != self.current else { return }
        self.tabs = tabs
        self.current = current
        needsDisplay = true
    }

    private func title(_ tab: TabpageInfo) -> String {
        let name = (tab.name as NSString).lastPathComponent
        return name.isEmpty ? "[No Name]" : name
    }

    override func draw(_: NSRect) {
        Design.chrome.setFill()
        bounds.fill()
        frames = []
        var x: CGFloat = 0
        for tab in tabs {
            let active = tab.handle == current
            let text = NSAttributedString(string: title(tab), attributes: [
                .font: Design.ui(13), .foregroundColor: active ? Design.text : Design.textMuted,
            ])
            let rect = NSRect(x: x, y: 0, width: ceil(text.size().width) + 36, height: bounds.height)
            if active {
                Design.editor.setFill()
                rect.fill()
                Design.accent.setFill()
                NSRect(x: rect.minX, y: 0, width: rect.width, height: 2).fill()
            }
            text.draw(at: NSPoint(x: rect.minX + 18, y: (bounds.height - text.size().height) / 2))
            Design.border.setFill()
            NSRect(x: rect.maxX - 1, y: 8, width: 1, height: bounds.height - 16).fill()
            frames.append((tab.handle, rect))
            x = rect.maxX
        }
        Design.border.setFill()
        NSRect(x: x, y: bounds.height - 1, width: bounds.width - x, height: 1).fill()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let tab = frames.first(where: { $0.rect.contains(point) }) { onSelect?(tab.handle) }
    }
}

/// The window's content: the title bar, the activity bar, the status bar, and between them the tab strip (when there
/// are tabs), the editor, and the overlay over the editor.
final class RootView: NSView {
    let titleBar = TitleBarView()
    let activityBar = ActivityBarView()
    let statusBar = StatusBarView()
    let tabBar = TabBarView()
    let editor: EditorView
    let overlay: OverlayLayer
    /// Without the frame (the self-check's first part runs as days 1 to 5 had it).
    var bare = false {
        didSet { needsLayout = true }
    }

    init(editor: EditorView, overlay: OverlayLayer) {
        self.editor = editor
        self.overlay = overlay
        super.init(frame: editor.frame)
        tabBar.isHidden = true
        for view in [titleBar, activityBar, statusBar, tabBar, editor, overlay] as [NSView] {
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// Shows or hides the tab strip, and lays out again when that changes the editor's size.
    func showTabs(_ visible: Bool) {
        guard tabBar.isHidden == visible else { return }
        tabBar.isHidden = !visible
        needsLayout = true
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        for view in [titleBar, activityBar, statusBar] as [NSView] {
            view.isHidden = bare
        }
        let top = bare ? 0 : TitleBarView.height
        let bottom = bare ? 0 : StatusBarView.height
        let left = bare ? 0 : ActivityBarView.width
        titleBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: TitleBarView.height)
        statusBar.frame = NSRect(
            x: 0,
            y: bounds.height - StatusBarView.height,
            width: bounds.width,
            height: StatusBarView.height
        )
        activityBar.frame = NSRect(x: 0, y: top, width: ActivityBarView.width, height: bounds.height - top - bottom)
        let tabs = tabBar.isHidden ? 0 : TabBarView.height
        tabBar.frame = NSRect(x: left, y: top, width: bounds.width - left, height: TabBarView.height)
        editor.frame = NSRect(
            x: left,
            y: top + tabs,
            width: bounds.width - left,
            height: bounds.height - top - tabs - bottom
        )
        overlay.frame = editor.frame
    }
}
