// Adapted from Veil (https://github.com/0x1b2c/Veil, MIT, a29c3d0, GlyphAtlas.swift); see THIRD_PARTY_NOTICES.md.
// Changed for sill: a second, BGRA atlas for colour glyphs (emoji); regions are in pixels, so instances built before
// the atlas grows stay valid; one atlas per font, with a generation that changes when it is cleared.
import AppKit
import CoreText
import Metal
import TrimDiagram

/// Rasterised glyphs in two textures: coverage masks (r8, coloured by the shader) and colour glyphs (BGRA, drawn as
/// they are). Used on one thread only: the render thread, or a test.
final class GlyphAtlas {
    struct Region: Equatable {
        /// Top-left corner and size in the atlas texture, in pixels.
        var x: Float
        var y: Float
        var width: Float
        var height: Float
        /// In the colour atlas, drawn without the foreground colour.
        var colored: Bool
    }

    private struct Key: Hashable {
        let text: String
        let bold: Bool
        let italic: Bool
        let cellCount: Int
        /// The size in percent (100 ordinarily): a scaled row's glyph is drawn from a font that many times the size.
        let factor: Int
    }

    let device: MTLDevice
    let font: NSFont
    /// Cell size in points.
    let cellSize: CGSize
    let scale: CGFloat
    private(set) var coverage: MTLTexture
    private(set) var color: MTLTexture
    /// Changes when the atlas is cleared; anything holding regions from before must drop them.
    private(set) var generation = 0
    private var regions: [Key: Region] = [:]
    /// Diagrams, by id and the serial of the picture the id then held.
    private var imageRegions: [Int: (serial: Int, region: Region)] = [:]
    private var coveragePacker: Packer
    private var colorPacker: Packer
    private let maxHeight = 8192

    init(device: MTLDevice, font: NSFont, cellSize: CGSize, scale: CGFloat, size: Int = 2048) {
        self.device = device
        self.font = font
        self.cellSize = cellSize
        self.scale = scale
        coverage = Self.texture(device, .r8Unorm, width: size, height: size)
        color = Self.texture(device, .bgra8Unorm, width: size, height: size)
        coveragePacker = Packer(width: size, height: size)
        colorPacker = Packer(width: size, height: size)
        FontFallback.probe()
    }

    var regionCount: Int { regions.count }

    func region(text: String, bold: Bool, italic: Bool, cellCount: Int = 1, factor: CGFloat = 1) -> Region {
        let key = Key(
            text: text,
            bold: bold,
            italic: italic,
            cellCount: cellCount,
            factor: Int((factor * 100).rounded())
        )
        if let existing = regions[key] { return existing }
        let size = font.pointSize * factor
        let cell = CGSize(width: cellSize.width * factor, height: cellSize.height * factor)

        var drawFont = font
        if factor != 1 { drawFont = NSFont(descriptor: font.fontDescriptor, size: size) ?? font }
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        if !traits.isEmpty {
            drawFont = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: size) ?? font
        }
        let resolved = FontFallback.resolveFont(drawFont as CTFont, for: text) as NSFont
        let colored = CTFontGetSymbolicTraits(resolved as CTFont).contains(.traitColorGlyphs)

