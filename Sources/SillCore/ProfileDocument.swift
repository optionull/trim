import Foundation

/// A CPU profile, whichever profiler made it (the sidecar's for .NET, samply, xctrace): the call tree of all threads
/// flattened in preorder, as triples in `frames` (an index into `names`, a
/// depth, samples), and what an agent is told about it.
public struct ProfileDocument: Decodable, Sendable, Equatable {
    public var name: String
    public var samples: Int
    public var durationMs: Double
    public var sampleMs: Double
    public var exited: Bool
    public var names: [String]
    public var frames: [Int]
    public var hotSpots: [HotFrame]
    public var collections: [GcRow]
    public var allocations: [AllocationRow]
    /// Samples in each of equal stretches of the run, first to last: the CPU over time strip.
    public var timeline: [Int]?
    /// Each sample's time (ms from the first) and the frame it ended in (a frame's number in preorder), and its weight
    /// when not one: what `within` rebuilds a stretch from. Native profiles carry them; the sidecar's answers a stretch
    /// itself.
    public var sampleTimes: [Double]?
    public var sampleFrames: [Int]?
    public var sampleWeights: [Int]?

    public init(
        name: String, samples: Int, durationMs: Double, sampleMs: Double, exited: Bool, names: [String], frames: [Int],
        hotSpots: [HotFrame], collections: [GcRow] = [], allocations: [AllocationRow] = []
    ) {
        self.name = name
        self.samples = samples
        self.durationMs = durationMs
        self.sampleMs = sampleMs
        self.exited = exited
        self.names = names
        self.frames = frames
        self.hotSpots = hotSpots
        self.collections = collections
        self.allocations = allocations
    }

    public struct HotFrame: Decodable, Sendable, Equatable {
        public var name: String
        public var module: String
        /// Samples in it and no deeper (the sidecar's `self`).
        public var selfSamples: Int
        public var total: Int
        public var file: String?
        public var line: Int?

        enum CodingKeys: String, CodingKey {
            case name, module, selfSamples = "self", total, file, line
        }

        public init(name: String, module: String, selfSamples: Int, total: Int, file: String?, line: Int?) {
            self.name = name
            self.module = module
            self.selfSamples = selfSamples
            self.total = total
            self.file = file
            self.line = line
        }
    }

    public struct GcRow: Decodable, Sendable, Equatable {
        public var number: Int
        public var generation: Int
        public var reason: String
        public var atMs: Double
        public var pauseMs: Double
    }

    public struct AllocationRow: Decodable, Sendable, Equatable {
        public var name: String
        public var bytes: Int64
        public var ticks: Int
    }

    /// Cuts sample times into `count` buckets over the run.
    public static func timeline(times: [Double], weights: [Int]?, count: Int = 120) -> [Int] {
        guard let first = times.min(), let last = times.max() else { return [] }
        let width = max(last - first, 1e-6) / Double(count)
        var buckets = [Int](repeating: 0, count: count)
        for (index, time) in times.enumerated() {
            buckets[min(Int((time - first) / width), count - 1)] += weights?[index] ?? 1
        }
        return buckets
    }

    /// The profile of a stretch of the run (fractions of it, 0 to 1), from its samples' times: the same tree with
    /// each frame's samples in the stretch, frames with none left out, and the hot spots counted again. Nil when the
    /// document has no times (the sidecar's: ask it).
    public func within(from: Double, to: Double) -> ProfileDocument? {
        guard let times = sampleTimes, let leaves = sampleFrames, times.count == leaves.count,
              let first = times.min(), let last = times.max() else { return nil }
        let span = last - first
        let start = first + span * min(from, to), end = first + span * max(from, to)
        let nodes = preorder
        var own = [Int](repeating: 0, count: nodes.count)
        var samples = 0
        for (index, time) in times.enumerated() where time >= start && time <= end && leaves[index] < nodes.count {
            let weight = sampleWeights?[index] ?? 1
            own[leaves[index]] += weight
            samples += weight
        }
        // Each frame's parent, then totals from the leaves up.
        var parents = [Int](repeating: -1, count: nodes.count)
        var stack: [Int] = []
        for (index, node) in nodes.enumerated() {
            while let top = stack.last, nodes[top].depth >= node.depth {
                stack.removeLast()
            }
            parents[index] = stack.last ?? -1
            stack.append(index)
        }
        var totals = own
        for index in nodes.indices.reversed() where parents[index] >= 0 {
            totals[parents[index]] += totals[index]
        }
        totals[0] = max(totals[0], samples)
        var kept: [Int] = []
        for (index, node) in nodes.enumerated() where totals[index] > 0 || index == 0 {
            kept += [node.name, node.depth, totals[index]]
        }
        // Hot spots: a function's own samples, and its total counted once per path (its outermost frame).
        var selfByName: [Int: Int] = [:], totalByName: [Int: Int] = [:]
        var path: [Int] = []
        for (index, node) in nodes.enumerated() where index > 0 {
            while path.count >= node.depth {
                path.removeLast()
            }
            selfByName[node.name, default: 0] += own[index]
            if !path.contains(node.name) { totalByName[node.name, default: 0] += totals[index] }
            path.append(node.name)
        }
        let places = Dictionary(hotSpots.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let hot = selfByName.filter { $0.value > 0 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : names[$0.key] < names[$1.key] }.prefix(25)
            .map { name, count in
                let place = places[names[name]]
                return HotFrame(
                    name: names[name],
                    module: place?.module ?? "",
                    selfSamples: count,
                    total: totalByName[name] ?? count,
                    file: place?.file,
                    line: place?.line
                )
            }
        var stretch = ProfileDocument(
            name: name,
            samples: samples,
            durationMs: end - start,
            sampleMs: sampleMs,
            exited: exited,
            names: names,
            frames: kept,
            hotSpots: Array(hot),
            collections: collections
                .filter { $0.atMs >= start - first && $0.atMs <= end - first },
            allocations: allocations
        )
        stretch.timeline = timeline
        return stretch
    }

    /// The frames as (name, depth, samples).
    public var preorder: [(name: Int, depth: Int, samples: Int)] {
        stride(from: 0, to: frames.count - 2, by: 3).map { (frames[$0], frames[$0 + 1], frames[$0 + 2]) }
    }
}
