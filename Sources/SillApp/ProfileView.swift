import AppKit
import SillRender

/// The profiler (boards 7 and 8): a flame graph drawn by level of detail, so a profile of millions of samples stays
/// smooth; the selected frame's self time, calls and hot path; and what an agent would be sent. The profile is the
/// synthetic one until M6 records real ones (EventPipe for .NET, samply, xctrace).
final class ProfileView: NSView, ToolContent {
    enum Tab: String, CaseIterable {
        case timeline = "Timeline", callTree = "Call tree", flameGraph = "Flame graph", allocations = "Allocations",
             heapDiff = "Heap diff"
    }

    let profile: FlameGraph
    private var parents: [Int] = []
    private(set) var tab: Tab = .flameGraph
    /// The samples shown, left edge to right edge.
    private(set) var from: Double = 0
    private(set) var to: Double = 0
    private(set) var selected: Int?
    private(set) var blocksDrawn = 0
    private var tabFrames: [(Tab, NSRect)] = []
    private var dragStart: (x: CGFloat, from: Double, to: Double)?
    static let header: CGFloat = 44
    /// The side panel: 300 points, or a third of a narrow view.
    private var side: CGFloat { min(300, bounds.width * 0.36) }
    static let rowHeight: CGFloat = 20

    /// Plausible frame names for the synthetic profile, as board 7's.
    private static let names = [
        "Main", "Kestrel.ProcessRequests", "OrdersController.Create", "OrderService.CreateAsync",
        "DbContext.SaveChangesAsync", "Npgsql.ExecuteReader", "JsonSerializer.Serialize", "Utf8JsonWriter.Write",
        "Pricing.Calculate", "Validate", "GC.Collect", "List.Add", "Dictionary.TryGetValue", "String.Concat",
        "Task.Run", "ThreadPool.Dispatch", "Socket.ReceiveAsync", "Linq.Select", "Linq.Where", "HashCode.Combine",
    ]

    init(profile: FlameGraph = .synthetic(samples: 11_800_000, maxDepth: 64, minSamples: 3, maxChildren: 12)) {
        self.profile = profile
        super.init(frame: .zero)
        to = Double(profile.totalSamples)
        // Each frame's parent: the nearest frame before it one level up.
        var stack: [Int] = []
        parents = profile.nodes.indices.map { index in
            let depth = profile.nodes[index].depth
            while let last = stack.last, profile.nodes[last].depth >= depth {
                stack.removeLast()
            }
            let parent = stack.last ?? -1
            stack.append(index)
            return parent
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func name(_ node: Int) -> String {
        node == 0 ? "Main" : Self.names[(profile.nodes[node].name % (Self.names.count - 1)) + 1]
    }

    /// A frame's own samples: its samples less its children's.
    func selfSamples(_ node: Int) -> Int {
        let frame = profile.nodes[node]
        var children = 0, child = node + 1
        while child < frame.end {
            children += profile.nodes[child].samples
            child = profile.nodes[child].end
        }
        return frame.samples - children
    }

    /// The frames from the root down to `node`.
    func path(_ node: Int) -> [Int] {
        var path = [node], current = node
        while parents[current] >= 0 {
            current = parents[current]
            path.insert(current, at: 0)
        }
        return path
    }

    private var graphRect: NSRect {
        NSRect(x: 0, y: Self.header, width: max(bounds.width - side, 100), height: bounds.height - Self.header)
    }

    // MARK: Drawing

    override func draw(_: NSRect) {
        Design.editor.setFill()
        bounds.fill()
        drawHeader()
        guard tab == .flameGraph else {
            NSAttributedString(string: "\(tab.rawValue) comes with the profiler itself (M6).", attributes: [
                .font: Design.ui(13), .foregroundColor: Design.textMuted,
            ]).draw(at: NSPoint(x: 24, y: Self.header + 24))
            return
        }
        let graph = graphRect
        let blocks = profile.blocks(from: from, to: to, pixels: Double(graph.width))
        blocksDrawn = blocks.count
        for block in blocks {
            let rect = NSRect(
                x: graph.minX + CGFloat(block.x),
                y: graph.minY + 8 + CGFloat(block.depth) * Self.rowHeight,
                width: max(CGFloat(block.width) - 1, 1),
                height: Self.rowHeight - 2
            )
            guard rect.minY < graph.maxY else { continue }
            let heat = CGFloat((block.node &* 2_654_435_761) % 1000) / 1000
            let color = block.merged ? Design.textFaint.withAlphaComponent(0.5) :
                NSColor(srgbRed: 0.85 + 0.15 * heat, green: 0.35 + 0.45 * heat, blue: 0.18, alpha: 0.9)
            (block.node == selected && !block.merged ? Design.accent : color).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
            if !block.merged, rect.width > 48 {
                NSAttributedString(string: name(block.node), attributes: [
                    .font: Design.ui(11), .foregroundColor: Design.onAccent,
                ]).draw(with: rect.insetBy(dx: 5, dy: 3), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            }
        }
        drawSide()
    }

    private func drawHeader() {
        Design.chrome.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: Self.header).fill()
        tabFrames = []
        var x: CGFloat = 16
        for tab in Tab.allCases {
            let active = tab == self.tab
            let label = NSAttributedString(string: tab.rawValue, attributes: [
                .font: Design.ui(13, weight: active ? .semibold : .regular),
                .foregroundColor: active ? Design.text : Design.textMuted,
            ])
            label.draw(at: NSPoint(x: x, y: (Self.header - label.size().height) / 2))
            if active {
                Design.accent.setFill()
                NSRect(x: x, y: Self.header - 2, width: label.size().width, height: 2).fill()
            }
            tabFrames.append((tab, NSRect(x: x - 8, y: 0, width: label.size().width + 16, height: Self.header)))
            x += label.size().width + 26
        }
        let summary = NSAttributedString(
            string: "Synthetic profile · \(profile.totalSamples.formatted()) samples as \(blocksDrawn.formatted()) blocks",
            attributes: [.font: Design.ui(12), .foregroundColor: Design.textFaint]
        )
        // Where it fits right of the tabs.
        if bounds.width - summary.size().width - 16 > x {
            summary.draw(at: NSPoint(
                x: bounds.width - summary.size().width - 16,
                y: (Self.header - summary.size().height) / 2
            ))
        }
    }

    private func drawSide() {
        let side = NSRect(x: bounds.width - side, y: Self.header, width: side, height: bounds.height - Self.header)
        Design.chrome.setFill()
        side.fill()
        Design.border.setFill()
        NSRect(x: side.minX, y: side.minY, width: 1, height: side.height).fill()
        var y = side.minY + 16
        func text(
            _ string: String,
            size: CGFloat = 12,
            color: NSColor = Design.text,
            weight: NSFont.Weight = .regular,
            mono: Bool = false
        ) {
            let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : Design.ui(
                size,
                weight: weight
            )
            let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
            let rect = NSRect(x: side.minX + 16, y: y, width: side.width - 32, height: 400)
            let height = attributed.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin]).height
            attributed.draw(with: rect, options: [.usesLineFragmentOrigin])
            y += ceil(height) + 6
        }
        guard let node = selected else {
            text("SELECTED FRAME", size: 11, color: Design.textMuted, weight: .semibold)
            text("Click a frame. Scroll to zoom, drag to pan.", color: Design.textMuted)
            return
        }
        let frame = profile.nodes[node]
        let total = Double(profile.totalSamples)
        text("SELECTED FRAME", size: 11, color: Design.textMuted, weight: .semibold)
        text(name(node), size: 15, weight: .semibold)
        text(
            "Self time  \(String(format: "%.1f", Double(selfSamples(node)) / total * 100))%    " +
                "Total  \(String(format: "%.1f", Double(frame.samples) / total * 100))%",
            color: Design.textMuted
        )
        y += 8
        text("HOT PATH", size: 11, color: Design.textMuted, weight: .semibold)
        let path = path(node)
        for (index, step) in path.suffix(6).enumerated() {
            text((index == 0 ? "" : "↳ ") + name(step), color: step == node ? Design.accent : Design.text)
        }
        y += 8
        text("WHAT THE AGENT GETS", size: 11, color: Design.textMuted, weight: .semibold)
        text("""
        kind: profile
        runtime: dotnet (synthetic)
        hot_frame: \(name(node))
        self_pct: \(Int(Double(selfSamples(node)) / total * 100))
        path: \(path.suffix(3).map(name).joined(separator: " > "))
        ask: make this faster
        """, size: 11, color: Design.text, mono: true)
    }

