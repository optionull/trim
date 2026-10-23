import AppKit
import MessagePack
import SillCore
import SillNvim

/// Tabs per split (board 1): a strip over each editor window's winbar row listing the files opened in that window.
@MainActor
final class SplitTabs {
    private let editor: EditorView
    private let channel: NvimChannel
    private(set) var strips: [Int: SplitTabStrip] = [:]

    init(editor: EditorView, channel: NvimChannel) {
        self.editor = editor
        self.channel = channel
    }

    func update(_ screen: Screen) {
        var shown = Set<Int>()
        for (grid, placement) in screen.placements where placement.kind == .window && !placement.hidden {
            guard let tabs = screen.windowTabs[placement.win], screen.paneRects.allSatisfy({ $0.grid != grid })
            else { continue }
            let strip = strips[placement.win] ?? {
                let strip = SplitTabStrip(channel: channel)
                editor.addSubview(strip)
                strips[placement.win] = strip
                return strip
            }()
            strip.show(tabs, active: screen.cursorWindow == placement.win)
            strip.frame = editor.rect(row: placement.row, col: placement.col, width: placement.width, height: 1)
            strip.isHidden = false
            shown.insert(placement.win)
        }
        for (win, strip) in strips where !shown.contains(win) {
            strip.removeFromSuperview()
            strips[win] = nil
        }
    }
}

final class SplitTabStrip: NSView {
    private let channel: NvimChannel
    private(set) var tabs = WindowTabs(win: 0, current: 0, tabs: [])
    private var active = false
    private var frames: [(tab: WindowTabs.Tab, rect: NSRect, close: NSRect)] = []
    private var hovered: Int?

    init(channel: NvimChannel) {
        self.channel = channel
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func show(_ tabs: WindowTabs, active: Bool) {
        guard tabs != self.tabs || active != self.active else { return }
        self.tabs = tabs
        self.active = active
        needsDisplay = true
    }

    override func draw(_: NSRect) {
        Design.chrome.setFill()
        bounds.fill()
        frames = []
        var x: CGFloat = 0
        for tab in tabs.tabs {
            let current = tab.buffer == tabs.current
            let name = NSAttributedString(string: tab.name, attributes: [
                .font: Design.ui(12), .foregroundColor: current ? Design.text : Design.textMuted,
            ])
            let rect = NSRect(x: x, y: 0, width: ceil(name.size().width) + 58, height: bounds.height)
            if current {
                Design.editor.setFill()
                rect.fill()
                if active {
                    Design.accent.setFill()
                    NSRect(x: rect.minX, y: 0, width: rect.width, height: 2).fill()
                }
            }
            if let icon = NSImage(systemSymbolName: ExplorerView.icon(tab.name), accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))?
                .tinted(ExplorerView.tint(tab.name))
            {
                icon.draw(in: NSRect(
                    x: rect.minX + 12,
                    y: rect.midY - icon.size.height / 2,
                    width: icon.size.width,
                    height: icon.size.height
                ))
            }
            name.draw(at: NSPoint(x: rect.minX + 28, y: rect.midY - name.size().height / 2))
            let close = NSRect(x: rect.maxX - 22, y: rect.midY - 7, width: 14, height: 14)
            if tab.modified, hovered != tab.buffer {
                Design.modified.setFill()
                NSBezierPath(ovalIn: close.insetBy(dx: 3.5, dy: 3.5)).fill()
            } else if current || hovered == tab.buffer {
                let cross = NSAttributedString(string: "×", attributes: [
                    .font: Design.ui(13), .foregroundColor: Design.textMuted,
                ])
                cross.draw(at: NSPoint(x: close.midX - cross.size().width / 2, y: close.midY - cross.size().height / 2))
            }
            Design.border.setFill()
            NSRect(x: rect.maxX - 1, y: 4, width: 1, height: bounds.height - 8).fill()
            frames.append((tab, rect, close))
            x = rect.maxX
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = frames.first(where: { $0.rect.contains(point) }) else { return }
        let args: [MessagePackValue] = [.int(Int64(tabs.win)), .int(Int64(hit.tab.buffer))]
        if hit.close.insetBy(dx: -3, dy: -3).contains(point) {
            Nvim.lua(channel, "require'sill'.close_tab(...)", args)
        } else {
            Nvim.lua(channel, "require'sill'.select_tab(...)", args)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let now = frames.first { $0.rect.contains(point) }?.tab.buffer
        if now != hovered {
            hovered = now
            needsDisplay = true
        }
    }

    override func mouseExited(with _: NSEvent) {
        hovered = nil
        needsDisplay = true
    }
}
