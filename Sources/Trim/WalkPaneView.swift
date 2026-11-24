import AppKit
import SillCore
import SillEditor
import TrimWalk

/// Where the editor goes for an item: a file and the lines to mark.
struct WalkJump: Equatable {
    var path: String
    var from: Int
    var to: Int
}

/// A block drawn as a card: code an anchor points at, a fenced block, a diff.
struct WalkCard {
    var heading: String
    /// A word and its colour at the right of the heading (fresh, changed since written, not found).
    var badge: (text: String, colour: NSColor)?
    var body: NSAttributedString
}

/// One thing in the document, with the lines of the source it came from (what the cursor is on).
struct WalkItem {
    enum Kind {
        case step(number: Int, title: String)
        case prose(NSAttributedString)
        case card(WalkCard)
        case task(text: String, done: Bool)
        case ask(question: String, answer: String?)
        case run(name: String, command: String)
    }

    var kind: Kind
    var span: ClosedRange<Int>
    /// The code the editor shows while this is the active item (a step's first anchor, when it has no own).
    var jump: WalkJump?
    var step: Int
}

/// What the pane draws: the header and the items in order.
struct WalkDoc {
    var title = ""
    var meta = ""
    var intro: NSAttributedString?
    var items: [WalkItem] = []
    var stale = 0
    var problems: [String] = []
}

/// The walkthrough pane: a header over the document, which scrolls. The keyboard is nvim's (a headless nvim holds the
/// document, see `WalkSession`); a click moves its cursor, and the item the cursor is in is marked.
final class WalkPaneView: NSView {
    private let look: TreeLook
    let document: WalkDocumentView
    private let scroll = NSScrollView()
    private let header = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    var onFocus: (() -> Void)?
    var onClose: (() -> Void)?

    var focusView: NSView { document }

    init(look: TreeLook) {
        self.look = look
        document = WalkDocumentView(look: look)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        header.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        header.textColor = look.muted
        header.lineBreakMode = .byTruncatingTail
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Close")
        closeButton.contentTintColor = look.muted
        closeButton.target = self
        closeButton.action = #selector(close)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        document.onFocus = { [weak self] in self?.onFocus?() }
        addSubview(scroll)
        addSubview(header)
        addSubview(closeButton)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func draw(_: NSRect) {
        look.island.setFill()
        bounds.fill()
        look.text.withAlphaComponent(0.06).setFill()
        NSRect(x: 0, y: 36, width: bounds.width, height: 1).fill()
    }

    override func layout() {
        super.layout()
        header.frame = NSRect(x: 16, y: 10, width: max(0, bounds.width - 60), height: 18)
        closeButton.frame = NSRect(x: bounds.width - 34, y: 6, width: 26, height: 24)
        scroll.frame = NSRect(x: 0, y: 37, width: bounds.width, height: max(0, bounds.height - 37))
        document.setWidth(scroll.contentSize.width)
    }

    @objc private func close() { onClose?() }

    func show(_ doc: WalkDoc) {
        header.stringValue = "WALKTHROUGH  ·  " + doc.title
        document.show(doc)
        needsLayout = true
        if let active = document.activeFrame { scroll.contentView.scrollToVisible(active.insetBy(dx: 0, dy: -60)) }
    }

    /// The cursor moved: the item it is in is marked, and brought into view.
    func setCursor(line: Int) {
        document.setCursor(line: line)
        if let active = document.activeFrame { scroll.contentView.scrollToVisible(active.insetBy(dx: 0, dy: -60)) }
    }
}

/// The document itself: laid out and drawn by hand (items are few), flipped, at the pane's width.
final class WalkDocumentView: NSView {
    private let look: TreeLook
    private var doc = WalkDoc()
    private var frames: [NSRect] = []
    private var headerFrame = NSRect.zero
    private var introFrame = NSRect.zero
    private var width: CGFloat = 400
    private var cursorLine = 1
    private(set) var activeIndex: Int?
    var onFocus: (() -> Void)?
    /// The cursor should go to this source line (a click).
    var onClick: ((Int) -> Void)?
    /// A checklist item was clicked (its source line), or a run button.
    var onToggle: ((Int) -> Void)?
    var onRun: ((Int) -> Void)?
    var onKey: ((NSEvent) -> Void)?
    var onActive: ((Int?) -> Void)?
    private var runRects: [(NSRect, Int)] = []
    private var taskRects: [(NSRect, Int)] = []
    static let pad: CGFloat = 22, gap: CGFloat = 14, cardPad: CGFloat = 12

    init(look: TreeLook) {
        self.look = look
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        onFocus?()
        return true
    }

    var activeFrame: NSRect? { activeIndex.flatMap { frames.indices.contains($0) ? frames[$0] : nil } }

    func setWidth(_ newWidth: CGFloat) {
        guard abs(newWidth - width) > 0.5 else { return }
        width = newWidth
        relayout()
    }

