import AppKit
import SillEditor

/// The one header of a tool pane (the map, a trace, the review, the profiler, the packages, telemetry): its title, what
/// it shows (cut to fit, never under anything), and its actions at the right; and the one footer, the keys it takes.
/// Every pane draws these, so they look alike and sit in the same place.
@MainActor
enum PaneBar {
    static let height: CGFloat = 44
    static let footer: CGFloat = 26

    struct Action {
        let id: String
        let title: String
        var primary = false
        var enabled = true
    }

    /// Draws the header across the top of `bounds` (a flipped view), the actions right to left from `right` (where
    /// the pane's own buttons begin, if it has any), and returns where each action was drawn.
    @discardableResult
    static func draw(
        title: String,
        detail: String = "",
        actions: [Action] = [],
        right: CGFloat? = nil,
        in bounds: NSRect
    ) -> [(id: String, rect: NSRect)] {
        Design.chrome.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: height).fill()
        Design.border.setFill()
        NSRect(x: 0, y: height - 1, width: bounds.width, height: 1).fill()
        var frames: [(id: String, rect: NSRect)] = []
        var x = (right ?? bounds.width) - 12
        for action in actions {
            let label = text(
                action.title,
                12,
                !action.enabled ? Design.textFaint : action.primary ? Design.onAccent : Design.text,
                weight: action.primary ? .semibold : .regular
            )
            let rect = NSRect(
                x: x - label.size().width - 24,
                y: (height - 26) / 2,
                width: label.size().width + 24,
                height: 26
            )
            let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 13, yRadius: 13)
            if action.primary, action.enabled {
                Design.accent.setFill()
                shape.fill()
            } else {
                Design.border.setStroke()
                shape.stroke()
            }
            label.draw(at: NSPoint(x: rect.minX + 12, y: rect.midY - label.size().height / 2))
            frames.append((action.id, rect))
            x = rect.minX - 8
        }
        let heading = text(title, 13, Design.text, weight: .semibold)
        heading.draw(at: NSPoint(x: 16, y: (height - heading.size().height) / 2))
        let left = 16 + heading.size().width + 12
        if !detail.isEmpty, x - 8 > left {
            let line = text(detail, 12, Design.textMuted)
            line.drawLine(in: NSRect(
                x: left,
                y: (height - line.size().height) / 2,
                width: x - 8 - left,
                height: line.size().height
            ))
        }
        return frames
    }

    /// Draws a pane's tabs in a strip under the header, `height` tall: the selected one lit and underlined. Returns
    /// where each tab was drawn and where the row ends.
    static func drawTabs(
        _ titles: [String],
        selected: Int,
        height strip: CGFloat,
        in bounds: NSRect
    ) -> (frames: [NSRect], end: CGFloat) {
        Design.chrome.setFill()
        NSRect(x: 0, y: height, width: bounds.width, height: strip).fill()
        Design.border.setFill()
        NSRect(x: 0, y: height + strip - 1, width: bounds.width, height: 1).fill()
        var frames: [NSRect] = []
        var x: CGFloat = 16
        for (index, title) in titles.enumerated() {
            let active = index == selected
            let label = text(title, 12, active ? Design.text : Design.textMuted, weight: active ? .semibold : .regular)
            label.draw(at: NSPoint(x: x, y: height + (strip - label.size().height) / 2))
            if active {
                Design.accent.setFill()
                NSRect(x: x, y: height + strip - 2, width: label.size().width, height: 2).fill()
            }
            frames.append(NSRect(x: x - 8, y: height, width: label.size().width + 16, height: strip))
            x += label.size().width + 24
        }
        return (frames, x)
    }

    /// Draws the keys the pane takes along the bottom of `bounds`, over whatever scrolled under them.
    static func drawKeys(_ keys: String, in bounds: NSRect) {
        let strip = NSRect(x: 0, y: bounds.height - footer, width: bounds.width, height: footer)
        Design.chrome.setFill()
        strip.fill()
        Design.border.setFill()
        NSRect(x: 0, y: strip.minY, width: bounds.width, height: 1).fill()
        let line = text(keys + "  ·  q back", 11, Design.textFaint)
        line.drawLine(in: NSRect(
            x: 16,
            y: strip.midY - line.size().height / 2,
            width: bounds.width - 32,
            height: line.size().height
        ))
    }

    private static func text(
        _ string: String,
        _ size: CGFloat,
        _ color: NSColor,
        weight: NSFont.Weight = .regular
    ) -> NSAttributedString {
        NSAttributedString(
            string: string,
            attributes: [.font: Design.ui(size, weight: weight), .foregroundColor: color]
        )
    }
}

extension NSAttributedString {
    /// One line in `rect`, cut with an ellipsis only when it does not fit: laying a line out to cut it costs
    /// milliseconds a string, and most fit.
    func drawLine(in rect: NSRect) {
        let size = size()
        if size.width <= rect.width {
            draw(at: NSPoint(x: rect.minX, y: rect.minY))
        } else {
            draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }
}
