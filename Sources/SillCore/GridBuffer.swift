import SillNvim

/// One cell of a grid. A double-width character fills its cell and leaves `text` empty in the one to its right.
public struct Cell: Sendable, Equatable {
    public var text: String
    public var hl: Int

    public static let blank = Cell(text: " ", hl: 0)
}

/// The cells of one nvim grid, row-major, updated by `grid_line`, `grid_scroll`, `grid_clear` and `grid_resize`.
public struct GridBuffer: Sendable, Equatable {
    public private(set) var rows = 0
    public private(set) var cols = 0
    public private(set) var cells: [Cell] = []

    public init() {}

    public subscript(row: Int, col: Int) -> Cell {
        cells[row * cols + col]
    }

    /// The text of a row, for tests and debugging.
    public func line(_ row: Int) -> String {
        guard row < rows else { return "" }
        return (0 ..< cols).map { self[row, $0].text }.joined()
    }

    mutating func resize(rows newRows: Int, cols newCols: Int) {
        guard newRows != rows || newCols != cols else { return }
        var resized = [Cell](repeating: .blank, count: newRows * newCols)
        for row in 0 ..< min(rows, newRows) {
            for col in 0 ..< min(cols, newCols) {
                resized[row * newCols + col] = cells[row * cols + col]
            }
        }
        rows = newRows
        cols = newCols
        cells = resized
    }

    mutating func clear() {
        cells = [Cell](repeating: .blank, count: rows * cols)
    }

    mutating func put(row: Int, colStart: Int, cells line: [GridCellData]) {
        guard row >= 0, row < rows else { return }
        var col = colStart
        for data in line {
            let cell = Cell(text: data.text, hl: data.hlId)
            for _ in 0 ..< max(data.repeats, 1) where col < cols {
                cells[row * cols + col] = cell
                col += 1
            }
        }
    }

    /// `grid_scroll`: the region moves up by `count` rows (down when negative); rows it uncovers keep their old
    /// cells, which nvim then redraws.
    mutating func scroll(top: Int, bottom: Int, left: Int, right: Int, count: Int) {
        guard count != 0 else { return }
        let rowsInOrder = count > 0 ? Array(top ..< bottom - count) : Array((top - count ..< bottom).reversed())
        for row in rowsInOrder {
            let source = row + count
            for col in left ..< min(right, cols) {
                cells[row * cols + col] = cells[source * cols + col]
            }
        }
    }
}
