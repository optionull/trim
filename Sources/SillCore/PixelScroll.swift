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
    /// The steps asked since nvim last reported a scroll: on their way, not in its rows yet.
    public private(set) var pending = 0

    public init() {}

    /// The finger moved the text by `lines` (down positive); `lastStep` is how many rows nvim's last scroll moved.
    /// Returns the
    /// whole lines to ask nvim to scroll now (down positive): going down, nvim is ahead of what is drawn, going up the
    /// other way.
    /// Nothing is asked while the move stays inside the line nvim is already at.
    ///
    /// Asking is compared with where nvim is, or soon will be, in rows (`reported` plus the steps asked and not yet
    /// reported),
    /// not with the steps asked: a wheel step scrolls a whole buffer line, one row of ordinary text but many under a
    /// line with a
    /// card, a diagram or a table drawn below it. Counting steps against rows would see nvim "behind" after every such
    /// step and
    /// ask for more, which scroll more, and the text races ahead of the finger.
    public mutating func move(by lines: Double, reported: Int = 0, slack: Int = 3, lastStep: Int = 1) -> Int {
        visual += lines
        // nvim that does not scroll (the end of the buffer) must not let the text run away from it. The text may be
        // behind
        // nvim by the rows of its last step: holding it closer would drag it ahead of the finger.
        let allowance = max(slack, abs(lastStep))
        visual = min(max(visual, Double(reported - allowance)), Double(reported + allowance))
        let asked: Int = if lines >= 0 {
            max(0, Int(visual.rounded(.up)) - (reported + max(0, pending)))
        } else {
            min(0, Int(visual.rounded(.down)) - (reported + min(0, pending)))
        }
        pending += asked
        sent += asked
        return asked
    }

    /// nvim reported a scroll: what was asked before it is in `reported` now.
    public mutating func acknowledge() { pending = 0 }

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
        pending = 0
    }
}
