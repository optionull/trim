import AppKit
import MessagePack
import SillCore
import SillNvim
import TrimModes

/// A control's action as a closure (AppKit wants a target and a selector).
private final class ControlAction: NSObject {
    let run: (NSControl) -> Void
    init(_ run: @escaping (NSControl) -> Void) { self.run = run }
    @objc func fire(_ sender: NSControl) { run(sender) }
}

/// Trim's settings as a window: the same file the person can edit by hand (`~/.config/trim/settings.toml`), changed
/// in place
/// by what is set here, and applied to the running editors at once where it can be (the rest says it needs a restart).
/// Layout
/// choices (where the status bar and tabs are) are the app's own, remembered as they always were.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow!
    private unowned let app: TrimApp
    /// Controls by what they set, so a check (or anything else) can reach them.
    private(set) var controls: [String: NSControl] = [:]
    private var actions: [ControlAction] = []
    private let grid = NSGridView()

    init(app: TrimApp) {
        self.app = app
        super.init()
    }

    private var channel: NvimChannel? { app.active?.session.channel }

    // MARK: Writing

    /// A setting written to the file, and applied to the running editors.
    private func store(_ path: [String], _ value: TOMLValue, live: String? = nil, args: [MessagePackValue] = []) {
        TrimSettings.set(path, to: value)
        guard let live else { return }
        for controller in app.controllers {
            let channel = controller.session.channel
            Task { _ = try? await channel.lua(live, args: args) }
        }
    }

    // MARK: Building

    private func label(_ text: String, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        field.font = .systemFont(ofSize: secondary ? 11 : 13)
        return field
    }

    private func section(_ title: String) {
        let heading = NSTextField(labelWithString: title)
        heading.font = .boldSystemFont(ofSize: 13)
        let row = grid.addRow(with: [heading, NSGridCell.emptyContentView])
        row.topPadding = grid.numberOfRows > 1 ? 14 : 0
        row.mergeCells(in: NSRange(location: 0, length: 2))
        row.cell(at: 0).xPlacement = .leading
    }

    private func row(_ title: String, _ control: NSView, note: String? = nil) {
        var right: NSView = control
        if let note {
            let stack = NSStackView(views: [control, label(note, secondary: true)])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 2
            right = stack
        }
        let name = label(title)
        name.alignment = .right
        grid.addRow(with: [name, right])
    }

    private func make<Control: NSControl>(
        _ key: String,
        _ control: Control,
        _ run: @escaping (NSControl) -> Void
    ) -> Control {
        let action = ControlAction(run)
        actions.append(action)
        control.target = action
        control.action = #selector(ControlAction.fire(_:))
        controls[key] = control
        return control
    }

    private func checkbox(_ key: String, _ title: String, on: Bool, _ run: @escaping (Bool) -> Void) -> NSButton {
        let box = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        box.state = on ? .on : .off
        return make(key, box) { run(($0 as? NSButton)?.state == .on) }
    }

    /// A number with a stepper and its value beside it.
    private func number(
        _ key: String, value: Int, range: ClosedRange<Int>, step: Int = 1, unit: String = "",
        _ run: @escaping (Int) -> Void
    ) -> NSView {
        let stepper = NSStepper()
        stepper.minValue = Double(range.lowerBound)
        stepper.maxValue = Double(range.upperBound)
        stepper.increment = Double(step)
        stepper.integerValue = value
        let shown = label("\(value)\(unit)")
        shown.alignment = .right
        shown.widthAnchor.constraint(equalToConstant: 64).isActive = true
        _ = make(key, stepper) { control in
            let now = control.integerValue
            shown.stringValue = "\(now)\(unit)"
            run(now)
        }
        let stack = NSStackView(views: [shown, stepper])
        stack.spacing = 6
        return stack
    }

    private func popup(
        _ key: String,
        _ titles: [String],
        selected: Int,
        _ run: @escaping (Int) -> Void
    ) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.addItems(withTitles: titles)
        button.selectItem(at: max(0, selected))
        return make(key, button) { run(($0 as? NSPopUpButton)?.indexOfSelectedItem ?? 0) }
    }

    private func button(_ key: String, _ title: String, _ run: @escaping () -> Void) -> NSButton {
        make(key, NSButton(title: title, target: nil, action: nil)) { _ in run() }
    }

    // MARK: The window

    /// Brings the window up (made the first time), filled with what is set now.
    func show() async {
        if window == nil { await build() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() async {
        let channel = channel
        let current = await (try? channel?.lua("return require('trim.options').current()"))?.dictionaryValue ?? [:]
        func integer(
            _ key: String,
            _ fallback: Int
        ) -> Int { current[.string(key)]?.integerValue.map(Int.init) ?? fallback }
        func flag(_ key: String, _ fallback: Bool) -> Bool { current[.string(key)]?.boolValue ?? fallback }
        let schemes = await (try? channel?.lua("return vim.fn.getcompletion('', 'color')"))?.arrayValue?
            .compactMap(\.stringValue) ?? []
        let saved = TrimSettings.load()
        let savedScheme = saved["theme"]?.table?["colorscheme"]?.string
        let shownScheme = await (try? channel?.lua("return vim.g.colors_name or ''"))?.stringValue ?? ""
        let leader = saved["editor"]?.table?["leader"]?.string ?? "\\"
        let delay = saved["whichkey"]?.table?["delay"]?.integer ?? 300

        section("Editor")
        row("Tab width", number("editor.tabwidth", value: integer("tabwidth", 4), range: 1 ... 16) { [self] now in
            store(
                ["editor", "tabwidth"],
                .integer(now),
                live: "require('trim.options').apply({ tabwidth = ... })",
                args: [.int(Int64(now))]
            )
        })
        row("", checkbox("editor.expandtab", "Indent with spaces", on: flag("expandtab", true)) { [self] on in
            store(
                ["editor", "expandtab"],
                .bool(on),
                live: "require('trim.options').apply({ expandtab = ... })",
                args: [.bool(on)]
            )
        })
        row("", checkbox("editor.wrap", "Wrap long lines", on: flag("wrap", false)) { [self] on in
            store(
                ["editor", "wrap"],
                .bool(on),
                live: "require('trim.options').apply({ wrap = ... })",
                args: [.bool(on)]
            )
        })
        row("", checkbox("editor.number", "Line numbers", on: flag("number", true)) { [self] on in
            store(
                ["editor", "number"],
                .bool(on),
                live: "require('trim.options').apply({ number = ... })",
                args: [.bool(on)]
            )
        })
        row(
            "",
            checkbox("editor.relativenumber", "Relative line numbers", on: flag("relativenumber", false)) { [self] on in
                store(
                    ["editor", "relativenumber"],
                    .bool(on),
                    live: "require('trim.options').apply({ relativenumber = ... })",
                    args: [.bool(on)]
                )
            }
        )
        let pixelOn = TrimSettings.load()["editor"]?.table?["pixelscroll"]?.bool ?? true
        row("", checkbox("editor.pixelscroll", "Smooth trackpad scrolling", on: pixelOn) { [self] on in
            store(["editor", "pixelscroll"], .bool(on))
            app.controllers.forEach { $0.editor?.pixelScrolling = on }
        })
        row("Scroll margin", number("editor.scrolloff", value: integer("scrolloff", 0), range: 0 ... 20) { [self] now in
            store(
                ["editor", "scrolloff"],
                .integer(now),
                live: "require('trim.options').apply({ scrolloff = ... })",
                args: [.int(Int64(now))]
            )
        }, note: "Lines kept around the cursor")

        section("Colour")
        let chosen = schemes.firstIndex(of: savedScheme ?? shownScheme) ?? 0
        row("Colour scheme", popup("theme.colorscheme", schemes, selected: chosen) { [self] index in
            guard schemes.indices.contains(index) else { return }
            store(
                ["theme", "colorscheme"],
                .string(schemes[index]),
                live: "pcall(vim.cmd.colorscheme, ...)",
                args: [.string(schemes[index])]
            )
        }, note: "The sidebar, tabs and status bar follow it")

        section("Keys")
        let field = NSTextField(string: leader)
        field.placeholderString = "\\"
        field.widthAnchor.constraint(equalToConstant: 60).isActive = true
        row("Leader", make("editor.leader", field) { [self] control in
            let text = (control as? NSTextField)?.stringValue ?? ""
            guard !text.isEmpty else { return }
            store(["editor", "leader"], .string(String(text.prefix(1))))
        }, note: "The key behind <leader>; from the next start")
        row(
            "Hints appear after",
            number("whichkey.delay", value: delay, range: 0 ... 2000, step: 100, unit: " ms") { [self] now in
                store(["whichkey", "delay"], .integer(now))
            },
            note: "How long which-key waits; from the next start"
        )

        section("Layout")
        let status = PaneLayout.statusPlacement
        row(
            "Status bar",
            popup(
                "layout.status",
                ["Beside the sidebar", "Across the window"],
                selected: status == .editor ? 0 : 1
            ) { [self] index in
                app.setStatusPlacement(index == 0 ? .editor : .window)
            }
        )
        let placements = TabsPlacement.allCases
        row(
            "Tabs",
            popup(
                "layout.tabs",
                placements.map { $0.title },
                selected: placements
                    .firstIndex(of: app.tabsLastShown == .hidden ? .statusbar : PaneLayout.tabsPlacement) ?? 0
            ) { [self] index in
                app.setTabs(placement: placements[index])
            }
        )
        row(
            "Most tabs",
            number("layout.tabsMax", value: app.tabsMax, range: 0 ... 50) { [self] now in app.setTabsMax(now) },
            note: "0 is no limit"
        )
        row("", checkbox("layout.autoclose", "Close tabs never edited past that", on: app.tabsAutoclose) { [self] on in
            app.setTabsAutoclose(on)
        })

        section("Packages and language servers")
        row("", button("packages", "Packages…") { [self] in
            window.orderOut(nil)
            app.active?.showPackages(nil)
        })
        let autostartOn = TrimSettings.load()["lsp"]?.table?["autostart"]?.bool ?? true
        row(
            "",
            checkbox(
                "lsp.autostart",
                "Start language servers from the folder at launch",
                on: autostartOn
            ) { [self] on in
                store(["lsp", "autostart"], .bool(on))
            }
        )
        row("", button("lsp.restart", "Restart language servers") { [self] in
            for controller in app.controllers {
                let channel = controller.session.channel
                Task { _ = try? await channel.lua("vim.cmd('TrimLsp restart')") }
            }
        })

        section("The file")
        row("", button("file", "Open settings.toml") { [self] in
            window.orderOut(nil)
            app.active?.open(file: TrimSettings.file.path, toEditor: true)
        }, note: TrimSettings.file.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))

        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        let content = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            grid.widthAnchor.constraint(greaterThanOrEqualToConstant: 440),
        ])
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false
        )
        window.title = "Settings"
        window.contentView = content
        window.setContentSize(content.fittingSize)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
    }
}
