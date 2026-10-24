import Foundation
@_exported import SillCore

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
