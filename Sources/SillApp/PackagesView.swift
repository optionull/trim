import AppKit
import SillCore
import SillNvim

/// The packages of the open solution (board 3, M9): what the SDK says is vulnerable, outdated and deprecated, worst
/// first, with each one's advisories, how it got into a project, and the updates that edit the files that say its
/// version. Read with the SDK (`dotnet list package`), the advisories' details from osv.dev; nothing runs on the main
/// thread.
@MainActor
final class PackageScanner {
    private let directory: String
    /// The solution (or project) read.
    private(set) var target: String?
    private(set) var report: PackageReport?
    private(set) var checkedAt: Date?
    private(set) var scanning = false
    private(set) var problem: String?
    /// Advisories' details by id, as osv.dev has them.
    private(set) var advisories: [String: Advisory] = [:]
    /// How each package got into its first project, and the file that says its version, read off the main thread.
    private(set) var origins: [String: Origin] = [:]
    var onChange: (() -> Void)?

    struct Origin: Equatable {
        var chain: [String]
        var file: String?
    }

    struct Advisory: Equatable {
        var summary: String
        var fixed: [String]
    }

    init(directory: String) {
        self.directory = directory
    }

    /// The solution in the folder (a .slnx, else a .sln), else the first project file.
    nonisolated static func target(in directory: String) -> String? {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).sorted()
        if let solution = names.first(where: { $0.hasSuffix(".slnx") }) ?? names
            .first(where: { $0.hasSuffix(".sln") })
        {
            return (directory as NSString).appendingPathComponent(solution)
        }
        let walker = FileManager.default.enumerator(atPath: directory)
        while let relative = walker?.nextObject() as? String {
            if relative.contains("/bin/") || relative.contains("/obj/") || relative.hasPrefix(".") { continue }
            if relative.hasSuffix(".csproj") || relative.hasSuffix(".fsproj") {
                return (directory as NSString).appendingPathComponent(relative)
            }
        }
        return nil
    }

    func scan() {
        guard !scanning else { return }
        guard let target = Self.target(in: directory) else {
            problem = "No .NET solution or project in this folder."
            return changed()
        }
        self.target = target
        scanning = true
        problem = nil
        changed()
        let directory = directory
        Task {
            do {
                let restored = try await NativeRecorder.capture(
                    "/usr/bin/env", ["dotnet", "restore", target, "-nologo", "-v", "q"], in: directory
                )
                guard restored.code == 0 else {
                    throw NativeRecorder.RecordFailure.failed("the restore failed: \(restored.output.suffix(300))")
                }
                // The SDK's answers, kept even when it exits with an error over a project it could not read: what it
                // could read is still there.
                func list(_ flags: [String]) async -> Data? {
                    let result = try? await NativeRecorder.capture(
                        "/usr/bin/env", [
                            "dotnet",
                            "list",
                            target,
                            "package",
                            "--include-transitive",
                            "--format",
                            "json",
                        ]
                            + flags, in: directory
                    )
                    guard let data = result?.data,
                          (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["projects"] != nil
                    else { return nil }
                    return data
                }
                async let all = list([])
                async let vulnerable = list(["--vulnerable"])
                async let deprecated = list(["--deprecated"])
                let (a, v, d) = await (all, vulnerable, deprecated)
                guard a != nil else { throw NativeRecorder.RecordFailure.failed("dotnet list package did not answer") }
                // Newer versions from nuget.org's index: the SDK's --outdated fails on many real solutions.
                report = await Task.detached {
                    let read = PackageReport.read(
                        all: a,
                        vulnerable: v,
                        outdated: nil,
                        highestPatch: nil,
                        deprecated: d
                    )
                    return await read.with(versions: Self.versions(of: read.packages.map(\.id)))
                }.value
                problems = PackageReport.problems(in: a)
                origins = [:]
                checkedAt = Date()
            } catch {
                problem = "\(error)"
            }
            scanning = false
            changed()
        }
    }

    /// What the SDK could not read.
    private(set) var problems: [String] = []

    /// Each package's versions, from nuget.org's flat container, a few at a time; a package not there has none.
    nonisolated static func versions(of ids: [String]) async -> [String: [String]] {
        await withTaskGroup(of: (String, [String]).self) { group in
            var found: [String: [String]] = [:]
            var pending = ids.map { $0.lowercased() }[...]
            func next() {
                guard let id = pending.popFirst(),
                      let url = URL(string: "https://api.nuget.org/v3-flatcontainer/\(id)/index.json") else { return }
                group.addTask {
                    guard let (data, response) = try? await URLSession.shared.data(from: url),
                          (response as? HTTPURLResponse)?.statusCode == 200,
                          let versions = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["versions"]
                          as? [String] else { return (id, []) }
                    return (id, versions)
                }
            }
            for _ in 0 ..< 16 {
                next()
            }
            for await (id, versions) in group {
                found[id] = versions
                next()
            }
            return found
        }
    }

    /// An advisory's summary and the versions that fix it, from osv.dev, read once.
    func advisory(_ id: String, for package: String) {
        guard advisories[id] == nil, let url = URL(string: "https://api.osv.dev/v1/vulns/\(id)") else { return }
        advisories[id] = Advisory(summary: "Reading the advisory…", fixed: [])
        Task {
            var advisory = Advisory(summary: "The advisory could not be read.", fixed: [])
            if let (data, _) = try? await URLSession.shared.data(from: url),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                advisory.summary = (root["summary"] as? String) ?? (root["details"] as? String).map {
                    String($0.prefix(240))
                } ?? id
                for affected in (root["affected"] as? [[String: Any]]) ?? [] {
                    guard ((affected["package"] as? [String: Any])?["name"] as? String)?.lowercased() == package
                        .lowercased()
                    else { continue }
                    for range in (affected["ranges"] as? [[String: Any]]) ?? [] {
                        for event in (range["events"] as? [[String: Any]]) ?? [] {
                            if let fixed = event["fixed"] as? String { advisory.fixed.append(fixed) }
                        }
                    }
                }
            }
            advisories[id] = advisory
            changed()
        }
    }

    /// Reads a package's origin once; the view draws it when it is there.
    func origin(of package: PackageReport.Package) {
        guard origins[package.id] == nil, let project = package.projectPaths.first else { return }
        origins[package.id] = Origin(chain: [], file: nil)
        let id = package.id
        Task {
            let origin = await Task.detached {
                Origin(
                    chain: Self.path(to: id, in: project) ?? [id],
                    file: PackageEdit.centralFile(for: project) ?? project
                )
            }.value
            origins[id] = origin
            changed()
        }
    }

    /// How a package got into its first project, from that project's restore.
    nonisolated static func path(to id: String, in project: String) -> [String]? {
        let folder = (project as NSString).deletingLastPathComponent
        let name = ((project as NSString).lastPathComponent as NSString).deletingPathExtension
        var candidates = [(folder as NSString).appendingPathComponent("obj/project.assets.json")]
        // Artifacts output (UseArtifactsOutput): artifacts/obj/<project>/ at the repo's root, wherever that is.
        var up = folder
        while up.count > 1 {
            candidates.append((up as NSString).appendingPathComponent("artifacts/obj/\(name)/project.assets.json"))
            up = (up as NSString).deletingLastPathComponent
        }
        for candidate in candidates {
            if let data = FileManager.default.contents(atPath: candidate) {
                return PackageGraph.path(to: id, assets: data)
            }
        }
        return nil
    }

    private func changed() { onChange?() }
}

