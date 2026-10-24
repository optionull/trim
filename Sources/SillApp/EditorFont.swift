import AppKit
import SillCore
import SillRender

/// The grid's font: the settings' font, size and line height, with ⌘+ and ⌘- on top for this session. Every view
/// that draws in the grid's font reads it here, so a change reaches them all; the editor then makes its renderer again
/// and tells nvim the new grid size.
@MainActor
enum EditorFont {
    private(set) static var metrics = CellMetrics()
    /// Points added by ⌘+ and ⌘- (not written to the settings; ⌘0 drops it).
    private(set) static var zoom: Double = 0
    private static var settings = SillSettings.default
    /// Called when the metrics changed.
    static var onChange: (() -> Void)?

    static var size: Double { min(max(settings.size + zoom, 6), 72) }

    /// The settings' font; true when that changed the metrics.
    @discardableResult
    static func load(_ settings: SillSettings) -> Bool {
        self.settings = settings
        return remake()
    }

    /// ⌘+ (1), ⌘- (-1), ⌘0 (0: back to the settings' size).
    static func zoom(_ step: Int) {
        zoom = step == 0 ? 0 : min(max(zoom + Double(step), 6 - settings.size), 72 - settings.size)
        remake()
    }

    @discardableResult
    private static func remake() -> Bool {
        let made = CellMetrics(font: settings.font, size: CGFloat(size), lineHeight: CGFloat(settings.lineHeight))
        guard made.regular != metrics.regular || made.cellSize != metrics.cellSize else { return false }
        metrics = made
        onChange?()
        return true
    }
}
