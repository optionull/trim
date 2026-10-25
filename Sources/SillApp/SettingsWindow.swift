import AppKit
import SillCore
import SillEditor

/// The settings file and its window (M9). The file is the truth: the window writes one value into it (comments and
/// layout kept) and the watcher reads it back, as it does an edit made by hand. ⌘, opens the window.
@MainActor
final class SettingsController {
    /// `SILL_SETTINGS`, else `~/.config/sill/settings.toml`; none for the checks and the showcase unless they name one,
    /// so a person's settings never change what they measure.
    static let file: URL? = {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["SILL_SETTINGS"] { return URL(fileURLWithPath: path) }
        if environment["SILL_CHECK"] != nil || environment["SILL_SHOWCASE"] != nil || environment["SILL_BENCH"] != nil {
            return nil
        }
        return SettingsLoader.defaultFile(environment)
    }()

    private var watcher: SettingsWatcher?
    private(set) var window: SettingsWindow?
    /// Called on the main thread after the file was read again: what applies at once is applied.
    var onApplied: (() -> Void)?
    /// Opens a file in the editor (the "Open settings.toml" button).
    var onOpenFile: ((String) -> Void)?

    /// Reads the file (writing the commented default the first time) before anything reads a setting, then watches it.
    func start() {
        guard let file = Self.file else { return }
        let watcher = SettingsWatcher(file: file) { source in
            Settings.shared.load(source)
            Task { @MainActor [weak self] in
                EditorFont.load(Settings.shared.current)
                self?.onApplied?()
                self?.window?.refresh()
            }
        }
        Settings.shared.load(watcher.start())
        self.watcher = watcher
    }

    func show() {
        let window = window ?? SettingsWindow(controller: self)
        self.window = window
        window.refresh()
        // Off screen (the checks), the window is built and drawn but not shown.
        if ProcessInfo.processInfo.environment["SILL_OFFSCREEN"] != "1" { window.makeKeyAndOrderFront(nil) }
    }

    /// One setting written to the file.
    func set(_ path: [String], to value: TOMLValue) {
        guard let file = Self.file else { return }
        do {
            try SettingsWatcher.set(path, to: value, in: file)
        } catch {
            window?.show(problem: "settings.toml could not be changed: \(error)")
        }
    }

    func openFile() {
        guard let file = Self.file else { return }
        onOpenFile?(file.path)
    }
}

/// The window: a row per setting, under its section, the control writing the file. A setting the environment sets is
/// shown but not editable; one read only at start says so.
@MainActor
final class SettingsWindow: NSWindow {
    private unowned let controller: SettingsController
    private var refreshers: [() -> Void] = []
    private let problems = NSTextField(wrappingLabelWithString: "")
    /// The controls by key path ("editor.size"), for the self-check.
    private(set) var controls: [String: NSControl] = [:]