/// Board 3: the cards (vulnerable, outdated, deprecated, up to date), the filters, the table and the selected package's
/// panel with its update, an agent's fix and the file that says its version.
final class PackagesView: NSView, ToolContent {
    enum Filter: String, CaseIterable {
        case attention = "Needs attention", vulnerable = "Vulnerable", outdated = "Outdated",
             deprecated = "Deprecated", all = "All"
    }

    let scanner: PackageScanner
    private(set) var filter: Filter = .attention {
        didSet { rows = filtered() }
    }

    private(set) var selected = 0
    private var filterFrames: [(Filter, NSRect)] = []
    private var rowFrames: [(Int, NSRect)] = []
    private var actionFrames: [(String, NSRect)] = []
    /// Update, Ask agent, Open file: what the panel's buttons do.
    var onUpdate: ((PackageReport.Package, String) -> Void)?
    var onUpdateSafe: (([PackageReport.Package]) -> Void)?
    var onAskAgent: ((PackageReport.Package) -> Void)?
    var onOpen: ((String) -> Void)?
    private let refresh = OutlineButton(title: "Refresh")
    private let updateSafe = PillButton(title: "Update security and patches")

    init(scanner: PackageScanner) {
        self.scanner = scanner
        super.init(frame: .zero)
        refresh.target = self
        refresh.action = #selector(refreshClicked)
        updateSafe.target = self
        updateSafe.action = #selector(updateSafeClicked)
        addSubview(refresh)
        addSubview(updateSafe)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    private static let bar: CGFloat = 64
    private static let cards: CGFloat = 112
    private static let chips: CGFloat = 48
    private var top: CGFloat { Self.bar + Self.cards + Self.chips }
    private var side: CGFloat { min(360, bounds.width * 0.32) }
    private let rowHeight: CGFloat = 52

    @objc private func refreshClicked() { scanner.scan() }
    @objc private func updateSafeClicked() { onUpdateSafe?(safe) }

    /// What "Update security and patches" moves: every package with a newer patch, vulnerable or not.
    /// The report's lists, worked out once when it is read, not on every draw.
    private struct Lists {
        var attention: [PackageReport.Package] = []
        var vulnerable: [PackageReport.Package] = []
        var outdated: [PackageReport.Package] = []
        var deprecated: [PackageReport.Package] = []
        var upToDate: [PackageReport.Package] = []
        var safe: [PackageReport.Package] = []

        init() {}

        init(_ report: PackageReport) {
            attention = report.attention
            vulnerable = attention.filter(\.isVulnerable)
            outdated = attention.filter(\.isOutdated)
            deprecated = attention.filter(\.isDeprecated)
            upToDate = report.upToDate
            safe = report.packages.filter { !$0.transitive && $0.safeUpdate != nil }
        }
    }

    private var lists = Lists()
    private var listed: PackageReport?

    var safe: [PackageReport.Package] { lists.safe }

    /// The filtered rows, worked out when the report or the filter changes, not on every draw.
    private(set) var rows: [PackageReport.Package] = []
    /// The first row shown: the table scrolls to keep the selected one in view.
    private var firstRow = 0

    private func filtered() -> [PackageReport.Package] {
        switch filter {
        case .attention: lists.attention
        case .vulnerable: lists.vulnerable
        case .outdated: lists.outdated
        case .deprecated: lists.deprecated
        case .all: lists.attention + lists.upToDate
        }
    }

    var current: PackageReport.Package? { rows.indices.contains(selected) ? rows[selected] : nil }

    override func layout() {
        super.layout()
        updateSafe.title = "Update security and patches (\(safe.count))"
        updateSafe.isHidden = safe.isEmpty
        var x = bounds.width - 24
        for button in [updateSafe, refresh] where !button.isHidden {
            let size = button.intrinsicContentSize
            x -= size.width
            button.frame = NSRect(x: x, y: (Self.bar - size.height) / 2 + 4, width: size.width, height: size.height)
            x -= 12
        }
    }

    // MARK: Drawing

    private func text(
        _ string: String,
        _ size: CGFloat = 13,
        _ color: NSColor = Design.text,
        weight: NSFont.Weight = .regular,
        mono: Bool = false
    ) -> NSAttributedString {
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : Design.ui(size, weight: weight)
        return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
    }

    override func draw(_: NSRect) {
        Design.editor.setFill()
        bounds.fill()
        needsLayout = true
        let heading = text("Packages", 18, weight: .semibold)
        heading.draw(at: NSPoint(x: 28, y: (Self.bar - heading.size().height) / 2 + 4))
        let target = scanner.target.map { ((($0 as NSString).lastPathComponent) as NSString).deletingPathExtension }
        text(target ?? "", 13, Design.textMuted).draw(at: NSPoint(x: 42 + heading.size().width, y: Self.bar / 2 - 4))
        guard let report = scanner.report else {
            let message = scanner.scanning ? "Asking the SDK about every package (a restore first)…" :
                scanner.problem ?? "Refresh reads the solution's packages."
            text(message, 14, Design.textMuted).draw(at: NSPoint(x: 28, y: Self.bar + 24))
            return
        }
        drawCards(report)
        drawChips(report)
        drawTable()
        drawSide()
        let status = scanner.scanning ? "Checking…" : scanner.checkedAt.map {
            "Advisories checked " + (Date().timeIntervalSince($0) < 60 ? "just now" :
                RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()))
        } ?? ""
        let note = scanner.problems.isEmpty ? "" :
            "\(scanner.problems.count) project\(scanner.problems.count == 1 ? "" : "s") not read (\(scanner.problems.first ?? "")) · "
        let footer = text(note + status + " · latest from nuget.org", 11, Design.textFaint)
        footer.draw(at: NSPoint(x: bounds.width - side - footer.size().width - 24, y: bounds.height - 22))
    }

