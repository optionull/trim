import Foundation

/// Scrolling by the pixel, as a trackpad does it. The text is drawn where the finger has taken it (`visual`, in lines,
/// down
/// positive, not whole); nvim scrolls in whole lines, and is kept a line ahead in the direction of the move, so the
/// rows that
/// come into view are already there: what is drawn is the window between the rows before and after nvim's last scroll
/// (`ScrollSlide`'s picture), with how far along it is set by the finger instead of the clock.
public struct PixelScroll: Equatable, Sendable {
    /// Where the text is drawn, in lines from where the gesture began (down positive).
    public private(set) var visual = 0.0
    /// The lines nvim has been asked to scroll, from where the gesture began.
    public private(set) var sent = 0

    public init() {}

    /// The finger moved the text by `lines` (down positive). Returns the whole lines to ask nvim to scroll now (down
    /// positive): going down, nvim is ahead of what is drawn (`sent` at least `visual`, rounded up); going up, the same
    /// the
    /// other way. Nothing is asked while the move stays inside the line nvim is already at.
    public mutating func move(by lines: Double, reported: Int = 0, slack: Int = 8) -> Int {
        visual += lines
        // nvim that does not scroll (the end of the buffer) must not let the text run away from it.
        visual = min(max(visual, Double(reported - slack)), Double(reported + slack))
        let target = lines >= 0 ? max(sent, Int(visual.rounded(.up))) : min(sent, Int(visual.rounded(.down)))
        let asked = target - sent
        sent = target
        return asked
    }

    /// How far nvim's rows (`reported`, the lines it has scrolled so far) are from what is drawn: positive when nvim is
    /// ahead going down. Zero when drawn where nvim is.
    public func lag(reported: Int) -> Double { Double(reported) - visual }

    /// How far along a slide of `lines` is, 0 to 1, when the text is `lag` lines short of where nvim is.
    public static func progress(lines: Int, lag: Double) -> Double {
        guard lines != 0 else { return 1 }
        return min(max(1 - lag / Double(lines), 0), 1)
    }

    /// The gesture is over: what was drawn has settled where nvim is.
    public mutating func reset() {
        visual = 0
        sent = 0
    }
}
