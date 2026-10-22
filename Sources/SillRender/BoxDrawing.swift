// Lifted from Veil (https://github.com/0x1b2c/Veil, MIT, a29c3d0); see THIRD_PARTY_NOTICES.md.
// Custom rendering of Box Drawing (U+2500-U+257F) and Block Elements (U+2580-U+259F), drawn into a CGContext at the
// cell's exact size so lines meet without gaps. Veil ported the algorithms from Ghostty
// (https://github.com/ghostty-org/ghostty, MIT).

import AppKit
import CoreGraphics
import CoreText

nonisolated enum BoxDrawing {
    /// Attempt to custom-draw the given Unicode scalar. Returns true if
    /// handled, false to fall back to normal font rendering.
    ///
    /// All coordinates are in the CGContext's point space (already scaled
    /// for Retina via `ctx.scaleBy`). CGContext y=0 is at the bottom.
    static func render(
        _ codepoint: UInt32, ctx: CGContext,
        cellWidth w: CGFloat, cellHeight h: CGFloat, font: NSFont
    ) -> Bool {
        guard (0x2500 ... 0x259F).contains(codepoint) else { return false }

        // Thickness derived from underline thickness (Ghostty approach).
        let underlineThickness = max(1, ceil(CTFontGetUnderlineThickness(font)))
        let base = Int(underlineThickness)
        let lightPx = base
        let heavyPx = base * 2

        let cw = Int(ceil(w))
        let ch = Int(ceil(h))

        ctx.setFillColor(.white)

        switch codepoint {
        // Box Drawing U+2500-U+257F
        case 0x2500 ... 0x2503:
            linesChar(
                ctx, cw: cw, ch: ch, lightPx: lightPx, heavyPx: heavyPx,
                lines: linesForCodepoint(codepoint)
            )
        case 0x2504 ... 0x250B:
            drawDash(ctx, codepoint: codepoint, cw: cw, ch: ch, lightPx: lightPx, heavyPx: heavyPx)
        case 0x250C ... 0x254B:
            linesChar(
                ctx, cw: cw, ch: ch, lightPx: lightPx, heavyPx: heavyPx,
                lines: linesForCodepoint(codepoint)
            )
        case 0x254C ... 0x254F:
            drawDash(ctx, codepoint: codepoint, cw: cw, ch: ch, lightPx: lightPx, heavyPx: heavyPx)
        case 0x2550 ... 0x256C:
            linesChar(
                ctx, cw: cw, ch: ch, lightPx: lightPx, heavyPx: heavyPx,
                lines: linesForCodepoint(codepoint)
            )
        case 0x256D ... 0x2570:
            drawArc(ctx, codepoint: codepoint, cw: cw, ch: ch, lightPx: lightPx)
        case 0x2571 ... 0x2573:
            drawDiagonal(ctx, codepoint: codepoint, w: w, h: h, lightPx: lightPx)
        case 0x2574 ... 0x257F:
            linesChar(
                ctx, cw: cw, ch: ch, lightPx: lightPx, heavyPx: heavyPx,
                lines: linesForCodepoint(codepoint)
            )
        // Block Elements U+2580-U+259F
        case 0x2580 ... 0x2590:
            drawBlock(ctx, codepoint: codepoint, cw: cw, ch: ch)
        case 0x2591 ... 0x2593:
            drawShade(ctx, codepoint: codepoint, cw: cw, ch: ch)
        case 0x2594 ... 0x259F:
            drawBlock(ctx, codepoint: codepoint, cw: cw, ch: ch)
        default:
            return false
        }
        return true
    }

    // MARK: - Line Style

    private enum Style: UInt8 {
        case none = 0
        case light = 1
        case heavy = 2
        case double = 3
    }

    private struct Lines {
        var up: Style = .none
        var right: Style = .none
        var down: Style = .none
        var left: Style = .none
    }

    // MARK: - Lines Character (Ghostty's linesChar)

    /// Unified algorithm for all intersection-style box-drawing characters.
    /// Computes stroke positions for each of the 4 edges based on their
    /// style and neighboring connections.
    ///
    /// Ghostty's coordinate system has y=0 at the top (screen convention),
    /// while CGContext has y=0 at the bottom. The "up" direction in Unicode
    /// naming = toward higher row on screen = toward y=0 in CGContext.
    /// We flip: Unicode "up" draws toward y=ch, Unicode "down" toward y=0.
    private static func linesChar(
        _ ctx: CGContext, cw: Int, ch: Int,
        lightPx: Int, heavyPx: Int, lines: Lines
    ) {
        // Centered positions for light strokes (horizontal)
        let hLightTop = (ch - lightPx) / 2
        let hLightBottom = hLightTop + lightPx
        // Centered positions for heavy strokes (horizontal)
        let hHeavyTop = (ch - heavyPx) / 2
        let hHeavyBottom = hHeavyTop + heavyPx
        // Double strokes: two light strokes separated by a light-px gap
        let hDoubleTop = hLightTop - lightPx
        let hDoubleBottom = hLightBottom + lightPx

        // Centered positions for light strokes (vertical)
        let vLightLeft = (cw - lightPx) / 2
        let vLightRight = vLightLeft + lightPx
        // Heavy
        let vHeavyLeft = (cw - heavyPx) / 2
        let vHeavyRight = vHeavyLeft + heavyPx
        // Double
        let vDoubleLeft = vLightLeft - lightPx
        let vDoubleRight = vLightRight + lightPx

        // Connection logic: how far each stroke extends toward the center.
        // This ensures proper junction appearance at intersections.

        // In Ghostty, "up" goes to y=0 (top of screen). For us, "up" goes
        // to y=ch (top of CGContext = top of screen after flip). We swap
        // up/down when mapping to CGContext coordinates.

        // The bottom of the "up" line (in Ghostty coords = the extent toward center)
        let upBottom: Int = if lines.left == .heavy || lines.right == .heavy {
            hHeavyBottom
        } else if lines.left != lines.right || lines.down == lines.up {
            if lines.left == .double || lines.right == .double {
                hDoubleBottom
            } else {
                hLightBottom
            }
        } else if lines.left == .none && lines.right == .none {
            hLightBottom
        } else {
            hLightTop
        }

        // The top of the "down" line (in Ghostty coords)
        let downTop: Int = if lines.left == .heavy || lines.right == .heavy {
            hHeavyTop
        } else if lines.left != lines.right || lines.up == lines.down {
            if lines.left == .double || lines.right == .double {
                hDoubleTop
            } else {
                hLightTop
            }
        } else if lines.left == .none && lines.right == .none {
            hLightTop
        } else {
            hLightBottom
        }

        // The right of the "left" line
        let leftRight: Int = if lines.up == .heavy || lines.down == .heavy {
            vHeavyRight
        } else if lines.up != lines.down || lines.left == lines.right {
            if lines.up == .double || lines.down == .double {
                vDoubleRight
            } else {
                vLightRight
            }
        } else if lines.up == .none && lines.down == .none {
            vLightRight
        } else {
            vLightLeft
        }

        // The left of the "right" line
        let rightLeft: Int = if lines.up == .heavy || lines.down == .heavy {
            vHeavyLeft
        } else if lines.up != lines.down || lines.right == lines.left {
            if lines.up == .double || lines.down == .double {
                vDoubleLeft
            } else {
                vLightLeft
            }
        } else if lines.up == .none, lines.down == .none {
            vLightLeft
        } else {
            vLightRight
        }

        // Now draw each edge. Map Ghostty's y coords to CGContext:
        // Ghostty y=0 (top of screen) = CGContext y=ch
        // Ghostty y=ch (bottom of screen) = CGContext y=0

        // UP stroke: Ghostty draws from y=0 to y=upBottom.
        // CGContext: from y=(ch - upBottom) to y=ch.
        switch lines.up {
        case .none: break
        case .light:
            box(ctx, vLightLeft, ch - upBottom, vLightRight, ch)
        case .heavy:
            box(ctx, vHeavyLeft, ch - upBottom, vHeavyRight, ch)
        case .double:
            let leftBottom = lines.left == .double ? hLightTop : upBottom
            let rightBottom = lines.right == .double ? hLightTop : upBottom
            box(ctx, vDoubleLeft, ch - leftBottom, vLightLeft, ch)
            box(ctx, vLightRight, ch - rightBottom, vDoubleRight, ch)
        }

        // RIGHT stroke: Ghostty draws from x=rightLeft to x=cw.
        // x coordinates are the same (no flip needed).
        // y in Ghostty: hLightTop to hLightBottom → CGContext: (ch - hLightBottom) to (ch - hLightTop)
        switch lines.right {
        case .none: break
        case .light:
            box(ctx, rightLeft, ch - hLightBottom, cw, ch - hLightTop)
        case .heavy:
            box(ctx, rightLeft, ch - hHeavyBottom, cw, ch - hHeavyTop)
        case .double:
            let topLeft = lines.up == .double ? vLightRight : rightLeft
            let bottomLeft = lines.down == .double ? vLightRight : rightLeft
            box(ctx, topLeft, ch - hLightTop, cw, ch - hDoubleTop)
            box(ctx, bottomLeft, ch - hDoubleBottom, cw, ch - hLightBottom)
        }

        // DOWN stroke: Ghostty draws from y=downTop to y=ch.
        // CGContext: from y=0 to y=(ch - downTop).
        switch lines.down {
        case .none: break
        case .light:
            box(ctx, vLightLeft, 0, vLightRight, ch - downTop)
        case .heavy:
            box(ctx, vHeavyLeft, 0, vHeavyRight, ch - downTop)
        case .double:
            let leftTop = lines.left == .double ? hLightBottom : downTop
            let rightTop = lines.right == .double ? hLightBottom : downTop
            box(ctx, vDoubleLeft, 0, vLightLeft, ch - leftTop)
            box(ctx, vLightRight, 0, vDoubleRight, ch - rightTop)
        }

        // LEFT stroke: Ghostty draws from x=0 to x=leftRight.
        switch lines.left {
        case .none: break
        case .light:
            box(ctx, 0, ch - hLightBottom, leftRight, ch - hLightTop)
        case .heavy:
            box(ctx, 0, ch - hHeavyBottom, leftRight, ch - hHeavyTop)
        case .double:
            let topRight = lines.up == .double ? vLightLeft : leftRight
            let bottomRight = lines.down == .double ? vLightLeft : leftRight
            box(ctx, 0, ch - hLightTop, topRight, ch - hDoubleTop)
            box(ctx, 0, ch - hDoubleBottom, bottomRight, ch - hLightBottom)
        }
    }

    // MARK: - Arcs (Rounded Corners)

    /// Cubic Bezier arcs for ╭╮╯╰. Ported from Ghostty's arc().
    private static func drawArc(
        _ ctx: CGContext, codepoint: UInt32, cw: Int, ch: Int, lightPx: Int
    ) {
        let fw = CGFloat(cw)
        let fh = CGFloat(ch)
        let thick = CGFloat(lightPx)
        let centerX = CGFloat((cw - lightPx) / 2) + thick / 2
        // Ghostty centerY is from top; we flip to CGContext bottom-up
        let ghosttyCenterY = CGFloat((ch - lightPx) / 2) + thick / 2
        let centerY = fh - ghosttyCenterY
        let r = min(fw, fh) / 2
        let s: CGFloat = 0.25 // control point factor

        ctx.setStrokeColor(.white)
        // Compensate for CGContext stroke anti-aliasing making arcs appear
        // thinner than fill-based straight lines.
        ctx.setLineWidth(thick + 0.5)
        ctx.setLineCap(.butt)

        // Ghostty corners: tl=╯, tr=╰... wait. Ghostty maps:
        // 0x256D (╭) → corner .br  (curve from bottom to right)
        // 0x256E (╮) → corner .bl  (curve from bottom to left)
        // 0x256F (╯) → corner .tl  (curve from top to left)
        // 0x2570 (╰) → corner .tr  (curve from top to right)
        //
        // In Ghostty's y-down system:
        // .tl: moveTo(centerX, 0) → lineTo(centerX, centerY-r) → curveTo → lineTo(0, centerY)
        // We flip y: Ghostty y → CGContext (fh - y)

        switch codepoint {
        case 0x256D: // ╭ = Ghostty .br: from bottom edge to right edge
            ctx.move(to: CGPoint(x: centerX, y: 0)) // Ghostty: (cx, height) flipped
            ctx.addLine(to: CGPoint(x: centerX, y: centerY - r))
            ctx.addCurve(
                to: CGPoint(x: centerX + r, y: centerY),
                control1: CGPoint(x: centerX, y: centerY - s * r),
                control2: CGPoint(x: centerX + s * r, y: centerY)
            )
            ctx.addLine(to: CGPoint(x: fw, y: centerY))
        case 0x256E: // ╮ = Ghostty .bl: from bottom edge to left edge
            ctx.move(to: CGPoint(x: centerX, y: 0))
            ctx.addLine(to: CGPoint(x: centerX, y: centerY - r))
            ctx.addCurve(
                to: CGPoint(x: centerX - r, y: centerY),
                control1: CGPoint(x: centerX, y: centerY - s * r),
                control2: CGPoint(x: centerX - s * r, y: centerY)
            )
            ctx.addLine(to: CGPoint(x: 0, y: centerY))
        case 0x256F: // ╯ = Ghostty .tl: from top edge to left edge
            ctx.move(to: CGPoint(x: centerX, y: fh)) // Ghostty: (cx, 0) flipped
            ctx.addLine(to: CGPoint(x: centerX, y: centerY + r))
            ctx.addCurve(
                to: CGPoint(x: centerX - r, y: centerY),
                control1: CGPoint(x: centerX, y: centerY + s * r),
                control2: CGPoint(x: centerX - s * r, y: centerY)
            )
            ctx.addLine(to: CGPoint(x: 0, y: centerY))
        case 0x2570: // ╰ = Ghostty .tr: from top edge to right edge
            ctx.move(to: CGPoint(x: centerX, y: fh))
            ctx.addLine(to: CGPoint(x: centerX, y: centerY + r))
            ctx.addCurve(
                to: CGPoint(x: centerX + r, y: centerY),
                control1: CGPoint(x: centerX, y: centerY + s * r),
                control2: CGPoint(x: centerX + s * r, y: centerY)
            )
            ctx.addLine(to: CGPoint(x: fw, y: centerY))
        default: break
        }

        ctx.strokePath()
    }

    // MARK: - Dashed Lines

    private static func drawDash(
        _ ctx: CGContext, codepoint: UInt32, cw: Int, ch: Int,
        lightPx: Int, heavyPx: Int
    ) {
        switch codepoint {
        // ┄ ┅ ┆ ┇ ┈ ┉ ┊ ┋
        case 0x2504: dashH(ctx, cw: cw, ch: ch, count: 3, thick: lightPx, gap: max(4, lightPx))
        case 0x2505: dashH(ctx, cw: cw, ch: ch, count: 3, thick: heavyPx, gap: max(4, lightPx))
        case 0x2506: dashV(ctx, cw: cw, ch: ch, count: 3, thick: lightPx, gap: max(4, lightPx))
        case 0x2507: dashV(ctx, cw: cw, ch: ch, count: 3, thick: heavyPx, gap: max(4, lightPx))
        case 0x2508: dashH(ctx, cw: cw, ch: ch, count: 4, thick: lightPx, gap: max(4, lightPx))
        case 0x2509: dashH(ctx, cw: cw, ch: ch, count: 4, thick: heavyPx, gap: max(4, lightPx))
        case 0x250A: dashV(ctx, cw: cw, ch: ch, count: 4, thick: lightPx, gap: max(4, lightPx))
        case 0x250B: dashV(ctx, cw: cw, ch: ch, count: 4, thick: heavyPx, gap: max(4, lightPx))
        // ╌ ╍ ╎ ╏
        case 0x254C: dashH(ctx, cw: cw, ch: ch, count: 2, thick: lightPx, gap: lightPx)
        case 0x254D: dashH(ctx, cw: cw, ch: ch, count: 2, thick: heavyPx, gap: heavyPx)
        case 0x254E: dashV(ctx, cw: cw, ch: ch, count: 2, thick: lightPx, gap: heavyPx)
        case 0x254F: dashV(ctx, cw: cw, ch: ch, count: 2, thick: heavyPx, gap: heavyPx)
        default: break
        }
    }

    private static func dashH(
        _ ctx: CGContext, cw: Int, ch: Int,
        count: Int, thick: Int, gap desiredGap: Int
    ) {
        let gapCount = count
        guard cw >= count + gapCount else {
            // Too small, draw solid
            let y = (ch - thick) / 2
            box(ctx, 0, ch - y - thick, cw, ch - y)
            return
        }
        let gapWidth = min(desiredGap, cw / (2 * count))
        let totalGap = gapCount * gapWidth
        let totalDash = cw - totalGap
        let dashWidth = totalDash / count
        var extra = totalDash % count
        // CGContext y-flip: Ghostty y = (ch - thick) / 2 from top
        let ghosttyY = (ch - thick) / 2
        let y = ch - ghosttyY - thick
        var x = gapWidth / 2
        for _ in 0 ..< count {
            var x1 = x + dashWidth
            if extra > 0 { extra -= 1; x1 += 1 }
            box(ctx, x, y, x1, y + thick)
            x = x1 + gapWidth
        }
    }

    private static func dashV(
        _ ctx: CGContext, cw: Int, ch: Int,
        count: Int, thick: Int, gap desiredGap: Int
    ) {
        let gapCount = count
        guard ch >= count + gapCount else {
            let x = (cw - thick) / 2
            box(ctx, x, 0, x + thick, ch)
            return
        }
        let gapWidth = min(desiredGap, ch / (2 * count))
        let totalGap = gapCount * gapWidth
        let totalDash = ch - totalGap
        let dashHeight = totalDash / count
        var extra = totalDash % count
        let x = (cw - thick) / 2
        // Ghostty starts from y=0 (top). We flip: start from y=ch (top in CGContext)
        var ghosttyY = 0
        for _ in 0 ..< count {
            var h = dashHeight
            if extra > 0 { extra -= 1; h += 1 }
            // Ghostty: box(x, ghosttyY, x+thick, ghosttyY+h)
            // CGContext flip: y1 = ch - ghosttyY - h, y2 = ch - ghosttyY
            box(ctx, x, ch - ghosttyY - h, x + thick, ch - ghosttyY)
            ghosttyY += h + gapWidth
        }
    }

    // MARK: - Diagonals

    private static func drawDiagonal(
        _ ctx: CGContext, codepoint: UInt32, w: CGFloat, h: CGFloat, lightPx: Int
    ) {
        let thick = CGFloat(lightPx)
        let slopeX = min(1.0, w / h)
        let slopeY = min(1.0, h / w)

        ctx.setStrokeColor(.white)
        ctx.setLineWidth(thick)

        switch codepoint {
        case 0x2571: // ╱ upper right to lower left
            // Ghostty: (w+0.5sx, -0.5sy) → (-0.5sx, h+0.5sy)
            // Flip y: (w+0.5sx, h+0.5sy) → (-0.5sx, -0.5sy)
            ctx.move(to: CGPoint(x: w + 0.5 * slopeX, y: h + 0.5 * slopeY))
            ctx.addLine(to: CGPoint(x: -0.5 * slopeX, y: -0.5 * slopeY))
        case 0x2572: // ╲ upper left to lower right
            // Ghostty: (-0.5sx, -0.5sy) → (w+0.5sx, h+0.5sy)
            // Flip y: (-0.5sx, h+0.5sy) → (w+0.5sx, -0.5sy)
            ctx.move(to: CGPoint(x: -0.5 * slopeX, y: h + 0.5 * slopeY))
            ctx.addLine(to: CGPoint(x: w + 0.5 * slopeX, y: -0.5 * slopeY))
        case 0x2573: // ╳ cross
            ctx.move(to: CGPoint(x: w + 0.5 * slopeX, y: h + 0.5 * slopeY))
            ctx.addLine(to: CGPoint(x: -0.5 * slopeX, y: -0.5 * slopeY))
            ctx.move(to: CGPoint(x: -0.5 * slopeX, y: h + 0.5 * slopeY))
            ctx.addLine(to: CGPoint(x: w + 0.5 * slopeX, y: -0.5 * slopeY))
        default: break
        }
        ctx.strokePath()
    }

    // MARK: - Block Elements

    /// Block elements: fractional fills anchored to cell edges.
    /// CGContext y=0 is at the bottom of the cell.
    private static func drawBlock(
        _ ctx: CGContext, codepoint: UInt32, cw: Int, ch: Int
    ) {
        switch codepoint {
        // Upper/lower fractional blocks
        case 0x2580: box(ctx, 0, ch / 2, cw, ch) // ▀ upper half
        case 0x2581: box(ctx, 0, 0, cw, ch / 8) // ▁ lower 1/8
        case 0x2582: box(ctx, 0, 0, cw, ch / 4) // ▂ lower 1/4
        case 0x2583: box(ctx, 0, 0, cw, ch * 3 / 8) // ▃ lower 3/8
        case 0x2584: box(ctx, 0, 0, cw, ch / 2) // ▄ lower half
        case 0x2585: box(ctx, 0, 0, cw, ch * 5 / 8) // ▅ lower 5/8
        case 0x2586: box(ctx, 0, 0, cw, ch * 3 / 4) // ▆ lower 3/4
        case 0x2587: box(ctx, 0, 0, cw, ch * 7 / 8) // ▇ lower 7/8
        case 0x2588: box(ctx, 0, 0, cw, ch) // █ full block
        // Left fractional blocks
        case 0x2589: box(ctx, 0, 0, cw * 7 / 8, ch) // ▉ left 7/8
        case 0x258A: box(ctx, 0, 0, cw * 3 / 4, ch) // ▊ left 3/4
        case 0x258B: box(ctx, 0, 0, cw * 5 / 8, ch) // ▋ left 5/8
        case 0x258C: box(ctx, 0, 0, cw / 2, ch) // ▌ left half
        case 0x258D: box(ctx, 0, 0, cw * 3 / 8, ch) // ▍ left 3/8
        case 0x258E: box(ctx, 0, 0, cw / 4, ch) // ▎ left 1/4
        case 0x258F: box(ctx, 0, 0, cw / 8, ch) // ▏ left 1/8
        case 0x2590: box(ctx, cw / 2, 0, cw, ch) // ▐ right half
        // Upper/right 1/8 blocks
        case 0x2594: box(ctx, 0, ch * 7 / 8, cw, ch) // ▔ upper 1/8
        case 0x2595: box(ctx, cw * 7 / 8, 0, cw, ch) // ▕ right 1/8
        // Quadrants
        case 0x2596: box(ctx, 0, 0, cw / 2, ch / 2) // ▖ lower left
        case 0x2597: box(ctx, cw / 2, 0, cw, ch / 2) // ▗ lower right
        case 0x2598: box(ctx, 0, ch / 2, cw / 2, ch) // ▘ upper left
        case 0x2599: // ▙ upper left + lower
            box(ctx, 0, 0, cw, ch / 2)
            box(ctx, 0, ch / 2, cw / 2, ch)
        case 0x259A: // ▚ upper left + lower right
            box(ctx, 0, ch / 2, cw / 2, ch)
            box(ctx, cw / 2, 0, cw, ch / 2)
        case 0x259B: // ▛ upper + lower left
            box(ctx, 0, ch / 2, cw, ch)
            box(ctx, 0, 0, cw / 2, ch / 2)
        case 0x259C: // ▜ upper + lower right
            box(ctx, 0, ch / 2, cw, ch)
            box(ctx, cw / 2, 0, cw, ch / 2)
        case 0x259D: box(ctx, cw / 2, ch / 2, cw, ch) // ▝ upper right
        case 0x259E: // ▞ upper right + lower left
            box(ctx, cw / 2, ch / 2, cw, ch)
            box(ctx, 0, 0, cw / 2, ch / 2)
        case 0x259F: // ▟ upper right + lower
            box(ctx, 0, 0, cw, ch / 2)
            box(ctx, cw / 2, ch / 2, cw, ch)
        default: break
        }
    }

    // MARK: - Shades

    private static func drawShade(
        _ ctx: CGContext, codepoint: UInt32, cw: Int, ch: Int
    ) {
        let alpha: CGFloat =
            switch codepoint {
            case 0x2591: 0.25 // ░ light shade
            case 0x2592: 0.50 // ▒ medium shade
            case 0x2593: 0.75 // ▓ dark shade
            default: 0
            }
        ctx.setFillColor(CGColor(gray: 1, alpha: alpha))
        ctx.fill(CGRect(x: 0, y: 0, width: cw, height: ch))
        ctx.setFillColor(.white) // restore for caller
    }

    // MARK: - Drawing Primitives

    /// Fill a rectangle (integer pixel coordinates).
    private static func box(_ ctx: CGContext, _ x1: Int, _ y1: Int, _ x2: Int, _ y2: Int) {
        guard x2 > x1, y2 > y1 else { return }
        ctx.fill(CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1))
    }

    // MARK: - Codepoint → Lines Mapping

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    /// Maps each box-drawing codepoint to its Lines specification.
    /// Direct port of Ghostty's switch table.
    private static func linesForCodepoint(_ cp: UInt32) -> Lines {
        switch cp {
        case 0x2500: Lines(right: .light, left: .light)
        case 0x2501: Lines(right: .heavy, left: .heavy)
        case 0x2502: Lines(up: .light, down: .light)
        case 0x2503: Lines(up: .heavy, down: .heavy)
        // 0x2504-0x250B are dashes, handled separately
        case 0x250C: Lines(right: .light, down: .light)
        case 0x250D: Lines(right: .heavy, down: .light)
        case 0x250E: Lines(right: .light, down: .heavy)
        case 0x250F: Lines(right: .heavy, down: .heavy)
        case 0x2510: Lines(down: .light, left: .light)
        case 0x2511: Lines(down: .light, left: .heavy)
        case 0x2512: Lines(down: .heavy, left: .light)
        case 0x2513: Lines(down: .heavy, left: .heavy)
        case 0x2514: Lines(up: .light, right: .light)
        case 0x2515: Lines(up: .light, right: .heavy)
        case 0x2516: Lines(up: .heavy, right: .light)
        case 0x2517: Lines(up: .heavy, right: .heavy)
        case 0x2518: Lines(up: .light, left: .light)
        case 0x2519: Lines(up: .light, left: .heavy)
        case 0x251A: Lines(up: .heavy, left: .light)
        case 0x251B: Lines(up: .heavy, left: .heavy)
        case 0x251C: Lines(up: .light, right: .light, down: .light)
        case 0x251D: Lines(up: .light, right: .heavy, down: .light)
        case 0x251E: Lines(up: .heavy, right: .light, down: .light)
        case 0x251F: Lines(up: .light, right: .light, down: .heavy)
        case 0x2520: Lines(up: .heavy, right: .light, down: .heavy)
        case 0x2521: Lines(up: .heavy, right: .heavy, down: .light)
        case 0x2522: Lines(up: .light, right: .heavy, down: .heavy)
        case 0x2523: Lines(up: .heavy, right: .heavy, down: .heavy)
        case 0x2524: Lines(up: .light, down: .light, left: .light)
        case 0x2525: Lines(up: .light, down: .light, left: .heavy)
        case 0x2526: Lines(up: .heavy, down: .light, left: .light)
        case 0x2527: Lines(up: .light, down: .heavy, left: .light)
        case 0x2528: Lines(up: .heavy, down: .heavy, left: .light)
        case 0x2529: Lines(up: .heavy, down: .light, left: .heavy)
        case 0x252A: Lines(up: .light, down: .heavy, left: .heavy)
        case 0x252B: Lines(up: .heavy, down: .heavy, left: .heavy)
        case 0x252C: Lines(right: .light, down: .light, left: .light)
        case 0x252D: Lines(right: .light, down: .light, left: .heavy)
        case 0x252E: Lines(right: .heavy, down: .light, left: .light)
        case 0x252F: Lines(right: .heavy, down: .light, left: .heavy)
        case 0x2530: Lines(right: .light, down: .heavy, left: .light)
        case 0x2531: Lines(right: .light, down: .heavy, left: .heavy)
        case 0x2532: Lines(right: .heavy, down: .heavy, left: .light)
        case 0x2533: Lines(right: .heavy, down: .heavy, left: .heavy)
        case 0x2534: Lines(up: .light, right: .light, left: .light)
        case 0x2535: Lines(up: .light, right: .light, left: .heavy)
        case 0x2536: Lines(up: .light, right: .heavy, left: .light)
        case 0x2537: Lines(up: .light, right: .heavy, left: .heavy)
        case 0x2538: Lines(up: .heavy, right: .light, left: .light)
        case 0x2539: Lines(up: .heavy, right: .light, left: .heavy)
        case 0x253A: Lines(up: .heavy, right: .heavy, left: .light)
        case 0x253B: Lines(up: .heavy, right: .heavy, left: .heavy)
        case 0x253C: Lines(up: .light, right: .light, down: .light, left: .light)
        case 0x253D: Lines(up: .light, right: .light, down: .light, left: .heavy)
        case 0x253E: Lines(up: .light, right: .heavy, down: .light, left: .light)
        case 0x253F: Lines(up: .light, right: .heavy, down: .light, left: .heavy)
        case 0x2540: Lines(up: .heavy, right: .light, down: .light, left: .light)
        case 0x2541: Lines(up: .light, right: .light, down: .heavy, left: .light)
        case 0x2542: Lines(up: .heavy, right: .light, down: .heavy, left: .light)
        case 0x2543: Lines(up: .heavy, right: .light, down: .light, left: .heavy)
        case 0x2544: Lines(up: .heavy, right: .heavy, down: .light, left: .light)
        case 0x2545: Lines(up: .light, right: .light, down: .heavy, left: .heavy)
        case 0x2546: Lines(up: .light, right: .heavy, down: .heavy, left: .light)
        case 0x2547: Lines(up: .heavy, right: .heavy, down: .light, left: .heavy)
        case 0x2548: Lines(up: .light, right: .heavy, down: .heavy, left: .heavy)
        case 0x2549: Lines(up: .heavy, right: .light, down: .heavy, left: .heavy)
        case 0x254A: Lines(up: .heavy, right: .heavy, down: .heavy, left: .light)
        case 0x254B: Lines(up: .heavy, right: .heavy, down: .heavy, left: .heavy)
        // Double lines
        case 0x2550: Lines(right: .double, left: .double)
        case 0x2551: Lines(up: .double, down: .double)
        case 0x2552: Lines(right: .double, down: .light)
        case 0x2553: Lines(right: .light, down: .double)
        case 0x2554: Lines(right: .double, down: .double)
        case 0x2555: Lines(down: .light, left: .double)
        case 0x2556: Lines(down: .double, left: .light)
        case 0x2557: Lines(down: .double, left: .double)
        case 0x2558: Lines(up: .light, right: .double)
        case 0x2559: Lines(up: .double, right: .light)
        case 0x255A: Lines(up: .double, right: .double)
        case 0x255B: Lines(up: .light, left: .double)
        case 0x255C: Lines(up: .double, left: .light)
        case 0x255D: Lines(up: .double, left: .double)
        case 0x255E: Lines(up: .light, right: .double, down: .light)
        case 0x255F: Lines(up: .double, right: .light, down: .double)
        case 0x2560: Lines(up: .double, right: .double, down: .double)
        case 0x2561: Lines(up: .light, down: .light, left: .double)
        case 0x2562: Lines(up: .double, down: .double, left: .light)
        case 0x2563: Lines(up: .double, down: .double, left: .double)
        case 0x2564: Lines(right: .double, down: .light, left: .double)
        case 0x2565: Lines(right: .light, down: .double, left: .light)
        case 0x2566: Lines(right: .double, down: .double, left: .double)
        case 0x2567: Lines(up: .light, right: .double, left: .double)
        case 0x2568: Lines(up: .double, right: .light, left: .light)
        case 0x2569: Lines(up: .double, right: .double, left: .double)
        case 0x256A: Lines(up: .light, right: .double, down: .light, left: .double)
        case 0x256B: Lines(up: .double, right: .light, down: .double, left: .light)
        case 0x256C: Lines(up: .double, right: .double, down: .double, left: .double)
        // Half lines
        case 0x2574: Lines(left: .light)
        case 0x2575: Lines(up: .light)
        case 0x2576: Lines(right: .light)
        case 0x2577: Lines(down: .light)
        case 0x2578: Lines(left: .heavy)
        case 0x2579: Lines(up: .heavy)
        case 0x257A: Lines(right: .heavy)
        case 0x257B: Lines(down: .heavy)
        case 0x257C: Lines(right: .heavy, left: .light)
        case 0x257D: Lines(up: .light, down: .heavy)
        case 0x257E: Lines(right: .light, left: .heavy)
        case 0x257F: Lines(up: .heavy, down: .light)
        default: Lines()
        }
    }
}
