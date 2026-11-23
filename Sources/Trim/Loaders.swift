import AppKit
import QuartzCore
import SillEditor

/// A turning arc, as a loader. Core Animation turns it: the main thread does nothing for it once it has started, so it
/// keeps turning while the window is busy (a build that uses every core, say), and costs nothing to draw again.
final class SpinnerLayer: CAShapeLayer {
    override init() {
        super.init()
        fillColor = nil
        lineWidth = 2
        lineCap = .round
        strokeEnd = 0.72
    }

    override init(layer: Any) { super.init(layer: layer) }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    func place(in rect: NSRect, color: NSColor) {
        frame = rect
        strokeColor = color.cgColor
        let inset = lineWidth / 2 + 0.5
        path = CGPath(ellipseIn: CGRect(origin: .zero, size: rect.size).insetBy(dx: inset, dy: inset), transform: nil)
        guard animation(forKey: "turn") == nil else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = -2 * Double.pi
        turn.duration = 0.9
        turn.repeatCount = .infinity
        turn.isRemovedOnCompletion = false
        add(turn, forKey: "turn")
    }
}

/// A bar with a piece going along it, for work that cannot say how far it is: animated by Core Animation like the
/// spinner.
final class IndeterminateBarLayer: CALayer {
    private let piece = CALayer()

    override init() {
        super.init()
        masksToBounds = true
        cornerRadius = 1.5
        piece.cornerRadius = 1.5
        addSublayer(piece)
    }

    override init(layer: Any) { super.init(layer: layer) }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    func place(in rect: NSRect, track: NSColor, color: NSColor) {
        frame = rect
        backgroundColor = track.cgColor
        let width = rect.width * 0.3
        piece.backgroundColor = color.cgColor
        piece.frame = CGRect(x: -width, y: 0, width: width, height: rect.height)
        piece.removeAllAnimations()
        let slide = CABasicAnimation(keyPath: "position.x")
        slide.fromValue = -width / 2
        slide.toValue = rect.width + width / 2
        slide.duration = 1.3
        slide.repeatCount = .infinity
        slide.isRemovedOnCompletion = false
        piece.add(slide, forKey: "slide")
    }

    var isAnimating: Bool { piece.animation(forKey: "slide") != nil }
}

/// A loader in a view of its own: the view is placed like any other (so it is where it is meant to be whichever way the
/// parent counts), and the animated layer fills it (so which way a layer counts cannot matter).
final class LoaderView: NSView {
    enum Kind { case spinner, bar }

    let kind: Kind
    private let spinner = SpinnerLayer()
    private let bar = IndeterminateBarLayer()
    var color = Design.accent {
        didSet { needsLayout = true }
    }

    var track = NSColor.gray.withAlphaComponent(0.25) {
        didSet { needsLayout = true }
    }

    init(_ kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(kind == .spinner ? spinner : bar)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let rect = NSRect(origin: .zero, size: bounds.size)
        switch kind {
        case .spinner: spinner.place(in: rect, color: color)
        case .bar: bar.place(in: rect, track: track, color: color)
        }
        CATransaction.commit()
    }

    /// Whether the loader is going (for the self-check).
    var isGoing: Bool { kind == .spinner ? spinner.animation(forKey: "turn") != nil : bar.isAnimating }
}
