import AppKit
import SillCore
import SillRender

/// The grid's font: the settings' font, size and line height, with ⌘+ and ⌘- on top for this session. Every view
/// that draws in the grid's font reads it here, so a change reaches them all; the editor then makes its renderer again
/// and tells nvim the new grid size.
@MainActor
package enum EditorFont {
    package private(set) static var metrics = CellMetrics()
    /// Points added by ⌘+ and ⌘- (not written to the settings; ⌘0 drops it).
    package private(set) static var zoom: Double = 0
    private static var settings = SillSettings.default
    /// Called when the metrics changed.
    package static var onChange: (() -> Void)?

    package static var size: Double { min(max(settings.size + zoom, 6), 72) }

    /// The grid's font at another size, bold from semibold up: code and data drawn outside the grid (a notebook, a
    /// profile's frames, a package's versions) in the same face as the code.
    package static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        // Made once a size and weight, for the font the grid has now.
        let key = "\(metrics.regular.fontName) \(size) \(weight >= .semibold)"
        if let font = fonts[key] { return font }
        let base = NSFont(descriptor: metrics.regular.fontDescriptor, size: size) ??
            NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        let font = weight >= .semibold ? NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask) : base
        fonts[key] = font
        return font
    }

    private static var fonts: [String: NSFont] = [:]

    /// The settings' font; true when that changed the metrics.
    @discardableResult
    package static func load(_ settings: SillSettings) -> Bool {
        self.settings = settings
        return remake()
    }

    /// ⌘+ (1), ⌘- (-1), ⌘0 (0: back to the settings' size).
    package static func zoom(_ step: Int) {
        zoom = step == 0 ? 0 : min(max(zoom + Double(step), 6 - settings.size), 72 - settings.size)
        remake()
    }

    @discardableResult
    private static func remake() -> Bool {
        let made = CellMetrics(font: settings.font, size: CGFloat(size), lineHeight: CGFloat(settings.lineHeight))
        guard made.regular != metrics.regular || made.cellSize != metrics.cellSize else { return false }
        metrics = made
        terminalFont()
        onChange?()
        return true
    }

    /// Terminal panes in the grid's family, a point smaller (the grid's 13 beside a pane's 12, as panes always were):
    /// the app that has terminal panes hands this to them.
    package static var onTerminalFont: ((_ family: String, _ size: Double) -> Void)?

    private static func terminalFont() {
        onTerminalFont?(settings.font, max(size - 1, 6))
    }
}
