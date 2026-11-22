import AppKit
import FrameRun

/// The form for one of the person's own run configurations: its name, the command line (the arguments are part of it),
/// the
/// folder it runs in, and its environment variables, a line each. Save keeps it in `.frame/run.json`; Save and Run
/// keeps it
/// and runs it. It is what the Run tab shows while one is being made or changed.
final class RunForm: NSView {
    var look = TreeLook() {
        didSet { apply() }
    }

    let name = NSTextField()
    let command = NSTextField()
    let directory = NSTextField()
    let environment = NSTextView()
    private let environmentScroll = NSScrollView()
    private let origin = NSTextField(labelWithString: "")
    private let save = NSButton(title: "Save", target: nil, action: nil)
    private let saveAndRun = NSButton(title: "Save and run", target: nil, action: nil)
    private let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    private let delete = NSButton(title: "Delete", target: nil, action: nil)
    private var labels: [NSTextField] = []

    /// Called with the configuration as it is now, and whether to run it.
    var onSave: ((RunConfig, Bool) -> Void)?
    var onCancel: (() -> Void)?
    var onDelete: (() -> Void)?
    private(set) var kind = "run"
    private(set) var basedOn: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        for field in [name, command, directory] {
            field.isBordered = true
            field.isBezeled = true
            field.bezelStyle = .roundedBezel
            field.usesSingleLineMode = true
            field.lineBreakMode = .byTruncatingTail
            addSubview(field)
        }
        name.placeholderString = "Name"
        command.placeholderString = "The command line, arguments and all: dotnet run --project src/App -- --port 8080"
        directory.placeholderString = "Where it runs, from the folder's root (empty: the root)"
        environment.isRichText = false
        environment.textContainerInset = NSSize(width: 8, height: 6)
        environment.isAutomaticQuoteSubstitutionEnabled = false
        environment.isAutomaticDashSubstitutionEnabled = false
        environment.isAutomaticTextReplacementEnabled = false
        environment.isVerticallyResizable = true
        environment.autoresizingMask = [.width]
        environmentScroll.documentView = environment
        environmentScroll.hasVerticalScroller = true
        environmentScroll.borderType = .bezelBorder
        addSubview(environmentScroll)
        for text in ["Name", "Command", "Folder", "Environment"] {
            let label = NSTextField(labelWithString: text)
            labels.append(label)
            addSubview(label)
        }
        origin.lineBreakMode = .byTruncatingMiddle
        addSubview(origin)
        for (button, action) in [
            (save, #selector(saved)),
            (saveAndRun, #selector(savedAndRun)),
            (cancel, #selector(cancelled)),
            (delete, #selector(deleted)),
        ] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
            addSubview(button)
        }
        saveAndRun.keyEquivalent = "\r"
        apply()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// Shows a configuration (a copy of what ran, or empty), and where it comes from.
    func show(_ config: RunConfig, isNew: Bool) {
        name.stringValue = config.name
        command.stringValue = config.command
        directory.stringValue = config.directory
        environment.string = RunConfigs.text(of: config.environment)
        kind = config.kind
        basedOn = config.basedOn
        origin.stringValue = (isNew ? "A new configuration" : "Kept in Frame's own folder, not in the project")
            + (config.basedOn.map { ", made from " + $0 } ?? "")
        delete.isHidden = isNew
        needsLayout = true
    }

    /// The configuration as typed.
    var config: RunConfig {
        RunConfig(
            name: name.stringValue.trimmingCharacters(in: .whitespaces), command: command.stringValue,
            directory: directory.stringValue.trimmingCharacters(in: .whitespaces),
            environment: RunConfigs.environment(from: environment.string), kind: kind, basedOn: basedOn
        )
    }

    /// Whether what is typed can be kept: a name and a command.
    var isComplete: Bool { !config.name.isEmpty && !config.command.trimmingCharacters(in: .whitespaces).isEmpty }

    private func apply() {
        for label in labels {
            label.font = look.smallFont
            label.textColor = look.muted
        }
        for field in [name, command, directory] {
            field.font = look.font
        }
        environment.font = look.font
        environment.textColor = look.text
        environment.backgroundColor = look.island
        origin.font = look.smallFont
        origin.textColor = look.faint
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let left: CGFloat = 20, labelWidth: CGFloat = 86, gap: CGFloat = 10
        let fieldX = left + labelWidth, fieldWidth = max(0, bounds.width - fieldX - 20)
        var y: CGFloat = 14
        for (index, field) in [name, command, directory].enumerated() {
            let height: CGFloat = 26
            labels[index].sizeToFit()
            labels[index].frame.origin = NSPoint(x: left, y: y + (height - labels[index].frame.height) / 2)
            field.frame = NSRect(x: fieldX, y: y, width: fieldWidth, height: height)
            y += height + gap
        }
        labels[3].sizeToFit()
        labels[3].frame.origin = NSPoint(x: left, y: y + 4)
        let buttonsHeight: CGFloat = 32
        let envHeight = max(60, bounds.height - y - buttonsHeight - 40)
        environmentScroll.frame = NSRect(x: fieldX, y: y, width: fieldWidth, height: envHeight)
        environment.frame = NSRect(x: 0, y: 0, width: environmentScroll.contentSize.width, height: envHeight)
        y += envHeight + 10
        origin.sizeToFit()
        origin.frame = NSRect(x: fieldX, y: y + 6, width: max(0, fieldWidth - 340), height: origin.frame.height)
        var x = bounds.width - 20
        for button in [saveAndRun, save, cancel, delete] where !button.isHidden {
            button.sizeToFit()
            x -= button.frame.width
            button.frame.origin = NSPoint(x: x, y: y)
            x -= 8
        }
    }

    @objc private func saved() { if isComplete { onSave?(config, false) } }
    @objc private func savedAndRun() { if isComplete { onSave?(config, true) } }
    @objc private func cancelled() { onCancel?() }
    @objc private func deleted() { onDelete?() }

    override func cancelOperation(_: Any?) { onCancel?() }
    var firstField: NSView { name }
}
