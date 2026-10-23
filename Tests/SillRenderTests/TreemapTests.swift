import CoreGraphics
@testable import SillRender
import Testing

@Suite("the treemap")
struct TreemapTests {
    @Test("areas follow the values, the rectangle is filled, and nothing overlaps")
    func squarified() {
        let values: [Double] = [6, 6, 4, 3, 2, 2, 1]
        let rect = CGRect(x: 10, y: 20, width: 600, height: 400)
        let tiles = Treemap.squarify(values, in: rect)
        let total = values.reduce(0, +)
        for (value, tile) in zip(values, tiles) {
            #expect(abs(Double(tile.width * tile.height) - value / total * 240_000) < 1)
            #expect(rect.insetBy(dx: -0.01, dy: -0.01).contains(tile))
        }
        for i in tiles.indices {
            for j in tiles.indices where j > i {
                let overlap = tiles[i].intersection(tiles[j])
                #expect(overlap.isNull || overlap.width * overlap.height < 0.01)
            }
        }
        // Squarified: no sliver thinner than a fifth of its length here.
        #expect(tiles.allSatisfy { min($0.width, $0.height) / max($0.width, $0.height) > 0.2 })
    }

    @Test("zero and negative values get nothing; no values, no tiles")
    func edges() {
        let tiles = Treemap.squarify([5, 0, -2, 5], in: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(tiles[1] == .zero && tiles[2] == .zero)
        #expect(abs(tiles[0].width * tiles[0].height - 5000) < 0.5)
        #expect(Treemap.squarify([], in: CGRect(x: 0, y: 0, width: 10, height: 10)).isEmpty)
    }
}
