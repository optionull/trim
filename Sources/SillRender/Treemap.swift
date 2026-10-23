import CoreGraphics

/// A squarified treemap (Bruls, Huizing and van Wijk): rectangles with areas in proportion to the values, laid out row
/// by row along the shorter side so they stay as near square as the values allow. The heap view draws types with it.
public enum Treemap {
    /// A rectangle per value, in order, filling `rect`. Values at or below zero get an empty rectangle.
    public static func squarify(_ values: [Double], in rect: CGRect) -> [CGRect] {
        var result = [CGRect](repeating: .zero, count: values.count)
        let total = values.reduce(0) { $0 + max($1, 0) }
        guard total > 0, rect.width > 0, rect.height > 0 else { return result }
        let scale = Double(rect.width * rect.height) / total
        // Largest first lays out best; the result keeps the given order.
        let order = values.indices.filter { values[$0] > 0 }.sorted { values[$0] > values[$1] }
        var free = rect
        var row: [Int] = []

        func area(_ index: Int) -> Double { values[index] * scale }

        /// The worst aspect ratio of a row laid along a side of `length`.
        func worst(_ row: [Int], _ length: Double) -> Double {
            let areas = row.map(area)
            let sum = areas.reduce(0, +)
            guard let largest = areas.max(), let smallest = areas.min(), sum > 0 else { return .infinity }
            let side = length * length
            return max(side * largest / (sum * sum), sum * sum / (side * smallest))
        }

        func place(_ row: [Int]) {
            let sum = row.map(area).reduce(0, +)
            let horizontal = free.width >= free.height
            // The row takes a strip off the free rectangle's shorter side.
            let thickness = CGFloat(sum / Double(horizontal ? free.height : free.width))
            var offset: CGFloat = 0
            for index in row {
                let length = CGFloat(area(index)) / thickness
                result[index] = horizontal
                    ? CGRect(x: free.minX, y: free.minY + offset, width: thickness, height: length)
                    : CGRect(x: free.minX + offset, y: free.minY, width: length, height: thickness)
                offset += length
            }
            free = horizontal
                ? CGRect(x: free.minX + thickness, y: free.minY, width: free.width - thickness, height: free.height)
                : CGRect(x: free.minX, y: free.minY + thickness, width: free.width, height: free.height - thickness)
        }

        for index in order {
            let length = Double(min(free.width, free.height))
            if row.isEmpty || worst(row + [index], length) <= worst(row, length) {
                row.append(index)
            } else {
                place(row)
                row = [index]
            }
        }
        if !row.isEmpty { place(row) }
        return result
    }
}
