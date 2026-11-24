import AppKit
import SillEditor

/// The Markdown a walkthrough's prose uses, as styled text: paragraphs, `-` and `1.` lists, `###` headings, `**bold**`,
/// `*italic*`, `` `code` ``, links (their words), `> [!note]` callouts and pipe tables. Nothing else is guessed at.
@MainActor
enum WalkMarkdown {
    @MainActor struct Style {
        var look: TreeLook
        var size: CGFloat { 13.5 }
        var body: NSFont { NSFont.systemFont(ofSize: size) }
        var bold: NSFont { NSFont.systemFont(ofSize: size, weight: .semibold) }
        var italic: NSFont { NSFontManager.shared.convert(body, toHaveTrait: .italicFontMask) }
        var mono: NSFont { EditorFont.font(size - 1) }
    }

    /// The accent of a callout kind.
    static func colour(ofCallout kind: String) -> NSColor {
        switch kind.lowercased() {
        case "warning", "caution", "danger": NSColor(red: 1, green: 0.69, blue: 0.24, alpha: 1)
        case "tip", "success": NSColor(red: 0.18, green: 0.9, blue: 0.77, alpha: 1)
        case "important": NSColor(red: 0.56, green: 0.48, blue: 1, alpha: 1)
        default: NSColor(red: 0.36, green: 0.66, blue: 0.94, alpha: 1)
        }
    }

