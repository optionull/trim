@testable import SillRender
import Testing

@Suite("flame graph level of detail")
struct FlameGraphTests {
    private let profile = FlameGraph.synthetic(samples: 200_000)

    @Test("the synthetic profile is a well-formed call tree")
    func wellFormed() {
        #expect(profile.totalSamples == 200_000)
        for (index, node) in profile.nodes.enumerated() {
            // Children start inside their parent and end before it does.
            var child = index + 1
            var covered = 0
            while child < node.end {
                let next = profile.nodes[child]
                #expect(next.depth == node.depth + 1)
                #expect(next.start >= node.start && next.start + next.samples <= node.start + node.samples)
                covered += next.samples
                child = next.end
            }
            #expect(covered <= node.samples)
        }
    }

    @Test("a call tree in preorder: each frame starts where its previous sibling ended")
    func preorder() {
        // root 10: a 6 (c 4), b 3; then a second root's worth is not possible, so the tree ends.
        let graph = FlameGraph(preorder: [(0, 0, 10), (1, 1, 6), (2, 2, 4), (3, 1, 3)])
        #expect(graph.nodes.map(\.start) == [0, 0, 0, 6])
        #expect(graph.nodes.map(\.end) == [4, 3, 3, 4])
        #expect(graph.nodes.map(\.name) == [0, 1, 2, 3])
        #expect(graph.totalSamples == 10)
        #expect(graph.maxDepth == 2)
    }

    @Test("zoomed out, blocks stay near the pixel count and cover the root")
    func zoomedOut() {
        let blocks = profile.blocks(from: 0, to: Double(profile.totalSamples), pixels: 1000)
        #expect(blocks.count < 1000 * (profile.maxDepth + 1))
        let root = blocks.filter { $0.depth == 0 }
        #expect(root.count == 1 && root[0].x == 0 && root[0].width == 1000)
        // Nothing narrower than a pixel is drawn.
        #expect(blocks.allSatisfy { $0.width >= 1 })
    }

    @Test("blocks at one depth never overlap")
    func noOverlap() {
        let blocks = profile.blocks(from: 0, to: Double(profile.totalSamples), pixels: 800)
        for depth in 0 ... profile.maxDepth {
            let row = blocks.filter { $0.depth == depth }.sorted { $0.x < $1.x }
            for (left, right) in zip(row, row.dropFirst()) {
                #expect(left.x + left.width <= right.x + 1, "depth \(depth)")
            }
        }
    }

    @Test("zooming in shows frames that were merged before")
    func zoomIn() throws {
        let all = profile.blocks(from: 0, to: Double(profile.totalSamples), pixels: 1000)
        let deep = try #require(profile.nodes.first { $0.depth == 12 && $0.samples < 50 })
        #expect(!all.contains { !$0.merged && profile.nodes[$0.node].start == deep.start && $0.depth == 12 })
        let zoomed = profile.blocks(
            from: Double(deep.start), to: Double(deep.start + deep.samples), pixels: 1000
        )
        #expect(zoomed.contains { !$0.merged && $0.depth == 12 && $0.width > 900 })
    }

    @Test("off-screen frames are skipped")
    func offScreen() {
        let half = Double(profile.totalSamples) / 2
        let blocks = profile.blocks(from: half, to: Double(profile.totalSamples), pixels: 500)
        #expect(blocks.allSatisfy { $0.x >= 0 && $0.x + $0.width <= 501 })
    }

    @Test("zoomed in, frames off screen are skipped with everything under them")
    func pruning() {
        var everything = 0, zoomed = 0
        _ = profile.blocks(from: 0, to: Double(profile.totalSamples), pixels: 1_000_000, visited: &everything)
        let start = Double(profile.totalSamples) * 0.4
        _ = profile.blocks(from: start, to: start + 500, pixels: 1000, visited: &zoomed)
        #expect(everything == profile.nodes.count, "a million pixels: every frame is wide enough to visit")
        #expect(zoomed * 50 < profile.nodes.count, "\(zoomed) of \(profile.nodes.count) visited")
    }
}
