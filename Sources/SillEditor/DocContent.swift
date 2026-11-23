import AppKit

/// Documentation as the host sends it: a JSON list of blocks, each `{t: "text", s}`, `{t: "code", s, h: [spans]}` or
/// `{t: "rule"}`. A span is `{b, e, c, bold, italic, u}`: the bytes it covers in the code, its colour (RGB), and its
/// weight. Text may have `backticks` for code in a line. Anything that is not that list is plain text.
package enum DocContent {
    private struct Block: Decodable {
        var t: String
        var s: String?
        var faint: Bool?
        var h: [Span]?
    }

    private struct Span: Decodable {
        var b: Int
        var e: Int
        var c: Int?
        var bold: Bool?
        var italic: Bool?
        var u: Bool?
    }

    package static func attributed(
        _ content: String, regular: NSFont, text: NSColor, code: NSColor, faint: NSColor, rule: NSColor
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let blocks: [Block] = if content.hasPrefix("["), let data = content.data(using: .utf8),
                                 let decoded = try? JSONDecoder().decode([Block].self, from: data)
        {
            decoded
        } else {
            [Block(t: "text", s: content)]
        }
        let result = NSMutableAttributedString()
        func gap(_ height: CGFloat) {
            let space = NSMutableParagraphStyle()
            space.maximumLineHeight = height
            space.minimumLineHeight = height
            result.append(NSAttributedString(string: "\n", attributes: [.font: regular, .paragraphStyle: space]))
        }
        func weighted(_ font: NSFont, bold: Bool, italic: Bool) -> NSFont {
            var font = font
            if bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            return font
        }
        for (index, block) in blocks.enumerated() {
            if index > 0 {
                // The line of the block before ends, then a little space.
                result.append(NSAttributedString(string: "\n", attributes: [.font: regular]))
                gap(6)
            }
            switch block.t {
            case "code":
                let source = block.s ?? ""
                let styled = NSMutableAttributedString(string: source, attributes: [
                    .font: regular, .foregroundColor: code, .paragraphStyle: paragraph,
                ])
                let bytes = Array(source.utf8)
                func offset(_ byte: Int) -> Int {
                    // UTF-16 units up to a byte offset.
                    String(decoding: bytes[0 ..< min(max(byte, 0), bytes.count)], as: UTF8.self).utf16.count
                }
                for span in block.h ?? [] where span.e > span.b {
                    let start = offset(span.b), end = offset(span.e)
                    guard end > start, end <= styled.length else { continue }
                    let range = NSRange(location: start, length: end - start)
                    if let colour = span.c {
                        styled.addAttribute(
                            .foregroundColor,
                            value: NSColor(
                                red: CGFloat((colour >> 16) & 0xFF) / 255, green: CGFloat((colour >> 8) & 0xFF) / 255,
                                blue: CGFloat(colour & 0xFF) / 255, alpha: 1
                            ),
                            range: range
                        )
                    }
                    if span.bold == true || span.italic == true {
                        styled.addAttribute(
                            .font, value: weighted(regular, bold: span.bold == true, italic: span.italic == true),
                            range: range
                        )
                    }
                    if span.u == true {
                        styled.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                    }
                }
                result.append(styled)
            case "rule":
                result.append(NSAttributedString(string: String(repeating: "\u{2500}", count: 24), attributes: [
                    .font: regular, .foregroundColor: rule, .paragraphStyle: paragraph,
                ]))
            default:
                // Text, with `code` in a line in the code colour.
                let color = block.faint == true ? faint : text
                let pieces = (block.s ?? "").components(separatedBy: "`")
                for (number, piece) in pieces.enumerated() {
                    result.append(NSAttributedString(string: piece, attributes: [
                        .font: regular, .foregroundColor: number % 2 == 1 ? code : color, .paragraphStyle: paragraph,
                    ]))
                }
            }
        }
        return result
    }
}
