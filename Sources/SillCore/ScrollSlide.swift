import Foundation

/// A window sliding to where nvim scrolled it: nvim has moved by `lines` at once, and what is drawn moves there over a
/// moment, easing out. `from` is how far along it starts (0 for a slide that starts from the grid as it was).
public struct ScrollSlide: Equatable, Sendable {
    /// How many lines the window moved from the rows `previous` held (down positive).
    public var lines: Int
    public var start: Double
    public var from: Double

    public init(lines: Int, start: Double, from: Double = 0) {
        self.lines = lines
        self.start = start
        self.from = from
    }

    /// How long a slide takes from nothing to done.
    public static let duration = 0.12

    /// How far along it is at `now`, `from` to 1, easing out: fast first, then settling.
    public func progress(at now: Double) -> Double {
        let t = min(max((now - start) / Self.duration, 0), 1)
        return from + (1 - from) * (1 - pow(1 - t, 3))
    }

    /// Whether it has arrived.
    public func isDone(at now: Double) -> Bool { now - start >= Self.duration - 1e-9 }

    /// How many lines of the move are still to show.
    public func remaining(at now: Double) -> Double { Double(lines) * (1 - progress(at: now)) }

    /// A scroll of `lines` that comes while `active` is still sliding, as one slide from the rows the first one began
    /// from: what is drawn goes on from where it is (not back to where the first began), to the new place. Nil when the
    /// two together are nothing (they cancel) or too much to slide (a screenful or more); the window then simply is
    /// where it is.
    public static func chained(
        _ active: ScrollSlide, then lines: Int, at now: Double, height: Int
    ) -> ScrollSlide? {
        let total = active.lines + lines
        guard total != 0, abs(total) < height else { return nil }
        let left = active.remaining(at: now) + Double(lines)
        // The same rows as the first began from, so the start is how much of the whole move is already behind.
        let from = min(max(1 - left / Double(total), 0), 0.999)
        return ScrollSlide(lines: total, start: now, from: from)
    }
}