    init(controller: SettingsController) {
        self.controller = controller
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        title = "Settings"
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)
        backgroundColor = Design.chrome
        contentView = build()
        center()
    }

    func refresh() {
        for refresh in refreshers {
            refresh()
        }
        let found = Settings.shared.problems
        problems.stringValue = found.isEmpty ? "" :
            "settings.toml: " + found.map(\.description).joined(separator: "; ") +
            (found.contains { $0.path.isEmpty } ? ". Nothing in it is used until that is fixed." :
                ". Those keep their defaults.")
        problems.isHidden = found.isEmpty
    }

    func show(problem: String) {
        problems.stringValue = problem
        problems.isHidden = false
    }

    // MARK: Building

    private func build() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 28, bottom: 24, right: 28)

        problems.textColor = Design.error
        problems.font = Design.ui(12)
        problems.isHidden = true
        stack.addArrangedSubview(problems)

        section("Editor", in: stack)
        let families = Self.monospacedFamilies()
        row("Font", "A monospaced font installed on this Mac.", in: stack) {
            let popup = NSPopUpButton()
            popup.addItems(withTitles: families)
            self.bind(["editor", "font"], popup) { popup.selectItem(withTitle: $0.font) } write: {
                .string(popup.titleOfSelectedItem ?? "")
            }
            return popup
        }
        row("Size", "In points. ⌘+ and ⌘- change it for this session, ⌘0 comes back.", in: stack) {
            self.stepper(["editor", "size"], range: 6 ... 72, step: 1, read: \.size) { .integer(Int($0)) }
        }
        row("Line height", "A multiple of the font's own.", in: stack) {
            self.stepper(["editor", "line_height"], range: 1 ... 2, step: 0.05, read: \.lineHeight) {
                .float(($0 * 100).rounded() / 100)
            }
        }
        row("Smooth scrolling", "Scroll by pixels as the trackpad moves, not a line at a time.", in: stack) {
            self.toggle(["editor", "smooth_scroll"], variable: "SILL_SMOOTH_SCROLL", read: \.smoothScroll)
        }

        section("Window", in: stack)
        row("Chrome", "The explorer, panel, activity and status bars. Applies when sill starts again.", in: stack) {
            self.toggle(["window", "chrome"], variable: "SILL_CHROME", read: \.chrome)
        }

        row("Islands", "The explorer, each window and the panel as rounded panels on a darker canvas.", in: stack) {
            let toggle = NSSwitch()
            self.bind(["window", "islands"], toggle) { toggle.state = $0.islands ? .on : .off } write: {
                .bool(toggle.state == .on)
            }
            return toggle
        }

        section("nvim", in: stack)
        row(
            "Config",
            "Your nvim config after sill's base settings, or sill's alone. Applies when sill starts again.",
            in: stack
        ) {
            let control = NSSegmentedControl(
                labels: ["Yours (~/.config/nvim)", "sill's alone"],
                trackingMode: .selectOne,
                target: nil,
                action: nil
            )
            self.bind(["nvim", "config"], control, variable: "SILL_NVIM_CONFIG") {
                control.selectedSegment = $0.nvimConfig == .yours ? 0 : 1
            } write: {
                .string(control.selectedSegment == 0 ? "yours" : "sill")
            }
            return control
        }

        section("Agents", in: stack)
        row("Agent", "The agent Send to agent starts in a terminal pane.", in: stack) {
            self.field(["agents", "command"], variable: "SILL_AGENT", placeholder: "claude", read: \.agent)
        }
        row("heed's agent", "The agent heed starts when sill hands it work.", in: stack) {
            self.field(["agents", "heed_agent"], variable: "SILL_HEED_AGENT", placeholder: "claude", read: \.heedAgent)
        }
        row("Allowed tools", "sill's tools an agent may use without asking, comma separated: build, …", in: stack) {
            let field = self.textField(placeholder: "none")
            self.bind(["agents", "allow"], field, variable: "SILL_MCP_ALLOW") {
                field.stringValue = $0.agentAllow.joined(separator: ", ")
            } write: {
                .array(field.stringValue.split(separator: ",")
                    .map { .string($0.trimmingCharacters(in: .whitespaces)) }
                    .filter { $0.string?.isEmpty == false })
            }
            return field
        }

        row(
            "Editor context",
            "With each prompt, the agent is told the file, the lines selected last and the basket open.",
            in: stack
        ) {
            let toggle = NSSwitch()
            self.bind(["agents", "editor_context"], toggle) { toggle.state = $0.editorContext ? .on : .off } write: {
                .bool(toggle.state == .on)
            }
            return toggle
        }

        section(".NET and heed", in: stack)
        row("dotnet", "Empty finds it: DOTNET_ROOT, your shell's PATH, the usual places.", in: stack) {
            self.field(["dotnet", "path"], variable: "SILL_DOTNET", placeholder: "found automatically", read: \.dotnet)
        }
        row("heed's socket", "Empty is heed's own place.", in: stack) {
            self.field(["heed", "control"], variable: "HEED_CONTROL", placeholder: "heed's own", read: \.heedControl)
        }

        let open = NSButton(title: "Open settings.toml", target: self, action: #selector(openFile))
        open.bezelStyle = .rounded
        let path = NSTextField(labelWithString: (SettingsController.file?.path ?? "")
            .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        path.textColor = Design.textFaint
        path.font = Design.ui(12)
        let bottom = NSStackView(views: [open, path])
        bottom.spacing = 12
        stack.setCustomSpacing(22, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(bottom)

        let scroll = NSScrollView()
        // The view draws its own background and carries the dark appearance, so a picture of it (the check's) looks
        // as the window does.
        scroll.drawsBackground = true
        scroll.backgroundColor = Design.chrome
        scroll.appearance = NSAppearance(named: .darkAqua)
        scroll.hasVerticalScroller = true
        let document = FlippedView()
        document.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        problems.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -56).isActive = true
        return scroll
    }

    private func section(_ title: String, in stack: NSStackView) {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = Design.ui(11, weight: .semibold)
        label.textColor = Design.textMuted
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(22, after: last) }
        stack.addArrangedSubview(label)
    }

    private func row(_ title: String, _ help: String, in stack: NSStackView, _ control: () -> NSView) {
        let label = NSTextField(labelWithString: title)
        label.font = Design.ui(13)
        label.textColor = Design.text
        label.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let made = control()
        let helpLabel = NSTextField(wrappingLabelWithString: help)
        helpLabel.font = Design.ui(11)
        helpLabel.textColor = Design.textFaint
        let column = NSStackView(views: [made, helpLabel])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 3
        helpLabel.widthAnchor.constraint(equalToConstant: 380).isActive = true
        if made is NSTextField { made.widthAnchor.constraint(equalToConstant: 380).isActive = true }
        let line = NSStackView(views: [label, column])
        line.alignment = .firstBaseline
        line.spacing = 12
        stack.addArrangedSubview(line)
    }

    // MARK: Controls

    /// Ties a control to its key: `read` shows the setting, an action writes `write()`; a variable set in the
    /// environment disables it and says so.
    private func bind(
        _ path: [String],
        _ control: NSControl,
        variable: String? = nil,
        read: @escaping (SillSettings) -> Void,
        write: @escaping () -> TOMLValue
    ) {
        let key = path.joined(separator: ".")
        controls[key] = control
        let action = ControlAction { [weak self] in self?.controller.set(path, to: write()) }
        control.target = action
        control.action = #selector(ControlAction.fire)
        actions.append(action)
        refreshers.append {
            read(Settings.shared.current)
            if let variable, Settings.shared.overridden(variable) {
                control.isEnabled = false
                control.toolTip = "\(variable) is set in the environment sill started with, and wins."
            }
        }
    }

    private var actions: [ControlAction] = []

    private func toggle(_ path: [String], variable: String, read: KeyPath<SillSettings, Bool>) -> NSControl {
        let toggle = NSSwitch()
        bind(path, toggle, variable: variable) { toggle.state = $0[keyPath: read] ? .on : .off } write: {
            .bool(toggle.state == .on)
        }
        return toggle
    }

    private func textField(placeholder: String) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.font = Design.ui(13)
        field.cell?.sendsActionOnEndEditing = true
        return field
    }

    private func field(
        _ path: [String],
        variable: String,
        placeholder: String,
        read: KeyPath<SillSettings, String>
    ) -> NSControl {
        let field = textField(placeholder: placeholder)
        bind(path, field, variable: variable) { field.stringValue = $0[keyPath: read] } write: {
            .string(field.stringValue.trimmingCharacters(in: .whitespaces))
        }
        return field
    }

    /// A number: its value beside a stepper.
    private func stepper(
        _ path: [String],
        range: ClosedRange<Double>,
        step: Double,
        read: KeyPath<SillSettings, Double>,
        write: @escaping (Double) -> TOMLValue
    ) -> NSView {
        let stepper = NSStepper()
        stepper.minValue = range.lowerBound
        stepper.maxValue = range.upperBound
        stepper.increment = step
        stepper.valueWraps = false
        let value = NSTextField(labelWithString: "")
        value.font = Design.ui(13)
        value.textColor = Design.text
        bind(path, stepper) {
            stepper.doubleValue = $0[keyPath: read]
            value.stringValue = Self.format($0[keyPath: read])
        } write: {
            value.stringValue = Self.format(stepper.doubleValue)
            return write(stepper.doubleValue)
        }
        let pair = NSStackView(views: [stepper, value])
        pair.spacing = 8
        return pair
    }

    private static func format(_ number: Double) -> String {
        number == number.rounded() ? String(Int(number)) : String(format: "%g", number)
    }

    /// The installed fixed-pitch families, the configured one first if it is not among them.
    static func monospacedFamilies() -> [String] {
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        var families = Set(names.compactMap { NSFont(name: $0, size: 13)?.familyName })
        families.insert(Settings.shared.current.font)
        return families.filter { !$0.hasPrefix(".") }.sorted()
    }

    @objc private func openFile() { controller.openFile() }
}

/// A control's action as a closure.
private final class ControlAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