    private func drawCards(_ report: PackageReport) {
        let severities = Dictionary(grouping: lists.vulnerable.compactMap { $0.severity?.lowercased() }, by: { $0 })
            .mapValues(\.count)
        let vulnerableDetail = ["critical", "high", "moderate", "low"].compactMap { severity in
            severities[severity].map { "\($0) \(severity)" }
        }.joined(separator: ", ")
        let changes = Dictionary(grouping: lists.outdated.compactMap(\.change), by: { $0 }).mapValues(\.count)
        let outdatedDetail = [PackageReport.Change.major, .minor, .patch].compactMap { change in
            changes[change].map { "\($0) \(change.rawValue)" }
        }.joined(separator: ", ")
        let cards: [(Int, String, String, NSColor)] = [
            (
                lists.vulnerable.count,
                "Vulnerable",
                vulnerableDetail.isEmpty ? "no advisories" : vulnerableDetail,
                Design.error
            ),
            (
                lists.outdated.count,
                "Outdated",
                outdatedDetail.isEmpty ? "all current" : outdatedDetail,
                Design.modified
            ),
            (
                lists.deprecated.count,
                "Deprecated",
                lists.deprecated.contains { $0.alternative != nil } ?
                    "has a replacement" : "none",
                Design.hot
            ),
            (lists.upToDate.count, "Up to date", "\(report.packages.count) packages in total", Design.accent),
        ]
        let gap: CGFloat = 16
        let width = (bounds.width - 56 - gap * 3) / 4
        for (index, card) in cards.enumerated() {
            let rect = NSRect(x: 28 + CGFloat(index) * (width + gap), y: Self.bar + 8, width: width, height: 92)
            Design.chrome.setFill()
            let shape = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
            shape.fill()
            (index == 0 && card.0 > 0 ? Design.error : Design.border).setStroke()
            shape.lineWidth = 1
            shape.stroke()
            text("\(card.0)", 26, card.0 == 0 && index < 3 ? Design.textFaint : card.3, weight: .semibold)
                .draw(at: NSPoint(x: rect.minX + 18, y: rect.minY + 10))
            text(card.1, 13).draw(at: NSPoint(x: rect.minX + 18, y: rect.minY + 48))
            text(card.2, 12, Design.textMuted).draw(at: NSPoint(x: rect.minX + 18, y: rect.minY + 66))
        }
    }

