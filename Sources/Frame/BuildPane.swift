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
    /// As tall as the file tabs' strip.
    static func headerHeight(for look: TreeLook) -> CGFloat { look.rowHeight + 12 }
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
        let header = Self.headerHeight(for: look)
        let body = NSRect(x: 0, y: header, width: bounds.width, height: max(0, bounds.height - header))
        terminal?.frame = body
        problems.frame = body
        terminal?.isHidden = tab != .output
        problems.isHidden = tab != .problems
    }

    override func draw(_: NSRect) {
        look.island.setFill()
        bounds.fill()
        tabFrames = []
        let header = Self.headerHeight(for: look)
        var x: CGFloat = 8
        let tabs: [(Tab, String, String)] = [
            (.problems, problemCount > 0 ? "Problems \(problemCount)" : "Problems", "\u{f071}"),
            (.output, "Output", "\u{f120}"),
        ]
        let iconFont = NerdFont.font(size: look.iconSize - 1) ?? look.smallFont
        for (which, name, glyph) in tabs {
            let enabled = which == .problems || terminal != nil
            let selected = which == tab
            let color = selected ? look.text : (enabled ? look.muted : look.faint)
            let icon = NSAttributedString(string: glyph, attributes: [.font: iconFont, .foregroundColor: color])
            let text = NSAttributedString(string: name, attributes: [.font: look.font, .foregroundColor: color])
            let width = 10 + max(icon.size().width, look.iconSize) + 7 + ceil(text.size().width) + 12
            let rect = NSRect(x: x, y: 4, width: width, height: header - 8)
            if selected {
                look.focusedSelection.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            }
            icon.draw(at: NSPoint(x: rect.minX + 10, y: rect.midY - icon.size().height / 2))
            text.draw(at: NSPoint(
                x: rect.minX + 10 + max(icon.size().width, look.iconSize) + 7,
                y: rect.midY - text.size().height / 2
            ))
            tabFrames.append((which, rect))
            x += width + 4
        }
        if let entry {
            let detail = NSAttributedString(string: entry.title + "  " + entry.command, attributes: [
                .font: look.smallFont, .foregroundColor: look.faint,
            ])
            let room = bounds.width - x - 14
            if room > 40 {
                detail.draw(
                    with: NSRect(
                        x: x + 8,
                        y: (header - detail.size().height) / 2,
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
