import Foundation

/// An open file as a tab: nvim's buffer, as nvim describes it.
public struct FrameTab: Equatable, Sendable, Identifiable {
    /// nvim's buffer number.
    public var id: Int
    public var path: String
    public var modified: Bool
    /// Written to at some time since it was opened: a tab never edited is a preview, and may be closed to make room.
    public var edited: Bool
    public var current: Bool

    public init(id: Int, path: String, modified: Bool = false, edited: Bool = false, current: Bool = false) {
        self.id = id
        self.path = path
        self.modified = modified
        self.edited = edited
        self.current = current
    }

    public var name: String { (path as NSString).lastPathComponent }
    /// A tab nobody has edited: shown quieter, and the first to go when there are too many.
    public var isPreview: Bool { !edited && !modified }
}

/// Where the tabs are: a strip over the grid, under it, a list beside it, a list in the sidebar above the tree, or
/// not at all.
public enum TabsPlacement: String, CaseIterable, Sendable {
    case top, bottom, right, tree, hidden

    public var title: String {
        switch self {
        case .top: "Top"
        case .bottom: "Bottom"
        case .right: "Right"
        case .tree: "In the Sidebar"
        case .hidden: "Hidden"
        }
    }

    /// Whether the tabs are a row of tabs (over or under the grid) and not a list.
    public var isStrip: Bool { self == .top || self == .bottom }
}

public enum Tabs {
    /// What each tab says: its file's name, and where it is when another tab has the same name (the folders above it,
    /// as few as tell them apart).
    public static func labels(_ tabs: [FrameTab]) -> [Int: String] {
        var result: [Int: String] = [:]
        let byName = Dictionary(grouping: tabs, by: \.name)
        for tab in tabs {
            let same = byName[tab.name] ?? []
            guard same.count > 1 else {
                result[tab.id] = tab.name
                continue
            }
            let folders = (tab.path as NSString).deletingLastPathComponent.split(separator: "/").map(String.init)
            var shown = 1
            func tail(_ other: FrameTab, _ count: Int) -> String {
                let parts = (other.path as NSString).deletingLastPathComponent.split(separator: "/").map(String.init)
                return parts.suffix(count).joined(separator: "/")
            }
            while shown < min(folders.count, 4),
                  same.contains(where: { $0.id != tab.id && tail($0, shown) == tail(tab, shown) })
            {
                shown += 1
            }
            let place = tail(tab, shown)
            result[tab.id] = place.isEmpty ? tab.name : "\(tab.name) · \(place)"
        }
        return result
    }

    /// The tab `step` places from the current one, round again; the first when none is current.
    public static func neighbor(of current: Int?, in tabs: [FrameTab], by step: Int) -> Int? {
        guard !tabs.isEmpty else { return nil }
        guard let current, let at = tabs.firstIndex(where: { $0.id == current }) else { return tabs[0].id }
        return tabs[((at + step) % tabs.count + tabs.count) % tabs.count].id
    }

    /// The tab at a place (1 to 9, as ⌘1 to ⌘9 say it; 9 is the last, as in browsers).
    public static func numbered(_ number: Int, in tabs: [FrameTab]) -> Int? {
        guard !tabs.isEmpty, number >= 1 else { return nil }
        if number == 9 { return tabs.last?.id }
        return number <= tabs.count ? tabs[number - 1].id : nil
    }
}
