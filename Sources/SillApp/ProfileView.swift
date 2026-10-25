import AppKit
import SillEditor
import SillRender
import SillSidecar

/// The profiler (boards 7 and 8). A .NET run (M6): its CPU profile as a flame graph drawn by level of detail, its hot
/// spots with where they are written, its allocations and collections, and heap snapshots compared as a treemap of
/// growth; each with what an agent is sent, and Send to agent. `:SillProfile synthetic` shows M0's synthetic profile.
final class ProfileView: NSView, ToolContent {
    enum Tab: String, CaseIterable {
        case timeline = "Timeline", callTree = "Call tree", flameGraph = "Flame graph", allocations = "Allocations",
             heapDiff = "Heap diff", compare = "Compare"
    }

    /// Where the run is.
    enum Phase: Equatable {
        case synthetic, building, running(since: Date), reading, done, failed(String)
    }

    private(set) var profile: FlameGraph
    private(set) var phase: Phase = .synthetic
    /// The program profiled.
    private(set) var title = "Synthetic profile"
    private(set) var document: ProfileDocument?
    private(set) var heaps: [HeapDocument] = []
    /// The end of what the program wrote.
    private(set) var output = ""
    /// What is being done now ("taking snapshot #2…").
    var busy: String? {
        didSet { changed() }
    }

    var onSnapshot: (() -> Void)?
    var onStop: (() -> Void)?
    var onAgain: (() -> Void)?
    /// Send to agent: the prompt's first line (the session's title in heed) and the rest.
    var onSendToAgent: ((_ headline: String, _ prompt: String) -> Void)?
    var onOpenSource: ((_ file: String, _ line: Int) -> Void)?
    /// A stretch of the run picked on the CPU over time strip (fractions of it): the controller answers with
    /// `showStretch`.
    var onWithin: ((_ from: Double, _ to: Double) -> Void)?
    /// A heap type selected whose retainers are not read yet: the controller answers with `show(retainers:for:)`.
    var onRetainers: ((_ type: String) -> Void)?

    /// The whole run's profile, while a stretch of it is shown.
    private(set) var whole: ProfileDocument?
    /// The stretch shown, as fractions of the run; nil for all of it.
    private(set) var stretch: (from: Double, to: Double)?
    /// A stretch being dragged out on the strip.
    private var picking: (start: Double, end: Double)?
    /// This run against the program's previous one, when there was one.
    var comparison: ProfileComparison? {
        didSet { changed() }
    }

    /// An agent is profiling (through sill's MCP tools): the bar says so.
    var drivenByAgent = false {
        didSet { changed() }
    }

    /// What keeps each type alive in the last snapshot, as read.
    private(set) var retainers: [String: [Retainer]] = [:]

    private var parents: [Int] = []
    private var names: [String] = []
    private(set) var tab: Tab = .flameGraph
    /// The samples shown, left edge to right edge.
    private(set) var from: Double = 0
    private(set) var to: Double = 0
    private(set) var selected: Int?
    /// The heap type selected in the treemap, by name.
    private(set) var selectedType: String?
    /// The row selected in the tables.
    private(set) var row = 0
    private(set) var blocksDrawn = 0
    private var tabFrames: [(Tab, NSRect)] = []
    private(set) var tiles: [(name: String, rect: NSRect)] = []
    private var dragStart: (x: CGFloat, from: Double, to: Double)?
    private var ticker: Timer?
    private let snapshotButton = OutlineButton(title: "Take snapshot")
    private let stopButton = OutlineButton(title: "Stop")
    private let againButton = OutlineButton(title: "Profile again")
    private let sendButton = PillButton(title: "Send to agent")

    static let bar = PaneBar.height
    static let tabs: CGFloat = 36
    static var header: CGFloat { bar + tabs }
    /// The side panel: 320 points, or a third of a narrow view.
    private var side: CGFloat { min(320, bounds.width * 0.36) }
    static let rowHeight: CGFloat = 20
    private static let tableTop: CGFloat = 70

    /// Plausible frame names for the synthetic profile, as board 7's.
    private static let syntheticNames = [
        "Main", "Kestrel.ProcessRequests", "OrdersController.Create", "OrderService.CreateAsync",
        "DbContext.SaveChangesAsync", "Npgsql.ExecuteReader", "JsonSerializer.Serialize", "Utf8JsonWriter.Write",
        "Pricing.Calculate", "Validate", "GC.Collect", "List.Add", "Dictionary.TryGetValue", "String.Concat",
        "Task.Run", "ThreadPool.Dispatch", "Socket.ReceiveAsync", "Linq.Select", "Linq.Where", "HashCode.Combine",
    ]

