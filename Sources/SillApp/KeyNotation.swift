// Lifted from Veil (https://github.com/0x1b2c/Veil, MIT, a29c3d0, KeyUtils and Shortcut); see THIRD_PARTY_NOTICES.md.
import AppKit

/// AppKit key events in nvim's key notation (`<C-w>`, `<lt>`, `<S-Tab>`).
enum KeyNotation {
    /// The event as nvim keys, or nil when it has none (a lone modifier).
    static func keys(for event: NSEvent) -> String? {
        let modifiers = event.modifierFlags.intersection([.control, .option, .command])
        let characters = modifiers.isEmpty ? event.characters : event.charactersIgnoringModifiers
        guard let characters, !characters.isEmpty else { return nil }
        // Typed text goes as typed: Shift has already made `!` of `1`. Only `<` needs escaping.
        if modifiers.isEmpty, let scalar = characters.unicodeScalars.first, !isSpecial(scalar) {
            return characters.replacingOccurrences(of: "<", with: "<lt>")
        }
        let keys = nvimKey(characters: characters, modifiers: event.modifierFlags)
        return keys.isEmpty ? nil : keys
    }

    static func nvimKey(characters: String, modifiers: NSEvent.ModifierFlags) -> String {
        // Cocoa's `charactersIgnoringModifiers` applies Shift to punctuation, so Shift+] arrives as `}`. With Shift in
        // the set, go back to the unshifted form so the key matches how mappings are written (`<S-D-]>`).
        let resolved: String = {
            guard modifiers.contains(.shift), characters.count == 1, let first = characters.first,
                  let unshifted = unshiftedPunctuation[first]
            else { return characters }
            return String(unshifted)
        }()

        guard let scalar = resolved.unicodeScalars.first else { return "" }
        let code = Int(scalar.value)

        if let name = specialKeys[code] { return wrap(name, modifiers: modifiers) }
        switch code {
        case 0x1B: return wrap("Esc", modifiers: modifiers)
        case 0x7F: return wrap("BS", modifiers: modifiers)
        // Shift+Tab arrives as U+0019 (back-tab); Shift already adds `S-`.
        case 0x09, 0x19: return wrap("Tab", modifiers: modifiers)
        case 0x0D: return wrap("CR", modifiers: modifiers)
        case 0x20: return wrap("Space", modifiers: modifiers)
        default: break
        }
        if resolved == "<" { return wrap("lt", modifiers: modifiers) }
        if resolved == "\\" { return wrap("Bslash", modifiers: modifiers) }

        if modifiers.isDisjoint(with: [.control, .option, .command, .shift]) { return resolved }
        return wrap(resolved, modifiers: modifiers)
    }

    private static func wrap(_ key: String, modifiers: NSEvent.ModifierFlags) -> String {
        var prefix = ""
        if modifiers.contains(.control) { prefix += "C-" }
        if modifiers.contains(.shift) { prefix += "S-" }
        if modifiers.contains(.option) { prefix += "M-" }
        if modifiers.contains(.command) { prefix += "D-" }
        if prefix.isEmpty, key.count == 1 { return key }
        return "<\(prefix)\(key)>"
    }

    /// Control characters and the function-key range, which have names in nvim's notation.
    private static func isSpecial(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F || specialKeys[Int(scalar.value)] != nil
    }

    private static let specialKeys: [Int: String] = {
        var map: [Int: String] = [
            NSUpArrowFunctionKey: "Up", NSDownArrowFunctionKey: "Down", NSLeftArrowFunctionKey: "Left",
            NSRightArrowFunctionKey: "Right", NSInsertFunctionKey: "Insert", NSDeleteFunctionKey: "Del",
            NSHomeFunctionKey: "Home", NSEndFunctionKey: "End", NSPageUpFunctionKey: "PageUp",
            NSPageDownFunctionKey: "PageDown",
        ]
        for index in 0 ..< 35 {
            map[NSF1FunctionKey + index] = "F\(index + 1)"
        }
        return map
    }()

    /// US ANSI shifted punctuation back to its unshifted key.
    private static let unshiftedPunctuation: [Character: Character] = {
        let pairs: [Character: Character] = [
            "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
            "-": "_", "=": "+", "[": "{", "]": "}", "\\": "|", ";": ":", "'": "\"", ",": "<", ".": ">", "/": "?",
            "`": "~",
        ]
        return Dictionary(uniqueKeysWithValues: pairs.map { ($0.value, $0.key) })
    }()
}