    private func drawChips(_ report: PackageReport) {
        filterFrames = []
        var x: CGFloat = 28
        let counts: [Filter: Int] = [
            .attention: lists.attention.count, .vulnerable: lists.vulnerable.count,
            .outdated: lists.outdated.count, .deprecated: lists.deprecated.count, .all: report.packages.count,
        ]
        for filter in Filter.allCases {
            let label = text(
                "\(filter.rawValue) (\(counts[filter] ?? 0))",
                13,
                filter == self.filter ? Design.text : Design.textMuted
            )
            let rect = NSRect(x: x, y: Self.bar + Self.cards + 6, width: label.size().width + 32, height: 30)
            let shape = NSBezierPath(roundedRect: rect, xRadius: 15, yRadius: 15)
            if filter == self.filter {
                Design.selection.setFill()
                shape.fill()
                Design.accent.setStroke()
            } else {
                Design.border.setStroke()
            }
            shape.stroke()
            label.draw(at: NSPoint(x: rect.minX + 16, y: rect.midY - label.size().height / 2))
            filterFrames.append((filter, rect))
            x = rect.maxX + 10
        }
        Design.border.setFill()
        NSRect(x: 0, y: top - 1, width: bounds.width, height: 1).fill()
    }

    private func badge(_ string: String, _ color: NSColor, at point: NSPoint, filled: Bool) -> CGFloat {
        let label = text(string, 11, filled ? Design.onAccent : color, weight: .semibold)
        let rect = NSRect(x: point.x, y: point.y, width: label.size().width + 14, height: 20)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        if filled {
            color.setFill()
            shape.fill()
        } else {
            color.setStroke()
            shape.stroke()
        }
        label.draw(at: NSPoint(x: rect.minX + 7, y: rect.midY - label.size().height / 2))
        return rect.width
    }

