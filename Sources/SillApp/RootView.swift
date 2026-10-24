import AppKit
import SillCore
import SillEditor
import SillNvim
import SillRender

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
    let islands = IslandsView()
    /// Without the frame (the self-check's first part runs as days 1 to 5 had it).
    var bare = false {
        didSet { needsLayout = true }
    }

    /// Zen: no bars, no explorer or panel, the text in a column of `zenColumns` in the middle.
    var zen = false {
        didSet { needsLayout = true }
    }

    var zenColumns = 100

    /// The islands look turned on or off (the setting).
    func setIslands(_ on: Bool) {
        Design.islands = on
        islands.isHidden = !on
        window?.backgroundColor = on ? Design.canvas : Design.chrome
        for view in [titleBar, activityBar, statusBar, tabBar] as [NSView] {
            view.needsDisplay = true
        }
        needsLayout = true
    }

    init(editor: EditorView, overlay: OverlayLayer) {
        self.editor = editor
        self.overlay = overlay
        super.init(frame: editor.frame)
        tabBar.isHidden = true
        for view in [titleBar, activityBar, statusBar, tabBar, editor, islands, overlay] as [NSView] {
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
        let bare = bare || zen
        for view in [titleBar, activityBar, statusBar] as [NSView] {
            view.isHidden = bare
        }
        // With islands the editor is inset from the window's edges by the gap; without the bars, all round.
        let gap = Design.islands ? Design.islandGap : 0
        let top = bare ? gap : TitleBarView.height
        let bottom = (bare ? 0 : StatusBarView.height) + gap
        let left = bare ? gap : ActivityBarView.width
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
        var frame = NSRect(
            x: left,
            y: top + tabs,
            width: bounds.width - left - gap,
            height: bounds.height - top - tabs - bottom
        )
        // Zen: a readable column in the middle, as wide as `zenColumns` cells (the window's width when narrower).
        if zen {
            let width = min(frame.width, CGFloat(zenColumns) * EditorFont.metrics.width + 2 * gap)
            frame = NSRect(x: (bounds.width - width) / 2, y: frame.minY, width: width, height: frame.height)
        }
        editor.frame = frame
        islands.frame = frame
        overlay.frame = frame
    }
}
