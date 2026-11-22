import AppKit
import FrameModes
import FrameTree
import FrameWorkspaces
import MessagePack
import Metal
import SillAgent
import SillCore
import SillEditor
import SillRender

/// The frame's check (`SILL_FRAME_CHECK=1`, nvim without the person's config): what is typed reaches nvim and comes
/// back as the grid; the window has no title bar's buttons but stays a titled window (macOS rounds those) and moves by
/// its margin; `SILL_CHECK_SHOT` saves a picture of the window, its corners rounded as on screen.
@MainActor
struct FrameCheck {
    let shell: FrameWindowController
    let app: FrameApp

    init(_ shell: FrameWindowController, app: FrameApp) {
        self.shell = shell
        self.app = app
    }

    private func step(_ text: String) {
        print("ok    " + text)
        fflush(stdout)
    }

    private func fail(_ text: String) -> Never {
        print("frame check: FAILED: " + text)
        fflush(stdout)
        exit(1)
    }

    private func wait(_ what: String, _ ready: () -> Bool) async {
        for _ in 0 ..< 500 {
            if ready() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        fail("timed out waiting for " + what)
    }

    /// `wait` for something only nvim can say, asked of it each time.
    private func waitAsync(_ what: String, _ ready: () async -> Bool) async {
        for _ in 0 ..< 250 {
            if await ready() { return }
            try? await Task.sleep(for: .milliseconds(40))
        }
        fail("timed out waiting for " + what)
    }

    func run() async {
        guard let editor = shell.editor, let window = shell.window else { fail("no window") }
        await wait("nvim's grid") { editor.screen.grids[1] != nil }
        shell.session.channel.send(keys: "ihello from the frame<Esc>")
        // Each window is a grid of its own (multigrid): the text is in one of them.
        await wait("the text in the grid") {
            editor.screen.grids.values
                .contains { grid in (0 ..< grid.rows).contains { grid.line($0).contains("hello from the frame") } }
        }
        step("typed keys reach nvim and come back as the grid")
        // The landing page, before anything was opened from the tree: Escape in normal mode is the tree's.
        guard window.firstResponder === editor,
              shell.view.sidebarVisible else { fail("no editor, or no tree, at the start") }
        editor.keyDown(with: key("\u{1B}", code: 53))
        await wait("Escape on the landing page to go to the tree") { window.firstResponder === shell.tree.outline }
        shell.focusEditor()
        step("Escape in normal mode from a fresh editor goes to the tree")
        let hidden = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .allSatisfy { window.standardWindowButton($0)?.isHidden ?? true }
        guard hidden, window.styleMask.contains(.titled), window.titlebarAppearsTransparent,
              window.styleMask.contains(.fullSizeContentView)
        else { fail("no title bar, still a titled window: \(window.styleMask)") }
        guard shell.view.mouseDownCanMoveWindow, shell.view.sidebar.frame.minX == FrameView.margin,
              editor.frame.minY == FrameView.margin
        else { fail("the window's contents inside its margin: \(editor.frame)") }
        step(
            "no title bar or buttons; a titled window (rounded by macOS) that moves by its \(Int(FrameView.margin))-point margin"
        )
        // All of it by default; `SILL_FRAME_CHECK_ONLY=tabs,scroll` runs those groups alone (what was touched), each
        // timed.
        let only = ProcessInfo.processInfo.environment["SILL_FRAME_CHECK_ONLY"].map {
            Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        }
        func group(_ name: String, _ body: () async -> Void) async {
            guard only?.contains(name) ?? true else { return }
            let began = Date()
            await body()
            print(String(format: "time  %-8@ %.1fs", name as NSString, Date().timeIntervalSince(began)))
            fflush(stdout)
        }
        await group("tree") { await treeSteps() }
        await group("focus") { await focusSteps() }
        await group("forward") { await forwardSteps() }
        await group("layout") { await layoutSteps() }
        await group("isolation") { await isolationSteps() }
        await group("status") { await statusSteps() }
        await group("tabs") { await tabsSteps() }
        await group("scroll") { await scrollSteps() }
        await group("theme") { await themeSteps() }
        await group("whichkey") { await whichKeySteps() }
        await group("lsp") { await lspSteps() }
        await group("finder") { await finderSteps() }
        await group("windows") { await windowSteps() }
        await group("switcher") { await switcherSteps() }
        if let path = ProcessInfo.processInfo.environment["SILL_CHECK_SHOT"] {
            do {
                try shot(editor: editor, to: path)
                step("saved \(path)")
            } catch {
                fail("the shot: \(error)")
            }
        }
        print("frame check: passed")
        fflush(stdout)
        exit(0)
    }

    private func git(_ folder: String, _ arguments: String...) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", folder, "-c", "user.name=check", "-c", "user.email=check@example.com"] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { fail("git: \(error)") }
        process.waitUntilExit()
        if process.terminationStatus != 0 { fail("git \(arguments.joined(separator: " ")) failed") }
    }

