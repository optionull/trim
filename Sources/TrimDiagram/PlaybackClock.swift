import Foundation

/// Where in its animation a diagram is: running with the clock, paused, moved by a seek. Pure, with the time given, so
/// what
/// it says can be tested and the player only has to ask it.
public struct PlaybackClock: Equatable, Sendable {
    /// The animation's time at `anchor` (the time on the clock when it was last set).
    private var base = 0.0
    private var anchor = 0.0
    public private(set) var paused = false

    public init(now: Double = 0) { anchor = now }

    /// Seconds into the animation at clock time `now` (it loops: past its length it is the same frames again).
    public func time(now: Double) -> Double {
        max(0, paused ? base : base + (now - anchor))
    }

    public mutating func pause(now: Double) {
        guard !paused else { return }
        base = time(now: now)
        paused = true
    }

    public mutating func resume(now: Double) {
        guard paused else { return }
        anchor = now
        paused = false
    }

    public mutating func toggle(now: Double) {
        if paused { resume(now: now) } else { pause(now: now) }
    }

    /// Moves by `seconds` (back is negative), staying paused or running as it was.
    public mutating func seek(by seconds: Double, now: Double) {
        base = max(0, time(now: now) + seconds)
        anchor = now
    }

    /// Goes to `seconds` (not before the start), staying paused or running as it was.
    public mutating func seek(to seconds: Double, now: Double) {
        base = max(0, seconds)
        anchor = now
    }

    public mutating func restart(now: Double) {
        base = 0
        anchor = now
    }
}