        // Single-cell glyphs may spill past their cell (ink wider than the advance: italics, Nerd Font icons); wide
        // ones (CJK, ligatures) are laid out at their advance; box drawing is exactly the cells.
        let allocated = cell.width * CGFloat(cellCount)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: resolved]))
        let scalar = text.unicodeScalars.count == 1 ? text.unicodeScalars.first?.value : nil
        let boxDrawn = scalar.map { (0x2500 ... 0x259F).contains($0) } ?? false
        let width: CGFloat
        if boxDrawn {
            width = allocated
        } else if cellCount >= 2 {
            let advance = CTLineGetBoundsWithOptions(line, [])
            width = max(advance.maxX, allocated)
        } else {
            let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            width = max(allocated, ink.maxX)
        }
        let pixelWidth = Int(ceil(width * scale)), pixelHeight = Int(ceil(cell.height * scale))

        guard let origin = place(width: pixelWidth, height: pixelHeight, colored: colored) else {
            // Full at the largest size: start over. Everything cached against the old atlas is dropped by generation.
            clear()
            return region(text: text, bold: bold, italic: italic, cellCount: cellCount, factor: factor)
        }
        let bytes = rasterise(
            text: text, font: resolved, scalar: boxDrawn ? scalar : nil, width: pixelWidth, height: pixelHeight,
            drawWidth: width, colored: colored, cell: cell
        )
        let texture = colored ? color : coverage
        let bytesPerRow = pixelWidth * (colored ? 4 : 1)
        bytes.withUnsafeBytes { pointer in
            texture.replace(
                region: MTLRegionMake2D(origin.x, origin.y, pixelWidth, pixelHeight), mipmapLevel: 0,
                withBytes: pointer.baseAddress!, bytesPerRow: bytesPerRow
            )
        }
        let region = Region(
            x: Float(origin.x), y: Float(origin.y), width: Float(pixelWidth), height: Float(pixelHeight),
            colored: colored
        )
        regions[key] = region
        return region
    }

    /// A diagram in the colour atlas, uploaded the first time it is asked for; nil when it is wider or taller than the
    /// atlas can hold.
    func imageRegion(id: Int, entry: DiagramStore.Entry) -> Region? {
        if let known = imageRegions[id], known.serial == entry.serial { return known.region }
        let image = entry.image
        guard image.pixelWidth <= color.width, image.pixelHeight <= maxHeight,
              let origin = place(width: image.pixelWidth, height: image.pixelHeight, colored: true) else { return nil }
        image.pixels.withUnsafeBytes { pointer in
            color.replace(
                region: MTLRegionMake2D(origin.x, origin.y, image.pixelWidth, image.pixelHeight), mipmapLevel: 0,
                withBytes: pointer.baseAddress!, bytesPerRow: image.bytesPerRow
            )
        }
        let region = Region(
            x: Float(origin.x), y: Float(origin.y), width: Float(image.pixelWidth), height: Float(image.pixelHeight),
            colored: true
        )
        imageRegions[id] = (entry.serial, region)
        return region
    }

    /// Shapes a run, with ligatures.
    func shape(_ text: String, bold: Bool, italic: Bool) -> [ShapedGlyph] {
        shapeRunText(text, font: font, bold: bold, italic: italic)
    }

    func clear() {
        regions.removeAll()
        imageRegions.removeAll()
        coveragePacker = Packer(width: coverage.width, height: coverage.height)
        colorPacker = Packer(width: color.width, height: color.height)
        generation += 1
    }

    // MARK: Packing

    /// Shelf packing: glyphs left to right in rows as tall as the tallest glyph in them.
    private struct Packer {
        var width: Int
        var height: Int
        var x = 1 // Pixel (0, 0) stays empty.
        var y = 0
        var rowHeight = 0

        mutating func place(width w: Int, height h: Int) -> (x: Int, y: Int)? {
            if x + w > width {
                x = 0
                y += rowHeight
                rowHeight = 0
            }
            guard y + h <= height, w <= width else { return nil }
            defer {
                x += w
                rowHeight = max(rowHeight, h)
            }
            return (x, y)
        }
    }

    private func place(width: Int, height: Int, colored: Bool) -> (x: Int, y: Int)? {
        while true {
            let placed = colored ? colorPacker.place(width: width, height: height) :
                coveragePacker.place(width: width, height: height)
            if let placed { return placed }
            let texture = colored ? color : coverage
            guard texture.height < maxHeight else { return nil }
            grow(colored: colored)
        }
    }

    /// Doubles a texture's height, keeping what is in it. Regions are in pixels, so they stay right.
    private func grow(colored: Bool) {
        let old = colored ? color : coverage
        let grown = Self.texture(device, old.pixelFormat, width: old.width, height: min(old.height * 2, maxHeight))
        if let queue = device.makeCommandQueue(), let buffer = queue.makeCommandBuffer(),
           let blit = buffer.makeBlitCommandEncoder()
        {
            blit.copy(
                from: old, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: old.width, height: old.height, depth: 1), to: grown, destinationSlice: 0,
                destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blit.endEncoding()
            buffer.commit()
            buffer.waitUntilCompleted()
        }
        if colored {
            color = grown
            colorPacker.height = grown.height
        } else {
            coverage = grown
            coveragePacker.height = grown.height
        }
    }

    private static func texture(_ device: MTLDevice, _ format: MTLPixelFormat, width: Int, height: Int) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)!
    }

    // MARK: Rasterising

    /// Draws a glyph into bytes for its texture: a coverage mask (white text in an alpha-only context, as Ghostty's
    /// grayscale path does) or premultiplied BGRA for colour glyphs.
    private func rasterise(
        text: String, font: NSFont, scalar: UInt32?, width: Int, height: Int, drawWidth: CGFloat, colored: Bool,
        cell: CGSize
    ) -> [UInt8] {
        let bytesPerPixel = colored ? 4 : 1
        var bytes = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        let space = colored ? CGColorSpace(name: CGColorSpace.sRGB)! : CGColorSpace(name: CGColorSpace.linearGray)!
        let info = colored ? CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue :
            CGImageAlphaInfo.alphaOnly.rawValue
        bytes.withUnsafeMutableBytes { pointer in
            guard let context = CGContext(
                data: pointer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * bytesPerPixel, space: space, bitmapInfo: info
            ) else { return }
            context.setAllowsFontSmoothing(true)
            context.setShouldSmoothFonts(false)
            context.setAllowsFontSubpixelPositioning(true)
            context.setShouldSubpixelPositionFonts(true)
            context.setAllowsFontSubpixelQuantization(false)
            context.setShouldSubpixelQuantizeFonts(false)
            context.scaleBy(x: scale, y: scale)

            if let scalar, BoxDrawing.render(
                scalar, ctx: context, cellWidth: drawWidth, cellHeight: cell.height, font: font
            ) {
                return
            }
            // The baseline sits so the font's line is centred in the (taller) cell.
            let descent = CTFontGetDescent(font), leading = CTFontGetLeading(font)
            let natural = CTFontGetAscent(font) + descent + leading
            let baseline = descent + leading + (cell.height - natural) / 2
            let attributed = NSAttributedString(
                string: text, attributes: [.font: font, .foregroundColor: NSColor.white]
            )
            context.textPosition = CGPoint(x: 0, y: baseline)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        return bytes
    }
}