    private func key(
        _ characters: String, code: UInt16 = 0, flags: NSEvent.ModifierFlags = [], plain: String? = nil
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: shell.window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: plain ?? characters, isARepeat: false,
            keyCode: code
        )!
    }

    /// The tree beside the grid: what a folder holds in order, git's marks, the files changing under it, and the way to
    /// and from the editor, against a real repository.
    private func treeSteps() async {
        guard let tree = shell.tree else { fail("no tree") }
        guard NerdFont.register() else { fail("the icon font is not there (scripts/fonts.sh makes Vendor/fonts)") }
        let missing = FileIcons.all.filter { !NerdFont.has($0.glyph) }
        guard missing.isEmpty else {
            fail(
                "icons whose glyph is not in the font: \(missing.map { String(format: "%X", $0.glyph.unicodeScalars.first!.value) })"
            )
        }
        step("every icon is a glyph of the bundled Nerd Font")
        let manager = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory() + "frame-tree-\(UUID().uuidString)")
        try? manager.createDirectory(at: base, withIntermediateDirectories: true)
        let folder = RealPath.of(base.path)
        for (path, text) in [
            ("src/Order.cs", "class Order {}\n"), ("src/Util.swift", "let x = 1\n"), ("docs/guide.md", "# Guide\n"),
            ("README.md", "readme\n"), (".gitignore", "ignored.txt\n"),
        ] {
            let url = URL(fileURLWithPath: folder + "/" + path)
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        git(folder, "init", "-q", "-b", "main")
        git(folder, "add", ".")
        git(folder, "commit", "-q", "-m", "first")
        try? "nobody reads this\n".write(toFile: folder + "/ignored.txt", atomically: true, encoding: .utf8)
        let channel = shell.session.channel
        for command in ["%bwipeout!", "cd " + folder] {
            do { _ = try await channel.command(command) } catch { fail("\(command): \(error)") }
        }
        await wait("the tree to follow nvim's folder") { tree.rootPath == folder }
        func names() -> [String] { tree.visibleNodes.map(\.name) }
        await wait("the folder's entries, and what git ignores") {
            names().contains("README.md") && tree.tree?.git.ignored.isEmpty == false
        }
        let top = names()
        guard Array(top.prefix(2)) == ["docs", "src"], Set(top) == ["docs", "src", ".gitignore", "README.md"] else {
            fail("the rows are folders first, without git's folder or what git ignores: \(top)")
        }
        step("a folder's entries: folders first, git's folder and the ignored files left out")
        func cell(_ name: String) -> TreeCellView? {
            guard let row = tree.visibleNodes.firstIndex(where: { $0.name == name }) else { return nil }
            return tree.outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? TreeCellView
        }
        guard cell("README.md")?.icon
            .stringValue == String(FileIcons.icon(name: "README.md", isDirectory: false).glyph),
            cell("src")?.icon.stringValue == String(FileIcons.folder.glyph)
        else { fail("the rows' icons: \(cell("README.md")?.icon.stringValue ?? "none")") }
        // The editor's own font, row height and colours, and a colour scheme change followed as it comes.
        guard let readme = cell(".gitignore"), let sidebar = shell.view.sidebar as SidebarView?,
              let editor = shell.editor
        else { fail("no row to look at") }
        let grid = EditorFont.metrics.regular
        guard readme.name.font?.familyName == grid.familyName, readme.name.font?.pointSize == CGFloat(EditorFont.size),
              tree.outline.rowHeight == max(ceil(EditorFont.metrics.height), 20)
        else {
            fail(
                "the tree is not in the editor's font: \(readme.name.font?.fontName ?? "none"), the grid's is \(grid.fontName)"
            )
        }
        step("the tree is in the editor's font and size, a row a line of the grid")
        func expected(_ background: Int, _ foreground: Int) -> TreePalette {
            TreePalette(background: background, foreground: foreground, selection: tree.themeSelection)
        }
        let scheme = (editor.screen.defaultBackground, editor.screen.defaultForeground)
        guard sidebar.look.palette == expected(scheme.0, scheme.1)
        else { fail("the sidebar is not in the editor's colours") }
        do { _ = try await channel.command("highlight Normal guibg=#102030 guifg=#e0e0d0") } catch {
            fail("highlight: \(error)")
        }
        await wait("the sidebar to follow the colour scheme") { sidebar.look.palette == expected(0x102030, 0xE0E0D0) }
        guard sidebar.look.palette.sidebar == TreePalette.mix(0x102030, 0, TreePalette.darkShade),
              sidebar.look.palette.sidebar != 0x102030,
              cell(".gitignore")?.name.textColor == NSColor(frameRGB: 0xE0E0D0)
        else { fail("the sidebar's colours after the change: \(String(sidebar.look.palette.sidebar, radix: 16))") }
        // A which-key.nvim window (its WhichKeyNormal group) is in the sidebar's colour, and stays so when the colour
        // scheme
        // is applied again, which resets the groups.
        func windowColour() async -> Int64? {
            await (try? channel.lua("return vim.api.nvim_get_hl(0, { name = 'WhichKeyNormal' }).bg"))?.integerValue
        }
        await waitAsync("which-key.nvim's window to take the sidebar's colour") {
            await windowColour() == Int64(sidebar.look.palette.sidebar)
        }
        _ = try? await channel.command("highlight clear WhichKeyNormal")
        _ = try? await channel.command("doautocmd ColorScheme")
        await waitAsync("the colour to be put back when the colour scheme is applied") {
            await windowColour() == Int64(sidebar.look.palette.sidebar)
        }
        do {
            _ = try await channel.command(
                "highlight Normal guibg=#\(String(format: "%06x", scheme.0)) guifg=#\(String(format: "%06x", scheme.1))"
            )
        } catch { fail("highlight: \(error)") }
        await wait("the sidebar back in the first colours") { sidebar.look.palette == expected(scheme.0, scheme.1) }
        step("the sidebar is a shade of the editor's background and follows a change of colour scheme")
        // What is shown: ignored files and dotfiles, by key, by :FrameTree and by the eye's menu.
        guard !names().contains("ignored.txt"), names().contains(".gitignore"), !sidebar.visibilityButton.isOn else {
            fail("by default git's ignored files are left out and dotfiles shown: \(names())")
        }
        tree.focus()
        tree.outline.keyDown(with: key("I"))
        await wait("I to show what git ignores") { names().contains("ignored.txt") }
        guard let dim = cell("ignored.txt"), dim.alphaValue < 1, sidebar.visibilityButton.isOn else {
            fail("an ignored file is not dimmed, or the eye is not on")
        }
        tree.outline.keyDown(with: key("I"))
        await wait("I to hide what git ignores") { !names().contains("ignored.txt") }
        tree.outline.keyDown(with: key("H"))
        await wait("H to hide dotfiles") { !names().contains(".gitignore") }
        guard names().contains("README.md"),
              sidebar.visibilityButton.isOn else { fail("H hid more than dotfiles: \(names())") }
        tree.outline.keyDown(with: key("H"))
        await wait("H to show dotfiles") { names().contains(".gitignore") }
        do { _ = try await channel.command("FrameTree ignored") } catch { fail("FrameTree ignored: \(error)") }
        await wait(":FrameTree ignored") { names().contains("ignored.txt") }
        let menu = tree.visibilityMenu()
        guard menu.items.map(\.state) == [.on, .on], menu.items.count == 2 else {
            fail("the eye's menu does not say what is shown: \(menu.items.map(\.title)) \(menu.items.map(\.state))")
        }
        menu.performActionForItem(at: 0)
        await wait("the menu to hide ignored files") { !names().contains("ignored.txt") }
        guard !sidebar.visibilityButton.isOn, tree.visibilityMenu().items.map(\.state) == [.off, .on] else {
            fail("the eye does not follow what is shown")
        }
        step(
            "I and H, :FrameTree ignored and the eye's menu show and hide ignored files and dotfiles; ignored ones are dimmed"
        )
        shell.window.makeFirstResponder(editor)
        // The filter: an icon opens an input under the header; typing narrows the tree by path, live; Escape closes it.
        let box = sidebar.filterBox
        // A folder that is open when the filter starts is open again when it ends, and the ones it opened are shut.
        tree.expand(folder + "/docs")
        await wait("docs open") { names().contains("guide.md") }
        let everything = names()
        func type(_ text: String) {
            guard let editor = box.field.currentEditor() as? NSTextView
            else { fail("the filter is not being typed in") }
            editor.string = ""
            editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        func command(_ selector: Selector) {
            guard let editor = box.field.currentEditor() as? NSTextView
            else { fail("the filter is not being typed in") }
            editor.doCommand(by: selector)
        }
        guard !sidebar.filterVisible, box.isHidden else { fail("the filter is open from the start") }
        sidebar.filterButton.performClick(nil)
        guard sidebar.filterVisible, !box.isHidden, box.field.currentEditor() != nil, sidebar.filterButton.isOn else {
            fail("the filter's icon did not open the input with the keyboard in it")
        }
        type("ord")
        await wait("the tree narrowed to the files that match") { names() == ["src", "Order.cs"] }
        if let path = ProcessInfo.processInfo.environment["SILL_CHECK_SHOT"] {
            try? shot(editor: editor, to: path.replacingOccurrences(of: ".png", with: "-filter.png"))
        }
        guard tree.selectedNode?.name == "Order.cs" else { fail("the first match is not selected") }
        type("ZZZ")
        await wait("nothing to match") { names().isEmpty && !sidebar.emptyNote.isHidden }
        type("guide")
        await wait("another match") { names() == ["docs", "guide.md"] }
        command(#selector(NSResponder.moveDown(_:)))
        guard tree.selectedNode?.name == "guide.md" else { fail("the arrow did not move through the results") }
        command(#selector(NSResponder.insertTab(_:)))
        guard shell.window.firstResponder === tree.outline, tree.selectedNode?.name == "guide.md" else {
            fail("Tab did not go to the results: \(String(describing: shell.window.firstResponder))")
        }
        shell.window.makeFirstResponder(box.field)
        command(#selector(NSResponder.insertNewline(_:)))
        await waitAsync("Return to open the file the arrows chose") {
            let name = await (try? shell.session.channel.lua("return vim.api.nvim_buf_get_name(0)"))?.stringValue
            return name == folder + "/docs/guide.md"
        }
        await wait("the keyboard in the editor") { shell.window.firstResponder === shell.editor }
        shell.window.makeFirstResponder(box.field)
        type("ord")
        await wait("the filter on ord") { names() == ["src", "Order.cs"] }
        tree.outline.deselectAll(nil)
        command(#selector(NSResponder.insertNewline(_:)))
        await waitAsync("Return to open the first file when none is chosen") {
            let name = await (try? shell.session.channel.lua("return vim.api.nvim_buf_get_name(0)"))?.stringValue
            return name == folder + "/src/Order.cs"
        }
        step(
            "the filter narrows the tree to the paths that hold the text, live, Tab goes to the results, Return opens the file"
        )
        tree.outline.keyDown(with: key("/"))
        guard box.field.currentEditor() != nil else { fail("/ in the tree did not go to the filter") }
        // End on a filter that opens src, not the docs that were open: both must be put right when it closes.
        type("ord")
        await wait("src opened by the filter") { names() == ["src", "Order.cs"] }
        command(#selector(NSResponder.cancelOperation(_:)))
        await wait("Escape to close the filter and show everything") { !sidebar.filterVisible && names() == everything }
        guard shell.window.firstResponder === tree.outline, box.field.stringValue.isEmpty,
              !sidebar.filterButton.isOn
        else {
            fail("Escape did not leave the tree with no filter")
        }
        do { _ = try await channel.command("FrameTree filter") } catch { fail("FrameTree filter: \(error)") }
        await wait(":FrameTree filter") { sidebar.filterVisible && box.field.currentEditor() != nil }
        command(#selector(NSResponder.cancelOperation(_:)))
        await wait("the filter to close again") { !sidebar.filterVisible }
        step("/ and :FrameTree filter open it, Escape closes it and the folders it opened shut again")
        shell.window.makeFirstResponder(editor)
        tree.expand(folder + "/src")
        await wait("src's entries") { names().contains("Order.cs") }
        guard cell("src")?.icon.stringValue == String(FileIcons.folderOpen.glyph),
              cell("Order.cs")?.icon.stringValue == String(FileIcons.icon(name: "Order.cs", isDirectory: false).glyph)
        else { fail("an open folder's and a C# file's icons") }
        step("icons by kind; an open folder shows open; its files appear under it")
        try? "changed\n".write(toFile: folder + "/README.md", atomically: true, encoding: .utf8)
        try? "class New {}\n".write(toFile: folder + "/src/New.cs", atomically: true, encoding: .utf8)
        await wait("the file system's events (a new file, a changed one) in the tree") {
            names().contains("New.cs") && tree.tree?.node(at: folder + "/README.md")?.status == .modified
        }
        await wait("git's marks on the rows") { tree.tree?.node(at: folder + "/src/New.cs")?.status == .untracked }
        guard cell("README.md")?.badge.stringValue == "M", cell("New.cs")?.badge.stringValue == "U",
              cell("src")?.badge.stringValue == "•", tree.tree?.node(at: folder + "/src")?.changedBelow == true
        else { fail("git's marks: \(cell("README.md")?.badge.stringValue ?? "none")") }
        guard let src = tree.tree?.node(at: folder + "/src"), tree.isExpanded(src) else {
            fail("a folder that was open closed when the rows were read again")
        }
        step("a new file appears, git marks M and U and a dot on the folder, and open folders stay open")
        guard let order = tree.tree?.node(at: folder + "/src/Order.cs") else { fail("no Order.cs") }
        tree.focus()
        tree.activate(order)
        await waitAsync("nvim to open the file") {
            let name = await (try? shell.session.channel.lua("return vim.api.nvim_buf_get_name(0)"))?.stringValue
            return name == folder + "/src/Order.cs"
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard shell.window.firstResponder === tree.outline else {
            fail(
                "opening a file from the tree took the keyboard from it: \(String(describing: shell.window.firstResponder))"
            )
        }
        step("a file opened from the tree opens in nvim, and the keyboard stays in the tree")
        await wait("the opened file selected") { tree.selectedNode === order }
        tree.outline.keyDown(with: key("l"))
        try? await Task.sleep(for: .milliseconds(300))
        guard shell.window.firstResponder === tree.outline else { fail("l on a file took the keyboard from the tree") }
        tree.outline.keyDown(with: key("\r", code: 36))
        await wait("Return to go on into the editor") { shell.window.firstResponder === shell.editor }
        step("l opens and stays; Return opens and goes into the editor")
        // Escape in normal mode goes back to where the keyboard came from; in insert mode it is nvim's, and leaves it.
        shell.editor.keyDown(with: key("i"))
        await wait("insert mode") { editor.screen.mode == "insert" }
        shell.editor.keyDown(with: key("\u{1B}", code: 53))
        await wait("normal mode") { editor.screen.mode == "normal" }
        guard shell.window.firstResponder === shell.editor else { fail("Escape in insert mode left the editor") }
        shell.editor.keyDown(with: key("\u{1B}", code: 53))
        await wait("Escape in normal mode to go back to the tree") { shell.window.firstResponder === tree.outline }
        step("Escape in normal mode goes back to the tree the file was opened from; in insert mode it stays nvim's")
        shell.window.makeFirstResponder(editor)
        shell.editor.keyDown(with: key("\u{1B}", code: 53))
        try? await Task.sleep(for: .milliseconds(200))
        guard shell.window.firstResponder === shell.editor
        else { fail("Escape went to the tree without a file from it") }
        do { _ = try await channel.command("edit " + folder + "/docs/guide.md") } catch { fail("edit: \(error)") }
        await wait("the tree to show the editor's file") { tree.selectedNode?.path == folder + "/docs/guide.md" }
        guard let docs = tree.tree?.node(at: folder + "/docs"),
              tree.isExpanded(docs) else { fail("its folder is not open") }
        step("the file nvim shows is revealed in the tree: its folders open, its row selected")
        channel.send(keys: "<C-w>h")
        await wait("<C-w>h from the leftmost window to go into the tree") {
            shell.window.firstResponder === tree.outline
        }
        let before = tree.outline.selectedRow
        tree.outline.keyDown(with: key("k"))
        guard tree.outline.selectedRow == before - 1
        else { fail("k did not go up: \(before) to \(tree.outline.selectedRow)") }
        tree.outline.keyDown(with: key("j"))
        guard tree.outline.selectedRow == before else { fail("j did not go down") }
        tree.outline.keyDown(with: key("G"))
        guard tree.outline.selectedRow == tree.outline.numberOfRows - 1 else { fail("G did not go to the last row") }
        tree.outline.keyDown(with: key("g"))
        guard tree.outline.selectedRow == tree.outline.numberOfRows - 1 else { fail("one g moved the selection") }
        tree.outline.keyDown(with: key("g"))
        guard tree.outline.selectedRow == 0 else { fail("gg did not go to the first row") }
        tree.outline.keyDown(with: key("\u{1B}", code: 53))
        await wait("Escape back to the editor") { shell.window.firstResponder === shell.editor }
        step("<C-w>h goes into the tree, j k gg G move, Escape comes back")
        // Escape goes back and forth, as often as it is pressed.
        for round in 1 ... 3 {
            shell.editor.keyDown(with: key("\u{1B}", code: 53))
            await wait("Escape to the tree (round \(round))") { shell.window.firstResponder === tree.outline }
            guard shell.modes.surface == .tree
            else { fail("the keyboard is in the tree, the modes say \(shell.modes.surface)") }
            tree.outline.keyDown(with: key("\u{1B}", code: 53))
            await wait("Escape to the editor (round \(round))") { shell.window.firstResponder === shell.editor }
            guard shell.modes.surface == .editor
            else { fail("the keyboard is in the editor, the modes say \(shell.modes.surface)") }
        }
        step("Escape in the editor's normal mode and in the tree go back and forth, again and again")
        // A mode leaves before the tree does: with a filter on, Escape ends it first.
        shell.editor.keyDown(with: key("\u{1B}", code: 53))
        await wait("the tree") { shell.window.firstResponder === tree.outline }
        tree.outline.keyDown(with: key("/"))
        type("ord")
        await wait("the filter") { shell.modes.treeMode == .filter }
        tree.outline.window?.makeFirstResponder(tree.outline)
        tree.outline.keyDown(with: key("\u{1B}", code: 53))
        await wait("Escape to end the filter") { shell.modes.treeMode == .normal }
        guard shell.window.firstResponder === tree.outline else { fail("Escape in a filter left the tree with it") }
        tree.outline.keyDown(with: key("\u{1B}", code: 53))
        await wait("the next Escape to leave the tree") { shell.window.firstResponder === shell.editor }
        step("Escape in the tree ends the filter first and leaves the tree on the next")
        // After folders opened two levels deep: nothing is wider than what the sidebar shows, so no badge is cut off.
        let visible = shell.view.sidebar.scroll.contentSize.width
        guard tree.outline.frame.width == visible, tree.outline.tableColumns[0].width == visible,
              let deep = cell("New.cs"), deep.frame.maxX <= visible, deep.badge.frame.maxX <= deep.bounds.width
        else {
            fail(
                "the tree is wider than the sidebar: outline \(tree.outline.frame.width), column \(tree.outline.tableColumns[0].width), shows \(visible)"
            )
        }
        step("rows fit the sidebar after folders open: no badge is cut off")
        if let path = ProcessInfo.processInfo.environment["SILL_CHECK_SHOT"], let editor = shell.editor {
            let treePath = path.replacingOccurrences(of: ".png", with: "-tree.png")
            do {
                try shot(editor: editor, to: treePath)
                step("saved \(treePath)")
            } catch {
                fail("the tree's shot: \(error)")
            }
        }
    }

    /// What a person does to reach the tree, through AppKit's own event handling (hit-testing, first responder,
    /// key equivalents), not by calling the controller: a click on a row, and the menu's keys.
    private func focusSteps() async {
        guard let tree = shell.tree, let window = shell.window, let editor = shell.editor, let view = shell.view
        else { fail("no tree") }
        func click(row: Int, count: Int = 1) {
            let rect = tree.outline.convert(tree.outline.rect(ofRow: row), to: nil)
            let point = NSPoint(x: rect.minX + 60, y: rect.midY)
            func event(_ type: NSEvent.EventType, _ number: Int) -> NSEvent {
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: number, clickCount: count,
                    pressure: 1
                )!
            }
            // The release is queued first: a table's mouse-down tracks until it.
            NSApp.postEvent(event(.leftMouseUp, 2), atStart: false)
            // To the outline itself: a window that is not on screen is sent no mouse events, and what matters here is
            // what
            // the outline does with the click when its window or app is not the active one.
            tree.outline.mouseDown(with: event(.leftMouseDown, 1))
        }
        func chord(_ characters: String, _ flags: NSEvent.ModifierFlags) {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters.lowercased(), isARepeat: false, keyCode: 0
            )!
            // The menu's key equivalents, as the system hands them to the menu bar.
            if NSApp.mainMenu?.performKeyEquivalent(with: event) != true { fail("no menu item takes \(characters)") }
        }
        view.sidebarVisible = true
        view.layoutSubtreeIfNeeded()
        window.makeFirstResponder(editor)
        click(row: 0)
        await wait("a click on a row to give the tree the keyboard") { window.firstResponder === tree.outline }
        step("a click on a row gives the tree the keyboard")
        window.makeFirstResponder(editor)
        chord("E", [.command, .shift])
        await wait("⇧⌘E to give the tree the keyboard") { window.firstResponder === tree.outline }
        step("⇧⌘E gives the tree the keyboard")
        window.makeFirstResponder(editor)
        // :FrameTree and its keys, from inside nvim.
        let channel = shell.session.channel
        func command(_ text: String) async {
            do { _ = try await channel.command(text) } catch { fail("\(text): \(error)") }
        }
        await command("FrameTree hide")
        await wait(":FrameTree hide") { !view.sidebarVisible }
        guard window.firstResponder === editor
        else { fail("hiding the sidebar left the keyboard on something that is gone") }
        await command("FrameTree show")
        await wait(":FrameTree show") { view.sidebarVisible }
        await command("FrameTree focus")
        await wait(":FrameTree focus") { window.firstResponder === tree.outline }
        await command("FrameTree toggle")
        await wait(":FrameTree toggle to hide it from inside") { !view.sidebarVisible }
        guard window.firstResponder === editor
        else { fail("toggling the sidebar away from the tree lost the keyboard") }
        await command("FrameTree toggle")
        await wait(":FrameTree toggle to show it and go in") {
            view.sidebarVisible && window.firstResponder === tree.outline
        }
        window.makeFirstResponder(editor)
        await command("FrameTree hide")
        channel.send(keys: "<C-w>e")
        await wait("<C-w>e to show the tree and go in") { view.sidebarVisible && window.firstResponder === tree.outline
        }
        window.makeFirstResponder(editor)
        let mapped = await (try? channel.lua("return vim.fn.maparg('<leader>e', 'n') ~= ''"))?.boolValue
        let known = await (try? channel.lua("return vim.fn.getcompletion('FrameTree ', 'cmdline')"))?.arrayValue?
            .compactMap(\.stringValue)
        guard mapped == true, known == ["toggle", "show", "hide", "focus", "filter", "ignored", "dotfiles"] else {
            fail("<leader>e mapped: \(String(describing: mapped)); :FrameTree completes \(String(describing: known))")
        }
        _ = try? await channel.command("FrameTree sideways")
        try? await Task.sleep(for: .milliseconds(300))
        guard view.sidebarVisible else { fail("an unknown :FrameTree action changed the sidebar") }
        step(":FrameTree shows, hides and enters the sidebar; <C-w>e and <leader>e are bound; the keyboard follows")
    }

    /// Keys that are nvim's, pressed with the tree selected: the leader, `:` and Control chords go to nvim whatever row
    /// is selected, and the sequence they start is finished there.
    private func forwardSteps() async {
        guard let tree = shell.tree, let window = shell.window, let editor = shell.editor else { fail("no tree") }
        let channel = shell.session.channel
        func lua(_ code: String) async -> MessagePackValue? { try? await channel.lua(code) }
        let leader = await lua("return vim.g.mapleader or '\\\\'")?.stringValue ?? " "
        guard tree.leaders.contains(leader)
        else { fail("the tree does not know nvim's leader \(leader.debugDescription)") }
        _ = await lua("vim.g.leader_hit = 0; vim.keymap.set('n', '<leader>zz', function() vim.g.leader_hit = 1 end)")
        tree.focus()
        tree.outline.keyDown(with: key(leader))
        guard window.firstResponder === editor else { fail("the leader did not go to the editor") }
        editor.keyDown(with: key("z"))
        editor.keyDown(with: key("z"))
        await waitAsync("<leader>zz pressed in the tree") { await lua("return vim.g.leader_hit")?.integerValue == 1 }
        step("the leader pressed in the tree is nvim's: <leader>zz runs, whatever row is selected")
        tree.focus()
        tree.outline.keyDown(with: key(":"))
        guard window.firstResponder === editor else { fail(": did not go to the editor") }
        await waitAsync(": to open nvim's command line") { await lua("return vim.fn.mode()")?.stringValue == "c" }
        // The grid's own mode follows nvim's by a notification: an Escape sent before it arrives would be the tree's.
        await wait("the grid to show the command line") { editor.screen.mode != "normal" }
        editor.keyDown(with: key("\u{1B}", code: 53))
        await waitAsync("the command line to close") { await lua("return vim.fn.mode()")?.stringValue == "n" }
        tree.focus()
        tree.outline.keyDown(with: key("\u{17}", flags: .control, plain: "w"))
        guard window.firstResponder === editor else { fail("<C-w> did not go to the editor") }
        editor.keyDown(with: key("v"))
        await waitAsync("<C-w>v to split the window") {
            await lua("return #vim.api.nvim_list_wins()")?.integerValue == 2
        }
        _ = try? await channel.command("only")
        step(": and <C-w> chords pressed in the tree go to nvim and finish there")
        // What is the tree's own stays its own.
        tree.focus()
        tree.outline.keyDown(with: key("j"))
        guard window.firstResponder === tree.outline else { fail("j left the tree") }
        window.makeFirstResponder(editor)
    }

    /// The sidebar and the grid share the window: the grid takes what the sidebar leaves, nvim is told its new size
    /// when the sidebar is hidden, shown or dragged, and the sidebar's width is kept within bounds.
    private func layoutSteps() async {
        guard let editor = shell.editor, let view = shell.view else { fail("no view") }
        let margin = FrameView.margin, gap = FrameView.dividerWidth
        func gridCols() -> Int? { editor.screen.grids[1]?.cols }
        func settled(_ what: String) async {
            view.layoutSubtreeIfNeeded()
            await wait("nvim's grid to follow the layout (\(what))") { gridCols() == editor.gridSize.cols }
        }
        guard view.sidebarVisible, view.sidebar.frame.minX == margin, view.sidebar.frame.width == view.sidebarWidth,
              view.divider.frame.minX == margin + view.sidebarWidth,
              editor.frame.minX == margin + view.sidebarWidth + gap,
              editor.frame.maxX == view.bounds.maxX - margin
        else { fail("the sidebar then the grid: \(view.sidebar.frame) \(editor.frame) in \(view.bounds)") }
        await settled("shown")
        let withSidebar = editor.gridSize.cols
        view.sidebarVisible = false
        await settled("hidden")
        guard editor.frame.minX == margin, view.sidebar.isHidden, editor.gridSize.cols > withSidebar else {
            fail("hiding the sidebar: grid at \(editor.frame), \(editor.gridSize.cols) columns, was \(withSidebar)")
        }
        guard view.overlay.frame == editor.frame else { fail("the overlay does not follow the grid") }
        view.sidebarVisible = true
        view.divider.mouseDragged(from: view.sidebarWidth, by: 60)
        view.layoutSubtreeIfNeeded()
        guard view.sidebarWidth == PaneLayout.defaultWidth + 60,
              editor.frame.minX == margin + PaneLayout.defaultWidth + 60 + gap
        else { fail("dragging the divider: width \(view.sidebarWidth), grid at \(editor.frame.minX)") }
        await settled("dragged")
        guard editor.gridSize.cols < withSidebar else { fail("a wider sidebar left the grid as wide") }
        view.divider.mouseDragged(from: view.sidebarWidth, by: 5000)
        guard view.sidebarWidth == PaneLayout.widthRange.upperBound else { fail("the width is not kept in bounds") }
        view.divider.mouseDragged(from: view.sidebarWidth, by: -5000)
        guard view.sidebarWidth == PaneLayout.widthRange.lowerBound else { fail("the width is not kept in bounds") }
        view.sidebarWidth = PaneLayout.defaultWidth
        await settled("restored")
        step("the sidebar and the grid share the window; nvim follows when it is hidden, shown or dragged")
    }

    /// Frame runs its own isolated config: the person's additions (`$XDG_CONFIG_HOME/frame/init.lua`) load, nvim's own
    /// (`$XDG_CONFIG_HOME/nvim/init.lua`) does not, and the folders nvim keeps its things in are Frame's.
    private func isolationSteps() async {
        let channel = shell.session.channel
        func lua(_ code: String) async -> MessagePackValue? { try? await channel.lua(code) }
        let home = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        let state = await lua("""
        return { vim.g.frame or false, vim.g.frame_user or '', vim.g.nvim_config_leaked or '', vim.env.NVIM_APPNAME or '',
                 vim.fn.stdpath('config'), vim.fn.stdpath('data'), vim.fn.stdpath('state') }
        """)?.arrayValue
        guard let state, state.count == 7 else { fail("no word of nvim's config") }
        guard state[0].boolValue == true, state[3].stringValue == "frame" else {
            fail("nvim is not running as Frame's: frame=\(state[0]) appname=\(state[3])")
        }
        guard state[4].stringValue?.hasSuffix("/frame") == true, state[5].stringValue?.hasSuffix("/frame") == true,
              state[6].stringValue?.hasSuffix("/frame") == true
        else { fail("nvim keeps its things outside Frame's folders: \(state[4]) \(state[5]) \(state[6])") }
        step("nvim runs as Frame's own: its config, data and state folders are Frame's")
        guard let home else { return }
        // Only when the check was given a config home to look in (verify.sh does, with the two init files).
        if FileManager.default.fileExists(atPath: home + "/frame/init.lua") {
            guard state[1].stringValue == "user" else { fail("the person's additions in ~/.config/frame did not load") }
            guard shell.tree.leaders.contains(",") else {
                fail("the leader the additions set is not the tree's: \(shell.tree.leaders)")
            }
        }
        if FileManager.default.fileExists(atPath: home + "/nvim/init.lua") {
            guard state[2].stringValue == "" else { fail("the config in ~/.config/nvim was read") }
        }
        step("the additions in ~/.config/frame load, and nothing of ~/.config/nvim does")
        // Frame's own config: its defaults, the scheme the settings file chose, tree-sitter parsers, and none of Sill's
        // agent
        // commands.
        let config = await lua("""
        local parsers = 0
        for _ in ipairs(vim.api.nvim_get_runtime_file('parser/*', true)) do parsers = parsers + 1 end
        return { vim.g.colors_name or '', vim.o.expandtab, vim.o.clipboard, vim.o.smoothscroll, vim.o.shiftwidth,
                 vim.fn.exists(':SillReview'), vim.fn.exists(':SillAgent'), parsers, vim.o.timeoutlen }
        """)?.arrayValue
        guard let config, config.count == 9 else { fail("no word of Frame's config") }
        if FileManager.default.fileExists(atPath: (home ?? "") + "/frame/settings.toml") {
            guard config[0].stringValue == "rose-pine"
            else { fail("the colour scheme in the settings did not apply: \(config[0])") }
        }
        guard config[1].boolValue == true, config[2].stringValue == "unnamedplus", config[3].boolValue == true,
              config[4].integerValue == 4, config[8].integerValue == 400
        else { fail("Frame's defaults are not set: \(config)") }
        guard config[5].integerValue == 0,
              config[6].integerValue == 0 else { fail("Sill's agent commands are loaded in Frame") }
        guard (config[7].integerValue ?? 0) >= 25 else { fail("the tree-sitter parsers are not there: \(config[7])") }
        step(
            "Frame's own defaults, the settings file's colour scheme and the tree-sitter parsers are in; Sill's agent commands are not"
        )
    }

    /// The window as it shows: its background, the grid at its margin, corners rounded by the window's radius.
    /// The status bar: nvim's own is off while it shows, and it says the mode, the file and the position nvim has.
    private func statusSteps() async {
        let channel = shell.session.channel
        func lua(_ code: String) async -> MessagePackValue? { try? await channel.lua(code) }
        let bar = shell.view.statusBar
        shell.focusEditor()
        await waitAsync("nvim's own status line, ruler and mode message to be off") {
            await lua("return { vim.o.laststatus, vim.o.ruler, vim.o.showmode }")?.arrayValue.map {
                $0.first?.integerValue == 0 && $0[1].boolValue == false && $0[2].boolValue == false
            } ?? false
        }
        guard !bar.isHidden, shell.view.statusVisible else { fail("the bar is not showing") }
        step("the bar shows, and nvim's own status line, ruler and mode message are off")
        // The row the status line was drawn in: nothing of it may show through the window that took it over.
        let lastRow = (shell.editor.screen.grids[1]?.rows ?? 1) - 1
        let background = shell.editor.screen.defaultBackground
        let expected = (red: (background >> 16) & 0xFF, green: (background >> 8) & 0xFF, blue: background & 0xFF)
        let seen = (try? pixel(shell.editor, row: lastRow, col: 30)) ?? (red: -1, green: -1, blue: -1)
        guard abs(seen.red - expected.red) <= 3, abs(seen.green - expected.green) <= 3,
              abs(seen.blue - expected.blue) <= 3
        else { fail("the old status line shows through the last row: \(seen), the background is \(expected)") }
        step("nothing of the status line that went away shows through the window")
        _ =
            await lua(
                "vim.cmd('enew'); vim.api.nvim_buf_set_lines(0, 0, -1, false, {'a', 'b', 'c'}); vim.api.nvim_win_set_cursor(0, {2, 0}); vim.bo.filetype = 'lua'"
            )
        await wait("the bar to say the position and the file type") {
            bar.state.line == 2 && bar.state.filetype == "lua" && bar.state.modified
        }
        guard bar.state.mode == "NORMAL", bar.state.path == "[No name]" else { fail("the bar says \(bar.state)") }
        shell.editor.keyDown(with: key("i"))
        await wait("the bar to say INSERT") { bar.state.mode == "INSERT" }
        shell.editor.keyDown(with: key("\u{1B}", code: 53))
        await wait("the bar to say NORMAL again") { bar.state.mode == "NORMAL" }
        shell.tree.focus()
        await wait("the bar to say TREE") { bar.state.mode == "TREE" }
        shell.focusEditor()
        await wait("the bar to say NORMAL, out of the tree") { bar.state.mode == "NORMAL" }
        step("the bar says the mode (nvim's, or the tree's), the position, the type and that the buffer is changed")
        _ = await lua("vim.cmd('FrameStatusline hide')")
        await wait("the bar to hide") { bar.isHidden && !shell.view.statusVisible }
        await waitAsync("nvim's own status line back") { await lua("return vim.o.laststatus")?.integerValue != 0 }
        _ = await lua("vim.cmd('FrameStatusline show')")
        await wait("the bar to show again") { !bar.isHidden && shell.view.statusVisible }
        let (_, gridRows) = shell.editor.gridSize
        let sidebar = shell.view.sidebar, editor = shell.editor!, chip = shell.chip
        guard gridRows > 3 else { fail("no grid") }
        shell.view.layoutSubtreeIfNeeded()
        // By default the foot is two islands level with each other: the workspace button under the sidebar, the bar
        // under the grid; the sidebar and the grid both end above them.
        guard shell.view.statusPlacement == .editor, !chip.isHidden, chip.frame.minY == bar.frame.minY,
              chip.frame.height == bar.frame.height, chip.frame.minX == sidebar.frame.minX,
              chip.frame.width == sidebar.frame.width, sidebar.frame.maxY < chip.frame.minY,
              bar.frame.minX == editor.frame.minX, bar.frame.maxX == editor.frame.maxX,
              editor.frame.maxY < bar.frame.minY
        else {
            fail(
                "the foot is not a button under the sidebar and the bar under the grid: chip \(chip.frame), bar \(bar.frame)"
            )
        }
        step("the workspace button sits under the sidebar, level with the status bar under the grid")
        // The sidebar says the branch, so the bar does not; without the sidebar the bar does.
        guard bar.state.branch.isEmpty,
              !bar.state.showsWorkspace else { fail("the bar says the branch beside the sidebar") }
        shell.setSidebar(visible: false)
        shell.view.layoutSubtreeIfNeeded()
        await wait("the bar to say the branch") { bar.state.branch == shell.chip.branch }
        guard chip.isHidden, bar.frame.minX == shell.view.sidebar.frame.minX || bar.frame.minX == 8 else {
            fail("the button stayed with no sidebar: \(chip.frame), the bar \(bar.frame)")
        }
        shell.setSidebar(visible: true)
        await wait("the bar to leave the branch to the sidebar") { bar.state.branch.isEmpty }
        step("the bar says the branch only while the sidebar is away; the button goes with the sidebar")
        // `:FrameStatusline window`, and the menu, put one bar across the window: the workspace is its first segment.
        _ = await lua("vim.cmd('FrameStatusline window')")
        await wait("the bar across the window") { shell.view.statusPlacement == .window }
        shell.view.layoutSubtreeIfNeeded()
        if let path = ProcessInfo.processInfo.environment["SILL_CHECK_SHOT"] {
            try? await Task.sleep(for: .milliseconds(300))
            do { try shot(editor: editor, to: path.replacingOccurrences(of: ".png", with: "-across.png")) } catch {
                fail("the across shot: \(error)")
            }
        }
        guard chip.isHidden, bar.state.showsWorkspace, bar.frame.minX == sidebar.frame.minX,
              bar.frame.maxX == editor.frame.maxX, sidebar.frame.maxY < bar.frame.minY,
              editor.frame.maxY < bar.frame.minY
        else { fail("the bar does not span the window under the sidebar and the grid: \(bar.frame)") }
        shell.view.statusBar.display()
        guard !shell.view.statusBar.pointerRects().isEmpty
        else { fail("the pointer is not a hand over the workspace segment") }
        shell.view.statusBar.setHoveringWorkspace(true)
        guard shell.view.statusBar.hoveringWorkspace else { fail("the workspace segment does not light") }
        shell.view.statusBar.setHoveringWorkspace(false)
        let item = NSMenuItem(
            title: "",
            action: #selector(FrameWindowController.toggleStatusAcrossWindow(_:)),
            keyEquivalent: ""
        )
        _ = shell.validateMenuItem(item)
        guard item.state == .on else { fail("the menu item does not say it is across the window") }
        shell.toggleStatusAcrossWindow(nil)
        guard shell.view.statusPlacement == .editor else { fail("the menu item did not put it back") }
        _ = shell.validateMenuItem(item)
        guard item.state == .off else { fail("the menu item still says it is across the window") }
        _ = await lua("vim.cmd('FrameStatusline window')")
        await wait("across again") { shell.view.statusPlacement == .window }
        _ = await lua("vim.cmd('FrameStatusline editor')")
        await wait("under the grid again") { shell.view.statusPlacement == .editor }
        step(
            "the bar can go across the window (the workspace its first segment) or beside the button: `:FrameStatusline editor|window` and the View menu"
        )
        _ = await lua("vim.cmd('bwipeout!')")
        step(":FrameStatusline hides the bar and gives nvim's own back; the grid ends where the bar begins")
    }

    /// The colour scheme as a mode: a list in the tree's font whose rows are tried as the keyboard passes them (the
    /// sidebar
    /// and the bar follow), Return keeps one and saves it, Escape puts the old one back; `:FrameTheme` and `<leader>c`.
    private func themeSteps() async {
        let channel = shell.session.channel
        func lua(_ code: String) async -> MessagePackValue? { try? await channel.lua(code) }
        func scheme() async -> String { await lua("return vim.g.colors_name or ''")?.stringValue ?? "" }
        // The settings it saves go to a file of their own, not the config home the check was given.
        let saved = NSTemporaryDirectory() + "frame-theme-\(UUID().uuidString).toml"
        setenv("FRAME_SETTINGS", saved, 1)
        defer { unsetenv("FRAME_SETTINGS") }
        func savedText() -> String { (try? String(contentsOfFile: saved, encoding: .utf8)) ?? "" }
        shell.focusEditor()
        let original = await scheme()
        guard !original.isEmpty else { fail("no colour scheme to begin with") }
        // A variant (rose-pine-dawn) calls itself by its family's name, so what is compared is what is seen: the
        // background.
        let originalBackground = shell.editor.screen.defaultBackground
        shell.showThemePicker(nil)
        await wait("the colour schemes as a list") { shell.listPicker != nil }
        guard let picker = shell.listPicker, shell.modes.surface == .list,
              shell.modes.label(editorMode: "normal") == "COLOUR SCHEME", picker.all.count >= 10,
              picker.cursor == original, picker.all.first(where: \.isCurrent)?.id == original
        else { fail("the colour schemes did not come up as a mode on the current one: \(shell.modes.surface)") }
        guard picker.all.contains(where: { $0.id == "tokyonight-night" && $0.detail.hasPrefix("Frame") }),
              picker.all.contains(where: { $0.id.hasPrefix("catppuccin") })
        else { fail("Frame's own schemes are not in the list") }
        step("the colour schemes are a list, a mode of their own, on the scheme in use")
        // Moving tries each: nvim takes it, and the sidebar and the bar follow its colours.
        picker.keyDown(with: key("\u{F701}", code: 125))
        guard let tried = picker.cursor, tried != original else { fail("the down arrow did not move") }
        await wait("the editor's background to follow the keyboard") {
            shell.editor.screen.defaultBackground != originalBackground
        }
        await wait("the sidebar to follow the scheme") {
            shell.tree.look.palette.background == shell.editor.screen.defaultBackground
        }
        step("moving through the schemes tries each, and the sidebar follows")
        picker.keyDown(with: key("\u{1B}", code: 53))
        guard shell.listPicker == nil, shell.modes.surface == .editor else { fail("Escape did not put the list away") }
        await wait("the old scheme back") { shell.editor.screen.defaultBackground == originalBackground }
        guard savedText().isEmpty else { fail("a scheme only passed was saved: \(savedText())") }
        step("Escape puts the old scheme back and saves nothing")
        // Filter, choose: it stays and is saved.
        shell.showThemePicker(nil)
        await wait("the list again") { shell.listPicker != nil }
        guard let again = shell.listPicker else { fail("no list") }
        again.keyDown(with: key("/", code: 44))
        guard shell.modes.listFiltering,
              shell.modes.label(editorMode: "normal") == "FILTER" else { fail("`/` did not filter") }
        for letter in "moon" {
            again.keyDown(with: key(String(letter), code: 0))
        }
        guard !again.visible.isEmpty, again.visible.allSatisfy({ $0.title.contains("moon") }) else {
            fail("the filter did not narrow to moon: \(again.visible.map(\.title))")
        }
        let chosen = again.visible[0].title
        again.keyDown(with: key("\r", code: 36))
        guard shell.listPicker == nil, shell.modes.surface == .editor else { fail("Return did not put the list away") }
        await wait("the chosen scheme to stay") { shell.editor.screen.defaultBackground != originalBackground }
        guard savedText().contains("colorscheme = \"\(chosen)\"")
        else { fail("the choice was not saved: \(savedText())") }
        step("`/` filters the schemes, Return keeps one and saves it in the settings")
        // By name, and by the leader.
        _ = await lua("vim.cmd('FrameTheme tokyonight-storm')")
        await waitAsync(":FrameTheme to set it") { await scheme() == "tokyonight-storm" }
        await wait("it to be saved") { savedText().contains("colorscheme = \"tokyonight-storm\"") }
        _ = await lua("vim.cmd('FrameTheme no-such-scheme')")
        try? await Task.sleep(for: .milliseconds(200))
        guard await scheme() == "tokyonight-storm", !savedText().contains("no-such-scheme") else {
            fail("an unknown scheme changed something")
        }
        let leader = await lua("return vim.g.mapleader or '\\\\'")?.stringValue ?? "\\"
        channel.send(keys: leader + "c")
        await wait("<leader>c to bring up the list") { shell.listPicker != nil }
        shell.escape()
        guard shell.listPicker == nil else { fail("Escape did not put the list away") }
        step(
            "`:FrameTheme name` sets and saves a scheme, an unknown one changes nothing, and <leader>c brings up the list"
        )
        _ = await lua("vim.cmd.colorscheme('\(original)')")
    }

    /// Which-key: after the leader (or `g`) the hints of what can follow show in the grid, Frame's own keys among them,
    /// and
    /// Escape takes them away.
    private func whichKeySteps() async {
        let channel = shell.session.channel
        let editor = shell.editor!
        func lua(_ code: String) async -> MessagePackValue? { try? await channel.lua(code) }
        func hints() async -> Int {
            await lua("""
            local n = 0
            for _, w in ipairs(vim.api.nvim_list_wins()) do
              if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == 'wk' then n = n + 1 end
            end
            return n
            """)?.integerValue.map(Int.init) ?? 0
        }
        func onScreen(_ text: String) -> Bool {
            editor.screen.grids.values.contains { grid in (0 ..< grid.rows).contains { grid.line($0).contains(text) } }
        }
        shell.focusEditor()
        guard await lua("return package.loaded['which-key'] ~= nil")?.boolValue == true
        else { fail("which-key did not load") }
        let leader = await lua("return vim.g.mapleader or '\\\\'")?.stringValue ?? "\\"
        channel.send(keys: leader)
        await waitAsync("which-key to show what follows the leader") { await hints() >= 1 }
        await wait("Frame's own keys in the hints") { onScreen("Colour scheme") && onScreen("Switch workspace") }
        if let path = ProcessInfo.processInfo.environment["SILL_CHECK_SHOT"] {
            do { try shot(editor: editor, to: path.replacingOccurrences(of: ".png", with: "-whichkey.png")) } catch {
                fail("the which-key shot: \(error)")
            }
        }
        channel.send(keys: "<Esc>")
        await waitAsync("the hints to go with Escape") { await hints() == 0 }
        step("the leader shows what follows it, Frame's keys among them, and Escape takes it away")
        channel.send(keys: "g")
        await waitAsync("which-key to show what follows g") { await hints() >= 1 }
        channel.send(keys: "<Esc>")
        await waitAsync("the hints to go") { await hints() == 0 }
        guard await lua("return vim.fn.mode()")?.stringValue == "n" else { fail("nvim is not back in normal mode") }
        step("vim's own sequences (g) show their hints too")
    }

    /// Language servers, supervised: a real server (sourcekit-lsp, from Xcode) starts for a Swift file, and when it is
    /// killed
    /// nvim carries on and the server comes back; one that keeps dying shows in the bar as restarting, then as given up
    /// on, and
    /// `:FrameLsp restart` tries again.
    private func lspSteps() async {
        let channel = shell.session.channel
        func lua(_ code: String) async -> MessagePackValue? { try? await channel.lua(code) }
        /// The server's clients, those rooted at `root` when it is given (a server runs once for each root).
        func clients(_ name: String, root: String? = nil) async -> [Int] {
            let filter = root.map { " and c.root_dir == '\($0)'" } ?? ""
            return await lua("""
            local ids = {}
            for _, c in ipairs(vim.lsp.get_clients({ name = 'frame_\(name)' })) do
              if true\(filter) then ids[#ids + 1] = c.id end
            end
            return ids
            """)?.arrayValue?.compactMap { $0.integerValue.map(Int.init) } ?? []
        }
        shell.focusEditor()
        // A server that keeps dying, as a fake one, with short waits.
        _ = await lua("""
        local lsp = require('frame.lsp')
        lsp.wait_first, lsp.wait_max = 300, 600
        lsp.specs.crashy = { filetypes = { 'crashy' }, root = { '.git' }, aliases = {} }
        lsp.commands.crashy = { 'sh', '-c', 'exit 3' }
        vim.cmd('enew'); vim.bo.filetype = 'crashy'
        lsp.start('crashy', vim.api.nvim_get_current_buf())
        """)
        await wait("the bar to say the server is starting again") { shell.status.lsp.contains("crashy ↻") }
        await wait("the bar to say the server was given up on") { shell.status.lsp.contains("crashy ✗") }
        step("a server that keeps dying shows in the bar as restarting (↻), then as given up on (✗)")
        _ = await lua("vim.cmd('FrameLsp restart crashy')")
        await wait("restart to start it again") {
            shell.status.lsp.contains("crashy ↻") || shell.status.lsp.contains("crashy ✗")
        }
        _ = await lua("require('frame.lsp').stop('crashy')")
        // A real one.
        let viaXcode = await (try? FrameServers.run("/usr/bin/xcrun", ["--find", "sourcekit-lsp"]))?.code == 0
        guard FrameServers.onPath("sourcekit-lsp") != nil || viaXcode
        else { return step("no sourcekit-lsp here: the real server was not exercised") }
        let folder = RealPath.of(NSTemporaryDirectory()) + "/frame-lsp-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: folder + "/Sources/App", withIntermediateDirectories: true)
        try? "// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: \"App\", targets: [.target(name: \"App\")])\n"
            .write(toFile: folder + "/Package.swift", atomically: true, encoding: .utf8)
        try? "let answer = 42\n".write(toFile: folder + "/Sources/App/a.swift", atomically: true, encoding: .utf8)
        _ = await lua("vim.cmd('edit ' .. vim.fn.fnameescape('\(folder)/Sources/App/a.swift'))")
        var first: [Int] = []
        for _ in 0 ..< 200 {
            first = await clients("sourcekit", root: folder)
            if !first.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let id = first.first else { fail("sourcekit-lsp did not start for a Swift file") }
        step("a real server (sourcekit-lsp) is found, provisioned and started for a Swift file, rooted at its package")
        // Killed from outside: nvim and the window carry on, the server comes back.
        let nvimPid = await lua("return vim.fn.getpid()")?.integerValue ?? 0
        let children = await (try? FrameServers.run("/usr/bin/pgrep", ["-P", "\(nvimPid)", "-f", "sourcekit"]))?
            .output ?? ""
        let pids = children.split(separator: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
        guard !pids.isEmpty else { fail("no server process under nvim (\(nvimPid))") }
        pids.forEach { kill($0, SIGKILL) }
        await wait("the bar to say it is starting again") { shell.status.lsp.contains("sourcekit ↻") }
        guard await lua("return vim.fn.mode()")?.stringValue == "n" else { fail("nvim did not carry on") }
        var again: [Int] = []
        for _ in 0 ..< 300 {
            again = await clients("sourcekit", root: folder)
            if let new = again.first, new != id { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let new = again.first, new != id else { fail("the killed server did not come back") }
        step("a server killed from outside leaves nvim alone and is started again")
        _ = await lua("require('frame.lsp').stop('sourcekit')")
        try? FileManager.default.removeItem(atPath: folder)
    }

    /// The finder: files of the workspace ranked as you type, lines found by grep, Return opening the file (at the
    /// line), Escape
    /// going back at once, and the leader key and command that bring it up.
    private func finderSteps() async {
        let channel = shell.session.channel
        func lua(_ code: String) async -> MessagePackValue? { try? await channel.lua(code) }
        func buffer() async -> String { await lua("return vim.api.nvim_buf_get_name(0)")?.stringValue ?? "" }
        let folder = shell.workspace + "/finder-fixture"
        try? FileManager.default.createDirectory(atPath: folder + "/src", withIntermediateDirectories: true)
        try? "one\n".write(toFile: folder + "/alpha.txt", atomically: true, encoding: .utf8)
        try? "one\ntwo\nlet findermarker = 3\nfour\n".write(
            toFile: folder + "/src/finder-beta.swift", atomically: true, encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(atPath: folder) }
        func type(_ text: String, into picker: ListPickerView) {
            for letter in text {
                picker.keyDown(with: key(String(letter), code: 0))
            }
        }
        shell.focusEditor()
        shell.showFinder(nil)
        await wait("the finder as a list") { shell.listPicker != nil }
        guard let picker = shell.listPicker, shell.modes.surface == .list,
              shell.modes.label(editorMode: "normal") == "FIND FILE"
        else { fail("the finder did not come up as a mode: \(shell.modes.surface)") }
        await wait("the files of the workspace") { !picker.all.isEmpty }
        type("betaf", into: picker)
        await wait("the files to be ranked by the query") {
            picker.visible.first?.id == "finder-fixture/src/finder-beta.swift"
        }
        guard picker.visible.first?.file == "finder-beta.swift", picker.visible.first?.detail == "finder-fixture/src"
        else { fail("the row is not the file's name over its folder: \(String(describing: picker.visible.first))") }
        step("the finder lists the workspace's files and ranks them as you type: the name first, its folder beside it")
        picker.keyDown(with: key("\r", code: 36))
        await waitAsync("the file to open") { await buffer() == folder + "/src/finder-beta.swift" }
        guard shell.listPicker == nil,
              shell.modes.surface == .editor else { fail("Return did not put the finder away") }
        step("Return opens the file in nvim and the keyboard goes to it")
        // Grep.
        shell.showGrep(nil)
        await wait("the grep list") { shell.listPicker != nil }
        guard let grep = shell.listPicker, shell.modes.label(editorMode: "normal") == "FIND IN FILES"
        else { fail("grep did not come up") }
        _ = await lua("vim.cmd('enew')")
        type("findermarker", into: grep)
        await wait("a line found") { grep.visible.first?.id == "finder-fixture/src/finder-beta.swift\t3" }
        guard grep.visible.first?.title == "let findermarker = 3"
        else { fail("the row is not the line: \(String(describing: grep.visible.first))") }
        grep.keyDown(with: key("\r", code: 36))
        await waitAsync("the file to open at the line") { await buffer() == folder + "/src/finder-beta.swift" }
        guard await lua("return vim.fn.line('.')")?.integerValue == 3
        else { fail("the cursor is not on the line found") }
        step("grep finds the line as text and Return opens the file on it")
        // Escape at once, and the leader and the command.
        shell.showFinder(nil)
        await wait("the finder again") { shell.listPicker != nil }
        type("x", into: shell.listPicker!)
        shell.escape()
        guard shell.listPicker == nil,
              shell.modes.surface == .editor else { fail("Escape needed more than once, or did not close") }
        let leader = await lua("return vim.g.mapleader or '\\\\'")?.stringValue ?? "\\"
        channel.send(keys: leader + "ff")
        await wait("<leader>ff to bring up the finder") { shell.listPicker != nil }
        shell.escape()
        _ = await lua("vim.cmd('FrameGrep')")
        await wait(":FrameGrep to bring up grep") { shell.listPicker != nil }
        shell.escape()
        guard shell.listPicker == nil else { fail("Escape did not close") }
        step("Escape goes back at once; <leader>ff and :FrameGrep bring the lists up")
    }

    /// Smooth scrolling of the text: a scroll of nvim's slides, and a scroll that comes while one slides goes on from
    /// where
    /// the window is drawn, as one move of all the lines, instead of starting over.
    private func scrollSteps() async {
        let channel = shell.session.channel
        func lua(_ code: String) async -> MessagePackValue? { try? await channel.lua(code) }
        let file = RealPath.of(NSTemporaryDirectory()) + "frame-scroll-\(UUID().uuidString).txt"
        try? (1 ... 400).map { "line \($0)" }.joined(separator: "\n").write(
            toFile: file,
            atomically: true,
            encoding: .utf8
        )
        _ = await lua("vim.o.scrolloff = 0; vim.cmd('edit ' .. vim.fn.fnameescape('\(file)'))")
        let editor = shell.editor!
        // A window that is not on screen has no display link to end a slide: asking for the frame does.
        func sliding() -> Bool {
            _ = editor.currentFrame
            return editor.isSliding
        }
        await wait("nothing sliding to begin with") { !sliding() }
        /// The most lines any window was sliding by in the time given, looked at every few milliseconds.
        func watch(for seconds: Double) async -> Int {
            var most = 0
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                _ = editor.currentFrame
                most = max(most, editor.slidingLines.values.map(abs).max() ?? 0)
                try? await Task.sleep(for: .milliseconds(4))
            }
            return most
        }
        let one = Task { @MainActor in await watch(for: 0.6) }
        try? await Task.sleep(for: .milliseconds(50))
        channel.send(keys: "<C-e>")
        guard await one.value == 1 else { fail("a scroll of one line did not slide by one line") }
        await wait("the slide to end") { !sliding() }
        step("a scroll slides")
        let chained = Task { @MainActor in await watch(for: 0.8) }
        try? await Task.sleep(for: .milliseconds(50))
        for _ in 0 ..< 4 {
            channel.send(keys: "<C-e>")
            try? await Task.sleep(for: .milliseconds(18))
        }
        guard await chained.value >= 2
        else { fail("scrolls in quick succession were not one slide of all their lines") }
        await wait("the slides to end") { !sliding() }
        _ = await lua("vim.cmd('silent! bwipeout!')")
        step("a scroll that comes while one slides goes on from where the window is drawn")
    }

    /// The tabs: the open files, in the places they can be, selected and closed by clicks and keys, and kept from being
    /// too many.
    private func tabsSteps() async {
        let channel = shell.session.channel
        func lua(_ code: String) async -> MessagePackValue? { try? await channel.lua(code) }
        let dir = RealPath.of(NSTemporaryDirectory()) + "frame-tabs-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for name in ["a.txt", "b.txt", "c.txt", "d.txt", "e.txt", "f.txt"] {
            try? "\(name)\n".write(toFile: dir + "/" + name, atomically: true, encoding: .utf8)
        }
        func open(_ name: String) async { _ = await lua("vim.cmd('edit ' .. vim.fn.fnameescape('\(dir)/\(name)'))") }
        func names() -> [String] { shell.tabs.filter { $0.path.hasPrefix(dir) }.map(\.name) }
        func current() -> String? { shell.tabs.first { $0.current }?.name }
        func click(_ list: TabsView, tab name: String, close: Bool = false) {
            guard let id = shell.tabs.first(where: { $0.name == name })?.id, let rect = list.frame(ofTab: id) else {
                fail("no tab \(name) to click")
            }
            let point = NSPoint(x: close ? rect.maxX - 15 : rect.minX + 30, y: rect.midY)
            let event = NSEvent.mouseEvent(
                with: .leftMouseDown, location: list.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: shell.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )!
            list.mouseDown(with: event)
        }
        // Control-Tab as the keyboard sends it (a key code, before any menu), through the app's own handler.
        func tabKey(shift: Bool = false, extra: NSEvent.ModifierFlags = []) -> Bool {
            var flags: NSEvent.ModifierFlags = [.control]
            if shift { flags.insert(.shift) }
            flags.formUnion(extra)
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: shell.window.windowNumber, context: nil,
                characters: shift ? "\u{19}" : "\t", charactersIgnoringModifiers: shift ? "\u{19}" : "\t",
                isARepeat: false, keyCode: 48
            )!
            return shell.app.tabKey(event)
        }
        func chord(_ characters: String, _ plain: String, _ flags: NSEvent.ModifierFlags) -> Bool {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: shell.window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: plain, isARepeat: false, keyCode: 0
            )!
            return NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
        }
        let strip = shell.tabStrip, list = shell.tabList, view = shell.view!, editor = shell.editor!
        // By default the tabs are in the status bar: no strip, no list.
        guard view.tabsPlacement == .statusbar, strip.isHidden, list.isHidden else {
            fail("the tabs are not in the status bar by default: \(view.tabsPlacement)")
        }
        // From nothing: the buffers of the steps before are tabs too.
        _ = await lua("vim.cmd('silent! %bwipeout!')")
        await wait("no tabs to begin with") { shell.tabs.isEmpty }
        shell.app.setTabsAutoclose(true)
        shell.app.setTabsMax(10)
        shell.app.setTabs(placement: .top)
        await open("a.txt")
        await wait("the one file") { names() == ["a.txt"] && current() == "a.txt" }
        view.layoutSubtreeIfNeeded()
        guard strip.isHidden, list.isHidden,
              editor.frame.minY == shell.view.tabStrip.frame.minY || strip.isHidden
        else {
            fail("a single file has a strip")
        }
        step("one file is no tabs")
        await open("b.txt")
        await open("c.txt")
        await wait("the three files as tabs") { names() == ["a.txt", "b.txt", "c.txt"] && current() == "c.txt" }
        view.layoutSubtreeIfNeeded()
        guard !strip.isHidden, strip.frame.maxY < editor.frame.minY, strip.frame.minX == editor.frame.minX,
              strip.frame.width == editor.frame.width, list.isHidden
        else { fail("the strip is not over the grid: \(strip.frame), the grid \(editor.frame)") }
        step("the open files are tabs, in a strip over the grid")

        // Selecting and closing, by click.
        click(strip, tab: "a.txt")
        await waitAsync("a click to show a.txt") {
            await lua("return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':t')")?.stringValue == "a.txt"
        }
        guard shell.window.firstResponder === editor else { fail("clicking a tab took the keyboard from the editor") }
        click(strip, tab: "b.txt", close: true)
        await wait("the close mark to close b.txt") { names() == ["a.txt", "c.txt"] }
        step("a click on a tab shows it and the close mark closes it")

        // The pointer: over a tab it is a hand and the tab lights, over its close mark the mark has a square of its
        // own.
        func moved(_ list: TabsView, to point: NSPoint) {
            list.mouseMoved(with: NSEvent.mouseEvent(
                with: .mouseMoved, location: list.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: shell.window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
            )!)
        }
        guard let first = shell.tabs.first(where: { $0.path.hasPrefix(dir) }),
              let rect = strip.frame(ofTab: first.id)
        else {
            fail("no tab to point at")
        }
        moved(strip, to: NSPoint(x: rect.minX + 30, y: rect.midY))
        guard strip.hover.id == first.id, !strip.hover.onClose else { fail("the pointer over a tab does not light it") }
        moved(strip, to: NSPoint(x: rect.maxX - 15, y: rect.midY))
        guard strip.hover.id == first.id,
              strip.hover.onClose else { fail("the pointer over the close mark does not say so") }
        strip.mouseExited(with: NSEvent.mouseEvent(
            with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 0, pressure: 0
        )!)
        guard strip.hover.id == nil, !strip.hover.onClose else { fail("the tab stays lit when the pointer leaves") }
        let hands = strip.pointerRects()
        let count = shell.tabs.count(where: { $0.path.hasPrefix(dir) })
        guard hands.count == count, hands.contains(where: { $0.contains(NSPoint(x: rect.midX, y: rect.midY)) }) else {
            fail("the pointer is not a hand over each tab: \(hands)")
        }
        // The tree's header icons and the workspace button are clicks too.
        let header = shell.view.sidebar
        for button in [header.filterButton, header.visibilityButton] {
            guard button.pointerRects() == [button.bounds] else { fail("the pointer is not a hand over a header icon") }
            button.setHovering(true)
            guard button.isHovering else { fail("a header icon does not light under the pointer") }
            button.setHovering(false)
            guard !button.isHovering else { fail("a header icon stays lit") }
        }
        guard shell.chip.pointerRects() == [shell.chip.bounds]
        else { fail("the pointer is not a hand over the workspace button") }
        step(
            "tabs, their close marks, the tree's header icons and the workspace button light under the pointer, a hand over them"
        )

        // Keys: Control-Tab and its pair, the macOS ones, and Command-W. Three tabs, so next and previous differ.
        await open("d.txt")
        await wait("three tabs") { names() == ["a.txt", "c.txt", "d.txt"] && current() == "d.txt" }
        shell.focusEditor()
        guard tabKey() else { fail("Control-Tab is not taken") }
        await wait("Control-Tab for the next tab, round again") { current() == "a.txt" }
        guard tabKey() else { fail("Control-Tab is not taken") }
        await wait("Control-Tab for the next tab") { current() == "c.txt" }
        // Not Control-Command-Tab, nor with Option: those are other keys'.
        guard !tabKey(extra: .command),
              !tabKey(extra: .option) else { fail("Control-Tab with Command or Option was taken") }
        guard tabKey(shift: true) else { fail("Control-Shift-Tab is not taken") }
        await wait("Control-Shift-Tab for the previous tab") { current() == "a.txt" }
        guard tabKey(shift: true) else { fail("Control-Shift-Tab is not taken") }
        await wait("Control-Shift-Tab for the previous tab, round again") { current() == "d.txt" }
        guard chord("}", "]", [.command, .shift]) else { fail("no menu item takes Command-Shift-]") }
        await wait("Command-Shift-] for the next tab") { current() == "a.txt" }
        guard chord("{", "[", [.command, .shift]) else { fail("no menu item takes Command-Shift-[") }
        await wait("Command-Shift-[ for the previous tab") { current() == "d.txt" }
        _ = await lua("vim.cmd('FrameTabs prev')")
        await wait(":FrameTabs prev") { current() == "c.txt" }
        _ = await lua("vim.cmd('FrameTabs 3')")
        await wait(":FrameTabs 3") { current() == "d.txt" }
        _ = await lua("vim.cmd('FrameTabs next')")
        await wait(":FrameTabs next") { current() == "a.txt" }
        _ = await lua("vim.cmd('FrameTabs 2')")
        await wait(":FrameTabs 2") { current() == "c.txt" }
        guard chord("w", "w", .command) else { fail("no menu item takes Command-W") }
        await wait("Command-W to close the tab") { names() == ["a.txt", "d.txt"] }
        step(
            "Control-Tab and Control-Shift-Tab (and Command-Shift-] [) go round the tabs, Command-W closes one, `:FrameTabs` does too"
        )

        // The places: under the grid, beside it, in the sidebar, nowhere.
        await open("b.txt")
        await wait("three tabs") { names().count == 3 }
        _ = await lua("vim.cmd('FrameTabs bottom')")
        await wait("the strip under the grid") { view.tabsPlacement == .bottom }
        view.layoutSubtreeIfNeeded()
        guard !strip.isHidden, strip.frame.minY > editor.frame.maxY, strip.frame.maxY < shell.view.statusBar.frame.minY
        else { fail("the strip is not under the grid: \(strip.frame), the grid \(editor.frame)") }
        shell.app.setTabs(placement: .right)
        view.layoutSubtreeIfNeeded()
        guard strip.isHidden, !list.isHidden, list.frame.minX > editor.frame.maxX, list.frame.maxX <= view.bounds.width
        else { fail("the list is not beside the grid: \(list.frame), the grid \(editor.frame)") }
        click(list, tab: "a.txt")
        await wait("a click in the list") { current() == "a.txt" }

        // In the status bar: no strip, no list; the file's name is a button that lists the open files.
        let bar = shell.view.statusBar
        _ = await lua("vim.cmd('FrameTabs statusbar')")
        await wait("the tabs in the status bar") { view.tabsPlacement == .statusbar }
        await wait("the bar to know how many") { bar.state.picker == names().count }
        view.layoutSubtreeIfNeeded()
        bar.display()
        guard strip.isHidden, list.isHidden, editor.frame.minY == shell.view.sidebar.frame.minY,
              let fileRect = bar.pointerRects().last
        else { fail("with the tabs in the status bar there is still a strip or list, or the name is no button") }
        func clickFile() {
            bar.mouseDown(with: NSEvent.mouseEvent(
                with: .leftMouseDown, location: bar.convert(NSPoint(x: fileRect.midX, y: fileRect.midY), to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: shell.window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1
            )!)
        }
        let shownBefore = shell.tabs.first(where: \.current)?.id
        clickFile()
        guard let picker = shell.tabPicker, shell.modes.surface == .picker,
              shell.modes.label(editorMode: "normal") == "TABS", shell.window.firstResponder === picker
        else { fail("a click on the file's name did not bring up the list: \(shell.modes.surface)") }
        guard picker.tabs.count == names().count, picker.cursor == shownBefore, picker.list.highlightedID == shownBefore
        else { fail("the list does not show the open files with the keyboard on the shown one") }
        // Styled as the tree is: the editor's font and the scheme's colours, in the same palette.
        guard picker.list.largeText, picker.list.look.palette == shell.tree.look.palette,
              picker.list.look.font == shell.tree.look.font
        else { fail("the list is not in the tree's font and colours") }
        step(
            "a click on the file's name brings up a list in the tree's font and colours, the keyboard on the shown file"
        )
        // Keys: down moves the keyboard, Return shows that file and puts the list away.
        func press(_ code: UInt16, _ characters: String) {
            picker.keyDown(with: key(characters, code: code))
        }
        press(125, "\u{F701}")
        guard let movedTo = picker.cursor,
              movedTo != shownBefore else { fail("the down arrow did not move the keyboard") }
        press(126, "\u{F700}")
        guard picker.cursor == shownBefore else { fail("the up arrow did not move it back") }
        press(125, "\u{F701}")
        bar.setHoveringFile(true)
        if let path = ProcessInfo.processInfo.environment["SILL_CHECK_SHOT"] {
            try? await Task.sleep(for: .milliseconds(200))
            do { try shot(editor: editor, to: path.replacingOccurrences(of: ".png", with: "-pick.png")) } catch {
                fail("the picker's shot: \(error)")
            }
        }
        bar.setHoveringFile(false)
        let target = shell.tabs.first { $0.id == movedTo }?.name
        press(36, "\r")
        await wait("Return to show the file the keyboard was on") { current() == target }
        guard shell.tabPicker == nil, shell.modes.surface == .editor, shell.window.firstResponder === editor else {
            fail("the list stayed, or the keyboard is not the editor's: \(shell.modes.surface)")
        }
        // Filtering: `/` starts it, letters (j and k too) type, Escape ends the filter and not the list, then j and k move.
        guard let other = shell.tabs.first(where: { !$0.current && $0.path.hasPrefix(dir) && $0.name.first != "t" })
        else {
            fail("no other tab to filter for")
        }
        shell.showTabPicker()
        guard let filtering = shell.tabPicker else { fail("the list did not come up to filter") }
        let all = filtering.tabs.count
        filtering.keyDown(with: key("/", code: 44))
        guard filtering.filter == "", shell.modes.pickerFiltering,
              shell.modes.label(editorMode: "normal") == "FILTER"
        else {
            fail("`/` did not start the filter")
        }
        filtering.keyDown(with: key("j", code: 38))
        guard filtering.filter == "j",
              filtering.visible.isEmpty else { fail("j did not type into the filter: \(filtering.filter ?? "nil")") }
        filtering.keyDown(with: key("\u{7F}", code: 51))
        guard filtering.filter == "", filtering.visible.count == all else { fail("backspace did not take it back") }
        let letter = String(other.name.prefix(1))
        filtering.keyDown(with: key(letter, code: 2))
        guard filtering.visible.map(\.name) == [other.name], filtering.cursor == other.id else {
            fail("the filter did not narrow to \(other.name): \(filtering.visible.map(\.name))")
        }
        if let path = ProcessInfo.processInfo.environment["SILL_CHECK_SHOT"] {
            try? await Task.sleep(for: .milliseconds(150))
            do { try shot(editor: editor, to: path.replacingOccurrences(of: ".png", with: "-pickfilter.png")) } catch {
                fail("the filter's shot: \(error)")
            }
        }
        filtering.keyDown(with: key("\u{1B}", code: 53))
        guard shell.tabPicker === filtering, filtering.filter == nil, !shell.modes.pickerFiltering,
              filtering.visible.count == all, shell.modes.surface == .picker
        else { fail("Escape did not end the filter and keep the list") }
        let cursorBefore = filtering.cursor
        filtering.keyDown(with: key("j", code: 38))
        guard filtering.cursor != cursorBefore else { fail("j does not move once the filter has ended") }
        filtering.keyDown(with: key("/", code: 44))
        filtering.keyDown(with: key(letter, code: 2))
        filtering.keyDown(with: key("\r", code: 36))
        await wait("Return in the filter to show \(other.name)") { current() == other.name }
        guard shell.tabPicker == nil,
              shell.modes.surface == .editor else { fail("the list stayed after Return in the filter") }
        step(
            "`/` filters the open files by typing; j and k move when not filtering; Escape ends the filter, then the list"
        )
        // Escape puts it away and the keyboard goes back to where it was.
        shell.showTabPicker()
        guard let again = shell.tabPicker else { fail("the list did not come up again") }
        again.keyDown(with: key("\u{1B}", code: 53))
        guard shell.tabPicker == nil, shell.modes.surface == .editor else { fail("Escape did not put the list away") }
        // x closes the tab the keyboard is on, and the list stays with what is left.
        shell.showTabPicker()
        guard let third = shell.tabPicker else { fail("the list did not come up a third time") }
        let openBefore = names().count
        third.keyDown(with: key("x", code: 7))
        await wait("x to close that tab") { names().count == openBefore - 1 }
        guard shell.tabPicker != nil,
              third.tabs.count == names().count else { fail("the list did not follow the tabs") }
        // A click on a row shows it; Escape from the list in the tree goes back to the tree.
        guard let row = third.list.frame(ofTab: third.tabs[0].id) else { fail("no row") }
        let before = current()
        third.list.mouseDown(with: NSEvent.mouseEvent(
            with: .leftMouseDown, location: third.list.convert(NSPoint(x: row.minX + 40, y: row.midY), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: shell.window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1
        )!)
        await wait("a click on a row to show that file") { current() == third.tabs[0].name }
        _ = before
        shell.tree.focus()
        await wait("the keyboard in the tree") { shell.modes.surface == .tree }
        shell.showTabPicker()
        guard let fourth = shell.tabPicker else { fail("the list did not come up from the tree") }
        fourth.keyDown(with: key("\u{1B}", code: 53))
        guard shell.tabPicker == nil, shell.modes.surface == .tree,
              shell.window.firstResponder === shell.tree.outline
        else {
            fail("Escape did not give the keyboard back to the tree: \(shell.modes.surface)")
        }
        shell.focusEditor()
        shell.focusEditor()
        // By keyboard: Option-Command-E, `:FrameTabs list`, and a mapping for it; the same key puts it away.
        guard chord("´", "e", [.command, .option]) else { fail("no menu item takes Option-Command-E") }
        guard shell.tabPicker != nil,
              shell.modes.surface == .picker else { fail("Option-Command-E did not bring up the list") }
        guard chord("´", "e", [.command, .option]) else { fail("no menu item takes Option-Command-E") }
        guard shell.tabPicker == nil,
              shell.modes.surface == .editor else { fail("Option-Command-E did not put the list away") }
        _ = await lua("vim.cmd('FrameTabs list')")
        await wait(":FrameTabs list to bring up the list") { shell.tabPicker != nil }
        // The pointer over the list is not the editor's I-beam; over the grid it is.
        func moveEditor(to point: NSPoint, in view: NSView) {
            editor.mouseMoved(with: NSEvent.mouseEvent(
                with: .mouseMoved, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: shell.window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
            )!)
        }
        guard let listed = shell.tabPicker else { fail("no list") }
        NSCursor.arrow.set()
        moveEditor(to: NSPoint(x: 30, y: 10), in: listed.list)
        guard NSCursor.current == NSCursor.arrow else { fail("the editor's I-beam is over the list's rows") }
        listed.keyDown(with: key("\u{1B}", code: 53))
        NSCursor.arrow.set()
        moveEditor(to: NSPoint(x: 400, y: 200), in: editor)
        guard NSCursor.current == NSCursor.iBeam else { fail("the editor lost its I-beam over the grid") }
        step("Option-Command-E and `:FrameTabs list` bring up the list; over it the pointer is not the editor's I-beam")
        // Every mode on the leader (whatever nvim's is): the keys are bound, and they do what they say.
        for lhs in [
            "<leader>e",
            "<leader>E",
            "<leader>w",
            "<leader>t",
            "<leader>o",
            "<leader>fw",
            "<leader>fo",
            "<C-w>e",
        ] {
            let mapped = await lua("return vim.fn.maparg('\(lhs)', 'n')")?.stringValue ?? ""
            guard !mapped.isEmpty else { fail("\(lhs) is not bound") }
        }
        shell.app.sources = WorkspaceSources(
            roots: { [] }, heed: { [] }, opened: { [:] }, cached: { [] }, remember: { _ in }
        )
        shell.focusEditor()
        let leader = await lua("return vim.g.mapleader or '\\\\'")?.stringValue ?? "\\"
        channel.send(keys: leader + "t")
        await wait("<leader>t to bring up the open files") { shell.tabPicker != nil }
        shell.escape()
        guard shell.tabPicker == nil else { fail("Escape did not put the list away") }
        channel.send(keys: leader + "o")
        await wait("<leader>o to bring up the open files too") { shell.tabPicker != nil }
        shell.escape()
        guard shell.tabPicker == nil else { fail("Escape did not put the list away") }
        channel.send(keys: leader + "w")
        await wait("<leader>w to bring up the workspace switcher") { shell.switcher != nil }
        shell.escape()
        guard shell.switcher == nil else { fail("Escape did not put the switcher away") }
        channel.send(keys: leader + "E")
        await wait("<leader>E to open the tree's filter") { shell.modes.treeMode == .filter }
        shell.escape()
        await wait("Escape to end the filter") { shell.modes.treeMode == .normal }
        shell.focusEditor()
        step(
            "every mode is on the leader: e the tree, E its filter, w the workspaces, t or o the open files (and fw, fo)"
        )
        shell.app.setTabs(placement: .right)
        await wait("the bar to stop offering the list") { bar.state.picker == 0 }
        step(
            "the list: arrows move, Return shows, Escape goes back (to the tree if it came from there), x closes, a click shows a row"
        )
        shell.app.setTabs(placement: .hidden)
        view.layoutSubtreeIfNeeded()
        guard strip.isHidden, list.isHidden else { fail("hidden tabs are showing") }
        _ = await lua("vim.cmd('FrameTabs show')")
        await wait("show to bring them back") { view.tabsPlacement == .right }
        _ = await lua("vim.cmd('FrameTabs tree')")
        try? await Task.sleep(for: .milliseconds(200))
        guard view.tabsPlacement == .right else { fail("a placement that is gone was taken") }
        _ = await lua("vim.cmd('FrameTabs top')")
        await wait("top again") { view.tabsPlacement == .top }
        view.layoutSubtreeIfNeeded()
        // For the picture: files of several kinds, one changed and not saved, the rest quiet previews.
        for name in ["Order.cs", "Util.swift", "app.ts", "README.md"] {
            try? "\(name)\n".write(toFile: dir + "/" + name, atomically: true, encoding: .utf8)
            await open(name)
        }
        _ =
            await lua(
                "vim.cmd('edit ' .. vim.fn.fnameescape('\(dir)/b.txt')); vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'changed' }); vim.cmd('edit ' .. vim.fn.fnameescape('\(dir)/Util.swift'))"
            )
        await wait("the changed tab") {
            shell.tabs.contains { $0.name == "b.txt" && $0.modified } && current() == "Util.swift"
        }
        try? await Task.sleep(for: .milliseconds(300))
        // The pointer on the shown tab's close mark and on the filter icon, for the picture.
        if let shown = shell.tabs.first(where: \.current), let frame = strip.frame(ofTab: shown.id) {
            moved(strip, to: NSPoint(x: frame.maxX - 15, y: frame.midY))
        }
        shell.view.sidebar.filterButton.setHovering(true)
        if let path = ProcessInfo.processInfo.environment["SILL_CHECK_SHOT"] {
            do { try shot(editor: editor, to: path.replacingOccurrences(of: ".png", with: "-tabs.png")) } catch {
                fail("the tabs' shot: \(error)")
            }
        }
        shell.view.sidebar.filterButton.setHovering(false)
        // The picture is taken; those tabs are dropped, so the steps after start as they did.
        _ =
            await lua(
                "for _, n in ipairs({ 'Order.cs', 'Util.swift', 'app.ts', 'README.md' }) do vim.cmd('silent! bwipeout! ' .. vim.fn.bufnr('\(dir)/' .. n)) end"
            )

        _ = await lua("vim.cmd('silent! bwipeout! ' .. vim.fn.bufnr('\(dir)/b.txt'))")
        await wait("the changed tab gone") { !names().contains("b.txt") }
        step("tabs go top, bottom or right, or are hidden, and come back where they were")

        // The icons are the tree's, in colour; the selection is the colour scheme's, in the tabs and the tree.
        let order = FrameTab(id: 1, path: "/x/Order.cs")
        let plain = FrameTab(id: 2, path: "/x/notes.txt")
        let treeLook = shell.tree.look
        guard TabsView.iconColor(order, look: treeLook).withAlphaComponent(1) == TreeCellView.color(
            .dotnet,
            look: treeLook
        ),
            TabsView.iconColor(order, look: treeLook) != TabsView.iconColor(plain, look: treeLook)
        else { fail("a tab's icon is not the tree's colour for its kind") }
        _ = await lua("vim.api.nvim_set_hl(0, 'Visual', { bg = 0x336699 }); require('frame.theme').send()")
        await wait("the colour scheme's selection colour") { shell.tree.look.palette.selection == 0x336699 }
        guard strip.look.palette.selection == 0x336699, strip.look.focusedSelection == NSColor(frameRGB: 0x336699),
              shell.tree.look.focusedSelection == NSColor(frameRGB: 0x336699)
        else { fail("the tabs and the tree do not share the scheme's selection colour") }
        step("a tab's icon is the tree's, in colour; the selection is the colour scheme's, in the tabs and in the tree")

        // Too many: past the maximum the tabs nobody edited are closed, the edited ones stay.
        _ = await lua("""
        vim.cmd('edit ' .. vim.fn.fnameescape('\(dir)/a.txt'))
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'edited' })
        vim.cmd('write')
        """)
        shell.app.setTabsMax(3)
        await waitAsync("the maximum in nvim") {
            await lua("return require('frame.tabs').options().max")?.integerValue == 3
        }
        await open("d.txt")
        await open("e.txt")
        await open("f.txt")
        await wait("the unedited tabs closed past the maximum") { names().count == 3 && current() == "f.txt" }
        guard names().contains("a.txt"), current() == "f.txt" else {
            fail("the edited tab or the current one was closed: \(names())")
        }
        shell.app.setTabsAutoclose(false)
        await waitAsync("autoclose off in nvim") {
            await lua("return require('frame.tabs').options().autoclose")?.boolValue == false
        }
        await open("b.txt")
        await open("c.txt")
        await wait("tabs past the maximum when autoclose is off") { names().count == 5 && current() == "c.txt" }
        shell.app.setTabsAutoclose(true)
        _ = await lua("vim.cmd('FrameTabs hide')")
        await wait("hidden") { view.tabsPlacement == .hidden }
        // Hidden, nvim is told not to close anything: what is not seen is not tidied.
        await waitAsync("autoclose off while hidden") {
            await lua("return require('frame.tabs').options().autoclose")?.boolValue == false
        }
        await open("d.txt")
        await open("e.txt")
        await wait("every open file still a tab while hidden") { names().count >= 5 && current() == "e.txt" }
        _ = await lua("vim.cmd('FrameTabs top')")
        shell.app.setTabsMax(10)
        await wait("the strip back") { view.tabsPlacement == .top }
        _ = await lua("vim.cmd('silent! %bwipeout!')")
        await wait("no tabs") { names().isEmpty }
        step("past the maximum the tabs never edited are closed, the edited stay; off, or hidden, nothing is closed")
    }

    /// A window for each workspace: one folder, one window, found again by its real path; each with its own nvim in its
    /// own folder, and closing one leaves the other.
    private func windowSteps() async {
        let base = RealPath.of(NSTemporaryDirectory()) + "frame-windows-\(UUID().uuidString)"
        let other = base + "/other"
        try? FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(atPath: base + "/link", withDestinationPath: other)
        func cwd(_ controller: FrameWindowController) async -> String? {
            await (try? controller.session.channel.lua("return vim.fn.getcwd()"))?.stringValue
        }
        let first = shell
        let windows = app.controllers.count
        let second = app.open(folder: other)
        guard second !== first,
              app.controllers.count == windows + 1 else { fail("a second folder made no second window") }
        await waitAsync("the second window's nvim in its own folder") { await cwd(second) == other }
        guard await cwd(first) != other else { fail("the first window's nvim moved to the second's folder") }
        guard second.window !== first.window, second.tree !== first.tree, second.session !== first.session
        else { fail("the two windows share a window, a tree or an nvim") }
        step("a second folder opens a window of its own: its own nvim, tree and folder")
        guard app.open(folder: other) === second, app.open(folder: base + "/link") === second,
              app.controllers.count == windows + 1
        else { fail("a folder already open (by its path, or through a link) opened another window") }
        step("a folder that is open is found again, by its real path, not opened twice")
        app.close(second)
        await wait("the second window to go") { app.controllers.count == windows }
        guard app.controllers.contains(where: { $0 === first }), await cwd(first) != nil else {
            fail("closing the second window took the first with it")
        }
        step("closing one window leaves the other")
    }

    /// The workspace switcher, against two repositories and a worktree that is not under the roots: the rows heed
    /// names and the rows it does not, what a query finds, and where Return, a click and Escape go.
    private func switcherSteps() async {
        let base = RealPath.of(NSTemporaryDirectory()) + "frame-switcher-\(UUID().uuidString)"
        let roots = base + "/projects", alpha = roots + "/alpha", beta = roots + "/beta"
        let worktree = base + "/wt/alpha-blog"
        for folder in [alpha, beta] {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try? "x\n".write(toFile: folder + "/file.txt", atomically: true, encoding: .utf8)
            git(folder, "init", "-q", "-b", "main")
            git(folder, "add", ".")
            git(folder, "commit", "-q", "-m", "first")
        }
        try? FileManager.default.createDirectory(atPath: base + "/wt", withIntermediateDirectories: true)
        git(alpha, "worktree", "add", "-q", "-b", "feature/blog-option", worktree)
        let named = HeedSession(
            id: "s1", title: "Add the blog option", agent: "claude", state: "working", needsYou: false,
            directory: worktree, repo: "me/alpha", branch: "feature/blog-option", lastActivity: Date()
        )
        // This window's own folder, with a session that needs the person: it comes first, and is not where Return goes.
        let here = HeedSession(
            id: "s2", title: "This window", agent: "claude", state: "asking", needsYou: true,
            directory: shell.tree.rootPath, repo: "me/work", branch: "main", lastActivity: Date()
        )
        // The fixture's roots, and heed as a stand-in: a session for the worktree, or no heed at all.
        // When Frame opened them is the order: this window, then beta, then alpha; the worktree was never opened.
        let hereFolder = shell.tree.rootPath ?? shell.workspace
        let opened: [String: Date] = [
            hereFolder: Date(timeIntervalSinceNow: -60), beta: Date(timeIntervalSinceNow: -120),
            alpha: Date(timeIntervalSinceNow: -240),
        ]
        // `slow`: heed answers late; `cached`: what was found last time, shown before anything is looked for.
        func sources(heed: [HeedSession], slow: Bool = false, cached: [Checkout] = []) -> WorkspaceSources {
            WorkspaceSources(
                roots: { [roots] },
                heed: {
                    if slow { try? await Task.sleep(for: .seconds(1.5)) }
                    return heed
                },
                opened: { opened }, cached: { cached }, remember: { _ in }
            )
        }
        func paths(_ panel: SwitcherView) -> [String] { panel.matches.map(\.workspace.path) }
        func rows(_ panel: SwitcherView) -> [String] { panel.matches.map(\.workspace.primary) }
        func type(_ panel: SwitcherView, _ text: String) {
            guard let editor = panel.field.currentEditor() as? NSTextView
            else { fail("the search line is not being typed in") }
            editor.string = text
            editor.didChangeText()
        }
        let windows = app.controllers.count
        let editor = shell.editor!

        // Without heed: the worktree is its branch, the repositories their names; nothing waits on heed.
        app.sources = sources(heed: [])
        shell.showSwitcher()
        guard let panel = shell.switcher else { fail("the switcher did not come up") }
        await wait("the workspaces without heed") {
            rows(panel).contains("feature/blog-option") && rows(panel).contains("beta")
        }
        guard rows(panel).contains("alpha"), !rows(panel).contains("Add the blog option") else {
            fail("without heed, the rows are: \(rows(panel))")
        }
        guard shell.window.firstResponder === panel.field.currentEditor(), shell.modes.surface == .switcher,
              shell.modes.label(editorMode: "normal") == "SWITCH"
        else { fail("the search line has no keyboard, or the modes do not say switcher: \(shell.modes.surface)") }
        step("the switcher lists repositories and worktrees, a worktree by its branch, with no heed")
        shell.closeSwitcher()
        guard shell.switcher == nil, shell.window.firstResponder === editor else {
            fail(
                "closing the switcher did not give the keyboard back: \(String(describing: shell.window.firstResponder))"
            )
        }

        // With heed: the worktree is what the work is about, and a query finds it by that.
        let known = Checkouts.find(roots: [roots])
        app.sources = sources(heed: [named, here], slow: true, cached: known)
        shell.tree.focus()
        shell.showSwitcher()
        guard let withHeed = shell.switcher else { fail("the switcher did not come up again") }
        // At once, from the cache and in the order Frame knows: no heed yet, so no titles, and nothing waited for.
        let order = [hereFolder, beta, alpha, worktree]
        guard paths(withHeed) == order, !rows(withHeed).contains("Add the blog option") else {
            fail("the first paint is not the cached list in the order last opened: \(paths(withHeed))")
        }
        await wait("heed's title") { rows(withHeed).contains("Add the blog option") }
        guard let row = withHeed.matches.first(where: { $0.workspace.path == worktree }),
              row.workspace.secondary.contains("alpha")
        else { fail("the titled row is not the worktree, with its repository under it") }
        // heed's titles came in, and no row moved: needing the person does not reorder, nor does activity.
        guard paths(withHeed) == order, withHeed.matches.first?.workspace.needsYou == true else {
            fail("heed's word moved the rows: \(paths(withHeed))")
        }
        guard withHeed.selectedWorkspace?.isCurrent == false
        else { fail("Return would go to the workspace already shown") }
        step("heed names the worktree by what the work is about; the repository and branch stand under it")
        step(
            "the first paint is the cached list, last opened first; heed arriving late names rows and moves none; Return goes to the one before this"
        )
        if let path = ProcessInfo.processInfo.environment["SILL_CHECK_SHOT"] {
            do {
                try shot(editor: editor, to: path.replacingOccurrences(of: ".png", with: "-switcher.png"))
                step("saved the switcher's picture")
            } catch { fail("the switcher's shot: \(error)") }
        }
        let field = withHeed.field
        type(withHeed, "blog opt")
        await wait("the query to find the worktree") { rows(withHeed) == ["Add the blog option"] }
        guard withHeed.matches.first?.primaryHits.isEmpty == false else { fail("the match shows no characters found") }
        type(withHeed, "zzzz")
        await wait("no match") { withHeed.matches.isEmpty }
        type(withHeed, "alpha")
        await wait("both alpha's checkouts") { withHeed.matches.count == 2 }
        step("a query finds a workspace by its title, branch or repository; none found shows none")

        // Escape closes it and the keyboard goes back to the tree it came from.
        field.currentEditor()?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        guard shell.switcher == nil, shell.window.firstResponder === shell.tree.outline else {
            fail("Escape did not close it into the tree: \(String(describing: shell.window.firstResponder))")
        }
        guard shell.modes.surface == .tree
        else { fail("the modes did not go back to the tree: \(shell.modes.surface)") }
        step("Escape closes it and the keyboard goes back to where it was")

        // The chip at the sidebar's foot: the repository's name and its branch; it opens the switcher.
        let chip = shell.chip
        guard chip.name == ((shell.tree.rootPath ?? "") as NSString).lastPathComponent, chip.branch == "main",
              !chip.isWorktree
        else {
            fail("the chip says \(chip.name) \(chip.branch), the tree is at \(shell.tree.rootPath ?? "none")")
        }
        chip.onClick?()
        guard let chipped = shell.switcher else { fail("the chip did not open the switcher") }
        shell.closeSwitcher()
        _ = chipped
        step("the chip under the sidebar names the git root and its branch, and opens the switcher")

        // Return goes to the worktree in this window: nvim starts again in its folder, the tree is rooted there.
        shell.showSwitcher()
        guard let third = shell.switcher else { fail("the switcher did not come up a third time") }
        await wait("the rows") { rows(third).contains("Add the blog option") }
        type(third, "blog")
        await wait("the query") { rows(third) == ["Add the blog option"] }
        third.field.currentEditor()?.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        await wait("this window on the worktree") { shell.workspace == worktree }
        guard app.controllers.count == windows else { fail("Return opened a window instead of using this one") }
        await waitAsync("its nvim in the worktree") {
            await (try? shell.session.channel.lua("return vim.fn.getcwd()"))?.stringValue == worktree
        }
        await wait("the tree rooted in the worktree") { shell.tree.rootPath == worktree }
        guard shell.switcher == nil else { fail("the switcher stayed up after Return") }
        await wait("the chip to name the repository, not the worktree's folder") {
            chip.name == "alpha" && chip.branch == "feature/blog-option" && chip.isWorktree
        }
        // With a branch to say: beside the sidebar the bar leaves it to the sidebar; without the sidebar it says it.
        let statusBar = shell.view.statusBar
        await wait("the bar to leave the branch to the sidebar") { statusBar.state.branch.isEmpty }
        shell.setSidebar(visible: false)
        await wait("the bar to say the branch with no sidebar") { statusBar.state.branch == "feature/blog-option" }
        shell.setSidebar(visible: true)
        await wait("the branch back with the sidebar") { statusBar.state.branch.isEmpty }
        step(
            "Return opens the workspace in this window: nvim in its folder, the tree rooted there, the chip on its repository"
        )

        // Shift-Return opens it in a new window; one that has a window is gone to, not opened again.
        shell.showSwitcher()
        guard let fourth = shell.switcher else { fail("the switcher did not come up in the worktree") }
        fourth.shiftHeld = { true }
        await wait("the rows there") {
            fourth.matches.contains { $0.workspace.path == worktree && $0.workspace.isCurrent }
        }
        type(fourth, "beta")
        await wait("beta, the best match, selected") {
            fourth.selectedWorkspace?.path == beta && rows(fourth).first == "beta"
        }
        fourth.field.currentEditor()?.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        await wait("a window for beta") { app.controllers.count == windows + 1 }
        guard let beside = app.controllers.last, beside.workspace == beta, shell.workspace == worktree else {
            fail("Shift-Return did not open beta in a window of its own")
        }
        await waitAsync("beta's nvim in beta") {
            await (try? beside.session.channel.lua("return vim.fn.getcwd()"))?.stringValue == beta
        }
        step("Shift-Return opens the workspace in a new window, and this one stays where it was")
        beside.showSwitcher()
        guard let fifth = beside.switcher else { fail("the switcher did not come up in the new window") }
        await wait("the rows in the new window") {
            fifth.matches.contains { $0.workspace.path == beta && $0.workspace.isCurrent }
                && fifth.matches.contains { $0.workspace.path == worktree && $0.workspace.isOpen }
        }
        type(fifth, "blog")
        await wait("the worktree") { rows(fifth) == ["Add the blog option"] }
        fifth.choose()
        try? await Task.sleep(for: .milliseconds(500))
        guard app.controllers.count == windows + 1, beside.workspace == beta, shell.workspace == worktree else {
            fail("a workspace that has a window was opened again, or moved")
        }
        step("a workspace that has a window is gone to, not opened twice; ones with windows are marked")
        // Back to the windows there were.
        for controller in app.controllers.dropFirst(windows) {
            app.close(controller)
        }
        await wait("the extra windows gone") { app.controllers.count == windows }
        app.sources = .live
    }

    /// The colour of one cell of the grid as it is drawn (the middle of its first pixel row), by rendering a frame.
    private func pixel(_ editor: EditorView, row: Int, col: Int) throws -> (red: Int, green: Int, blue: Int) {
        let scale: CGFloat = 1
        guard let device = MTLCreateSystemDefaultDevice() else { throw ShotFailure() }
        let renderer = try GridRenderer(
            device: device, font: editor.metrics.regular, cellSize: editor.metrics.cellSize, scale: scale,
            pixelFormat: .bgra8Unorm
        )
        let size = editor.bounds.size
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: Int(size.width * scale), height: Int(size.height * scale), mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor),
              let commands = renderer.render(editor.currentFrame, to: texture) else { throw ShotFailure() }
        commands.waitUntilCompleted()
        let cell = editor.metrics.cellSize
        let x = min(Int((CGFloat(col) + 0.5) * CGFloat(cell.width) * scale), texture.width - 1)
        let y = min(Int((CGFloat(row) + 0.5) * CGFloat(cell.height) * scale), texture.height - 1)
        var bytes = [UInt8](repeating: 0, count: 4)
        texture.getBytes(&bytes, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        return (Int(bytes[2]), Int(bytes[1]), Int(bytes[0]))
    }

    private func shot(editor: EditorView, to path: String) throws {
        let size = shell.view.bounds.size, scale: CGFloat = 2
        guard let device = MTLCreateSystemDefaultDevice() else { throw ShotFailure() }
        let renderer = try GridRenderer(
            device: device,
            font: editor.metrics.regular,
            cellSize: editor.metrics.cellSize,
            scale: scale,
            pixelFormat: .bgra8Unorm
        )
        let grid = editor.bounds.size
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(grid.width * scale),
            height: Int(grid.height * scale),
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor),
              let commands = renderer.render(editor.currentFrame, to: texture) else { throw ShotFailure() }
        commands.waitUntilCompleted()
        guard let gridRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: texture.width,
            pixelsHigh: texture.height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: texture.width * 4,
            bitsPerPixel: 32
        ),
            let pixels = gridRep.bitmapData else { throw ShotFailure() }
        texture.getBytes(
            pixels,
            bytesPerRow: texture.width * 4,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0
        )
        for index in stride(from: 0, to: texture.width * texture.height * 4, by: 4) {
            (pixels[index], pixels[index + 2]) = (pixels[index + 2], pixels[index])
        }
        gridRep.size = grid
        // A transparent picture with room for the shadow, the window rounded in it.
        let pad: CGFloat = 24
        let canvas = NSSize(width: size.width + 2 * pad, height: size.height + 2 * pad)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(canvas.width * scale),
            pixelsHigh: Int(canvas.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { throw ShotFailure() }
        // In points before the context is made, so what is drawn is at the backing scale.
        rep.size = canvas
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { throw ShotFailure() }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let frame = NSRect(x: pad, y: pad, width: size.width, height: size.height)
        // macOS 26 rounds a window's corners by about 16 points.
        let shape = NSBezierPath(roundedRect: frame, xRadius: 16, yRadius: 16)
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 18
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.set()
        NSColor(rgb: editor.screen.defaultBackground).setFill()
        shape.fill()
        NSShadow().set()
        shape.addClip()
        // The view is flipped: the grid's frame from the top, the picture's from the bottom.
        gridRep.draw(in: NSRect(
            x: pad + editor.frame.minX,
            y: pad + size.height - editor.frame.maxY,
            width: grid.width,
            height: grid.height
        ))
        // The native panes are ordinary views, drawn as they are (the grid is Metal, so it is drawn above).
        let sidebar = shell.view.sidebar
        if !sidebar.isHidden, let pane = sidebar.bitmapImageRepForCachingDisplay(in: sidebar.bounds) {
            // The view paints only its rounded island: what is behind it in the window is the window's own colour.
            if let backing = NSGraphicsContext(bitmapImageRep: pane) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = backing
                NSColor(rgb: editor.screen.defaultBackground).setFill()
                sidebar.bounds.fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            sidebar.cacheDisplay(in: sidebar.bounds, to: pane)
            pane.draw(in: NSRect(
                x: pad + sidebar.frame.minX,
                y: pad + size.height - sidebar.frame.maxY,
                width: sidebar.frame.width,
                height: sidebar.frame.height
            ))
        }
        for tabs in [shell.tabStrip, shell.tabList] where !tabs.isHidden {
            if let pane = tabs.bitmapImageRepForCachingDisplay(in: tabs.bounds) {
                if let backing = NSGraphicsContext(bitmapImageRep: pane) {
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = backing
                    NSColor(rgb: editor.screen.defaultBackground).setFill()
                    tabs.bounds.fill()
                    NSGraphicsContext.restoreGraphicsState()
                }
                tabs.cacheDisplay(in: tabs.bounds, to: pane)
                pane.draw(in: NSRect(
                    x: pad + tabs.frame.minX, y: pad + size.height - tabs.frame.maxY, width: tabs.frame.width,
                    height: tabs.frame.height
                ))
            }
        }
        let button = shell.chip
        if !button.isHidden, let pane = button.bitmapImageRepForCachingDisplay(in: button.bounds) {
            if let backing = NSGraphicsContext(bitmapImageRep: pane) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = backing
                NSColor(rgb: editor.screen.defaultBackground).setFill()
                button.bounds.fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            button.cacheDisplay(in: button.bounds, to: pane)
            pane.draw(in: NSRect(
                x: pad + button.frame.minX, y: pad + size.height - button.frame.maxY, width: button.frame.width,
                height: button.frame.height
            ))
        }
        let bar = shell.view.statusBar
        if !bar.isHidden, let pane = bar.bitmapImageRepForCachingDisplay(in: bar.bounds) {
            if let backing = NSGraphicsContext(bitmapImageRep: pane) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = backing
                NSColor(rgb: editor.screen.defaultBackground).setFill()
                bar.bounds.fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            bar.cacheDisplay(in: bar.bounds, to: pane)
            pane.draw(in: NSRect(
                x: pad + bar.frame.minX, y: pad + size.height - bar.frame.maxY, width: bar.frame.width,
                height: bar.frame.height
            ))
        }
        if let panel = shell.tabPicker, let pane = panel.bitmapImageRepForCachingDisplay(in: panel.bounds) {
            panel.cacheDisplay(in: panel.bounds, to: pane)
            pane.draw(in: NSRect(x: pad, y: pad, width: panel.bounds.width, height: panel.bounds.height))
        }
        if let panel = shell.switcher, let pane = panel.bitmapImageRepForCachingDisplay(in: panel.bounds) {
            panel.cacheDisplay(in: panel.bounds, to: pane)
            pane.draw(in: NSRect(x: pad, y: pad, width: panel.bounds.width, height: panel.bounds.height))
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { throw ShotFailure() }
        try data.write(to: URL(fileURLWithPath: path))
    }

    struct ShotFailure: Error {}
}
