import AppKit
import SillInput
import Testing

@Suite("key notation")
struct KeyNotationTests {
    /// A key-down event as AppKit makes it for a typed key.
    private func event(
        _ characters: String, unmodified: String? = nil, flags: NSEvent.ModifierFlags = [], keyCode: UInt16 = 0
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: unmodified ?? characters, isARepeat: false,
            keyCode: keyCode
        )!
    }

    @Test("typed text goes as typed", arguments: [("a", "a"), ("A", "A"), ("!", "!"), ("é", "é"), ("<", "<lt>")])
    func typed(characters: String, expected: String) {
        let flags: NSEvent.ModifierFlags = characters == "A" || characters == "!" || characters == "<" ? .shift : []
        #expect(KeyNotation.keys(for: event(characters, flags: flags)) == expected)
    }

    @Test("control chords", arguments: [
        ("\u{17}", "w", "<C-w>"), ("\u{1C}", "\\", "<C-Bslash>"), ("\u{0E}", "n", "<C-n>"), ("\u{1B}", "[", "<C-[>"),
    ])
    func control(characters: String, unmodified: String, expected: String) {
        #expect(KeyNotation.keys(for: event(characters, unmodified: unmodified, flags: .control)) == expected)
    }

    private static let namedKeys: [(String, NSEvent.ModifierFlags, String)] = [
        ("\u{1B}", [], "<Esc>"), ("\r", [], "<CR>"), ("\t", [], "<Tab>"), ("\u{19}", .shift, "<S-Tab>"),
        ("\u{7F}", [], "<BS>"), (String(UnicodeScalar(UInt32(NSUpArrowFunctionKey))!), [], "<Up>"),
        (String(UnicodeScalar(UInt32(NSF5FunctionKey))!), [], "<F5>"),
        (String(UnicodeScalar(UInt32(NSLeftArrowFunctionKey))!), .shift, "<S-Left>"),
    ]

    @Test("named keys", arguments: namedKeys)
    func named(characters: String, flags: NSEvent.ModifierFlags, expected: String) {
        #expect(KeyNotation.keys(for: event(characters, flags: flags)) == expected)
    }

    @Test("command and option chords keep the key, shifted punctuation unshifted")
    func chords() {
        #expect(KeyNotation.keys(for: event("s", flags: .command)) == "<D-s>")
        #expect(KeyNotation.keys(for: event("}", unmodified: "}", flags: [.command, .shift])) == "<S-D-]>")
        #expect(KeyNotation.keys(for: event("∫", unmodified: "b", flags: [.control, .option])) == "<C-M-b>")
        #expect(KeyNotation.keys(for: event(" ", flags: .control)) == "<C-Space>")
    }
}
