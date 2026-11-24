import Foundation

/// The diagrams drawn, by id, for the grid renderer to take its rows from. A diagram sits in the editor as rows that
/// each hold
/// one private-use character (plane 16: no icon font is there) naming the diagram and which slice of it that row shows,
/// so
/// the picture scrolls, slides and is clipped as the rows are.
public final class DiagramStore: @unchecked Sendable {
    public static let shared = DiagramStore()

    /// The first of the characters: `base + id * slices + slice`.
    public static let base: UInt32 = 0x100000
    /// How many rows a diagram can have.
    public static let slices = 64
    /// How many diagrams are kept: ids 1 ... capacity (the oldest is replaced after that).
    public static let capacity = 1000

    public struct Entry: Sendable {
        public var image: DiagramImage
        /// Changes when the id is given to another picture, so what was cached for the old one is dropped.
        public var serial: Int
    }

    private let lock = NSLock()
    private var entries: [Int: Entry] = [:]
    private var ids: [String: Int] = [:]
    private var order: [Int] = []
    private var nextSerial = 1

    public init() {}

    /// The id of the diagram made from `key` (its source, colours, width and scale): the one it already has, or a new
    /// one.
    public func register(_ image: DiagramImage, key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        if let id = ids[key], entries[id] != nil { return id }
        let id: Int
        if order.count < Self.capacity {
            id = order.count + 1
            order.append(id)
        } else {
            id = order.removeFirst()
            order.append(id)
            ids = ids.filter { $0.value != id }
        }
        entries[id] = Entry(image: image, serial: nextSerial)
        nextSerial += 1
        ids[key] = id
        return id
    }

    /// The id for `key` when that diagram is already drawn.
    public func id(forKey key: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return ids[key].flatMap { entries[$0] != nil ? $0 : nil }
    }

    public func entry(_ id: Int) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[id]
    }

    /// The character for slice `slice` of diagram `id`.
    public static func character(id: Int, slice: Int) -> Character? {
        guard id >= 1, id <= capacity, slice >= 0, slice < slices,
              let scalar = Unicode.Scalar(base + UInt32(id * slices + slice)) else { return nil }
        return Character(scalar)
    }

    /// What a cell's text names, when it is one of these characters.
    public static func decode(_ text: String) -> (id: Int, slice: Int)? {
        guard text.unicodeScalars.count == 1, let value = text.unicodeScalars.first?.value,
              value >= base else { return nil }
        let offset = Int(value - base)
        let id = offset / slices
        guard id >= 1, id <= capacity else { return nil }
        return (id, offset % slices)
    }
}
