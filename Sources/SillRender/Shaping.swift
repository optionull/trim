// Lifted from Veil (https://github.com/0x1b2c/Veil, MIT, a29c3d0, GlyphAtlas.swift); see THIRD_PARTY_NOTICES.md.
// Changed for sill: ligatures are a parameter rather than a global.
import AppKit
import CoreText

struct ShapedGlyph: Equatable {
    let text: String
    let colOffset: Int
    let cellCount: Int
}

/// Shape a run of text using CoreText to detect font ligatures.
/// Handles both traditional ligatures (glyph merging, fewer glyphs) and
/// contextual alternates (calt, same glyph count but different glyph IDs).
/// Most programming fonts (Fira Code, JetBrains Mono) use calt.
nonisolated func shapeRunText(
    _ runText: String, font: NSFont, bold: Bool, italic: Bool, ligatures: Bool = true
) -> [ShapedGlyph] {
    if !ligatures { return perCharacterGlyphs(runText) }

    var drawFont = font
    var traits: NSFontDescriptor.SymbolicTraits = []
    if bold { traits.insert(.bold) }
    if italic { traits.insert(.italic) }
    if !traits.isEmpty {
        let descriptor = drawFont.fontDescriptor.withSymbolicTraits(traits)
        drawFont = NSFont(descriptor: descriptor, size: drawFont.pointSize) ?? drawFont
    }

    let attributes: [NSAttributedString.Key: Any] = [.font: drawFont]
    let attrString = NSAttributedString(string: runText, attributes: attributes)
    let line = CTLineCreateWithAttributedString(attrString)
    // A CTLine's glyph runs are always CTRuns.
    let ctRuns = (CTLineGetGlyphRuns(line) as? [CTRun]) ?? []

    // Extract shaped glyph IDs from CTLine (with OpenType features applied)
    var shapedIDs = [CGGlyph]()
    for ctRun in ctRuns {
        let count = CTRunGetGlyphCount(ctRun)
        var glyphs = [CGGlyph](repeating: 0, count: count)
        CTRunGetGlyphs(ctRun, CFRange(location: 0, length: count), &glyphs)
        shapedIDs.append(contentsOf: glyphs)
    }

    let utf16 = Array(runText.utf16)

    // When shaped glyph count matches UTF-16 count, check for contextual alternates
    // by comparing shaped glyph IDs against unshaped (cmap-only) glyph IDs
    if shapedIDs.count == utf16.count {
        var unshapedIDs = [CGGlyph](repeating: 0, count: utf16.count)
        let allCovered = CTFontGetGlyphsForCharacters(
            drawFont, utf16, &unshapedIDs, utf16.count
        )

        if !allCovered || shapedIDs == unshapedIDs {
            return perCharacterGlyphs(runText)
        }

        // Contextual alternates detected: group consecutive changed glyphs
        var utf16ToCol = [Int]()
        var colIdx = 0
        for char in runText {
            for _ in 0 ..< char.utf16.count {
                utf16ToCol.append(colIdx)
            }
            colIdx += 1
        }

        var result = [ShapedGlyph]()
        var i = 0
        while i < utf16.count {
            let col = utf16ToCol[i]
            if shapedIDs[i] == unshapedIDs[i] {
                var end = i + 1
                while end < utf16.count, utf16ToCol[end] == col {
                    end += 1
                }
                let startIdx = runText.utf16.index(
                    runText.utf16.startIndex, offsetBy: i
                )
                let endIdx = runText.utf16.index(
                    runText.utf16.startIndex, offsetBy: end
                )
                result.append(
                    ShapedGlyph(
                        text: String(runText[startIdx ..< endIdx]),
                        colOffset: col, cellCount: 1
                    ))
                i = end
            } else {
                var end = i
                while end < utf16.count, shapedIDs[end] != unshapedIDs[end] {
                    end += 1
                }
                let endCol = (end < utf16ToCol.count) ? utf16ToCol[end] : colIdx
                let cellCount = max(endCol - col, 1)
                let startIdx = runText.utf16.index(
                    runText.utf16.startIndex, offsetBy: i
                )
                let endIdx = runText.utf16.index(
                    runText.utf16.startIndex, offsetBy: end
                )
                result.append(
                    ShapedGlyph(
                        text: String(runText[startIdx ..< endIdx]),
                        colOffset: col, cellCount: cellCount
                    ))
                i = end
            }
        }
        return result
    }

    // Traditional ligature: fewer glyphs than characters (glyph merging)
    var utf16ToCol = [Int]()
    var colIdx = 0
    for char in runText {
        for _ in 0 ..< char.utf16.count {
            utf16ToCol.append(colIdx)
        }
        colIdx += 1
    }
    let totalCols = colIdx

    var result = [ShapedGlyph]()
    for ctRun in ctRuns {
        let glyphCount = CTRunGetGlyphCount(ctRun)
        guard glyphCount > 0 else { continue }

        var indices = [CFIndex](repeating: 0, count: glyphCount)
        CTRunGetStringIndices(ctRun, CFRange(location: 0, length: glyphCount), &indices)
        let runRange = CTRunGetStringRange(ctRun)
        let runStringEnd = runRange.location + runRange.length

        for i in 0 ..< glyphCount {
            let utf16Start = indices[i]
            let utf16End = (i + 1 < glyphCount) ? indices[i + 1] : runStringEnd

            let startCol = utf16ToCol[utf16Start]
            let endCol = (utf16End < utf16ToCol.count) ? utf16ToCol[utf16End] : totalCols
            let cellCount = max(endCol - startCol, 1)

            let startIdx = runText.utf16.index(
                runText.utf16.startIndex, offsetBy: utf16Start
            )
            let endIdx = runText.utf16.index(
                runText.utf16.startIndex, offsetBy: utf16End
            )
            result.append(
                ShapedGlyph(
                    text: String(runText[startIdx ..< endIdx]),
                    colOffset: startCol, cellCount: cellCount
                ))
        }
    }

    return result.isEmpty ? perCharacterGlyphs(runText) : result
}

private nonisolated func perCharacterGlyphs(_ text: String) -> [ShapedGlyph] {
    var result = [ShapedGlyph]()
    result.reserveCapacity(text.count)
    var col = 0
    for char in text {
        result.append(ShapedGlyph(text: String(char), colOffset: col, cellCount: 1))
        col += 1
    }
    return result
}