    static func attributed(_ text: String, style: Style) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 7
        let list = NSMutableParagraphStyle()
        list.lineSpacing = 3
        list.paragraphSpacing = 3
        list.headIndent = 16
        list.firstLineHeadIndent = 2
        let lines = text.components(separatedBy: "\n")
        var index = 0
        var buffer: [String] = []
        func flush() {
            guard !buffer.isEmpty else { return }
            append(inline(buffer.joined(separator: " "), style: style), paragraph)
            buffer = []
        }
        func append(_ piece: NSAttributedString, _ paragraphStyle: NSParagraphStyle) {
            let styled = NSMutableAttributedString(attributedString: piece)
            styled.addAttribute(
                .paragraphStyle,
                value: paragraphStyle,
                range: NSRange(location: 0, length: styled.length)
            )
            if result.length > 0 { result.append(NSAttributedString(string: "\n")) }
            result.append(styled)
        }
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flush(); index += 1; continue }
            if trimmed.hasPrefix("|") {
                flush()
                var rows: [[String]] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    let cells = lines[index].trimmingCharacters(in: .whitespaces).split(
                        separator: "|",
                        omittingEmptySubsequences: false
                    )
                    .dropFirst().dropLast().map { $0.trimmingCharacters(in: .whitespaces) }
                    if !cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { rows.append(cells) }
                    index += 1
                }
                append(table(rows, style: style), paragraph)
                continue
            }
            if trimmed.hasPrefix(">") {
                flush()
                var quoted: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quoted
                        .append(String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst())
                            .trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                append(callout(quoted, style: style), paragraph)
                continue
            }
            if trimmed.hasPrefix("#") {
                flush()
                let title = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                append(
                    NSAttributedString(string: title, attributes: [
                        .font: style.bold,
                        .foregroundColor: style.look.text,
                    ]),
                    paragraph
                )
                index += 1
                continue
            }
            if let item = Self.listItem(trimmed) {
                flush()
                append(
                    NSAttributedString(string: item.marker + "  ", attributes: [
                        .font: style.body,
                        .foregroundColor: style.look.muted,
                    ]) + inline(item.text, style: style),
                    list
                )
                index += 1
                continue
            }
            buffer.append(trimmed)
            index += 1
        }
        flush()
        return result
    }

    private static func listItem(_ line: String) -> (marker: String, text: String)? {
        for bullet in ["- ", "* ", "+ "] where line.hasPrefix(bullet) {
            return ("\u{2022}", String(line.dropFirst(2)))
        }
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") {
            return (digits + ".", String(line.dropFirst(digits.count + 2)))
        }
        return nil
    }

    private static func table(_ rows: [[String]], style: Style) -> NSAttributedString {
        let columns = rows.map(\.count).max() ?? 0
        var widths = [Int](repeating: 0, count: columns)
        for row in rows {
            for (number, cell) in row.enumerated() {
                widths[number] = max(widths[number], cell.count)
            }
        }
        let result = NSMutableAttributedString()
        for (number, row) in rows.enumerated() {
            let cells = row.enumerated().map { column, cell in cell + String(
                repeating: " ",
                count: widths[column] - cell.count
            ) }
            let font = number == 0 ? NSFontManager.shared.convert(style.mono, toHaveTrait: .boldFontMask) : style.mono
            result.append(NSAttributedString(
                string: cells.joined(separator: "   ") + (number < rows.count - 1 ? "\n" : ""),
                attributes: [
                    .font: font, .foregroundColor: number == 0 ? style.look.muted : style.look.text,
                ]
            ))
        }
        return result
    }

    private static func callout(_ lines: [String], style: Style) -> NSAttributedString {
        var lines = lines
        var kind = "note"
        if let first = lines.first, first.hasPrefix("[!"), let end = first.firstIndex(of: "]") {
            kind = String(first[first.index(first.startIndex, offsetBy: 2) ..< end])
            let rest = first[first.index(after: end)...].trimmingCharacters(in: .whitespaces)
            lines[0] = rest
            if rest.isEmpty { lines.removeFirst() }
        }
        let tint = colour(ofCallout: kind)
        let result = NSMutableAttributedString(string: kind.uppercased() + "  ", attributes: [
            .font: NSFont.systemFont(ofSize: style.size - 2.5, weight: .bold), .foregroundColor: tint,
        ])
        result.append(inline(lines.joined(separator: " "), style: style))
        return result
    }

    /// `**bold**`, `*italic*`, `` `code` `` and `[words](link)` inside one paragraph.
    static func inline(_ text: String, style: Style) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var rest = Substring(text)
        func plain(_ string: String, font: NSFont? = nil, colour: NSColor? = nil) {
            result.append(NSAttributedString(string: string, attributes: [
                .font: font ?? style.body, .foregroundColor: colour ?? style.look.text,
            ]))
        }
        while let first = rest.first {
            if first == "`", let end = rest.dropFirst().firstIndex(of: "`") {
                let code = String(rest[rest.index(after: rest.startIndex) ..< end])
                result.append(NSAttributedString(string: code, attributes: [
                    .font: style.mono, .foregroundColor: style.look.text,
                    .backgroundColor: style.look.text.withAlphaComponent(0.09),
                ]))
                rest = rest[rest.index(after: end)...]
            } else if rest.hasPrefix("**"), let end = rest.dropFirst(2).range(of: "**") {
                plain(String(rest[rest.index(rest.startIndex, offsetBy: 2) ..< end.lowerBound]), font: style.bold)
                rest = rest[end.upperBound...]
            } else if first == "*" || first == "_", let end = rest.dropFirst().firstIndex(of: first),
                      end != rest.index(after: rest.startIndex)
            {
                plain(String(rest[rest.index(after: rest.startIndex) ..< end]), font: style.italic)
                rest = rest[rest.index(after: end)...]
            } else if first == "[", let close = rest.firstIndex(of: "]"),
                      rest[rest.index(after: close)...].hasPrefix("("),
                      let end = rest[rest.index(after: close)...].firstIndex(of: ")")
            {
                result.append(NSAttributedString(
                    string: String(rest[rest.index(after: rest.startIndex) ..< close]),
                    attributes: [
                        .font: style.body, .foregroundColor: style.look.text,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                    ]
                ))
                rest = rest[rest.index(after: end)...]
            } else {
                let next = rest.dropFirst().firstIndex { "`*_[".contains($0) } ?? rest.endIndex
                plain(String(rest[rest.startIndex ..< next]))
                rest = rest[next...]
            }
        }
        return result
    }
}

private func + (lhs: NSAttributedString, rhs: NSAttributedString) -> NSAttributedString {
    let result = NSMutableAttributedString(attributedString: lhs)
    result.append(rhs)
    return result
}
