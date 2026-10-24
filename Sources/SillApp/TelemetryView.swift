import AppKit
import SillCore
import SillEditor

/// The telemetry pane: a program's logs as they come, its traces (a waterfall of the selected one's spans) and its
/// metrics (each series' latest value over a sparkline).
final class TelemetryView: NSView, ToolContent {
    enum Tab: String, CaseIterable { case logs = "Logs", traces = "Traces", metrics = "Metrics" }

    let watch: TelemetryWatch
    private(set) var tab: Tab = .logs
    /// Logs at this level or worse.
    private(set) var minimumLevel = 0
    private(set) var selectedTrace = 0
    private var tabFrames: [(Tab, NSRect)] = []
    private var traceFrames: [(Int, NSRect)] = []

    init(watch: TelemetryWatch) {
        self.watch = watch
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    private static let bar: CGFloat = 52, tabs: CGFloat = 40
    private var top: CGFloat { Self.bar + Self.tabs }

    func changed() { needsDisplay = true }

    func select(tab: Tab) {
        self.tab = tab
        needsDisplay = true
    }

    private func text(
        _ string: String,
        _ size: CGFloat = 13,
        _ color: NSColor = Design.text,
        weight: NSFont.Weight = .regular,
        mono: Bool = false
    ) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [
            .font: mono ? EditorFont.metrics.regular : Design.ui(size, weight: weight), .foregroundColor: color,
        ])
    }

    override func draw(_: NSRect) {
        Design.editor.setFill()
        bounds.fill()
        Design.chrome.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: top).fill()
        let title = text("Telemetry", 16, weight: .semibold)
        title.draw(at: NSPoint(x: 20, y: 16))
        let state = watch.processId.map { pid in
            "\(watch.name) · pid \(pid) · " + (watch.run != nil ? "watching" : "ended") +
                " · \(watch.store.logs.count) logs, \(watch.store.spans.count) spans, \(watch.store.series.count) series"
        } ?? "Nothing watched: :SillTelemetry picks a running .NET program"
        text(state, 13, Design.textMuted).draw(at: NSPoint(x: 36 + title.size().width, y: 19))
        tabFrames = []
        var x: CGFloat = 20
        for tab in Tab.allCases {
            let active = tab == self.tab
            let label = text(
                tab.rawValue,
                13,
                active ? Design.text : Design.textMuted,
                weight: active ? .semibold : .regular
            )
            label.draw(at: NSPoint(x: x, y: Self.bar + 10))
            if active {
                Design.accent.setFill()
                NSRect(x: x, y: top - 2, width: label.size().width, height: 2).fill()
            }
            tabFrames.append((tab, NSRect(x: x - 8, y: Self.bar, width: label.size().width + 16, height: Self.tabs)))
            x += label.size().width + 26
        }
        let hint = switch tab {
        case .logs: "1-3 tabs · a all · w warnings · e errors · x stop"
        case .traces: "1-3 tabs · j/k traces · x stop"
        case .metrics: "1-3 tabs · x stop"
        }
        let hintText = text(hint, 11, Design.textFaint)
        hintText.draw(at: NSPoint(x: bounds.width - hintText.size().width - 20, y: Self.bar + 12))
        switch tab {
        case .logs: drawLogs()
        case .traces: drawTraces()
        case .metrics: drawMetrics()
        }
    }

    // MARK: Logs

    private static func levelColor(_ level: Int) -> NSColor {
        level >= 4 ? Design.error : level == 3 ? Design.modified : level == 2 ? Design.textMuted : Design.textFaint
    }

    private func drawLogs() {
        let row = EditorFont.metrics.height + 4
        let fit = max(Int((bounds.height - top - 16) / row), 1)
        let logs = watch.store.logs.filter { $0.level >= minimumLevel }.suffix(fit)
        var y = top + 8
        for log in logs {
            let time = Date(timeIntervalSince1970: log.atMs / 1000).formatted(.dateTime.hour().minute().second())
            text(time, 12, Design.textFaint, mono: true).draw(at: NSPoint(x: 20, y: y + 2))
            text(log.levelName.uppercased(), 11, Self.levelColor(log.level), weight: .semibold).draw(at: NSPoint(
                x: 120,
                y: y + 3
            ))
            let category = log.category.split(separator: ".").last.map(String.init) ?? log.category
            text(category, 12, Design.textMuted).draw(
                with: NSRect(x: 200, y: y + 2, width: 170, height: row),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
            )
            text(log.message, 13, log.level >= 3 ? Self.levelColor(log.level) : Design.text).draw(
                with: NSRect(x: 380, y: y + 1, width: bounds.width - 400, height: row),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
            )
            y += row
        }
    }

    // MARK: Traces

    private func drawTraces() {
        traceFrames = []
        let traces = watch.store.traces
        let list = min(360, bounds.width * 0.32)
        Design.chrome.setFill()
        NSRect(x: 0, y: top, width: list, height: bounds.height - top).fill()
        var y = top + 6
        for (index, trace) in traces.enumerated() {
            guard y + 30 < bounds.height else { break }
            let rect = NSRect(x: 0, y: y, width: list, height: 30)
            if index == selectedTrace {
                Design.selection.setFill()
                rect.fill()
            }
            text(trace.label, 13).draw(
                with: NSRect(x: 16, y: y + 7, width: list - 100, height: 18),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
            )
            let duration = text(
                String(format: "%.1f ms", trace.durationMs),
                12,
                trace.durationMs > 50 ? Design.hot : Design.textMuted,
                mono: true
            )
            duration.draw(at: NSPoint(x: list - duration.size().width - 14, y: y + 7))
            traceFrames.append((index, rect))
            y += 30
        }
        guard let trace = traces[safe: selectedTrace] else { return }
        let left = list + 20, width = bounds.width - list - 40
        y = top + 12
        text(
            "\(trace.label) · \(String(format: "%.1f ms", trace.durationMs)) · \(trace.spans.count) spans",
            14,
            weight: .semibold
        ).draw(at: NSPoint(x: left, y: y))
        y += 30
        let nameWidth = min(300, width * 0.4), barLeft = left + nameWidth + 10, barWidth = width - nameWidth - 10
        for span in trace.spans {
            guard y + 24 < bounds.height else { break }
            let depth = CGFloat(TelemetryStore.depth(of: span, in: trace))
            text(span.name, 12).draw(
                with: NSRect(x: left + depth * 14, y: y + 3, width: nameWidth - depth * 14, height: 18),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
            )
            let start = (span.startMs - trace.startMs) / max(trace.durationMs, 0.001)
            let length = span.durationMs / max(trace.durationMs, 0.001)
            let bar = NSRect(
                x: barLeft + CGFloat(start) * barWidth,
                y: y + 4,
                width: max(CGFloat(length) * barWidth, 2),
                height: 14
            )
            (span.durationMs > 50 ? Design.hot : Design.accent).withAlphaComponent(0.8).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3).fill()
            text(String(format: "%.1f ms", span.durationMs), 11, Design.textMuted).draw(at: NSPoint(
                x: bar.maxX + 6,
                y: y + 4
            ))
            y += 24
        }
    }

    // MARK: Metrics

    private func drawMetrics() {
        let series = watch.store.orderedSeries.map { ($0.name, $0.points) }
        let columns = max(Int((bounds.width - 40) / 300), 1)
        let width = (bounds.width - 40 - CGFloat(columns - 1) * 12) / CGFloat(columns), height: CGFloat = 92
        for (index, (name, points)) in series.enumerated() {
            let x = 20 + CGFloat(index % columns) * (width + 12)
            let y = top + 12 + CGFloat(index / columns) * (height + 12)
            guard y + height < bounds.height else { break }
            let card = NSRect(x: x, y: y, width: width, height: height)
            Design.chrome.setFill()
            NSBezierPath(roundedRect: card, xRadius: 8, yRadius: 8).fill()
            text(name, 11, Design.textMuted).draw(
                with: NSRect(x: x + 12, y: y + 8, width: width - 24, height: 16),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
            )
            let values = points.compactMap(\.value)
            if let last = values.last {
                let unit = points.last?.unit ?? ""
                text(TelemetryStoreFormat.number(last) + (unit.isEmpty ? "" : " " + unit), 16, weight: .semibold)
                    .draw(at: NSPoint(x: x + 12, y: y + 26))
            }
            // The sparkline: the series over what was seen.
            guard values.count > 1, let low = values.min(), let high = values.max() else { continue }
            let line = NSBezierPath()
            let plot = NSRect(x: x + 12, y: y + 54, width: width - 24, height: 28)
            for (offset, value) in values.enumerated() {
                let px = plot.minX + plot.width * CGFloat(offset) / CGFloat(values.count - 1)
                let py = plot.maxY - plot.height * CGFloat(high > low ? (value - low) / (high - low) : 0.5)
                if offset == 0 { line.move(to: NSPoint(x: px, y: py)) } else { line.line(to: NSPoint(x: px, y: py)) }
            }
            Design.accent.setStroke()
            line.lineWidth = 1.5
            line.stroke()
        }
    }

    // MARK: Input

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let (tab, _) = tabFrames.first(where: { $0.1.contains(point) }) { return select(tab: tab) }
        if tab == .traces, let (index, _) = traceFrames.first(where: { $0.1.contains(point) }) {
            selectedTrace = index
            needsDisplay = true
        }
    }

    func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { return false }
        switch event.characters ?? "" {
        case "1": select(tab: .logs)
        case "2": select(tab: .traces)
        case "3": select(tab: .metrics)
        case "a": minimumLevel = 0
        case "w": minimumLevel = 3
        case "e": minimumLevel = 4
        case "j": selectedTrace += 1
        case "k": selectedTrace = max(selectedTrace - 1, 0)
        case "x": watch.stop()
        default: return false
        }
        needsDisplay = true
        return true
    }
}

/// Numbers as the telemetry pane writes them.
enum TelemetryStoreFormat {
    static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(format: "%.4g", value)
    }
}
