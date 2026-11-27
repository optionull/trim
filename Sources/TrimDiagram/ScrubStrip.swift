import CoreGraphics
import CoreText
import Foundation

/// The bar under a diagram that moves: a play or pause mark, a track with a handle where the animation is, and the
/// time. It
/// is drawn into the diagram's own picture (the bottom `height` points), so it scrolls and is clipped with the rows;
/// where a
/// click on it lands is worked out from the position in the picture alone (`hit`), which is what the editor asks.
public struct ScrubStrip: Sendable, Equatable {
    public static let height: CGFloat = 26
    public static let iconWidth: Double = 32
    public static let labelWidth: Double = 96
    public static let margin: Double = 8

    /// Where in the loop it is, and how long the loop is, in seconds.
    public var seconds: Double
    public var duration: Double
    public var paused: Bool
    /// The colours of the page, as `#rrggbb`: the text, the filled part and handle, and the rest of the track.
    public var foreground: String
    public var accent: String
    public var muted: String

    public init(seconds: Double, duration: Double, paused: Bool, theme: [String: String]) {
        self.duration = duration
        self.seconds = duration > 0 ? seconds.truncatingRemainder(dividingBy: duration) : 0
        self.paused = paused
        foreground = theme["fg"] ?? "#c0caf5"
        accent = theme["accent"] ?? "#7aa2f7"
        muted = theme["muted"] ?? "#565f89"
    }

    public enum Hit: Equatable, Sendable {
        /// The play or pause mark.
        case toggle
        /// The track: the fraction of the loop, 0 to 1.
        case seek(Double)
    }

    /// The track's left and right, in points of a picture `width` wide.
    public static func track(width: Double) -> (from: Double, to: Double) {
        (iconWidth, max(iconWidth + 20, width - labelWidth - margin))
    }

    /// What a press at `x` (points from the picture's left) does, nil where the strip does nothing (the time).
    public static func hit(x: Double, width: Double) -> Hit? {
        if x < iconWidth { return .toggle }
        let track = track(width: width)
        return x <= track.to + 6 ? .seek(fraction(x: x, width: width)) : nil
    }

    /// The fraction of the loop under `x`, held to 0 ... 1: a drag that leaves the track goes on following it.
    public static func fraction(x: Double, width: Double) -> Double {
        let track = track(width: width)
        return min(max((x - track.from) / (track.to - track.from), 0), 1)
    }

    static func color(_ hex: String, alpha: Double = 1) -> CGColor {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let value = UInt32(digits, radix: 16) ?? 0x808080
        return CGColor(
            srgbRed: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255,
            blue: Double(value & 255) / 255, alpha: alpha
        )
    }

    /// Draws the strip into the bottom of `context` (y up, origin at the bottom left, `scale` pixels to a point).
    func draw(in context: CGContext, pixelWidth: Int, scale: CGFloat) {
        let width = Double(pixelWidth) / Double(scale)
        let middle = Double(Self.height) / 2
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        // The mark: a triangle while paused (play it), two bars while it plays (pause it).
        context.setFillColor(Self.color(accent))
        let centre = Self.iconWidth / 2
        if paused {
            context.move(to: CGPoint(x: centre - 4, y: middle - 6))
            context.addLine(to: CGPoint(x: centre - 4, y: middle + 6))
            context.addLine(to: CGPoint(x: centre + 6, y: middle))
            context.closePath()
            context.fillPath()
        } else {
            context.fill(CGRect(x: centre - 5, y: middle - 6, width: 3.5, height: 12))
            context.fill(CGRect(x: centre + 1.5, y: middle - 6, width: 3.5, height: 12))
        }
        // The track, its filled part and the handle.
        let track = Self.track(width: width)
        let line = CGRect(x: track.from, y: middle - 1.5, width: track.to - track.from, height: 3)
        context.setFillColor(Self.color(muted, alpha: 0.45))
        context.addPath(CGPath(roundedRect: line, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
        context.fillPath()
        let fraction = duration > 0 ? seconds / duration : 0
        let reach = track.from + (track.to - track.from) * fraction
        context.setFillColor(Self.color(accent))
        var filled = line
        filled.size.width = reach - track.from
        context.addPath(CGPath(roundedRect: filled, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
        context.fillPath()
        context.setFillColor(Self.color(foreground))
        context.fillEllipse(in: CGRect(x: reach - 5, y: middle - 5, width: 10, height: 10))
        // The time, as `4.2 / 15.0 s`.
        let font = CTFontCreateWithName("Menlo" as CFString, 11, nil)
        let text = String(format: "%.1f / %.1f s", seconds, duration)
        let attributed = NSAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: Self.color(muted)]
        )
        let label = CTLineCreateWithAttributedString(attributed)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: width - Self.labelWidth, y: middle - 4)
        CTLineDraw(label, context)
        context.restoreGState()
    }
}
