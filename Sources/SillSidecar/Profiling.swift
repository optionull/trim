import Foundation

/// The sidecar's profiler (M6): a .NET program run under EventPipe's sampler, heap snapshots of it compared as they are
/// taken, and its CPU profile once the recording stops.

/// What a run says while it goes: building, running (its process and name), output (the program's text), reading.
public struct ProfilePartial: Decodable, Sendable, Equatable {
    public var stage: String
    public var text: String?
    public var error: Bool?
    public var processId: Int?
    public var name: String?
}

/// A CPU profile: the call tree of all threads flattened in preorder, as triples in `frames` (an index into `names`, a
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

/// A heap snapshot: its types by bytes, and how it differs from the run's previous one.
public struct HeapDocument: Decodable, Sendable, Equatable {
    public var number: Int
    public var name: String
    public var objects: Int
    public var bytes: Int64
    public var tookMs: Double
    public var types: [TypeRow]
    public var comparison: Comparison?

    public struct TypeRow: Decodable, Sendable, Equatable {
        public var name: String
        public var count: Int
        public var bytes: Int64
        public var retainedBytes: Int64
    }

    public struct Comparison: Decodable, Sendable, Equatable {
        public var title: String
        public var newObjects: Int
        public var deadObjects: Int
        public var survivedObjects: Int
        public var inexact: String?
        public var types: [Delta]
    }

    public struct Delta: Decodable, Sendable, Equatable {
        public var name: String
        public var objectsDelta: Int
        public var bytesDelta: Int64
        public var newObjects: Int
        public var newBytes: Int64
        public var deadObjects: Int
        public var deadBytes: Int64
    }
}

public extension Sidecar {
    /// Starts a profiling run of `project` (a folder or project file, built in Release) and returns its id at once;
    /// `profileResult(run:)` waits for its CPU profile, which comes once it is stopped or the program ends.
    func startProfile(
        project: String, arguments: [String] = [], progress: (@Sendable (ProfilePartial) -> Void)? = nil
    ) async throws -> Int {
        struct Params: Encodable {
            var project: String
            var arguments: [String]
        }
        return try send("profile", Params(project: project, arguments: arguments)) { data in
            if let update = try? JSONDecoder().decode(ProfilePartial.self, from: data) { progress?(update) }
        }
    }

    func profileResult(run: Int) async throws -> ProfileDocument {
        try await JSONDecoder().decode(ProfileDocument.self, from: reply(to: run))
    }

    /// A heap snapshot of a run now, compared with its previous one.
    func heapSnapshot(run: Int) async throws -> HeapDocument {
        try await request("profile.snapshot", RunParams(run: run), as: HeapDocument.self)
    }

    /// Ends a run's recording: its `profileResult` then comes.
    @discardableResult
    func stopProfile(run: Int) async throws -> Bool {
        try await request("profile.stop", RunParams(run: run), as: Bool.self)
    }
}

private struct RunParams: Encodable {
    var run: Int
}
