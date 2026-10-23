import Foundation

/// A flame graph drawn by level of detail: frames at least a pixel wide are drawn as they are; narrower ones are
/// merged, per depth, into blocks a pixel or more wide. However many samples there are, the number of blocks stays
/// near the number of pixels.
///
/// For M0 this proves the approach on a synthetic profile (the go/no-go in plan §3); the profiler's own views build
/// on it later.
public struct FlameGraph: Sendable {
    /// One call-tree node: where its samples start, how many there are, and its depth. Children follow their parent.
    public struct Node: Sendable {
        public var start: Int
        public var samples: Int
        public var depth: Int
        public var name: Int
        /// Index past this node's last descendant.
        public var end: Int
    }

    public let nodes: [Node]
    public let maxDepth: Int
    public var totalSamples: Int { nodes.first?.samples ?? 0 }

    public init(nodes: [Node]) {
        self.nodes = nodes
        maxDepth = nodes.map(\.depth).max() ?? 0
    }

    /// A call tree given in preorder (each frame's name, depth and samples, children after their parent): each frame
    /// starts where its previous sibling ended, or where its parent starts.
    public init(preorder: [(name: Int, depth: Int, samples: Int)]) {
        var nodes: [Node] = []
        nodes.reserveCapacity(preorder.count)
        // The open frames, root first, and where each one's next child starts.
        var open: [(index: Int, next: Int)] = []
        for frame in preorder {
            while let last = open.last, nodes[last.index].depth >= frame.depth {
                nodes[last.index].end = nodes.count
                open.removeLast()
            }
            let start = open.last?.next ?? 0
            if !open.isEmpty { open[open.count - 1].next += frame.samples }
            nodes.append(Node(start: start, samples: frame.samples, depth: frame.depth, name: frame.name, end: 0))
            open.append((nodes.count - 1, start))
        }
        for frame in open {
            nodes[frame.index].end = nodes.count
        }
        self.init(nodes: nodes)
    }

    /// A deterministic synthetic profile of `samples` samples, with skewed fan-out like a real call tree. Frames with
    /// at least `minSamples` samples get up to `maxChildren` children.
    public static func synthetic(
        samples: Int, seed: UInt64 = 42, maxDepth: Int = 40, minSamples: Int = 8, maxChildren: Int = 6
    ) -> FlameGraph {
        var random = SplitMix(seed: seed)
        var nodes: [Node] = []
        nodes.reserveCapacity(samples / max(minSamples, 1))
        func grow(start: Int, samples: Int, depth: Int) {
            let index = nodes.count
            nodes.append(Node(start: start, samples: samples, depth: depth, name: Int(random.next() % 5000), end: 0))
            if depth < maxDepth, samples >= minSamples {
                // Children take most of the parent (the rest is self time), split with a heavy head.
                var left = Int(Double(samples) * (0.55 + 0.4 * random.unit()))
                var offset = start
                let children = 1 + Int(random.next() % UInt64(maxChildren))
                for child in 0 ..< children where left > 0 {
                    let share = child == children - 1 ? left : max(1, Int(Double(left) * (0.3 + 0.6 * random.unit())))
                    grow(start: offset, samples: share, depth: depth + 1)
                    offset += share
                    left -= share
                }
            }
            nodes[index].end = nodes.count
        }
        grow(start: 0, samples: samples, depth: 0)
        return FlameGraph(nodes: nodes)
    }

    public struct Block: Sendable, Equatable {
        public var x: Float
        public var width: Float
        public var depth: Int
        /// The node this block is, or for a merged block, the first node in it.
        public var node: Int
        public var merged: Bool
    }

    /// The blocks to draw for samples `from ..< to` across `pixels` pixels. Frames narrower than a pixel are merged
    /// with their neighbours at the same depth; their descendants are not visited.
    public func blocks(from: Double, to: Double, pixels: Double) -> [Block] {
        var visited = 0
        return blocks(from: from, to: to, pixels: pixels, visited: &visited)
    }

    /// As `blocks(from:to:pixels:)`, counting the frames looked at: those off screen or under a pixel are skipped
    /// with everything under them.
    func blocks(from: Double, to: Double, pixels: Double, visited: inout Int) -> [Block] {
        guard !nodes.isEmpty, to > from else { return [] }
        let scale = pixels / (to - from)
        var blocks: [Block] = []
        // Per depth, a run of sub-pixel frames being merged.
        var pending = [Block?](repeating: nil, count: maxDepth + 1)
        func flush(_ depth: Int) {
            if let block = pending[depth] {
                var block = block
                block.width = max(block.width, 1)
                blocks.append(block)
                pending[depth] = nil
            }
        }
        var index = 0
        while index < nodes.count {
            visited += 1
            let node = nodes[index]
            let x0 = (Double(node.start) - from) * scale, x1 = (Double(node.start + node.samples) - from) * scale
            if x1 < 0 || x0 > pixels {
                index = node.end // Off screen, with everything under it.
                continue
            }
            let left = max(x0, 0), right = min(x1, pixels)
            if right - left >= 1 {
                flush(node.depth)
                blocks.append(Block(
                    x: Float(left), width: Float(right - left), depth: node.depth, node: index, merged: false
                ))
                index += 1
                continue
            }
            // Under a pixel: fold into the depth's pending block if it touches it, else start a new one.
            if var block = pending[node.depth], Double(block.x + block.width) >= left - 1 {
                block.width = Float(max(Double(block.x + block.width), right)) - block.x
                pending[node.depth] = block
            } else {
                flush(node.depth)
                pending[node.depth] = Block(
                    x: Float(left), width: Float(right - left), depth: node.depth, node: index, merged: true
                )
            }
            index = node.end
        }
        for depth in pending.indices {
            flush(depth)
        }
        return blocks
    }
}

/// A small, fast, seeded generator, so the synthetic profile is the same on every run.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
