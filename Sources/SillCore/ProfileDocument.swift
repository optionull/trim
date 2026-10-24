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

    /// The frames as (name, depth, samples).
    public var preorder: [(name: Int, depth: Int, samples: Int)] {
        stride(from: 0, to: frames.count - 2, by: 3).map { (frames[$0], frames[$0 + 1], frames[$0 + 2]) }
    }
}
