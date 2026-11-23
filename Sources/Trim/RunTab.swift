import AppKit
import SillEditor
import TrimRun

/// The Run pane (a pane and a mode of its own): everything the folder can run, each row saying what kind it is and the
/// file it comes
/// from;
/// Return runs it. The person's own configurations come first, and any entry can be copied into one (`c`) to change its
/// arguments, folder and environment variables in a form; `e` changes one of their own, `d` deletes it, `n` makes a new
/// one.
extension TrimWindowController {
    /// What a highlighted entry will do, in a line or two.
    static func runDetail(_ entry: RunEntry, root: String) -> String {
        var text = entry.command
        let folder = relative(entry.directory, to: root)
        text += "\n" + (folder == root || folder.isEmpty ? "in the folder's root" : "in " + folder)
        if !entry.environment.isEmpty {
            text += "  ·  with " + entry.environment.keys.sorted().joined(separator: ", ")
        }
        if !entry.origin.isEmpty { text += "  ·  from " + entry.origin }
        return text
    }

    nonisolated static func runItems(_ entries: [RunEntry]) -> [PickerItem] {
        entries.map { entry in
            let file = entry.origin.split(separator: " ").first.map(String.init) ?? ""
            return PickerItem(
                id: entry.id + "\t" + entry.command + "\t" + entry.directory, title: entry.title,
                detail: entry.source + " · " + entry.kind.rawValue, glyph: entry.isCustom ? "\u{f005}" : "",
                subtitle: entry.origin,
                file: file
                    .isEmpty ? nil :
                    (file.split(separator: ":").first.map(String.init).map { ($0 as NSString).lastPathComponent })
            )
        }
    }

