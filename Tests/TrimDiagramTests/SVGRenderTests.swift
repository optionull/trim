import AppKit
import Foundation
import Testing
@testable import TrimDiagram

private func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

/// The pixel at a point (in points from the top left) as 0xAARRGGBB, straight alpha.
private func pixel(_ image: DiagramImage, x: Double, y: Double) -> (a: Int, r: Int, g: Int, b: Int) {
    let px = min(max(Int(x * Double(image.scale)), 0), image.pixelWidth - 1)
    let py = min(max(Int(y * Double(image.scale)), 0), image.pixelHeight - 1)
    let offset = py * image.bytesPerRow + px * 4
    let (b, g, r, a) = image.pixels.withUnsafeBytes { ($0[offset], $0[offset + 1], $0[offset + 2], $0[offset + 3]) }
    guard a > 0 else { return (0, 0, 0, 0) }
    func straight(_ c: UInt8) -> Int { min(255, Int((Double(c) * 255 / Double(a)).rounded())) }
    return (Int(a), straight(r), straight(g), straight(b))
}

/// Where the pictures go when TRIM_DIAGRAM_OUT names a folder: to look at.
private func dump(_ image: DiagramImage, as name: String) {
    guard let folder = ProcessInfo.processInfo.environment["TRIM_DIAGRAM_OUT"] else { return }
    try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    let provider = CGDataProvider(data: image.pixels as CFData)!
    let cg = CGImage(
        width: image.pixelWidth, height: image.pixelHeight, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: image.bytesPerRow,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little
            .rawValue),
        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
    )!
    let rep = NSBitmapImageRep(cgImage: cg)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder + "/" + name + ".png"))
}

@Suite("SVG renderer on Mermaider's own output")
struct SVGRenderTests {
    static let names = ["flowchart", "sequence", "classdiagram", "state", "er", "pie", "gantt"]

    @Test(
        "every diagram type Mermaider made draws, at the size its SVG says, with ink and a transparent page",
        arguments: names
    )
    func draws(name: String) throws {
        let svg = try fixture(name)
        let image = try SVGRender.image(svg: svg, scale: 2)
        dump(image, as: name)
        let box = try #require(svg.firstMatch(of: /viewBox="[-\d.]+ [-\d.]+ ([\d.]+) ([\d.]+)"/))
        #expect(abs(image.size.width - Double(box.1)!) < 0.01 && abs(image.size.height - Double(box.2)!) < 0.01)
        #expect(image.pixelWidth == Int((image.size.width * 2).rounded(.up)))
        var inked = 0
        for y in stride(from: 0, to: image.pixelHeight, by: 3) {
            for x in stride(from: 0, to: image.pixelWidth, by: 3)
                where pixel(image, x: Double(x) / 2, y: Double(y) / 2).a > 0
            {
                inked += 1
            }
        }
        #expect(inked > 200, "\(name) is drawn: \(inked) sampled pixels of ink")
        #expect(pixel(image, x: 0.5, y: 0.5).a == 0, "the page is transparent")
    }

    @Test("a flowchart's nodes are regions by data-id, in the places the layout put them")
    func flowchartRegions() throws {
        let image = try SVGRender.image(svg: fixture("flowchart"), scale: 2)
        let byID = Dictionary(uniqueKeysWithValues: image.regions.filter { $0.kind == "node" }.map { ($0.id, $0.rect) })
        let a = try #require(byID["A"]), b = try #require(byID["B"]), c = try #require(byID["C"])
        #expect(a.midY < b.midY && b.midY < c.midY, "top to bottom: Start, Ok?, Done")
        #expect(a.width > 20 && a.height > 20 && a.maxX <= image.size.width)
        #expect(image.regions.contains { $0.id == "D" }, "a node inside a subgraph is one too")
        // The centre of a node is ink (its label and fill), not the page.
        #expect(pixel(image, x: a.midX, y: a.midY).a > 0)
    }

    @Test("shapes are filled with the theme's colours: color-mix and var() resolved, gradients drawn")
    func colours() throws {
        let image = try SVGRender.image(svg: fixture("flowchart"), scale: 2)
        let a = try #require(image.regions.first { $0.id == "A" }).rect
        // Inside the box, away from its label: a tinted fill, not black, not the foreground, a little off the page.
        let inside = pixel(image, x: a.minX + 4, y: a.midY)
        #expect(inside.a > 200 && inside.r + inside.g + inside.b > 20, "a fill: \(inside)")
        let top = pixel(image, x: a.midX, y: a.minY + 3), bottom = pixel(image, x: a.midX, y: a.maxY - 3)
        #expect(top.r != bottom.r || top.g != bottom.g || top.b != bottom.b, "the gradient changes down the node")
    }

    @Test("a message ends in an arrowhead: at its end the ink is much taller than the line")
    func markers() throws {
        let svg = try fixture("sequence")
        let image = try SVGRender.image(svg: svg, scale: 2)
        // The first message: a line with a marker-end; its (x2, y2) is where the head's tip is.
        let match = try #require(svg
            .firstMatch(of: /<line x1="[\d.]+" y1="[\d.]+" x2="([\d.]+)" y2="([\d.]+)"[^>]*marker-end/))
        let tipX = try #require(Double(match.1)), tipY = try #require(Double(match.2))
        func inkHeight(at x: Double) -> Int {
            var count = 0
            for dy in stride(from: -12.0, through: 12.0, by: 0.5)
                where pixel(image, x: x, y: tipY + dy).a > 60
            {
                count += 1
            }
            return count
        }
        let atHead = inkHeight(at: tipX - 8), onLine = inkHeight(at: tipX - 16)
        #expect(onLine <= 6, "the line alone is thin: \(onLine) samples")
        #expect(atHead >= 10, "the head is tall: \(atHead) samples")
    }

    @Test("text is drawn: a label's ink is inside its node")
    func text() throws {
        let image = try SVGRender.image(svg: fixture("flowchart"), scale: 2)
        let a = try #require(image.regions.first { $0.id == "A" }).rect
        var light = 0
        for y in stride(from: a.minY, to: a.maxY, by: 0.5) {
            for x in stride(from: a.minX + 6, to: a.maxX - 6, by: 0.5) {
                let p = pixel(image, x: x, y: y)
                if p.a > 200, p.r > 150, p.g > 150 { light += 1 }
            }
        }
        #expect(light > 20, "the label's letters in the foreground colour: \(light) samples")
    }

    @Test("a diagram wider than the room is drawn smaller, whole")
    func fitsWidth() throws {
        let svg = try fixture("sequence")
        let natural = try SVGRender.image(svg: svg, scale: 2)
        let fitted = try SVGRender.image(svg: svg, scale: 2, maxWidth: natural.size.width / 2)
        #expect(abs(fitted.size.width - natural.size.width / 2) < 0.5 &&
            abs(fitted.size.height - natural.size.height / 2) < 0.5)
        let region = try #require(fitted.regions.first)
        #expect(region.rect.maxX <= fitted.size.width + 1, "the regions are in the smaller size")
    }

    @Test("what is not SVG is an error, not a crash")
    func notSVG() {
        #expect(throws: (any Error).self) { try SVGRender.image(svg: "<html></html>", scale: 2) }
        #expect(throws: (any Error).self) { try SVGRender.image(svg: "nothing", scale: 2) }
        #expect(throws: (any Error).self) { try SVGRender.image(svg: "<svg width=\"0\" height=\"0\"/>", scale: 2) }
    }
}
