import AppKit
import FrameRun
import SillEditor

/// The pane beside or under the code for building and running: one header with two tabs, Output (a real terminal that
/// stays after the command ends) and Problems (every diagnostic and what the build printed, as a list with a toggle per
/// level). The header says what ran; the tabs are clicked, or kept apart by keys (see `FrameWindowController`).
final class BuildPane: NSView {
    enum Tab { case output, problems }

    var look: TreeLook {
        didSet {
            problems.look = look
            needsDisplay = true
        }
    }

    /// The problems, as a list that is part of the pane (it filters, has toggles, goes to a problem on Return).
    let problems: ListPickerView
    private(set) var tab: Tab = .problems
    /// What ran last, shown at the right of the header.
    private(set) var entry: RunEntry?
    private(set) var terminal: NSView?
    /// What the terminal shows, scrollback included, for the problems to be read from.
    private(set) var screenText: () -> String? = { nil }
    /// The errors and warnings in the list, shown on the tab.
    var problemCount = 0 {
        didSet { if problemCount != oldValue { needsDisplay = true } }
    }

    var onTabChange: ((Tab) -> Void)?
    static let headerHeight: CGFloat = 34
    private var tabFrames: [(Tab, NSRect)] = []

    init(look: TreeLook) {
        self.look = look
        problems = ListPickerView(title: "Problems", look: look)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        problems.embedded = true
        addSubview(problems)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// A run begins: its terminal replaces the last one, and the Output tab shows it.
    func setTerminal(_ view: NSView, entry: RunEntry, screenText: @escaping () -> String?) {
        terminal?.removeFromSuperview()
        terminal = view
        self.entry = entry
        self.screenText = screenText
        addSubview(view)
        select(.output)
    }

    func select(_ tab: Tab) {
        guard tab == .problems || terminal != nil else { return }
        self.tab = tab
        terminal?.isHidden = tab != .output
        problems.isHidden = tab != .problems
        needsLayout = true
        needsDisplay = true
        onTabChange?(tab)
    }

    /// Where the keyboard goes: the terminal on Output, the list on Problems.
    var focusView: NSView { tab == .output ? (terminal ?? problems) : problems }

    override func layout() {
        super.layout()
        let body = NSRect(
            x: 0, y: Self.headerHeight, width: bounds.width, height: max(0, bounds.height - Self.headerHeight)
        )
        terminal?.frame = body
        problems.frame = body
        terminal?.isHidden = tab != .output
        problems.isHidden = tab != .problems
    }

    override func draw(_: NSRect) {
        look.island.setFill()
        bounds.fill()
        tabFrames = []
        var x: CGFloat = 14
        let tabs: [(Tab, String)] = [
            (.output, "Output"),
            (.problems, problemCount > 0 ? "Problems \(problemCount)" : "Problems"),
        ]
        for (which, name) in tabs {
            let enabled = which == .problems || terminal != nil
            let selected = which == tab
            let text = NSAttributedString(string: name, attributes: [
                .font: selected ? look.boldFont : look.font,
                .foregroundColor: selected ? look.text : (enabled ? look.muted : look.faint),
            ])
            let width = ceil(text.size().width)
            let y = (Self.headerHeight - text.size().height) / 2
            text.draw(at: NSPoint(x: x, y: y))
            if selected {
                Design.accent.setFill()
                NSRect(x: x, y: Self.headerHeight - 3, width: width, height: 2).fill()
            }
            tabFrames.append((which, NSRect(x: x - 8, y: 0, width: width + 16, height: Self.headerHeight)))
            x += width + 24
        }
        if let entry {
            let detail = NSAttributedString(string: entry.title + "  " + entry.command, attributes: [
                .font: look.smallFont, .foregroundColor: look.faint,
            ])
            let room = bounds.width - x - 14
            if room > 40 {
                detail.draw(
                    with: NSRect(
                        x: x,
                        y: (Self.headerHeight - detail.size().height) / 2,
                        width: room,
                        height: detail.size().height
                    ),
                    options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin]
                )
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let hit = tabFrames.first(where: { $0.1.contains(point) }) { select(hit.0) }
    }
}
