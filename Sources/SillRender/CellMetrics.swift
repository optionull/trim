import AppKit

/// The cell size and fonts of the grid.
public struct CellMetrics: @unchecked Sendable {
    public let regular: NSFont
    public let width: CGFloat
    public let height: CGFloat
    /// From the top of a cell to where text is drawn, centring the line in the cell.
    public let textOffset: CGFloat

    /// The font by name (the system's monospaced one when it is not installed), a line `lineHeight` times its own.
    public init(font: String = "JetBrains Mono", size: CGFloat = 13, lineHeight: CGFloat = 1.2) {
        regular = NSFont(name: font, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        width = ceil(("M" as NSString).size(withAttributes: [.font: regular]).width)
        let line = ceil(regular.ascender - regular.descender + regular.leading)
        height = ceil(line * lineHeight)
        textOffset = floor((height - line) / 2)
    }

    public func font(bold: Bool, italic: Bool) -> NSFont {
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        guard !traits.isEmpty else { return regular }
        return NSFontManager.shared.convert(regular, toHaveTrait: traits)
    }
}

public extension CellMetrics {
    var cellSize: CGSize { CGSize(width: width, height: height) }
}