    /// The tab's list, from the folder as it is now (read off the main thread).
    func reloadRunList() {
        guard runListPane != nil else { return }
        let root = workspace
        Task { [weak self] in
            let entries = await Task.detached { RunEntries.find(in: root) }.value
            guard let self, let pane = runListPane else { return }
            runEntries = Dictionary(
                entries.map { ($0.id + "\t" + $0.command + "\t" + $0.directory, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            // A pill for each origin, with how many it has; those switched off leave the list.
            let off = runSourcesOff
            let counts = Dictionary(grouping: entries, by: \.source).mapValues(\.count)
            let sources = counts.keys.sorted { ($0 == RunConfigs.source ? 0 : 1, $0) < (
                $1 == RunConfigs.source ? 0 : 1,
                $1
            ) }
            pane.chipsView.chips = sources.map { source in
                ListChip(
                    id: source, title: source == RunConfigs.source ? "yours" : source, glyph: "", color: Design.accent,
                    count: counts[source] ?? 0, on: !off.contains(source), key: ""
                )
            }
            pane.needsLayout = true
            let items = Self.runItems(entries.filter { !off.contains($0.source) })
            if pane.list.all != items { pane.list.set(items, current: pane.list.cursor) }
            if let cursor = pane.list.cursor, let entry = runEntries[cursor] {
                pane.setDetail(Self.runDetail(entry, root: root))
            } else {
                pane
                    .setDetail(entries
                        .isEmpty ?
                        "Nothing to run or build was found in this folder: n makes a configuration of your own." :
                        "")
            }
        }
    }

    func configureRunPane(_ pane: RunPaneView) {
        let list = pane.list, root = { [unowned self] in workspace }
        pane.onFocus = { [weak self] in self?.runFocused() }
        pane.onMinimize = { [weak self] in self?.hideRunPane() }
        pane.onRerun = { [weak self] session in self?.runInRunPane(session.entry, replacing: session) }
        pane.onClose = { [weak self, weak pane] session in
            pane?.close(session)
            if self?.modes.surface == .run { self?.focus(.run) }
        }
        pane.chipsView.onToggle = { [weak self] source in
            guard let self else { return }
            if runSourcesOff.contains(source) { runSourcesOff.remove(source) } else { runSourcesOff.insert(source) }
            reloadRunList()
        }
        pane.onNew = { [weak self, weak pane] in
            guard let self, let pane else { return }
            editingConfig = nil
            pane.edit(
                RunConfig(name: RunConfigs.unusedName("My run", among: RunConfigs.load(in: workspace)), command: ""),
                isNew: true
            )
            focus(.run)
        }
        list.onFocus = { [weak self] in self?.runFocused() }
        list.onDismiss = { [weak self] in self?.focusEditor() }
        list.onChoose = { [weak self] item in
            if let entry = self?.runEntries[item.id] { self?.runInRunPane(entry) }
        }
        list.onMove = { [weak self, weak pane] item in
            guard let self, let entry = runEntries[item.id] else { return }
            pane?.setDetail(Self.runDetail(entry, root: root()))
        }
        list.onKey = { [weak self, weak pane] key, item in
            guard let self, let pane else { return false }
            let entry = runEntries[item.id]
            switch key {
            case "c":
                guard let entry else { return false }
                var config = RunConfigs.config(from: entry, in: root())
                config.name = RunConfigs.unusedName(config.name, among: RunConfigs.load(in: root()))
                editingConfig = nil
                pane.edit(config, isNew: true)
            case "e":
                guard let entry, entry.isCustom,
                      RunConfigs.load(in: root()).contains(where: { $0.name == entry.title }),
                      let config = RunConfigs.load(in: root()).first(where: { $0.name == entry.title })
                else { return false }
                editingConfig = config.name
                pane.edit(config, isNew: false)
            case "o":
                // To the output of the last thing run.
                guard let last = pane.sessions.last else { return false }
                pane.select(.session(last.id))
                focus(.run)
                return true
            case "n":
                editingConfig = nil
                pane.edit(
                    RunConfig(name: RunConfigs.unusedName("My run", among: RunConfigs.load(in: root())), command: ""),
                    isNew: true
                )
            case "d":
                guard let entry, entry.isCustom else { return false }
                deleteConfig(named: entry.title)
                return true
            default:
                return false
            }
            focus(.run)
            return true
        }
        pane.form.onCancel = { [weak self, weak pane] in
            pane?.endEditing()
            self?.focus(.run)
        }
        pane.form.onDelete = { [weak self] in
            if let name = self?.editingConfig { self?.deleteConfig(named: name) }
            self?.runListPane?.endEditing()
            self?.focus(.run)
        }
        pane.form.onSave = { [weak self] config, andRun in self?.saveConfig(config, andRun: andRun) }
    }

    /// The form's answer: kept under its name (replacing the one that was being changed), the list made again, and run
    /// if asked.
    func saveConfig(_ config: RunConfig, andRun: Bool) {
        let root = workspace
        var configs = RunConfigs.load(in: root)
        if let editing = editingConfig, let index = configs.firstIndex(where: { $0.name == editing }) {
            configs[index] = config
        } else {
            var fresh = config
            fresh.name = RunConfigs.unusedName(config.name, among: configs)
            configs.append(fresh)
        }
        try? RunConfigs.save(configs, in: root)
        editingConfig = nil
        runListPane?.endEditing()
        reloadRunList()
        if andRun,
           let entry = RunConfigs.entries(in: root)
           .first(where: { $0.title == config.name || $0.title == configs.last?.name })
        {
            runInRunPane(entry)
            focus(.run)
        } else {
            focus(.run)
        }
    }

    func deleteConfig(named name: String) {
        let root = workspace
        try? RunConfigs.save(RunConfigs.load(in: root).filter { $0.name != name }, in: root)
        editingConfig = nil
        reloadRunList()
    }

    /// The Run pane, made when first wanted.
    func ensureRunPane() -> RunPaneView {
        if let pane = runListPane { return pane }
        let pane = RunPaneView(look: tree.look)
        configureRunPane(pane)
        runListPane = pane
        pane.isHidden = true
        view.runView = pane
        return pane
    }

    /// ⇧⌘R, `\rp`: the Run pane (in the slot the build pane has, which steps aside) with the keyboard in its list;
    /// again,
    /// from the pane, back to the code.
    @objc func showRunPicker(_: Any?) {
        let pane = ensureRunPane()
        if !pane.isHidden, modes.surface == .run {
            // From its output the keyboard goes to the list; from the list, back to the code.
            if pane.current != nil {
                pane.select(.list)
                return focus(.run)
            }
            return focusEditor()
        }
        runPane?.isHidden = true
        if modes.surface == .terminal { terminalGone() }
        pane.isHidden = false
        view.needsLayout = true
        reloadRunList()
        focus(.run)
    }

    /// The minimize button: the Run pane goes, the keyboard back in the code.
    func hideRunPane() {
        guard let pane = runListPane, !pane.isHidden else { return }
        let wasFocused = modes.surface == .run
        pane.isHidden = true
        view.needsLayout = true
        if wasFocused {
            runGone()
            focusEditor()
        }
    }
}
