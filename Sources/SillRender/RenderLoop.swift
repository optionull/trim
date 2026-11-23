import Foundation
import Metal
import os
import QuartzCore
import Synchronization

/// When a frame was drawn, for latency and trim-time measurements.
public struct TrimTiming: Sendable {
    /// The frame's tag, as submitted.
    public var tag: UInt64
    /// When `submit` was called, in `CACurrentMediaTime` seconds.
    public var submitted: CFTimeInterval
    /// When the drawable reached the screen; 0 when the system does not say (seen on this machine at times, for
    /// every frame, from any app).
    public var presented: CFTimeInterval
    /// When the frame was encoded and committed.
    public var committed: CFTimeInterval
    /// CPU time spent building the frame's instances, in milliseconds.
    public var buildMilliseconds: Double
    /// GPU time for the frame, in milliseconds.
    public var gpuMilliseconds: Double
}

/// Draws frames into a `CAMetalLayer` on a thread of its own.
///
/// `submit` never waits: it leaves the newest frame where the render thread takes it. A frame submitted when nothing
/// was drawn in the last refresh is drawn at once, so a key is not held back for a display link tick; frames that
/// come faster are drawn once per refresh by a display link that follows the view's display. The link keeps running
/// for `linger` after the last frame, then pauses, so an idle editor draws nothing and wakes nothing.
///
/// Not `CAMetalDisplayLink`, which the plan named. Measured with the self-check on one machine and display (an LG 4K),
/// key to screen was a median 65 ms with it, each frame drawn for a refresh about four ahead; 45 ms with a view display
/// link and `nextDrawable()`, the pairing Ghostty uses; and 28 ms once a frame that is due is drawn at once.
public final class RenderLoop: NSObject, @unchecked Sendable {
    public let layer: CAMetalLayer
    private let renderer: GridRenderer
    private let state = Mutex(State())
    private var link: CADisplayLink?
    private var runLoop: CFRunLoop?
    private let started = DispatchSemaphore(value: 0)
    /// The shortest time between two frames: one refresh at 120 Hz.
    private let minimumInterval: CFTimeInterval = 1.0 / 120

    private struct State {
        var pending: (frame: Trim, tag: UInt64, submitted: CFTimeInterval)?
        var last: (frame: Trim, tag: UInt64)?
        var framesDrawn = 0
        var lastDrawn: CFTimeInterval = 0
        var paused = true
        var onPresented: (@Sendable (TrimTiming) -> Void)?
    }

    /// Frames drawn since the loop started.
    public var framesDrawn: Int { state.withLock { $0.framesDrawn } }

    /// True while the display link is paused: nothing to draw, and nothing drawn for `linger`.
    public var isPaused: Bool { state.withLock { $0.paused } }

    /// How long the link keeps running after the last frame.
    public let linger: CFTimeInterval = 0.5

    /// Called on a Metal thread for every frame presented.
    public var onPresented: (@Sendable (TrimTiming) -> Void)? {
        get { state.withLock { $0.onPresented } }
        set { state.withLock { $0.onPresented = newValue } }
    }

    /// `makeLink` makes the display link for a target and selector, on the main thread:
    /// `NSView.displayLink(target:selector:)`, so the link follows the display the view is on. The link retains this
    /// loop until `stop` invalidates it.
    @MainActor
    public init(layer: CAMetalLayer, renderer: GridRenderer, makeLink: (Any, Selector) -> CADisplayLink) {
        self.layer = layer
        self.renderer = renderer
        super.init()
        layer.device = renderer.device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.maximumDrawableCount = 3
        let link = makeLink(self, #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.isPaused = true
        self.link = link
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "sill.render"
        thread.qualityOfService = .userInteractive
        thread.start()
        started.wait()
    }

    private func run() {
        // A port keeps the run loop running while the link is paused; without a source CFRunLoopRun returns at once.
        RunLoop.current.add(NSMachPort(), forMode: .default)
        link?.add(to: .current, forMode: .default)
        runLoop = CFRunLoopGetCurrent()
        started.signal()
        CFRunLoopRun()
    }

    /// Hands the render thread a frame to draw. Frames not yet drawn are replaced.
    public func submit(_ frame: Trim, tag: UInt64 = 0) {
        state.withLock { $0.pending = (frame, tag, CACurrentMediaTime()) }
        onRenderThread { $0.drawOrSchedule() }
    }

    /// Draws the last frame again, at the layer's new size.
    public func redraw() {
        state.withLock { state in
            if state.pending == nil, let last = state.last {
                state.pending = (last.frame, last.tag, CACurrentMediaTime())
            }
        }
        onRenderThread { $0.drawOrSchedule() }
    }

    public func stop() {
        onRenderThread { loop in
            loop.link?.invalidate()
            loop.link = nil
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
    }

    private func onRenderThread(_ body: @escaping (RenderLoop) -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
            if let self { body(self) }
        }
        CFRunLoopWakeUp(runLoop)
    }

    /// Draws now if nothing was drawn in the last refresh; otherwise leaves it to the link's next tick.
    private func drawOrSchedule() {
        let now = CACurrentMediaTime()
        if state.withLock({ now - $0.lastDrawn >= minimumInterval }) {
            drawPending(now: now)
        }
        state.withLock { $0.paused = false }
        link?.isPaused = false
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        guard !drawPending(now: now) else { return }
        let idle = state.withLock { state -> Bool in
            if now - state.lastDrawn > linger { state.paused = true }
            return state.paused
        }
        if idle { link.isPaused = true }
    }

    /// Draws the pending frame, if there is one.
    @discardableResult
    private func drawPending(now: CFTimeInterval) -> Bool {
        let next = state.withLock { state -> (frame: Trim, tag: UInt64, submitted: CFTimeInterval)? in
            guard let pending = state.pending else { return nil }
            state.pending = nil
            state.last = (pending.frame, pending.tag)
            state.framesDrawn += 1
            state.lastDrawn = now
            return pending
        }
        guard let next else { return false }
        guard let drawable = layer.nextDrawable() else { return true }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = renderer.clearColor(next.frame.screen)
        guard let commands = renderer.queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return true }
        renderer.encode(
            next.frame, into: encoder,
            viewport: CGSize(width: drawable.texture.width, height: drawable.texture.height)
        )
        encoder.endEncoding()

        if let onPresented = state.withLock({ $0.onPresented }) {
            let build = renderer.stats.buildMilliseconds
            let (tag, submitted) = (next.tag, next.submitted)
            let committed = CACurrentMediaTime()
            let gpu = OSAllocatedUnfairLock(initialState: 0.0)
            commands.addCompletedHandler { buffer in
                let milliseconds = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
                gpu.withLock { $0 = milliseconds }
            }
            drawable.addPresentedHandler { drawable in
                onPresented(TrimTiming(
                    tag: tag, submitted: submitted, presented: drawable.presentedTime, committed: committed,
                    buildMilliseconds: build, gpuMilliseconds: gpu.withLock { $0 }
                ))
            }
        }
        commands.present(drawable)
        commands.commit()
        return true
    }
}
