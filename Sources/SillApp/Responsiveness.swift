import Foundation

/// Watches the main thread from a thread of its own: every 10 ms it schedules a block there and records how late it
/// ran. A stall is a block more than 50 ms late, kept with the phase it happened in, so a check can say what blocked
/// the UI and when. Off unless a check starts it.
final class MainThreadWatch: @unchecked Sendable {
    struct Stall {
        var phase: String
        var at: Double
        var milliseconds: Double
    }

    private let lock = NSLock()
    private var running = false
    private var phase = ""
    private var started = Date()
    private var delays: [String: [Double]] = [:]
    private var stalls: [Stall] = []

    func start() {
        lock.withLock {
            running = true
            started = Date()
        }
        let thread = Thread { [self] in
            while lock.withLock({ running }) {
                let posted = DispatchTime.now().uptimeNanoseconds
                let done = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { done.signal() }
                done.wait()
                let late = Double(DispatchTime.now().uptimeNanoseconds - posted) / 1_000_000
                lock.withLock {
                    delays[phase, default: []].append(late)
                    if late > 50 {
                        stalls.append(Stall(phase: phase, at: Date().timeIntervalSince(started), milliseconds: late))
                    }
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        thread.name = "sill.watch.main"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() { lock.withLock { running = false } }

    /// What follows is counted as `name`.
    func enter(_ name: String) { lock.withLock { phase = name } }

    var current: String { lock.withLock { phase } }

    /// A phase's worst delay and its 99th percentile, in milliseconds.
    func summary(_ name: String) -> (worst: Double, p99: Double, samples: Int) {
        let values = lock.withLock { delays[name] ?? [] }.sorted()
        guard !values.isEmpty else { return (0, 0, 0) }
        return (values.last!, values[min(values.count - 1, Int(Double(values.count) * 0.99))], values.count)
    }

    var allStalls: [Stall] { lock.withLock { stalls } }
}

/// Round trips to nvim, by phase, in milliseconds.
final class PingLog: @unchecked Sendable {
    private let lock = NSLock()
    private var times: [String: [Double]] = [:]

    private let started = Date()
    /// Round trips over 200 ms: when, in which phase, how long.
    private(set) var slow: [(at: Double, phase: String, milliseconds: Double)] = []

    func add(_ phase: String, _ milliseconds: Double) {
        lock.withLock {
            times[phase, default: []].append(milliseconds)
            if milliseconds > 200 { slow.append((Date().timeIntervalSince(started), phase, milliseconds)) }
        }
    }

    var slowTrips: [(at: Double, phase: String, milliseconds: Double)] { lock.withLock { slow } }

    func summary(_ phase: String) -> (worst: Double, p99: Double) {
        let values = lock.withLock { times[phase] ?? [] }.sorted()
        guard !values.isEmpty else { return (0, 0) }
        return (values.last!, values[min(values.count - 1, Int(Double(values.count) * 0.99))])
    }
}