    init(profile: FlameGraph = .synthetic(samples: 11_800_000, maxDepth: 64, minSamples: 3, maxChildren: 12)) {
        self.profile = profile
        super.init(frame: .zero)
        show(profile)
        for (button, action) in [
            (snapshotButton, #selector(snapshotClicked)), (stopButton, #selector(stopClicked)),
            (againButton, #selector(againClicked)), (sendButton, #selector(sendClicked)),
        ] {
            button.target = self
            button.action = action
            addSubview(button)
        }
        updateButtons()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    // MARK: The run

    /// The synthetic profile again.
    func showSynthetic() {
        ticker?.invalidate()
        phase = .synthetic
        title = "Synthetic profile"
        document = nil
        heaps = []
        names = []
        show(.synthetic(samples: 11_800_000, maxDepth: 64, minSamples: 3, maxChildren: 12))
        changed()
    }

    /// What recorded the run (".NET · EventPipe", "Rust · samply").
    private(set) var engine = ""
    /// The runtime an agent is told: dotnet, rust, swift.
    private var runtime: String {
        let first = engine.split(separator: " ").first.map(String.init)?.lowercased() ?? "dotnet"
        return first == ".net" ? "dotnet" : first
    }

    /// Whether the run takes heap snapshots (.NET's does).
    private(set) var canSnapshot = true

    /// A run of `name` begins: built first.
    func begin(_ name: String, engine: String, snapshots: Bool) {
        phase = .building
        title = name
        self.engine = engine
        canSnapshot = snapshots
        document = nil
        heaps = []
        output = ""
        selected = nil
        selectedType = nil
        tab = .flameGraph
        changed()
    }

    func running(_ name: String) {
        title = name
        phase = .running(since: Date())
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
        changed()
    }

    func reading() {
        phase = .reading
        ticker?.invalidate()
        changed()
    }

    func append(output text: String) {
        output = String((output + text).suffix(4000))
        needsDisplay = true
    }

    func failed(_ why: String) {
        phase = .failed(why)
        ticker?.invalidate()
        busy = nil
        changed()
    }

    func add(_ heap: HeapDocument) {
        heaps.append(heap)
        retainers = [:]
        selectedType = heap.comparison?.types.first?.name ?? heap.types.first?.name
        tab = .heapDiff
        busy = nil
        if let selectedType { onRetainers?(selectedType) }
    }

    func show(retainers paths: [Retainer], for type: String) {
        retainers[type] = paths
        changed()
    }

    /// A stretch of the run shown in place of all of it; the strip still shows the whole run.
    func showStretch(_ part: ProfileDocument, from: Double, to: Double) {
        let whole = whole ?? document
        show(document: part)
        self.whole = whole
        stretch = (from, to)
        busy = nil
    }

    /// The whole run again.
    func clearStretch() {
        guard let whole, stretch != nil else { return }
        show(document: whole)
        changed()
    }

    /// The CPU profile: the flame graph, its hottest frame selected.
    func finish(_ document: ProfileDocument) {
        phase = .done
        ticker?.invalidate()
        busy = nil
        show(document: document)
        if heaps.count < 2 { tab = .flameGraph }
        changed()
    }

    private func show(document: ProfileDocument) {
        self.document = document
        whole = nil
        stretch = nil
        names = document.names
        show(FlameGraph(preorder: document.preorder))
        // The hottest frame that is the program's own (its source is known), else the hottest: a system library's
        // time is spent on behalf of the code that called it.
        if let hot = document.hotSpots.first(where: { $0.file != nil }) ?? document.hotSpots.first {
            selected = profile.nodes.indices.filter { names[profile.nodes[$0].name] == hot.name }
                .max { profile.nodes[$0].samples < profile.nodes[$1].samples }
        }
    }

    private func show(_ graph: FlameGraph) {
        profile = graph
        from = 0
        to = Double(graph.totalSamples)
        selected = nil
        // Each frame's parent: the nearest frame before it one level up.
        var stack: [Int] = []
        parents = graph.nodes.indices.map { index in
            let depth = graph.nodes[index].depth
            while let last = stack.last, graph.nodes[last].depth >= depth {
                stack.removeLast()
            }
            let parent = stack.last ?? -1
            stack.append(index)
            return parent
        }
    }

    private func changed() {
        updateButtons()
        needsLayout = true
        needsDisplay = true
    }

    var isRecording: Bool {
        if case .running = phase { return true }
        return false
    }

    private var isOver: Bool {
        switch phase {
        case .done, .failed: true
        default: false
        }
    }

    private func updateButtons() {
        snapshotButton.isHidden = !isRecording || !canSnapshot
        stopButton.isHidden = !isRecording
        againButton.isHidden = !isOver
        sendButton.isHidden = agentPayload() == nil
        snapshotButton.isEnabled = busy == nil
    }

    @objc private func snapshotClicked() { if busy == nil { onSnapshot?() } }
    @objc private func stopClicked() { onStop?() }
    @objc private func againClicked() { onAgain?() }
    @objc private func sendClicked() {
        guard let (headline, prompt) = agentPrompt() else { return }
        onSendToAgent?(headline, prompt)
    }

    override func layout() {
        super.layout()
        let frames = buttonFrames()
        for button in [sendButton, againButton, stopButton, snapshotButton] {
            if let frame = frames.first(where: { $0.0 === button })?.1 {
                button.frame = frame
            } else {
                button.frame = .zero
            }
        }
    }

    /// The bar's buttons, right to left from the right edge; in a narrow view, those that do not fit right of the
    /// heading are left out.
    private func buttonFrames() -> [(NSButton, NSRect)] {
        var x = bounds.width - 16
        var frames: [(NSButton, NSRect)] = []
        for button in [sendButton, againButton, stopButton, snapshotButton] where !button.isHidden {
            let size = button.intrinsicContentSize
            guard x - size.width > 150 else { break }
            x -= size.width
            frames.append((
                button,
                NSRect(x: x, y: (Self.bar - size.height) / 2, width: size.width, height: size.height)
            ))
            x -= 10
        }
        return frames
    }

    // MARK: Frames

    func name(_ node: Int) -> String {
        if !names.isEmpty { return names[profile.nodes[node].name] }
        return node == 0 ? "Main" :
            Self.syntheticNames[(profile.nodes[node].name % (Self.syntheticNames.count - 1)) + 1]
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

    /// Where a method is written, if the run found its PDB.
    func source(of method: String) -> (file: String, line: Int)? {
        guard let hot = document?.hotSpots.first(where: { $0.name == method }), let file = hot.file,
              let line = hot.line else { return nil }
        return (file, line)
    }

    private var graphRect: NSRect {
        let top = Self.header + (stripRect == nil ? 0 : Self.strip)
        return NSRect(x: 0, y: top, width: max(bounds.width - side, 100), height: bounds.height - top)
    }

    private static let strip: CGFloat = 104

    /// Board 7's CPU over time, above the flame graph, when the run has samples in time.
    private var stripRect: NSRect? {
        guard tab == .flameGraph, ((whole ?? document)?.timeline?.isEmpty ?? true) == false else { return nil }
        return NSRect(x: 16, y: Self.header + 30, width: max(bounds.width - side, 100) - 32, height: Self.strip - 42)
    }

    /// The strip: samples per stretch of the run as bars, the stretch shown (or being picked) in the accent.
    private func drawStrip(_ rect: NSRect) {
        guard let buckets = (whole ?? document)?.timeline, !buckets.isEmpty else { return }
        let picked = picking.map { (min($0.start, $0.end), max($0.start, $0.end)) } ?? stretch.map { ($0.from, $0.to) }
        attributed("CPU OVER TIME", 11, Design.textMuted, weight: .semibold).draw(at: NSPoint(
            x: rect.minX,
            y: rect.minY - 22
        ))
        let hint = picked == nil ? "drag to look at a stretch" :
            "\(Int((picked!.0 * 100).rounded()))% to \(Int((picked!.1 * 100).rounded()))% of the run · click or 0 for all"
        let hintText = attributed(hint, 11, Design.textFaint)
        hintText.draw(at: NSPoint(x: rect.maxX - hintText.size().width, y: rect.minY - 22))
        Design.chrome.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        let most = CGFloat(buckets.max() ?? 1)
        let width = (rect.width - 16) / CGFloat(buckets.count)
        for (index, count) in buckets.enumerated() where count > 0 {
            let fraction = (Double(index) + 0.5) / Double(buckets.count)
            let inside = picked.map { fraction >= $0.0 && fraction <= $0.1 } ?? false
            (inside ? Design.accent : Design.cool).setFill()
            let height = max((rect.height - 12) * CGFloat(count) / max(most, 1), 1)
            NSRect(
                x: rect.minX + 8 + CGFloat(index) * width,
                y: rect.maxY - 6 - height,
                width: max(width - 1, 1),
                height: height
            ).fill()
        }
    }

    private func stripFraction(_ point: NSPoint, in rect: NSRect) -> Double {
        min(max(Double((point.x - rect.minX - 8) / (rect.width - 16)), 0), 1)
    }

    // MARK: Drawing

    override func draw(_: NSRect) {
        Design.editor.setFill()
        bounds.fill()
        drawBar()
        drawTabs()
        if !isOver, phase != .synthetic {
            return tab == .heapDiff && !heaps.isEmpty ? drawHeap() : drawProgress()
        }
        if case .failed = phase, tab != .heapDiff || heaps.isEmpty { return drawProgress() }
        switch tab {
        case .flameGraph: drawFlameGraph()
        case .callTree: drawCallTree()
        case .allocations: drawAllocations()
        case .timeline: drawTimeline()
        case .heapDiff: drawHeap()
        case .compare: drawCompare()
        }
    }

    private func attributed(
        _ string: String, _ size: CGFloat = 12, _ color: NSColor = Design.text, weight: NSFont.Weight = .regular,
        mono: Bool = false
    ) -> NSAttributedString {
        let font = mono ? EditorFont.font(size, weight) : Design.ui(size, weight: weight)
        return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
    }

    private func drawBar() {
        PaneBar.draw(
            title: tab == .heapDiff ? "Memory" : "CPU profile",
            detail: subtitle,
            right: buttonsLeft,
            in: bounds
        )
    }

    private var buttonsLeft: CGFloat { buttonFrames().map(\.1.minX).min() ?? bounds.width }

    var subtitle: String {
        switch phase {
        case .synthetic:
            return "Synthetic · \(profile.totalSamples.formatted()) samples"
        case .building: return "\(title) · building in Release…"
        case let .running(since):
            let seconds = String(format: "%.1f", Date().timeIntervalSince(since))
            return "\(title) · \(engine) · recording \(seconds) s" + (busy.map { " · \($0)" } ?? "") +
                (drivenByAgent ? " · an agent is profiling" : "")
        case .reading: return "\(title) · reading the trace…"
        case let .failed(why): return "\(title) · \(why)"
        case .done:
            guard let document else { return title }
            let seconds = String(format: "%.1f", document.durationMs / 1000)
            return "\(title) · \(engine) · \(document.samples.formatted()) samples over \(seconds) s" +
                (heaps.isEmpty ? "" : " · \(heaps.count) snapshot\(heaps.count == 1 ? "" : "s")") +
                (drivenByAgent ? " · profiled by an agent" : "")
        }
    }

    private func drawTabs() {
        let tabs = PaneBar.drawTabs(
            Tab.allCases.map(\.rawValue),
            selected: Tab.allCases.firstIndex(of: tab) ?? 0,
            height: Self.tabs,
            in: bounds
        )
        tabFrames = zip(Tab.allCases, tabs.frames).map { ($0, $1) }
        let x = tabs.end
        if phase == .synthetic || phase == .done, tab == .flameGraph {
            let summary = attributed(
                "\(profile.totalSamples.formatted()) samples as \(blocksDrawn.formatted()) blocks", 12,
                Design.textFaint
            )
            if bounds.width - summary.size().width - 16 > x {
                summary.draw(at: NSPoint(
                    x: bounds.width - summary.size().width - 16,
                    y: Self.bar + (Self.tabs - summary.size().height) / 2
                ))
            }
        }
    }

    /// Building, recording, reading or failed: what the program says, and what to do.
    private func drawProgress() {
        var y = Self.header + 28
        let big: String, hint: String
        switch phase {
        case .building: (big, hint) = ("Building \(title)…", "Then it runs under the profiler from its first line.")
        case let .running(since):
            big = "Recording \(title) · \(String(format: "%.1f", Date().timeIntervalSince(since))) s"
            hint = (canSnapshot ? "Take snapshot (s) records the heap; take another later to see what grew. " : "") +
                "Stop (x) ends the recording and shows the CPU profile."
        case .reading: (big, hint) = ("Reading the trace…", "")
        case let .failed(why): (big, hint) = ("The profile failed", why)
        default: (big, hint) = ("", "")
        }
        let heading = attributed(big, 18, weight: .semibold)
        heading.draw(at: NSPoint(x: 24, y: y))
        y += heading.size().height + 8
        let explain = attributed(hint, 13, Design.textMuted)
        let rect = NSRect(x: 24, y: y, width: bounds.width - 48, height: 60)
        explain.draw(with: rect, options: [.usesLineFragmentOrigin])
        y += explain.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin]).height + 20
        if !heaps.isEmpty {
            let taken = heaps.map { "\($0.name): \($0.objects.formatted()) objects, \(bytes($0.bytes))" }
            attributed(taken.joined(separator: "\n"), 12, Design.text).draw(at: NSPoint(x: 24, y: y))
            y += CGFloat(taken.count) * 18 + 16
        }
        guard !output.isEmpty else { return }
        attributed("OUTPUT", 11, Design.textMuted, weight: .semibold).draw(at: NSPoint(x: 24, y: y))
        y += 20
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).suffix(
            max(Int((bounds.height - y) / 16) - 1, 1)
        )
        attributed(lines.joined(separator: "\n"), 11, Design.textMuted, mono: true).draw(
            with: NSRect(x: 24, y: y, width: bounds.width - 48, height: bounds.height - y),
            options: [.usesLineFragmentOrigin]
        )
    }

    private func drawFlameGraph() {
        if let strip = stripRect { drawStrip(strip) }
        let graph = graphRect
        let blocks = profile.blocks(from: from, to: to, pixels: Double(graph.width - 16))
        blocksDrawn = blocks.count
        // Board 7: hot frames have a twentieth of the samples or more to themselves; warm ones lead to a hot one.
        let hot = Set(profile.nodes.indices.filter { selfSamples($0) * 20 >= profile.totalSamples })
        let warm = Set(hot.flatMap { path($0).dropLast() })
        for block in blocks {
            let rect = NSRect(
                x: graph.minX + 8 + CGFloat(block.x),
                y: graph.minY + 12 + CGFloat(block.depth) * Self.rowHeight,
                width: max(CGFloat(block.width) - 1, 1),
                height: Self.rowHeight - 2
            )
            guard rect.minY < graph.maxY else { continue }
            let color: NSColor
            if block.merged {
                color = Design.textFaint.withAlphaComponent(0.5)
            } else if document != nil {
                color = hot.contains(block.node) ? Design.hot : warm.contains(block.node) ? Design.warm : Design.cool
            } else {
                let heat = CGFloat((block.node &* 2_654_435_761) % 1000) / 1000
                color = NSColor(srgbRed: 0.85 + 0.15 * heat, green: 0.35 + 0.45 * heat, blue: 0.18, alpha: 0.9)
            }
            (block.node == selected && !block.merged ? Design.accent : color).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
            if !block.merged, rect.width > 48 {
                let ink = color == Design.cool && block.node != selected ? Design.text : Design.onAccent
                attributed(name(block.node), 11, ink).draw(
                    with: rect.insetBy(dx: 5, dy: 3), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
                )
            }
        }
        drawFrameSide()
    }

    /// The side panel, and lines written down it.
    private final class Side {
        let rect: NSRect
        var y: CGFloat

        init(_ rect: NSRect) {
            self.rect = rect
            y = rect.minY + 18
        }

        func write(_ text: NSAttributedString) {
            let frame = NSRect(x: rect.minX + 18, y: y, width: rect.width - 36, height: 600)
            let height = text.boundingRect(with: frame.size, options: [.usesLineFragmentOrigin]).height
            text.draw(with: frame, options: [.usesLineFragmentOrigin])
            y += ceil(height) + 6
        }
    }

    private func sidePanel() -> Side {
        let panel = NSRect(x: bounds.width - side, y: Self.header, width: side, height: bounds.height - Self.header)
        Design.chrome.setFill()
        panel.fill()
        Design.border.setFill()
        NSRect(x: panel.minX, y: panel.minY, width: 1, height: panel.height).fill()
        return Side(panel)
    }

    private func label(_ side: Side, _ text: String) {
        side.write(attributed(text, 11, Design.textMuted, weight: .semibold))
    }

    private func drawFrameSide() {
        let side = sidePanel()
        label(side, "SELECTED FRAME")
        guard let node = selected else {
            side.write(attributed("Click a frame. Scroll to zoom, drag to pan, 0 for all of it.", 12, Design.textMuted))
            return
        }
        let frame = profile.nodes[node]
        let total = Double(max(profile.totalSamples, 1))
        side.write(attributed(name(node), 15, Design.modified, weight: .semibold, mono: true))
        side.write(attributed(
            "Self time  \(percent(Double(selfSamples(node)) / total))    Total  \(percent(Double(frame.samples) / total))",
            12, Design.textMuted
        ))
        if let document {
            side.write(attributed(
                String(format: "%.1f s on the stack", Double(frame.samples) * document.sampleMs / 1000), 12,
                Design.textMuted
            ))
        }
        side.y += 6
        label(side, "HOT PATH")
        for (index, step) in path(node).suffix(6).enumerated() {
            side.write(attributed((index == 0 ? "" : "↳ ") + name(step), 12, step == node ? Design.hot : Design.text))
        }
        if let source = source(of: name(node)) {
            side.write(attributed(
                "Source \((source.file as NSString).lastPathComponent):\(source.line)",
                12,
                Design.accent
            ))
        }
        side.y += 6
        label(side, "WHAT THE AGENT GETS")
        side.write(attributed(cpuPayload(node), 11, mono: true))
    }

    private func percent(_ fraction: Double) -> String { String(format: "%.1f%%", fraction * 100) }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .memory)
    }

    private func signed(_ delta: Int64) -> String { (delta >= 0 ? "+" : "−") + bytes(abs(delta)) }

    /// Board 7's payload for a frame.
    func cpuPayload(_ node: Int) -> String {
        let total = Double(max(profile.totalSamples, 1))
        var lines = [
            "kind: profile",
            "runtime: \(document == nil ? "dotnet (synthetic)" : runtime)",
            "hot_frame: \(name(node))",
            "self_pct: \(String(format: "%.1f", Double(selfSamples(node)) / total * 100))",
            "total_pct: \(String(format: "%.1f", Double(profile.nodes[node].samples) / total * 100))",
            "path: \(path(node).dropFirst().suffix(4).map(name).joined(separator: " > "))",
        ]
        if let source = source(of: name(node)) { lines.append("file: \(source.file):\(source.line)") }
        lines.append("ask: make this faster without changing what it does")
        return lines.joined(separator: "\n")
    }

    /// The type a heap payload is about: the selected one, else what grew most.
    private var heapSubject: HeapDocument.Delta? {
        guard let comparison = heaps.last?.comparison else { return nil }
        return comparison.types.first { $0.name == selectedType } ?? comparison.types.first
    }

    /// Board 8's payload: what grew between the last two snapshots.
    func heapPayload() -> String? {
        guard let comparison = heaps.last?.comparison, let grew = heapSubject else { return nil }
        let others = comparison.types.filter { $0.name != grew.name && $0.bytesDelta > 0 }.prefix(3)
        return ([
            "kind: heap_diff",
            "compared: \(comparison.title)",
            "top_growth: \(grew.name) \(signed(grew.bytesDelta)) (\(grew.objectsDelta.formatted()) objects, " +
                "\(grew.newObjects.formatted()) new)",
        ] + (retainers[grew.name]?.first.map {
            ["retainer: " + ([$0.root] + $0.steps).joined(separator: " → ")]
        } ?? []) + others.map { "also: \($0.name) \(signed($0.bytesDelta))" } + [
            "ask: find what keeps these alive and bound it, or let them go",
        ]).joined(separator: "\n")
    }

    /// What Send to agent sends now: the heap diff on its tab, else the selected frame.
    func agentPayload() -> String? {
        if tab == .heapDiff { return heapPayload() }
        guard document != nil, let selected else { return nil }
        return cpuPayload(selected)
    }

    func agentPrompt() -> (headline: String, prompt: String)? {
        guard let payload = agentPayload() else { return nil }
        let headline: String
        if tab == .heapDiff, let grew = heapSubject {
            headline = "Stop \(Self.short(Self.shortType(grew.name))) growing"
        } else if let selected {
            headline = "Make \(Self.short(name(selected))) faster"
        } else {
            return nil
        }
        let prompt = "A profile of \(title) found this. Read the code it points at, change it so the problem goes " +
            "without changing what the program does, and build with sill's build tool to check.\n" + payload
        return (headline, prompt)
    }

    /// A method or type name without its parameters, namespace or full stops (heed titles a session up to the
    /// first full stop): `Pricing.Total(int32)` is `Pricing Total`.
    static func short(_ name: String) -> String {
        let bare = name.split(separator: "(").first.map(String.init) ?? name
        return bare.split(separator: ".").suffix(2).joined(separator: " ")
    }

    /// `System.Collections.Generic.List<Order>` as `List<Order>`.
    static func shortType(_ name: String) -> String {
        let generic = name.split(separator: "<", maxSplits: 1)
        let head = generic.first.map { String($0.split(separator: ".").last ?? $0) } ?? name
        return generic.count > 1 ? head + "<" + generic[1] : head
    }

    // MARK: Tables

    private func drawTable(_ columns: [(String, CGFloat)], _ rows: [[String]], hint: String) {
        let left: CGFloat = 24
        attributed(hint, 12, Design.textMuted).draw(at: NSPoint(x: left, y: Self.header + 18))
        var x = left
        for (title, width) in columns {
            attributed(title.uppercased(), 11, Design.textMuted, weight: .semibold)
                .draw(at: NSPoint(x: x, y: Self.header + Self.tableTop - 24))
            x += width
        }
        var y = Self.header + Self.tableTop
        for (index, cells) in rows.enumerated() {
            guard y < bounds.height else { break }
            if index == row {
                Design.selection.setFill()
                NSRect(x: 12, y: y - 3, width: bounds.width - 24, height: 24).fill()
            }
            x = left
            for (column, cell) in cells.enumerated() {
                let width = columns[column].1
                attributed(cell, 12, column == 0 ? Design.text : Design.textMuted, mono: column == 0).draw(
                    with: NSRect(x: x, y: y, width: width - 12, height: 18),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
                )
                x += width
            }
            y += 24
        }
    }

    private func needsRun(_ what: String) {
        attributed("\(what) come with a real run: :SillProfile in a .NET project.", 13, Design.textMuted)
            .draw(at: NSPoint(x: 24, y: Self.header + 24))
    }

    private func drawCallTree() {
        guard let document else { return needsRun("Hot spots") }
        let total = Double(max(document.samples, 1))
        let rows = document.hotSpots.map { hot -> [String] in
            [
                hot.name,
                percent(Double(hot.selfSamples) / total),
                percent(Double(hot.total) / total),
                hot.file.map { "\(($0 as NSString).lastPathComponent):\(hot.line ?? 0)" } ?? hot.module,
            ]
        }
        drawTable(
            [("Method", max(bounds.width - 600, 260)), ("Self", 90), ("Total", 90), ("Source", 380)], rows,
            hint: "The methods the samples found, by their own time. Return opens one's source."
        )
    }

    private func drawAllocations() {
        guard let document else { return needsRun("Allocations") }
        let rows = document.allocations.map { [$0.name, bytes($0.bytes), $0.ticks.formatted()] }
        drawTable(
            [("Type", max(bounds.width - 340, 260)), ("Allocated", 160), ("Samples", 120)], rows,
            hint: "What the run allocated, by type, as the GC's allocation ticks sample it (about every 100 KB)."
        )
    }

    private func drawTimeline() {
        guard let document else { return needsRun("Collections") }
        let rows = document.collections.map {
            [
                "#\($0.number) gen \($0.generation)",
                String(format: "%.1f s", $0.atMs / 1000),
                String(format: "%.2f ms", $0.pauseMs),
                $0.reason,
            ]
        }
        let pauses = document.collections.reduce(0) { $0 + $1.pauseMs }
        drawTable(
            [("Collection", 180), ("At", 120), ("Pause", 120), ("Reason", 300)], rows,
            hint: "\(document.collections.count) garbage collections, \(String(format: "%.1f", pauses)) ms paused " +
                "over \(String(format: "%.1f", document.durationMs / 1000)) s."
        )
    }

    /// This run against the previous one: each function's total and own time before and after, the biggest
    /// change first.
    private func drawCompare() {
        guard let comparison else { return needsRun("Comparison (profile the program twice)") }
        func ms(_ value: Double) -> String { String(format: "%.0f ms", value) }
        func signed(_ value: Double) -> String { (value > 0 ? "+" : "") + ms(value) }
        func share(_ value: Double) -> String { String(format: "%.0f%%", value * 100) }
        let rows = comparison.rows.map { row in
            [
                row.name,
                ms(row.totalBefore),
                ms(row.totalAfter),
                signed(row.totalChange),
                signed(row.selfChange),
                "\(share(row.shareBefore)) → \(share(row.shareAfter))",
            ]
        }
        let change = comparison.cpuAfter - comparison.cpuBefore
        drawTable(
            [("Function", 340), ("Before", 100), ("After", 100), ("Total", 100), ("Own", 100), ("Share of run", 140)],
            rows,
            hint: "This run against the previous one: CPU \(ms(comparison.cpuBefore)) then \(ms(comparison.cpuAfter)) " +
                "(\(signed(change))) over " +
                String(
                    format: "%.1f s then %.1f s",
                    comparison.durationBefore / 1000,
                    comparison.durationAfter / 1000
                ) +
                ". Runs of different lengths compare by their share."
        )
    }

    // MARK: Heap

    private func drawHeap() {
        tiles = []
        guard let last = heaps.last else {
            if !canSnapshot {
                return attributed(
                    "Heap snapshots are for .NET programs: this profile is the CPU's.",
                    13,
                    Design.textMuted
                ).draw(at: NSPoint(x: 24, y: Self.header + 24))
            }
            attributed(
                "No snapshots yet. While a run records, Take snapshot (s); let it work, then take another: the " +
                    "second is compared with the first, object by object.", 13, Design.textMuted
            ).draw(
                with: NSRect(x: 24, y: Self.header + 24, width: graphRect.width - 48, height: 80),
                options: [.usesLineFragmentOrigin]
            )
            return
        }
        let area = graphRect.insetBy(dx: 24, dy: 0)
        let deltas = Dictionary(
            (last.comparison?.types ?? []).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first }
        )
        attributed(
            "HEAP BY SIZE · " + (last.comparison?.title ?? last.name).uppercased(), 11, Design.textMuted,
            weight: .semibold
        ).draw(at: NSPoint(x: area.minX, y: area.minY + 16))
        let legend = attributed("\(last.objects.formatted()) objects · \(bytes(last.bytes))", 12, Design.textFaint)
        if area.width > 640 { legend.draw(at: NSPoint(x: area.maxX - legend.size().width, y: area.minY + 16)) }
        let map = NSRect(x: area.minX, y: area.minY + 44, width: area.width, height: max(area.height - 84, 40))
        let types = Array(last.types.filter { $0.bytes > 0 }.prefix(40))
        let rects = Treemap.squarify(types.map { Double($0.bytes) }, in: map)
        for (type, rect) in zip(types, rects) where rect.width >= 2 && rect.height >= 2 {
            let delta = deltas[type.name]?.bytesDelta ?? 0
            let color = Self.growthColor(delta: delta, of: type.bytes)
            let tile = rect.insetBy(dx: 1, dy: 1)
            color.setFill()
            NSBezierPath(rect: tile).fill()
            if type.name == selectedType {
                Design.accent.setStroke()
                let outline = NSBezierPath(rect: tile.insetBy(dx: 1, dy: 1))
                outline.lineWidth = 2
                outline.stroke()
            }
            tiles.append((type.name, tile))
            guard tile.width > 70, tile.height > 36 else { continue }
            let ink = color == Design.cool ? Design.text : Design.onAccent
            attributed(Self.shortType(type.name), 13, ink, weight: .semibold).draw(
                with: NSRect(x: tile.minX + 10, y: tile.minY + 8, width: tile.width - 20, height: 18),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
            )
            attributed(bytes(type.bytes) + (delta == 0 ? "" : " · " + signed(delta)), 11, ink).draw(
                with: NSRect(x: tile.minX + 10, y: tile.minY + 27, width: tile.width - 20, height: 16),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
            )
        }
        attributed(
            last.comparison == nil ? "Take another snapshot to see what grew since this one." :
                "Orange grew, slate stayed, blue shrank. Click a type.", 12, Design.textFaint
        ).draw(at: NSPoint(x: area.minX, y: map.maxY + 12))
        drawHeapSide(last)
    }

    /// Board 8's colours: hot for a type that grew by a third or more, warm for one that grew, blue for one that
    /// shrank, slate for the same.
    static func growthColor(delta: Int64, of size: Int64) -> NSColor {
        if delta > size / 3, delta > 0 { return Design.hot }
        if delta > size / 20, delta > 0 { return Design.warm }
        if delta < -(size / 20), delta < 0 { return Design.insert }
        return Design.cool
    }

    private func drawHeapSide(_ last: HeapDocument) {
        let side = sidePanel()
        let type = last.types.first { $0.name == selectedType }
        let delta = last.comparison?.types.first { $0.name == selectedType }
        label(side, "SELECTED")
        side.write(attributed(
            selectedType.map(Self.shortType) ?? "Click a type",
            15,
            Design.insert,
            weight: .semibold,
            mono: true
        ))
        if let type {
            side.write(attributed(
                "Instances \(type.count.formatted())    Size \(bytes(type.bytes))",
                12,
                Design.textMuted
            ))
            side.write(attributed("Retained \(bytes(type.retainedBytes))", 12, Design.textMuted))
        }
        if let delta {
            side.write(attributed(
                "Growth \(signed(delta.bytesDelta)) · \(delta.newObjects.formatted()) new, " +
                    "\(delta.deadObjects.formatted()) died", 12, delta.bytesDelta > 0 ? Design.hot : Design.textMuted,
                weight: .semibold
            ))
        }
        if let type = selectedType {
            side.y += 8
            label(side, "WHO KEEPS THEM ALIVE")
            if let paths = retainers[type] {
                if let path = paths.first {
                    side.write(attributed("GC root: " + path.root, 12, Design.textMuted, mono: true))
                    for (index, step) in path.steps.enumerated() {
                        side.write(attributed(
                            "↳ " + Self.shortType(step),
                            12,
                            index == path.steps.count - 1 ? Design.hot : Design.textMuted,
                            mono: true
                        ))
                    }
                    if paths.count > 1 {
                        side.write(attributed(
                            "and \(paths.count - 1) more path\(paths.count == 2 ? "" : "s")",
                            11,
                            Design.textFaint
                        ))
                    }
                } else {
                    side.write(attributed("Nothing keeps them: they go at the next collection.", 12, Design.textFaint))
                }
            } else {
                side.write(attributed("Reading the paths from the GC roots…", 12, Design.textFaint))
            }
        }
        guard let comparison = last.comparison else { return }
        side.y += 8
        let older = heaps.count > 1 ? heaps[heaps.count - 2].name : "the last"
        label(side, "GROWTH, \(older.uppercased()) TO \(last.name.uppercased())")
        let growing = comparison.types.filter { $0.bytesDelta > 0 }.prefix(5)
        let largest = Double(growing.first?.bytesDelta ?? 1)
        for grew in growing {
            let top = side.y
            attributed(Self.shortType(grew.name), 12).draw(
                with: NSRect(x: side.rect.minX + 18, y: top, width: side.rect.width * 0.4, height: 16),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
            )
            let barX = side.rect.minX + 18 + side.rect.width * 0.42
            let width = side.rect.width * 0.24 * CGFloat(Double(grew.bytesDelta) / largest)
            (grew.name == growing.first?.name ? Design.hot : Design.warm).setFill()
            NSRect(x: barX, y: top + 5, width: max(width, 2), height: 7).fill()
            attributed(signed(grew.bytesDelta), 11, Design.textMuted).draw(at: NSPoint(x: barX + width + 6, y: top))
            side.y += 24
        }
        side.y += 8
        if let payload = heapPayload() {
            label(side, "WHAT THE AGENT GETS")
            side.write(attributed(payload, 11, mono: true))
        }
        if let inexact = comparison.inexact { side.write(attributed(inexact, 11, Design.textFaint)) }
    }

    // MARK: Zoom, pan, select

    override func scrollWheel(with event: NSEvent) {
        let graph = graphRect
        let point = convert(event.locationInWindow, from: nil)
        guard tab == .flameGraph, graph.contains(point), profile.totalSamples > 0 else { return }
        let fraction = Double((point.x - graph.minX) / graph.width)
        let anchor = from + (to - from) * fraction
        let zoom = pow(1.01, Double(-event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 1 : 10))
        let span = min(max((to - from) * zoom, 50), Double(profile.totalSamples))
        from = max(anchor - span * fraction, 0)
        to = min(from + span, Double(profile.totalSamples))
        from = to - span
        needsDisplay = true
    }

    /// Zooms to `node`'s samples, as a double click on a frame does.
    func select(_ node: Int, zoom: Bool) {
        selected = node
        if zoom {
            let frame = profile.nodes[node]
            from = Double(frame.start)
            to = Double(frame.start + frame.samples)
        }
        changed()
    }

    func select(tab: Tab) {
        self.tab = tab
        row = 0
        changed()
    }

    func select(type name: String) {
        selectedType = name
        if retainers[name] == nil { onRetainers?(name) }
        changed()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let (tab, _) = tabFrames.first(where: { $0.1.contains(point) }) { return select(tab: tab) }
        switch tab {
        case .heapDiff:
            if let tile = tiles.first(where: { $0.rect.contains(point) }) { select(type: tile.name) }
        case .callTree, .allocations, .timeline, .compare:
            let index = Int(floor((point.y - Self.header - Self.tableTop + 3) / 24))
            guard index >= 0 else { return }
            row = index
            if event.clickCount >= 2 { openRow() }
            needsDisplay = true
        case .flameGraph:
            if let strip = stripRect, strip.insetBy(dx: 0, dy: -4).contains(point) {
                let at = stripFraction(point, in: strip)
                picking = (at, at)
                return needsDisplay = true
            }
            let graph = graphRect
            guard graph.contains(point) else { return }
            dragStart = (point.x, from, to)
            let depth = Int((point.y - graph.minY - 12) / Self.rowHeight)
            let x = point.x - graph.minX - 8
            let block = profile.blocks(from: from, to: to, pixels: Double(graph.width - 16)).first { block in
                block.depth == depth && CGFloat(block.x) <= x && x < CGFloat(block.x + block.width)
            }
            if let block, !block.merged { select(block.node, zoom: event.clickCount >= 2) }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let started = picking, let strip = stripRect {
            picking = (started.start, stripFraction(point, in: strip))
            return needsDisplay = true
        }
        guard let start = dragStart else { return }
        let samplesPerPoint = (start.to - start.from) / Double(graphRect.width)
        let shift = Double(point.x - start.x) * samplesPerPoint
        let span = start.to - start.from
        from = min(max(start.from - shift, 0), Double(profile.totalSamples) - span)
        to = from + span
        needsDisplay = true
    }

    override func mouseUp(with _: NSEvent) {
        dragStart = nil
        guard let picked = picking else { return }
        picking = nil
        // A click is the whole run; a drag, the stretch dragged over.
        if abs(picked.end - picked.start) < 0.01 {
            clearStretch()
        } else {
            pick(from: min(picked.start, picked.end), to: max(picked.start, picked.end))
        }
        needsDisplay = true
    }

    /// Asks for a stretch of the run (fractions of it), as dragging on the strip does.
    func pick(from: Double, to: Double) {
        busy = "reading \(Int((from * 100).rounded()))% to \(Int((to * 100).rounded()))% of the run…"
        onWithin?(from, to)
    }

    private func openRow() {
        guard tab == .callTree, let hot = document?.hotSpots[safe: row], let file = hot.file else { return }
        onOpenSource?(file, hot.line ?? 1)
    }

    /// 1 to 5 pick a tab; s takes a snapshot and x stops while recording; a sends to an agent; j/k and Return in the
    /// tables; 0 shows the whole flame graph again; Escape lets the frame go.
    func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { return false }
        let key = event.charactersIgnoringModifiers ?? ""
        if let number = Int(key), (1 ... Tab.allCases.count).contains(number) {
            select(tab: Tab.allCases[number - 1])
            return true
        }
        switch key {
        case "s" where isRecording && canSnapshot: snapshotClicked()
        case "x" where isRecording: onStop?()
        case "a": sendClicked()
        case "j", String(UnicodeScalar(NSDownArrowFunctionKey)!): row += 1
        case "k", String(UnicodeScalar(NSUpArrowFunctionKey)!): row = max(row - 1, 0)
        case "\r": openRow()
        case "0":
            if stretch != nil { clearStretch() }
            from = 0
            to = Double(profile.totalSamples)
        case "\u{1B}":
            selected = nil
        default:
            return false
        }
        changed()
        return true
    }
}

/// A quiet button with a border, as board 7's Compare snapshot.
final class OutlineButton: NSButton {
    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        focusRingType = .none
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize {
        let size = NSAttributedString(string: title, attributes: [.font: Design.ui(13)]).size()
        return NSSize(width: ceil(size.width) + 26, height: 28)
    }

    override func draw(_: NSRect) {
        (isHighlighted ? Design.selection : Design.popup).setFill()
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        shape.fill()
        Design.border.setStroke()
        shape.stroke()
        let text = NSAttributedString(string: title, attributes: [
            .font: Design.ui(13), .foregroundColor: isEnabled ? Design.text : Design.textFaint,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
