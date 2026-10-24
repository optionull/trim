import Foundation

/// Two CPU profiles of the same program compared (before a change and after): each function's own and total time in
/// both, in milliseconds (samples times how long a sample stands for, so runs of different lengths and rates compare),
/// the biggest changes first. What an agent that changed the code is told, and what the Compare tab draws.
public struct ProfileComparison: Sendable, Equatable {
    public struct Row: Sendable, Equatable {
        public var name: String
        public var selfBefore: Double
        public var selfAfter: Double
        public var totalBefore: Double
        public var totalAfter: Double
        public var file: String?
        public var line: Int?

        /// Its total as a share of its run's CPU (0 to 1): what compares when the runs were not as long.
        public var shareBefore = 0.0
        public var shareAfter = 0.0

        public var selfChange: Double { selfAfter - selfBefore }
        public var totalChange: Double { totalAfter - totalBefore }
    }

    public var before: String
    public var after: String
    /// All the CPU time each run sampled, in milliseconds.
    public var cpuBefore: Double
    public var cpuAfter: Double
    /// How long each run was, in milliseconds.
    public var durationBefore: Double
    public var durationAfter: Double
    /// The functions whose time changed most, by total, then by own time.
    public var rows: [Row]

    public init(before: ProfileDocument, after: ProfileDocument, limit: Int = 25) {
        self.before = before.name
        self.after = after.name
        cpuBefore = Double(before.samples) * before.sampleMs
        cpuAfter = Double(after.samples) * after.sampleMs
        durationBefore = before.durationMs
        durationAfter = after.durationMs
        let old = Self.times(before), new = Self.times(after)
        var places: [String: (file: String, line: Int?)] = [:]
        for hot in before.hotSpots + after.hotSpots {
            if let file = hot.file { places[hot.name] = (file, hot.line) }
        }
        var all: [Row] = []
        for name in Set(old.keys).union(new.keys) {
            let a: (own: Double, total: Double) = old[name] ?? (0, 0)
            let b: (own: Double, total: Double) = new[name] ?? (0, 0)
            guard a.own != b.own || a.total != b.total else { continue }
            var row = Row(
                name: name,
                selfBefore: a.own,
                selfAfter: b.own,
                totalBefore: a.total,
                totalAfter: b.total,
                file: places[name]?.file,
                line: places[name]?.line
            )
            row.shareBefore = cpuBefore > 0 ? a.total / cpuBefore : 0
            row.shareAfter = cpuAfter > 0 ? b.total / cpuAfter : 0
            all.append(row)
        }
        all.sort { left, right in
            let l = abs(left.totalChange), r = abs(right.totalChange)
            if l != r { return l > r }
            let ls = abs(left.selfChange), rs = abs(right.selfChange)
            if ls != rs { return ls > rs }
            return left.name < right.name
        }
        rows = Array(all.prefix(limit))
    }

    /// Each function's own and total time in a profile, in milliseconds: its own is its frames' samples not in a
    /// deeper frame; its total counts a sample once however often the function is on its stack. The program's root
    /// and the thread frames are left out.
    static func times(_ document: ProfileDocument) -> [String: (own: Double, total: Double)] {
        let nodes = document.preorder
        var own = [Int](repeating: 0, count: nodes.count)
        var parents = [Int](repeating: -1, count: nodes.count)
        var stack: [Int] = []
        for (index, node) in nodes.enumerated() {
            while let top = stack.last, nodes[top].depth >= node.depth {
                stack.removeLast()
            }
            parents[index] = stack.last ?? -1
            stack.append(index)
            own[index] = node.samples
        }
        for index in nodes.indices where parents[index] >= 0 {
            own[parents[index]] -= nodes[index].samples
        }
        var times: [String: (own: Double, total: Double)] = [:]
        var path: [Int] = []
        for (index, node) in nodes.enumerated() {
            while path.count > node.depth {
                path.removeLast()
            }
            // Depth 0 is the program, 1 a thread.
            if node.depth >= 2 {
                let name = document.names[node.name]
                var entry = times[name] ?? (0, 0)
                entry.own += Double(own[index]) * document.sampleMs
                if !path.contains(node.name) { entry.total += Double(node.samples) * document.sampleMs }
                times[name] = entry
            }
            path.append(node.name)
        }
        return times
    }

    /// For an agent: the run's CPU before and after, then each function's change.
    public var text: String {
        func ms(_ value: Double) -> String { String(format: "%.0f ms", value) }
        func signed(_ value: Double) -> String { (value > 0 ? "+" : "") + ms(value) }
        func share(_ value: Double) -> String { String(format: "%.0f%%", value * 100) }
        var lines = ["cpu: \(ms(cpuBefore)) → \(ms(cpuAfter)) (\(signed(cpuAfter - cpuBefore))), over runs of " +
            String(format: "%.1f s → %.1f s", durationBefore / 1000, durationAfter / 1000) +
            "; when the runs differ in length, compare the shares of each run"]
        for row in rows {
            let place = row.file.map { " (\(($0 as NSString).lastPathComponent):\(row.line ?? 0))" } ?? ""
            lines.append("\(row.name)\(place): total \(ms(row.totalBefore)) → \(ms(row.totalAfter)) " +
                "(\(signed(row.totalChange))), own \(ms(row.selfBefore)) → \(ms(row.selfAfter)), " +
                "share \(share(row.shareBefore)) → \(share(row.shareAfter))")
        }
        return lines.joined(separator: "\n")
    }
}