    func show(_ new: WalkDoc) {
        doc = new
        relayout()
        updateActive()
    }

    func setCursor(line: Int) {
        cursorLine = line
        updateActive()
        needsDisplay = true
    }

    /// The item the cursor is in: the last whose lines start at or before it.
    private func updateActive() {
        let index = doc.items.lastIndex { $0.span.lowerBound <= cursorLine }
        if index != activeIndex {
            activeIndex = index
            onActive?(index)
        }
    }

    // MARK: Layout

    private func measure(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        ceil(text.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height)
    }

    private var inner: CGFloat { max(120, width - 2 * Self.pad) }

    private func heading(_ doc: WalkDoc) -> NSAttributedString {
        let title = NSAttributedString(string: doc.title, attributes: [
            .font: NSFont.systemFont(ofSize: 22, weight: .bold), .foregroundColor: look.text,
        ])
        return title
    }

    private func relayout() {
        var y = Self.pad
        headerFrame = NSRect(x: Self.pad, y: y, width: inner, height: measure(heading(doc), width: inner))
        y = headerFrame.maxY + 4
        let meta = NSAttributedString(
            string: doc.meta,
            attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: look.muted]
        )
        let metaHeight = doc.meta.isEmpty ? 0 : measure(meta, width: inner)
        y += metaHeight + (metaHeight > 0 ? 10 : 0)
        if let intro = doc.intro {
            introFrame = NSRect(x: Self.pad, y: y, width: inner, height: measure(intro, width: inner))
            y = introFrame.maxY + Self.gap
        } else { introFrame = .zero }
        frames = []
        for item in doc.items {
            let height = itemHeight(item)
            if case .step = item.kind { y += 8 }
            frames.append(NSRect(x: Self.pad, y: y, width: inner, height: height))
            y += height + Self.gap
        }
        let total = y + Self.pad
        setFrameSize(NSSize(width: width, height: max(total, 100)))
        needsDisplay = true
    }

    private func cardBody(_ card: WalkCard, width: CGFloat) -> CGFloat {
        measure(card.body, width: width - 2 * Self.cardPad)
    }

    private func itemHeight(_ item: WalkItem) -> CGFloat {
        switch item.kind {
        case .step: 30
        case let .prose(text): measure(text, width: inner)
        case let .card(card): 26 + cardBody(card, width: inner) + 2 * Self.cardPad
        case let .task(text, _): max(22, measure(plain(text), width: inner - 28))
        case let .ask(question, answer):
            max(22, measure(plain(question, bold: true), width: inner - 28)) + (answer.map { 6 + measure(
                plain($0),
                width: inner - 28
            ) } ?? 0)
        case let .run(name, command): 30 + 0 * Double(name.count + command.count)
        }
    }

