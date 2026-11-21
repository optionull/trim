import AppKit
import FrameModes
import FrameTree
import SillEditor

/// The open files as tabs: a row of them (over or under the grid) or a list (beside it, or in the sidebar above the
/// tree), drawn in the editor's font and the sidebar's colours. A tab never edited is quieter and in italics; one with
/// changes has a dot where the close mark is. Clicking selects, the close mark (or a middle click) closes, and the
/// wheel scrolls when there are more than fit. The keyboard is not taken from where it was.
final class TabsView: NSView {
    enum Axis { case horizontal, vertical }

    let axis: Axis
    var look = TreeLook() {
        didSet { needsDisplay = true }
    }

    var tabs: [FrameTab] = [] {
        didSet {
            guard tabs != oldValue else { return }
            labels = Tabs.labels(tabs)
            scrollToCurrent = true
            needsDisplay = true
        }
    }

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?

    private var labels: [Int: String] = [:]
    private var offset: CGFloat = 0
    private var scrollToCurrent = false
    private var hovered: Int?
    private var hoveredClose = false

    init(axis: Axis) {
        self.axis = axis
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    // MARK: Measures

    /// A strip is a line of the grid with room around it.
    static func stripHeight(for look: TreeLook) -> CGFloat { look.rowHeight + 12 }

    private var rowHeight: CGFloat { max(look.rowHeight + 4, 24) }
    /// What a list needs to show every tab.
    var contentHeight: CGFloat { CGFloat(tabs.count) * rowHeight }

    /// The file's icon in its colour, as the tree draws it (a little quieter on a tab that is not the shown one).
    static func iconColor(_ tab: FrameTab, look: TreeLook) -> NSColor {
        let color = TreeCellView.color(FileIcons.icon(name: tab.name, isDirectory: false).tint, look: look)
        return tab.current ? color : color.withAlphaComponent(0.75)
    }

    private func font(for tab: FrameTab) -> NSFont {
        let base = look.smallFont.withSize(look.smallFont.pointSize + 1)
        guard tab.isPreview else { return base }
        return NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
    }

    /// Where each tab is, before scrolling: a strip's tabs side by side, each as wide as its name wants within bounds
    /// and all of them narrower when they would not fit; a list's one under another.
    private func frames() -> [(tab: FrameTab, frame: NSRect)] {
        switch axis {
        case .vertical:
            return tabs.enumerated().map { index, tab in
                (
                    tab,
                    NSRect(x: 0, y: CGFloat(index) * rowHeight, width: bounds.width, height: rowHeight)
                )
            }
        case .horizontal:
            let inset: CGFloat = 6, gap: CGFloat = 4
            let wanted = tabs.map { tab -> CGFloat in
                let text = (labels[tab.id] ?? tab.name) as NSString
                return ceil(text.size(withAttributes: [.font: font(for: tab)]).width) + 62
            }
            let room = bounds.width - 2 * inset - gap * CGFloat(max(tabs.count - 1, 0))
            var widths = wanted.map { min(max($0, 96), 240) }
            if widths.reduce(0, +) > room, !tabs.isEmpty {
                // Shrink to fit, down to a width that still says something; beyond that the row scrolls.
                widths = widths.map { max(96, $0 * room / widths.reduce(0, +)) }
            }
            var x = inset
            return zip(tabs, widths).map { tab, width in
                defer { x += width + gap }
                return (tab, NSRect(x: x, y: 5, width: width, height: bounds.height - 10))
            }
        }
    }

    /// The scroll offset that keeps the current tab in view.
    private func clamp(_ proposed: CGFloat, items: [(tab: FrameTab, frame: NSRect)]) -> CGFloat {
        switch axis {
        case .horizontal:
            let content = (items.last?.frame.maxX ?? 0) + 6
            return min(max(proposed, 0), max(0, content - bounds.width))
        case .vertical:
            return min(max(proposed, 0), max(0, contentHeight - bounds.height))
        }
    }

    private func shifted(_ rect: NSRect) -> NSRect {
        axis == .horizontal ? rect.offsetBy(dx: -offset, dy: 0) : rect.offsetBy(dx: 0, dy: -offset)
    }

    private func closeRect(in rect: NSRect) -> NSRect {
        NSRect(x: rect.maxX - 24, y: rect.midY - 9, width: 18, height: 18)
    }

    // MARK: Drawing

    override func layout() {
        super.layout()
        needsDisplay = true
    }

    override func draw(_: NSRect) {
        // No ground of its own: the tabs sit on the editor's background, and a list has a hairline to tell it from the
        // grid.
        if axis == .vertical {
            look.faint.withAlphaComponent(0.35).setFill()
            NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
        }
        let items = frames()
        if scrollToCurrent, let current = items.first(where: { $0.tab.current }) {
            scrollToCurrent = false
            switch axis {
            case .horizontal:
                if current.frame.minX - offset < 0 { offset = current.frame.minX - 6 }
                if current.frame.maxX - offset > bounds.width { offset = current.frame.maxX - bounds.width + 6 }
            case .vertical:
                if current.frame.minY - offset < 0 { offset = current.frame.minY }
                if current.frame.maxY - offset > bounds.height { offset = current.frame.maxY - bounds.height }
            }
        }
        offset = clamp(offset, items: items)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        for (tab, frame) in items {
            let rect = shifted(frame)
            guard rect.intersects(bounds) else { continue }
            draw(tab, in: rect, hovering: hovered == tab.id)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func draw(_ tab: FrameTab, in rect: NSRect, hovering: Bool) {
        if tab.current {
            look.focusedSelection.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: axis == .vertical ? 6 : 0, dy: 0), xRadius: 6, yRadius: 6).fill()
        } else if hovering {
            look.selection.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: axis == .vertical ? 6 : 0, dy: 0), xRadius: 6, yRadius: 6).fill()
        }
        let color = tab.current ? look.text : look.muted
        let glyph = String(FileIcons.icon(name: tab.name, isDirectory: false).glyph)
        let iconFont = NerdFont.font(size: look.iconSize - 1) ?? look.smallFont
        let iconSize = (glyph as NSString).size(withAttributes: [.font: iconFont])
        let left = rect.minX + (axis == .vertical ? 16 : 10)
        (glyph as NSString).draw(
            at: NSPoint(x: left, y: rect.midY - iconSize.height / 2),
            withAttributes: [.font: iconFont, .foregroundColor: Self.iconColor(tab, look: look)]
        )
        let textX = left + max(iconSize.width, look.iconSize) + 7
        let text = NSAttributedString(
            string: labels[tab.id] ?? tab.name, attributes: [.font: font(for: tab), .foregroundColor: color]
        )
        let height = text.size().height
        text.draw(
            with: NSRect(x: textX, y: rect.midY - height / 2, width: max(0, rect.maxX - 28 - textX), height: height),
            options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin]
        )
        // The mark at the right: a dot while it has changes, a cross under the pointer (and on the shown tab).
        let mark = closeRect(in: rect)
        if hovering || tab.current || tab.modified {
            let showsClose = hovering && (hoveredClose || !tab.modified) || (tab.current && !tab.modified)
            let glyph = showsClose ? "✕" : "●"
            let tint = showsClose ? (hoveredClose && hovering ? look.text : look.muted) : NSColor(frameRGB: 0xE5C07B)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: look.smallFont.withSize(showsClose ? look.smallFont.pointSize - 1 : look.smallFont.pointSize),
                .foregroundColor: tint,
            ]
            let size = (glyph as NSString).size(withAttributes: attributes)
            (glyph as NSString).draw(
                at: NSPoint(x: mark.midX - size.width / 2, y: mark.midY - size.height / 2),
                withAttributes: attributes
            )
        }
    }

    // MARK: The pointer

    private func hit(_ point: NSPoint) -> (tab: FrameTab, frame: NSRect)? {
        frames().first { shifted($0.frame).contains(point) }.map { ($0.tab, shifted($0.frame)) }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let (tab, frame) = hit(point) else { return }
        if closeRect(in: frame).insetBy(dx: -3, dy: -3).contains(point) {
            onClose?(tab.id)
        } else {
            onSelect?(tab.id)
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2, let (tab, _) = hit(convert(event.locationInWindow, from: nil)) else { return }
        onClose?(tab.id)
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = axis == .horizontal && abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX : event.scrollingDeltaY
        let before = offset
        offset = clamp(offset - delta * (event.hasPreciseScrollingDeltas ? 1 : 8), items: frames())
        if offset != before { needsDisplay = true }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let found = hit(point)
        let overClose = found.map { closeRect(in: $0.frame).insetBy(dx: -3, dy: -3).contains(point) } ?? false
        if found?.tab.id != hovered || overClose != hoveredClose {
            hovered = found?.tab.id
            hoveredClose = overClose
            needsDisplay = true
        }
    }

    override func mouseExited(with _: NSEvent) {
        hovered = nil
        hoveredClose = false
        needsDisplay = true
    }

    /// The tab at a point, for the self-check (a click without a window server).
    func tabId(at point: NSPoint) -> (id: Int, onClose: Bool)? {
        guard let (tab, frame) = hit(point) else { return nil }
        return (tab.id, closeRect(in: frame).insetBy(dx: -3, dy: -3).contains(point))
    }

    /// Where a tab is drawn, in this view's coordinates.
    func frame(ofTab id: Int) -> NSRect? { frames().first { $0.tab.id == id }.map { shifted($0.frame) } }
}
