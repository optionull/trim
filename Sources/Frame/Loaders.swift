import AppKit
import QuartzCore

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