    private func drawTable() {
        rowFrames = []
        let width = bounds.width - side
        let columns: [(String, CGFloat)] = [
            ("PACKAGE", 28), ("INSTALLED", width * 0.36), ("LATEST", width * 0.36 + 100), (
                "CHANGE",
                width * 0.36 + 200
            ),
            ("STATUS", width * 0.36 + 290),
        ]
        for (title, x) in columns {
            text(title, 11, Design.textMuted, weight: .semibold).draw(at: NSPoint(x: x, y: top + 14))
        }
        var y = top + 40
        for (index, package) in rows.enumerated().dropFirst(firstRow) {
            guard y + rowHeight < bounds.height - 28 else { break }
            let rect = NSRect(x: 0, y: y, width: width, height: rowHeight)
            if index == selected {
                Design.selection.setFill()
                rect.fill()
            }
            if package.needsAttention {
                (package.isVulnerable ? Design.error : package.isDeprecated ? Design.hot : Design.border).setFill()
                NSRect(x: 0, y: y, width: 3, height: rowHeight).fill()
            }
            let midY = rect.midY
            let name = text(package.id, 14)
            name.draw(
                with: NSRect(x: 28, y: midY - 9, width: columns[1].1 - 40, height: 18),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
            )
            if package.transitive {
                _ = badge(
                    "transitive",
                    Design.textFaint,
                    at: NSPoint(
                        x: 28 + min(name.size().width, columns[1].1 - 140) + 10,
                        y: midY - 10
                    ),
                    filled: false
                )
            }
            text(package.installed, 13, package.isVulnerable ? Design.error : Design.text, mono: true)
                .draw(at: NSPoint(x: columns[1].1, y: midY - 8))
            text(package.latest ?? (package.isDeprecated ? "none" : "–"), 13, Design.textMuted, mono: true)
                .draw(at: NSPoint(x: columns[2].1, y: midY - 8))
            if let change = package.change {
                _ = badge(
                    change.rawValue,
                    change == .major ? Design.hot : change == .minor ? Design.warm : Design.accent,
                    at: NSPoint(x: columns[3].1, y: midY - 10),
                    filled: false
                )
            }
            var x = columns[4].1
            if let severity = package.severity {
                x += badge(
                    severity.uppercased(),
                    severity.lowercased() == "critical" ? Design.error : Design.hot,
                    at: NSPoint(x: x, y: midY - 10),
                    filled: true
                ) + 10
                let ids = package.vulnerabilities.map(\.id).joined(separator: ", ")
                text(ids, 12, Design.textMuted).draw(
                    with: NSRect(x: x, y: midY - 8, width: width - x - 16, height: 16),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
                )
            } else if package.isDeprecated {
                x += badge("DEPRECATED", Design.hot, at: NSPoint(x: x, y: midY - 10), filled: false) + 10
                text(
                    package.alternative.map { "use \($0)" } ?? (package.deprecation ?? []).joined(separator: ", "),
                    12,
                    Design.textMuted
                ).draw(at: NSPoint(x: x, y: midY - 8))
            } else if package.isOutdated {
                text("Outdated", 13, Design.textMuted).draw(at: NSPoint(x: x, y: midY - 8))
            } else {
                text("Up to date", 13, Design.textFaint).draw(at: NSPoint(x: x, y: midY - 8))
            }
            rowFrames.append((index, rect))
            y += rowHeight
        }
        if filter == .attention, scanner.report != nil, !lists.upToDate.isEmpty {
            text("\(lists.upToDate.count) up to date, hidden", 12, Design.textFaint).draw(at: NSPoint(x: 28, y: y + 14))
        }
    }

