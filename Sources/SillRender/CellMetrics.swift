import AppKit

/// The cell size and fonts of the grid.
public struct CellMetrics: @unchecked Sendable {
    public let regular: NSFont
    public let width: CGFloat
    public let height: CGFloat
    /// From the top of a cell to where text is drawn, centring the line in the cell.
    public let textOffset: CGFloat

    public init(size: CGFloat = 13) {
        regular = NSFont(name: "JetBrains Mono", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        width = ceil(("M" as NSString).size(withAttributes: [.font: regular]).width)
        let line = ceil(regular.ascender - regular.descender + regular.leading)
        height = ceil(line * 1.2)
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
