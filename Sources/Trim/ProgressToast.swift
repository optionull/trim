import AppKit
import SillEditor

/// One thing that is going on: a language server loading projects or analysing, a build running. A percentage when it
/// has one (a bar that fills), else a bar that moves.
struct ProgressItem: Equatable {
    var id: String
    var client: String
    var title: String
    var message: String
    var percentage: Int?
}

/// A toast with a row for everything that is going on, each with its own loader and bar: it grows with what there is
/// (the most recent few shown, a line for the rest) and is gone when nothing is. It does not take clicks.
final class ProgressToastView: NSView {
    var look = TreeLook() {
        didSet { needsDisplay = true }
    }

    var items: [ProgressItem] = [] {
        didSet {
            guard items != oldValue else { return }
            isHidden = items.isEmpty
            needsDisplay = true
            needsLayout = true
            superview?.needsLayout = true
        }
    }

    static let maxRows = 5
    static let rowHeight: CGFloat = 40
    private static let left: CGFloat = 36

    /// The loaders: a turning arc by each row, and a moving bar where a row has no percentage. Core Animation moves
    /// them, so nothing is drawn again while they go.
    private var spinners: [LoaderView] = []
    private var bars: [LoaderView] = []

    /// The rows that are shown: the newest.
    var shown: [ProgressItem] { Array(items.suffix(Self.maxRows)) }

    /// How many rows have a loader going (for the self-check).
    var loaders: Int { spinners.count(where: \.isGoing) }
    var movingBars: Int { bars.count(where: \.isGoing) }
    /// Where the loaders are, in the view's own coordinates (down from the top).
    var spinnerFrames: [NSRect] { spinners.map(\.frame) }
    var barFrames: [NSRect] { bars.map(\.frame) }

    /// How tall it is for what it holds.
    var contentHeight: CGFloat {
        guard !items.isEmpty else { return 0 }
        return 16 + CGFloat(shown.count) * Self.rowHeight + (items.count > Self.maxRows ? 22 : 0)
    }

    override var isFlipped: Bool { true }
    override func hitTest(_: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        spinners.forEach { $0.removeFromSuperview() }
        bars.forEach { $0.removeFromSuperview() }
        spinners = []
        bars = []
        guard !items.isEmpty else { return }
        var y: CGFloat = 8
        for item in shown {
            let spinner = LoaderView(.spinner)
            spinner.frame = NSRect(x: 14, y: y + 3, width: 14, height: 14)
            addSubview(spinner)
            spinners.append(spinner)
            if item.percentage == nil {
                let bar = LoaderView(.bar)
                bar.track = look.faint.withAlphaComponent(0.25)
                bar.frame = NSRect(
                    x: Self.left, y: y + Self.rowHeight - 7, width: max(0, bounds.width - Self.left - 14), height: 3
                )
                addSubview(bar)
                bars.append(bar)
            }
            y += Self.rowHeight
        }
    }

    override func draw(_: NSRect) {
        guard !items.isEmpty else { return }
        let panel = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        look.island.setFill()
        panel.fill()
        look.faint.withAlphaComponent(0.4).setStroke()
        panel.lineWidth = 1
        panel.stroke()
        var y: CGFloat = 8
        for item in shown {
            let head = NSMutableAttributedString(string: item.client, attributes: [
                .font: look.boldFont, .foregroundColor: look.text,
            ])
            head.append(NSAttributedString(string: "  " + item.title, attributes: [
                .font: look.font, .foregroundColor: look.muted,
            ]))
            let left = Self.left
            head.draw(
                with: NSRect(x: left, y: y + 2, width: bounds.width - left - 14, height: 18),
                options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin]
            )
            var detail = item.message
            if let percentage = item.percentage { detail += (detail.isEmpty ? "" : "  ") + "\(percentage)%" }
            if !detail.isEmpty {
                NSAttributedString(string: detail, attributes: [.font: look.smallFont, .foregroundColor: look.faint])
                    .draw(
                        with: NSRect(x: left, y: y + 20, width: bounds.width - left - 14, height: 14),
                        options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin]
                    )
            }
            // The bar of a row that knows how far it is: filled to the percentage (the others have a moving one).
            if let percentage = item.percentage {
                let track = NSRect(x: left, y: y + Self.rowHeight - 7, width: bounds.width - left - 14, height: 3)
                look.faint.withAlphaComponent(0.25).setFill()
                NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
                Design.accent.setFill()
                let fill = NSRect(
                    x: track.minX, y: track.minY, width: track.width * CGFloat(min(max(percentage, 0), 100)) / 100,
                    height: 3
                )
                NSBezierPath(roundedRect: fill, xRadius: 1.5, yRadius: 1.5).fill()
            }
            y += Self.rowHeight
        }
        if items.count > Self.maxRows {
            NSAttributedString(string: "+\(items.count - Self.maxRows) more", attributes: [
                .font: look.smallFont, .foregroundColor: look.faint,
            ]).draw(at: NSPoint(x: 14, y: y + 2))
        }
    }
}
