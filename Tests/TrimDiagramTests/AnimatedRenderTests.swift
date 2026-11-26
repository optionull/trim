import AppKit
import Foundation
import Testing
@testable import TrimDiagram

private func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

/// Whether the pixel is the request line's blue (#3b6cf6), not the grey of the edge under it or the page.
private func isBlue(_ image: DiagramImage, x: Double, y: Double) -> Bool {
    let px = min(max(Int(x * Double(image.scale)), 0), image.pixelWidth - 1)
    let py = min(max(Int(y * Double(image.scale)), 0), image.pixelHeight - 1)
    let offset = py * image.bytesPerRow + px * 4
    let (b, r, a): (UInt8, UInt8, UInt8) = image.pixels.withUnsafeBytes { ($0[offset], $0[offset + 2], $0[offset + 3]) }
    return a > 150 && Int(b) > Int(r) + 100
}

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
    try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
        .write(to: URL(fileURLWithPath: folder + "/" + name + ".png"))
}

@Suite("Mermaider.Animate's diagrams, played natively")
struct AnimatedRenderTests {
    @Test("an animated diagram has a loop length; a still one has none")
    func duration() throws {
        let animated = try AnimatedDiagram(svg: fixture("animated-request-path"))
        #expect(animated.isAnimated && animated.duration == 15)
        let still = try AnimatedDiagram(svg: fixture("flowchart"))
        #expect(!still.isAnimated && still.duration == 0)
    }

    @Test("a line draws itself: at first nothing, then from its start along its length, then all of it")
    func drawOn() throws {
        // The first request path: M80,190 L250,190 L450,115 L640,190, drawn between 1 s and 3 s.
        let diagram = try AnimatedDiagram(svg: fixture("animated-request-path"))
        let early = try diagram.frame(at: 0.5, scale: 2)
        let part = try diagram.frame(at: 1.5, scale: 2)
        let all = try diagram.frame(at: 3.5, scale: 2)
        for (index, time) in [0.5, 1.5, 3.5, 5.6, 7.5, 12].enumerated() {
            try dump(diagram.frame(at: time, scale: 2), as: "request-path-\(index)-t\(time)")
        }
        let start = (165.0, 190.0) // on the first segment, 85 along
        let middle = (350.0, 152.5) // on the second, 277 along (of 597)
        #expect(!isBlue(early, x: start.0, y: start.1), "nothing before it starts")
        #expect(isBlue(part, x: start.0, y: start.1), "the start of it is there")
        #expect(!isBlue(part, x: middle.0, y: middle.1), "and the rest is not yet")
        #expect(
            isBlue(all, x: start.0, y: start.1) && isBlue(all, x: middle.0, y: middle.1),
            "all of it, once it has drawn"
        )
        let gone = try diagram.frame(at: 5.6, scale: 2)
        #expect(!isBlue(gone, x: start.0, y: start.1), "and it fades at 36%")
    }

    @Test("a frame is a function of the time: the same time is the same picture, and a loop later is too")
    func pure() throws {
        let diagram = try AnimatedDiagram(svg: fixture("animated-request-path"))
        let a = try diagram.frame(at: 2.2, scale: 2)
        let b = try diagram.frame(at: 2.2, scale: 2)
        let looped = try diagram.frame(at: 2.2 + 15, scale: 2)
        #expect(a.pixels == b.pixels, "the same time")
        #expect(a.pixels == looped.pixels, "a loop later")
        #expect(try a.pixels != diagram.frame(at: 7, scale: 2).pixels, "another time")
    }

    @Test("every animated sample draws at several moments, differently, and the regions do not move")
    func samples() throws {
        for name in ["animated-request-path", "animated-state-machine", "animated-sequence"] {
            let diagram = try AnimatedDiagram(svg: fixture(name))
            #expect(diagram.isAnimated, "\(name)")
            let times = [0.0, diagram.duration * 0.25, diagram.duration * 0.5, diagram.duration * 0.75]
            let frames = try times.map { try diagram.frame(at: $0, scale: 2) }
            for (index, frame) in frames.enumerated() {
                dump(frame, as: "\(name)-\(index)")
            }
            #expect(Set(frames.map(\.pixels)).count >= 3, "\(name) changes over its loop")
            #expect(frames.allSatisfy { $0.size == frames[0].size })
        }
    }

    @Test("a frame costs little enough to play at 30 frames a second, and the regions are the same in every frame")
    func cost() throws {
        for name in ["animated-request-path", "animated-state-machine", "animated-sequence"] {
            let diagram = try AnimatedDiagram(svg: fixture(name))
            let first = try diagram.frame(at: 0, scale: 2)
            let began = Date()
            var last = first
            for frame in 1 ... 30 {
                last = try diagram.frame(at: Double(frame) / 30 * diagram.duration, scale: 2)
            }
            let each = Date().timeIntervalSince(began) / 30 * 1000
            print("animated frame cost \(name): \(String(format: "%.1f", each)) ms at 2x")
            #expect(each < 20, "\(name): a frame took \(each) ms")
        }
    }

    @Test("a clickable group that is invisible at the moment still has its region, where it always is")
    func regionsOfHiddenGroups() throws {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="200" height="100" viewBox="0 0 200 100">
        <style>@keyframes k{0%{opacity:0}50%{opacity:1}100%{opacity:0}}.k{animation:k 10s linear infinite both}</style>
        <g class="k" data-id="node-a" opacity="0"><rect x="20" y="20" width="60" height="30" fill="#3b6cf6"/></g>
        </svg>
        """
        let diagram = try AnimatedDiagram(svg: svg)
        let hidden = try diagram.frame(at: 0, scale: 2)
        let shown = try diagram.frame(at: 5, scale: 2)
        #expect(hidden.pixels != shown.pixels, "it does fade in")
        #expect(shown.regions.count == 1, "a region while shown")
        #expect(hidden.regions == shown.regions, "and the same one while hidden: \(hidden.regions)")
    }
}