    // MARK: Zoom, pan, select

    override func scrollWheel(with event: NSEvent) {
        let graph = graphRect
        let point = convert(event.locationInWindow, from: nil)
        guard graph.contains(point) else { return }
        let fraction = Double((point.x - graph.minX) / graph.width)
        let anchor = from + (to - from) * fraction
        let zoom = pow(1.01, Double(-event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 1 : 10))
        let span = min(max((to - from) * zoom, 50), Double(profile.totalSamples))
        from = max(anchor - span * fraction, 0)
        to = min(from + span, Double(profile.totalSamples))
        from = to - span
        needsDisplay = true
    }

    /// Zooms to `node`'s samples, as a click on a frame does.
    func select(_ node: Int, zoom: Bool) {
        selected = node
        if zoom {
            let frame = profile.nodes[node]
            from = Double(frame.start)
            to = Double(frame.start + frame.samples)
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let (tab, _) = tabFrames.first(where: { $0.1.contains(point) }) {
            self.tab = tab
            needsDisplay = true
            return
        }
        let graph = graphRect
        guard graph.contains(point) else { return }
        dragStart = (point.x, from, to)
        let depth = Int((point.y - graph.minY - 8) / Self.rowHeight)
        let block = profile.blocks(from: from, to: to, pixels: Double(graph.width)).first { block in
            block.depth == depth && CGFloat(block.x) <= point.x - graph.minX && point.x - graph
                .minX < CGFloat(block.x + block.width)
        }
        if let block, !block.merged { select(block.node, zoom: event.clickCount >= 2) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        let samplesPerPoint = (start.to - start.from) / Double(graphRect.width)
        let shift = Double(point.x - start.x) * samplesPerPoint
        let span = start.to - start.from
        from = min(max(start.from - shift, 0), Double(profile.totalSamples) - span)
        to = from + span
        needsDisplay = true
    }

    override func mouseUp(with _: NSEvent) { dragStart = nil }

    /// 0 shows the whole profile again; Escape lets the frame go.
    func handleKey(_ event: NSEvent) -> Bool {
        switch event.charactersIgnoringModifiers {
        case "0":
            from = 0
            to = Double(profile.totalSamples)
        case "\u{1B}":
            selected = nil
        default:
            return false
        }
        needsDisplay = true
        return true
    }
}