    private func drawSide() {
        actionFrames = []
        let panel = NSRect(x: bounds.width - side, y: top, width: side, height: bounds.height - top)
        Design.chrome.setFill()
        panel.fill()
        Design.border.setFill()
        NSRect(x: panel.minX, y: panel.minY, width: 1, height: panel.height).fill()
        guard let package = current else { return }
        var y = panel.minY + 22
        let x = panel.minX + 24, width = panel.width - 48
        func write(_ string: NSAttributedString, gap: CGFloat = 6) {
            let rect = NSRect(x: x, y: y, width: width, height: 400)
            let height = string.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin]).height
            string.draw(with: rect, options: [.usesLineFragmentOrigin])
            y += ceil(height) + gap
        }
        write(text("SELECTED", 11, Design.textMuted, weight: .semibold))
        write(text(package.id, 18, weight: .semibold))
        let target = update(for: package)
        write(
            text(target.map { "\(package.installed) to \($0)" } ?? package.installed, 13, Design.textMuted, mono: true),
            gap: 16
        )
        for vulnerability in package.vulnerabilities {
            let advisory = scanner.advisories[vulnerability.id]
            let box = NSRect(x: x, y: y, width: width, height: 92)
            Design.error.setStroke()
            NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).stroke()
            let w = badge(
                vulnerability.severity.uppercased(),
                Design.error,
                at: NSPoint(x: x + 14, y: y + 12),
                filled: true
            )
            text(vulnerability.id, 13).draw(at: NSPoint(x: x + 24 + w, y: y + 13))
            let detail = (advisory?.fixed
                .isEmpty == false ? "Fixed in \(advisory!.fixed.joined(separator: ", ")). " : "") +
                (advisory?.summary ?? "")
            text(detail, 12, Design.textMuted).draw(
                with: NSRect(x: x + 14, y: y + 40, width: width - 28, height: 46),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
            )
            actionFrames.append(("advisory:\(vulnerability.advisory)", box))
            y += 104
        }
        if let alternative = package.alternative {
            write(text("Deprecated: use \(alternative) instead.", 13, Design.hot), gap: 14)
        }
        write(text("HOW IT GOT HERE", 11, Design.textMuted, weight: .semibold))
        if package.projectPaths.first != nil {
            let chain = scanner.origins[package.id]?.chain ?? []
            write(text(package.projects.first ?? "", 13))
            for (index, step) in chain.enumerated() {
                write(
                    text(
                        "↳ " + step,
                        13,
                        index == chain.count - 1 ? (package.isVulnerable ? Design.error : Design.accent) :
                            Design.text
                    ),
                    gap: 4
                )
            }
        }
        write(text("Used by \(package.projects.joined(separator: ", "))", 12, Design.textMuted), gap: 20)
        // The actions, at the bottom: update, an agent's fix, the file.
        var bottom = panel.maxY - 20
        let file = scanner.origins[package.id]?.file
        for (title, action, primary) in [
            (file.map { "Open \(($0 as NSString).lastPathComponent)" }, "open", false),
            ("Ask agent to update it and run tests", "agent", false),
            (target.map { "Update to \($0)" }, "update", true),
        ] {
            guard let title else { continue }
            let rect = NSRect(x: x, y: bottom - 44, width: width, height: 44)
            let shape = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
            if primary {
                Design.accent.setFill()
                shape.fill()
            } else {
                Design.border.setStroke()
                shape.stroke()
            }
            let label = text(title, 14, primary ? Design.onAccent : Design.text, weight: primary ? .semibold : .regular)
            label.draw(at: NSPoint(x: rect.midX - label.size().width / 2, y: rect.midY - label.size().height / 2))
            actionFrames.append((action, rect))
            bottom = rect.minY - 12
        }
    }

    /// Where Update takes a package: a vulnerable one to the lowest version that fixes all its advisories when osv.dev
    /// said, else its newest patch, else the newest.
    func update(for package: PackageReport.Package) -> String? {
        if package.isVulnerable {
            let fixes = package.vulnerabilities.compactMap { scanner.advisories[$0.id]?.fixed }
                .compactMap {
                    $0.filter { Version.compare($0, package.installed) > 0 }.min { Version.compare($0, $1) < 0 }
                }
            if fixes.count == package.vulnerabilities.count,
               let highest = fixes.max(by: { Version.compare($0, $1) < 0 })
            {
                return highest
            }
        }
        return package.safeUpdate ?? package.latest
    }

    // MARK: Input

    private var visibleRows: Int { max(1, Int((bounds.height - 28 - top - 40) / rowHeight)) }

    private func select(_ index: Int) {
        selected = max(0, min(index, rows.count - 1))
        firstRow = min(max(firstRow, selected - visibleRows + 1), selected)
        if let package = current {
            scanner.origin(of: package)
            for vulnerability in package.vulnerabilities {
                scanner.advisory(vulnerability.id, for: package.id)
            }
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let (filter, _) = filterFrames.first(where: { $0.1.contains(point) }) {
            self.filter = filter
            return select(0)
        }
        if let (index, _) = rowFrames.first(where: { $0.1.contains(point) }) { return select(index) }
        if let (action, _) = actionFrames.first(where: { $0.1.contains(point) }), let package = current {
            perform(action, package)
        }
    }

    private func perform(_ action: String, _ package: PackageReport.Package) {
        switch action {
        case "update": if let version = update(for: package) { onUpdate?(package, version) }
        case "agent": onAskAgent?(package)
        case "open":
            if let file = scanner.origins[package.id]?.file { onOpen?(file) }
        default:
            if action.hasPrefix("advisory:"), let url = URL(string: String(action.dropFirst("advisory:".count))) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// j/k and the arrows move; 1 to 5 pick a filter; u updates; a asks an agent; r refreshes.
    func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { return false }
        let key = event.charactersIgnoringModifiers ?? ""
        if let number = Int(key), (1 ... Filter.allCases.count).contains(number) {
            filter = Filter.allCases[number - 1]
            select(0)
            return true
        }
        switch key {
        case "j", String(UnicodeScalar(NSDownArrowFunctionKey)!): select(selected + 1)
        case "k", String(UnicodeScalar(NSUpArrowFunctionKey)!): select(selected - 1)
        case "u": if let package = current { perform("update", package) }
        case "a": if let package = current { perform("agent", package) }
        case "r": scanner.scan()
        default: return false
        }
        return true
    }

    /// The first row selected, its advisories asked for: after a scan.
    func scanned() {
        if scanner.report != listed {
            listed = scanner.report
            lists = scanner.report.map(Lists.init) ?? Lists()
        }
        rows = filtered()
        select(min(selected, max(rows.count - 1, 0)))
    }

    override func scrollWheel(with event: NSEvent) {
        let rows = Int((-event.scrollingDeltaY / (event.hasPreciseScrollingDeltas ? rowHeight : 1)).rounded())
        guard rows != 0 else { return }
        firstRow = max(0, min(firstRow + rows, self.rows.count - visibleRows))
        needsDisplay = true
    }
}
