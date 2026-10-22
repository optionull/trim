import AppKit

/// Mouse input in nvim's terms.
public enum Mouse {
    /// The modifiers `nvim_input_mouse` takes: `C`, `S`, `A`, `D` run together.
    public static func modifiers(_ flags: NSEvent.ModifierFlags) -> String {
        var result = ""
        if flags.contains(.control) { result += "C" }
        if flags.contains(.shift) { result += "S" }
        if flags.contains(.option) { result += "A" }
        if flags.contains(.command) { result += "D" }
        return result
    }
}

/// Turns scroll deltas into wheel steps, one per line scrolled. Trackpads report pixels a little at a time; they add
/// up until they make a line, and what is left over carries to the next event.
public struct ScrollAccumulator {
    /// The height of a line (a cell) and the width of a column, in points.
    public var lineHeight: CGFloat
    public var columnWidth: CGFloat
    private var vertical: CGFloat = 0
    private var horizontal: CGFloat = 0

    public init(lineHeight: CGFloat, columnWidth: CGFloat) {
        self.lineHeight = lineHeight
        self.columnWidth = columnWidth
    }

    /// The wheel actions for a scroll: `up`, `down`, `left` or `right`, once per line or column. `precise` deltas are
    /// in points (trackpads); others in lines (mouse wheels), each of which scrolls one line.
    public mutating func steps(deltaX: CGFloat, deltaY: CGFloat, precise: Bool) -> [String] {
        if !precise {
            vertical = 0
            horizontal = 0
            let rows = Int(deltaY.rounded(.awayFromZero)), cols = Int(deltaX.rounded(.awayFromZero))
            return Array(repeating: rows > 0 ? "up" : "down", count: abs(rows)) +
                Array(repeating: cols > 0 ? "left" : "right", count: abs(cols))
        }
        vertical += deltaY
        horizontal += deltaX
        let rows = Int(vertical / lineHeight), cols = Int(horizontal / columnWidth)
        vertical -= CGFloat(rows) * lineHeight
        horizontal -= CGFloat(cols) * columnWidth
        return Array(repeating: rows > 0 ? "up" : "down", count: abs(rows)) +
            Array(repeating: cols > 0 ? "left" : "right", count: abs(cols))
    }

    /// Forgets partial lines, as when a gesture ends.
    public mutating func reset() {
        vertical = 0
        horizontal = 0
    }
}
