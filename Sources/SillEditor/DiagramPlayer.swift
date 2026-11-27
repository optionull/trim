import AppKit
import Foundation
import QuartzCore
import SillRender
import TrimDiagram

/// Plays the diagrams of an editor that move (Mermaider.Animate's): while one has rows on screen, a timer draws its
/// frame
/// for the time on its clock off the main thread, hands it to the renderer to put in the atlas, and asks for a frame to
/// be
/// drawn. Nothing is on screen that moves, nothing runs: the timer stops after a tick that finds none, and the renderer
/// starts it again when a frame with one in it is built, so an idle editor still wakes nothing.
package final class DiagramPlayer: @unchecked Sendable {
    /// Frames a second while playing.
    static let rate = 30.0

    private let queue = DispatchQueue(label: "trim.diagram.player", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var clock = PlaybackClock(now: CACurrentMediaTime())
    private var lastTime: Double?
    private let lock = NSLock()
    private weak var renderer: GridRenderer?
    private weak var loop: RenderLoop?
    /// Frames drawn since it started, for the self-check.
    package private(set) var framesPlayed = 0
    /// Whether it is running now (a diagram on screen moves).
    package var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timer != nil
    }

    package var isPaused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return clock.paused
    }

    package init() {}

    /// Plays on `renderer`'s diagrams, drawing through `loop`.
    package func attach(renderer: GridRenderer, loop: RenderLoop) {
        stop()
        self.renderer = renderer
        self.loop = loop
        renderer.onMovingDiagramShown { [weak self] in self?.start() }
    }

    package func detach() {
        renderer?.onMovingDiagramShown(nil)
        stop()
    }

    private func start() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1 / Self.rate, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    private func stop() {
        lock.lock()
        timer?.cancel()
        timer = nil
        lock.unlock()
    }

    private func tick() {
        guard let renderer, let loop else { return stop() }
        let moving = renderer.visibleDiagrams
            .compactMap { id in DiagramStore.shared.entry(id)?.playback.map { (id, $0) } }
        guard !moving.isEmpty else { return stop() }
        lock.lock()
        let time = clock.time(now: CACurrentMediaTime())
        let paused = clock.paused
        let unchanged = time == lastTime
        lastTime = time
        lock.unlock()
        // Paused, the same time is the same picture: nothing to draw until the clock moves.
        if unchanged { return }
        for (id, playback) in moving {
            if let image = playback
                .frame(at: time, paused: paused) { renderer.submitDiagramFrame(id: id, image: image) }
        }
        framesPlayed += 1
        loop.redraw()
    }

    // MARK: Transport

    package func toggle() { change { $0.toggle(now: $1) } }
    package func seek(by seconds: Double) { change { $0.seek(by: seconds, now: $1) } }
    package func restart() { change { $0.restart(now: $1) } }

    /// Where it is, in seconds into the loop.
    package var seconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return clock.time(now: CACurrentMediaTime())
    }

    private var pausedForScrub = false

    /// A drag on the bar begins: the animation holds where it is, and goes on from where the drag leaves it if it was
    /// playing.
    package func beginScrub() {
        change {
            pausedForScrub = $0.paused
            $0.pause(now: $1)
        }
    }

    /// The drag is at `fraction` of the loop of diagram `id`.
    package func scrub(id: Int, to fraction: Double) {
        guard let duration = DiagramStore.shared.entry(id)?.playback?.diagram.duration, duration > 0 else { return }
        change { $0.seek(to: fraction * duration, now: $1) }
    }

    package func endScrub() {
        if !pausedForScrub { change { $0.resume(now: $1) } }
    }

    private func change(_ edit: (inout PlaybackClock, Double) -> Void) {
        lock.lock()
        edit(&clock, CACurrentMediaTime())
        lastTime = nil
        lock.unlock()
        // A paused clock has no timer ticks to show a seek: draw one frame.
        queue.async { [weak self] in self?.tick() }
    }
}
