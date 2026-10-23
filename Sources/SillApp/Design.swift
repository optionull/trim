import AppKit
import SillCore
import SillNvim

/// The design's tokens, sampled from the boards (docs/designs; board 1 for these). Dark first, mint accent, Inter
/// for the chrome and JetBrains Mono for text that lines up.
enum Design {
    // Surfaces
    static let editor = NSColor(hex: 0x121418)
    static let chrome = NSColor(hex: 0x181B21) // Sidebar, title bar, tab strips, status bar.
    static let rail = NSColor(hex: 0x14161B) // Activity bar.
    static let terminal = NSColor(hex: 0x0F1114)
    static let popup = NSColor(hex: 0x1F232B)
    static let popupSelected = NSColor(hex: 0x2A3140)
    static let selection = NSColor(hex: 0x232833)
    static let border = NSColor(hex: 0x2A2F38)

    // Text
    static let text = NSColor(hex: 0xD9DCE3)
    static let textMuted = NSColor(hex: 0x8B93A1)
    static let textFaint = NSColor(hex: 0x5D6572)

    // Signals
    static let accent = NSColor(hex: 0x6EE7B7)
    static let modified = NSColor(hex: 0xFFC857)
    static let error = NSColor(hex: 0xFF6B6B)

    static let radius: CGFloat = 8

    /// The chrome's typeface: Inter when installed, else the system's.
    static func ui(_ size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSFont {
        if let inter = NSFont(name: "Inter", size: size) {
            return NSFontManager.shared.convert(inter, toHaveTrait: weight >= .semibold ? .boldFontMask : [])
        }
        return .systemFont(ofSize: size, weight: weight)
    }
}

extension NSColor {
    convenience init(hex: Int) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1
        )
    }
}

extension Screen {
    /// Chunks as attributed text: each in its highlight's colour and weight, over `color` where it has none.
    func attributed(_ chunks: [StyledChunk], font: NSFont, color: NSColor = Design.text) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for chunk in chunks {
            let style = highlight(of: chunk)
            var attributes: [NSAttributedString.Key: Any] = [
                .font: style.bold ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font,
                .foregroundColor: style.foreground.map { NSColor(hex: $0) } ?? color,
            ]
            if style.underline || style.undercurl { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            result.append(NSAttributedString(string: chunk.text, attributes: attributes))
        }
        return result
    }
}
