import Foundation
import Testing

/// sill's nvim colour scheme copies the palette of the views around it (Design.swift): the two must not drift, or the
/// editor and its panes stop being one thing.
@Suite struct ColorSchemeTests {
    /// `name = '#RRGGBB'` in the scheme's palette table.
    private static func scheme() throws -> [String: String] {
        let text = try String(
            contentsOf: runtimeDirectory.appendingPathComponent("colors/sill.lua"),
            encoding: .utf8
        )
        let table = try #require(text.range(of: "local p = {").map { text[$0.upperBound...] })
        let body = table[..<(table.firstIndex(of: "}") ?? table.endIndex)]
        var colours: [String: String] = [:]
        for match in body.matches(of: /(\w+) = '#([0-9A-Fa-f]{6})'/) {
            colours[String(match.1)] = match.2.uppercased()
        }
        return colours
    }

    /// `static let name = NSColor(hex: 0xRRGGBB)` in Design.swift.
    private static func design() throws -> [String: String] {
        let source = runtimeDirectory.deletingLastPathComponent()
            .appendingPathComponent("Sources/SillEditor/Design.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        var colours: [String: String] = [:]
        for match in text.matches(of: /static let (\w+) = NSColor\(hex: 0x([0-9A-Fa-f]{6})\)/) {
            colours[String(match.1)] = match.2.uppercased()
        }
        return colours
    }

    @Test func thePaletteIsDesigns() throws {
        let scheme = try Self.scheme(), design = try Self.design()
        #expect(scheme.count >= 15, "the scheme's palette read: \(scheme.count) colours")
        for (name, hex) in scheme {
            #expect(design[name] == hex, "\(name): the scheme has #\(hex), Design.swift \(design[name] ?? "nothing")")
        }
    }
}
