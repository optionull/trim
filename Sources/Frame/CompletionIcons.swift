import AppKit
import SillEditor

/// An icon for each kind of completion (the Nerd Font ships with the app), each in its own colour: what can be called,
/// what holds a value, what is a type, what is only text.
enum CompletionIcons {
    static var style: CompletionStyle {
        CompletionStyle(iconFont: NerdFont.font(size: 13) ?? .systemFont(ofSize: 13)) { icon(for: $0) }
    }

    static func icon(for kind: String) -> (glyph: String, color: NSColor)? {
        let key = kind.lowercased()
        // Codicons, as the editors that made these icons familiar have them.
        let method = "\u{ea8c}", field = "\u{eb5f}", type = "\u{eb5b}"
        let table: [String: (String, NSColor)] = [
            "method": (method, .systemPurple), "function": (method, .systemPurple),
            "constructor": (method, .systemOrange),
            "field": (field, .systemCyan), "property": ("\u{eb65}", .systemCyan),
            "variable": ("\u{ea88}", .systemBlue), "constant": ("\u{eb5d}", .systemOrange),
            "class": (type, .systemYellow), "struct": ("\u{ea91}", .systemYellow),
            "interface": ("\u{eb61}", .systemTeal), "module": ("\u{ea8b}", .systemGreen),
            "enum": ("\u{ea95}", .systemOrange), "enummember": ("\u{ea95}", .systemOrange),
            "keyword": ("\u{eb62}", .systemPink), "snippet": ("\u{eb66}", .systemGreen),
            "typeparameter": ("\u{ea92}", .systemTeal), "event": ("\u{ea86}", .systemRed),
            "operator": ("\u{eb64}", .systemGray), "unit": ("\u{ea96}", .systemGray),
            "value": ("\u{ea95}", .systemBlue), "color": ("\u{eb5c}", .systemPink),
            "file": ("\u{ea7b}", .systemGray), "folder": ("\u{ea83}", .systemGray),
            "reference": ("\u{ea94}", .systemGray), "text": ("\u{ea93}", .systemGray),
        ]
        guard let (glyph, color) = table[key] else { return kind.isEmpty ? nil : ("\u{ea93}", .systemGray) }
        return (glyph, color)
    }
}