    private func plain(
        _ text: String,
        bold: Bool = false,
        mono: Bool = false,
        colour: NSColor? = nil
    ) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: mono ? EditorFont.font(12) : NSFont.systemFont(ofSize: 13.5, weight: bold ? .semibold : .regular),
            .foregroundColor: colour ?? look.text,
        ])
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        runRects = []
        taskRects = []
        heading(doc).draw(in: headerFrame)
        if !doc.meta.isEmpty {
            NSAttributedString(
                string: doc.meta,
                attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: look.muted]
            )
            .draw(in: NSRect(x: Self.pad, y: headerFrame.maxY + 4, width: inner, height: 18))
        }
        doc.intro?.draw(in: introFrame)
        for (index, item) in doc.items.enumerated() where frames.indices.contains(index) {
            let frame = frames[index]
            guard frame.intersects(dirtyRect.insetBy(dx: 0, dy: -40)) else { continue }
            if index == activeIndex, doc.items.indices.contains(index) {
                look.focusedSelection.withAlphaComponent(0.55).setFill()
                NSBezierPath(roundedRect: frame.insetBy(dx: -8, dy: -5), xRadius: 8, yRadius: 8).fill()
                Design.accent.setFill()
                NSBezierPath(
                    roundedRect: NSRect(x: frame.minX - 14, y: frame.minY - 3, width: 3, height: frame.height + 6),
                    xRadius: 1.5,
                    yRadius: 1.5
                ).fill()
            }
            draw(item, in: frame)
        }
    }

    private func draw(_ item: WalkItem, in frame: NSRect) {
        switch item.kind {
        case let .step(number, title):
            let text = NSMutableAttributedString(string: String(format: "%02d  ", number), attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold), .foregroundColor: Design.accent,
            ])
            text.append(NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: look.text,
            ]))
            text.draw(in: NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: 30))
        case let .prose(text):
            text.draw(in: frame)
        case let .card(card):
            look.text.withAlphaComponent(0.055).setFill()
            NSBezierPath(roundedRect: frame, xRadius: 9, yRadius: 9).fill()
            look.text.withAlphaComponent(0.07).setStroke()
            NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9).stroke()
            let title = NSAttributedString(string: card.heading, attributes: [
                .font: EditorFont.font(11.5, .semibold), .foregroundColor: look.muted,
            ])
            title.draw(in: NSRect(
                x: frame.minX + Self.cardPad,
                y: frame.minY + 8,
                width: frame.width - 2 * Self.cardPad - 130,
                height: 16
            ))
            if let badge = card.badge {
                let word = NSAttributedString(string: badge.text, attributes: [
                    .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: badge.colour,
                ])
                let size = word.size()
                let pill = NSRect(
                    x: frame.maxX - size.width - 24,
                    y: frame.minY + 7,
                    width: size.width + 14,
                    height: 17
                )
                badge.colour.withAlphaComponent(0.16).setFill()
                NSBezierPath(roundedRect: pill, xRadius: 8.5, yRadius: 8.5).fill()
                word.draw(at: NSPoint(x: pill.minX + 7, y: pill.minY + 2))
            }
            card.body.draw(in: NSRect(
                x: frame.minX + Self.cardPad,
                y: frame.minY + 26 + Self.cardPad / 2,
                width: frame.width - 2 * Self.cardPad,
                height: frame.height - 26
            ))
        case let .task(text, done):
            let box = NSRect(x: frame.minX, y: frame.minY + 3, width: 15, height: 15)
            (done ? Design.accent : look.muted).setStroke()
            let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
            path.lineWidth = 1.4
            if done {
                Design.accent.setFill()
                path.fill()
                let check = NSBezierPath()
                check.move(to: NSPoint(x: box.minX + 3.5, y: box.midY))
                check.line(to: NSPoint(x: box.minX + 6.5, y: box.maxY - 4))
                check.line(to: NSPoint(x: box.maxX - 3.5, y: box.minY + 4))
                NSColor.black.withAlphaComponent(0.8).setStroke()
                check.lineWidth = 1.8
                check.stroke()
            } else { path.stroke() }
            plain(text, colour: done ? look.muted : look.text).draw(in: NSRect(
                x: frame.minX + 26,
                y: frame.minY + 2,
                width: frame.width - 28,
                height: frame.height
            ))
            taskRects.append((frame, item.span.lowerBound))
        case let .ask(question, answer):
            let mark = NSAttributedString(
                string: "?",
                attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .bold), .foregroundColor: Design.accent]
            )
            mark.draw(at: NSPoint(x: frame.minX + 3, y: frame.minY + 1))
            let height = max(22, measure(plain(question, bold: true), width: frame.width - 28))
            plain(question, bold: true).draw(in: NSRect(
                x: frame.minX + 26,
                y: frame.minY + 2,
                width: frame.width - 28,
                height: height
            ))
            if let answer {
                Design.accent.withAlphaComponent(0.6).setFill()
                NSRect(x: frame.minX + 26, y: frame.minY + height + 6, width: 2, height: frame.height - height - 6)
                    .fill()
                plain(answer, colour: look.muted).draw(in: NSRect(
                    x: frame.minX + 36,
                    y: frame.minY + height + 6,
                    width: frame.width - 38,
                    height: frame.height - height - 6
                ))
            }
        case let .run(name, command):
            look.text.withAlphaComponent(0.055).setFill()
            NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8).fill()
            let button = NSRect(x: frame.minX + 8, y: frame.minY + 5, width: 58, height: 20)
            Design.accent.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: button, xRadius: 6, yRadius: 6).fill()
            NSAttributedString(
                string: "\u{25B6} Run",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .bold),
                    .foregroundColor: NSColor.black.withAlphaComponent(0.85),
                ]
            )
            .draw(at: NSPoint(x: button.minX + 9, y: button.minY + 3))
            let label = NSMutableAttributedString(
                string: name + "  ",
                attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: look.text]
            )
            label.append(NSAttributedString(
                string: command,
                attributes: [.font: EditorFont.font(11.5), .foregroundColor: look.muted]
            ))
            label.draw(in: NSRect(x: button.maxX + 10, y: frame.minY + 6, width: frame.width - 90, height: 18))
            runRects.append((frame, item.span.lowerBound))
        }
    }

    // MARK: Input

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if let hit = runRects.first(where: { $0.0.contains(point) }) { onRun?(hit.1); return }
        if let hit = taskRects.first(where: { $0.0.contains(point) }),
           point.x < hit.0.minX + 24 { onToggle?(hit.1); return }
        if let index = frames.firstIndex(where: { $0.insetBy(dx: -10, dy: -7).contains(point) }) {
            onClick?(doc.items[index].span.lowerBound)
        }
    }

    override func keyDown(with event: NSEvent) {
        onKey?(event)
    }
}
