import Foundation

/// The colours the sidebar draws in, made from the editor's own: the sidebar is the editor's background (the same hue,
/// a shade darker, so the two read as one colour scheme), the text is its foreground, and what is quieter is the
/// foreground fading into the background. Colours are 0xRRGGBB, as nvim reports them.
public struct TreePalette: Equatable, Sendable {
    public var background: Int
    public var foreground: Int
    public var sidebar: Int
    public var muted: Int
    public var faint: Int
    /// The colour of what is selected, from the colour scheme (nvim's `Visual`) when it says one: the same in the tree
    /// and the tabs, so a selection is one colour whichever pane it is in.
    public var selection: Int
    /// The same where the pane does not have the keyboard: quieter, toward the sidebar's own colour.
    public var selectionDim: Int
    public var isDark: Bool

    /// How much of black a dark editor's background gets for the sidebar, and a light one's.
    public static let darkShade = 0.28
    public static let lightShade = 0.05

    public init(background: Int, foreground: Int, selection: Int? = nil) {
        self.background = background
        self.foreground = foreground
        isDark = Self.luminance(background) < 0.5
        sidebar = Self.mix(background, 0x000000, isDark ? Self.darkShade : Self.lightShade)
        muted = Self.mix(foreground, background, 0.45)
        faint = Self.mix(foreground, background, 0.65)
        // Without a word from the colour scheme: the foreground faintly over the background.
        let chosen = selection ?? Self.mix(background, foreground, 0.2)
        self.selection = chosen
        selectionDim = Self.mix(sidebar, chosen, 0.55)
    }

    /// `a` toward `b` by `amount` (0 is `a`, 1 is `b`), channel by channel.
    public static func mix(_ a: Int, _ b: Int, _ amount: Double) -> Int {
        func channel(_ shift: Int) -> Int {
            let from = Double((a >> shift) & 0xFF), to = Double((b >> shift) & 0xFF)
            return min(max(Int((from + (to - from) * amount).rounded()), 0), 255)
        }
        return channel(16) << 16 | channel(8) << 8 | channel(0)
    }

    /// 0 (black) to 1 (white), by the usual weights of the three channels.
    public static func luminance(_ rgb: Int) -> Double {
        let red = Double((rgb >> 16) & 0xFF), green = Double((rgb >> 8) & 0xFF), blue = Double(rgb & 0xFF)
        return (0.2126 * red + 0.7152 * green + 0.0722 * blue) / 255
    }
}
