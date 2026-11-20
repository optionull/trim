import AppKit
import CoreText

/// The Symbols Nerd Font that ships in the app (`Contents/Resources/fonts`, from `scripts/fonts.sh`; a debug build
/// finds
/// it in `Vendor/fonts`), registered for this process only. Icons are drawn with it, and the grid's fallback finds it
/// for the private-use characters a config's own icons are made of, so nobody has to install a patched font.
enum NerdFont {
    private nonisolated(unsafe) static var postScriptName: String?

    static var directory: URL? {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("fonts")
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Vendor/fonts")
        return [bundled, source].compactMap(\.self).first { directory in
            ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
                .contains { $0.hasSuffix(".ttf") }
        }
    }

    /// Registers the font once, before anything is drawn. False when there is none to register.
    @discardableResult
    static func register() -> Bool {
        if postScriptName != nil { return true }
        guard let directory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return false }
        let files = names.filter { $0.hasSuffix(".ttf") }.map { directory.appendingPathComponent($0) }
        guard !files.isEmpty else { return false }
        CTFontManagerRegisterFontURLs(files as CFArray, .process, false, nil)
        let descriptor = (CTFontManagerCreateFontDescriptorsFromURL(files[0] as CFURL) as? [CTFontDescriptor])?.first
        postScriptName = descriptor.flatMap { CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String }
        return postScriptName != nil
    }

    static func font(size: CGFloat) -> NSFont? {
        postScriptName.flatMap { NSFont(name: $0, size: size) }
    }

    /// Whether the font has the glyph (a code point that is not in it draws as nothing).
    static func has(_ glyph: Character) -> Bool {
        guard let font = font(size: 14) else { return false }
        var characters = Array(String(glyph).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        return CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count) && glyphs[0] != 0
    }
}
