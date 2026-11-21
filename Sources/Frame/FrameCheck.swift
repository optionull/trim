import AppKit
import FrameTree
import MessagePack
import Metal
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
        for _ in 0 ..< 100 {
            if ready() { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        fail("timed out waiting for " + what)
    }

    /// `wait` for something only nvim can say, asked of it each time.
    private func waitAsync(_ what: String, _ ready: () async -> Bool) async {
        for _ in 0 ..< 100 {
            if await ready() { return }
            try? await Task.sleep(for: .milliseconds(100))
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
        window.makeFirstResponder(editor)
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
        await treeSteps()
        await focusSteps()
        await forwardSteps()
        await layoutSteps()
        await switchSteps()
        await windowSteps()
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
            TreePalette(background: background, foreground: foreground)
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
            tree.outline.keyDown(with: key("\u{1B}", code: 53))
            await wait("Escape to the editor (round \(round))") { shell.window.firstResponder === shell.editor }
        }
        step("Escape in the editor's normal mode and in the tree go back and forth, again and again")
        // A mode leaves before the tree does: with a filter on, Escape ends it first.
        shell.editor.keyDown(with: key("\u{1B}", code: 53))
        await wait("the tree") { shell.window.firstResponder === tree.outline }
        tree.outline.keyDown(with: key("/"))
        type("ord")
        await wait("the filter") { tree.mode == .filter }
        tree.outline.window?.makeFirstResponder(tree.outline)
        tree.outline.keyDown(with: key("\u{1B}", code: 53))
        await wait("Escape to end the filter") { tree.mode == .normal }
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

    /// Switching config, when `XDG_CONFIG_HOME` holds one to switch to (verify.sh makes it): nvim restarts in the same
    /// window under that config, in the same folder, with the file it had open at the same line; and back again.
    private func switchSteps() async {
        let environment = ProcessInfo.processInfo.environment
        guard let home = environment["XDG_CONFIG_HOME"],
              let target = NvimConfigs.discover(environment: environment).first(where: { !$0.isBuiltIn })
        else { return }
        let folder = home + "/work"
        let file = folder + "/notes.txt"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? "one\ntwo\nthree\nfour\n".write(toFile: file, atomically: true, encoding: .utf8)
        let channel = shell.session.channel
        for command in ["%bwipeout!", "cd " + folder, "edit " + file, "call cursor(3, 2)"] {
            do { _ = try await channel.command(command) } catch { fail("\(command): \(error)") }
        }
        let window = shell.window
        // Through nvim, as a person does: `:FrameConfig name`.
        do { _ = try await channel.command("FrameConfig " + target.appName) } catch { fail("FrameConfig: \(error)") }
        await wait("nvim to restart under \(target.appName)") { shell.current == target }
        guard shell.window === window else { fail("the switch made another window") }
        func lua(_ code: String) async -> MessagePackValue? { try? await shell.session.channel.lua(code) }
        let there = await (try? shell.session.channel.lua(
            "return { vim.g.frame_marker or '', vim.fn.getcwd(), vim.api.nvim_buf_get_name(0), vim.api.nvim_win_get_cursor(0)[1] }"
        ))?.arrayValue
        let marker = there?[0].stringValue, cwd = there?[1].stringValue
        let name = there?[2].stringValue, line = there?[3].integerValue
        guard marker == target.appName else { fail("the config did not load: marker \(marker ?? "nil")") }
        guard cwd.map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }) ==
            URL(fileURLWithPath: folder).resolvingSymlinksInPath().path
        else { fail("the folder was not kept: \(cwd ?? "nil")") }
        guard name.map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }) ==
            URL(fileURLWithPath: file).resolvingSymlinksInPath().path, line == 3
        else { fail("the open file was not kept: \(name ?? "nil") at \(line.map(String.init) ?? "nil")") }
        step("switching to \(target.appName) restarts nvim in the same window, folder, file and line")
        // That config's leader is a comma: the tree knows it from nvim and hands it over.
        if marker == target.appName, await lua("return vim.g.mapleader")?.stringValue == "," {
            guard shell.tree.leaders.contains(",")
            else { fail("the tree's leaders after the switch: \(shell.tree.leaders)") }
            shell.tree.focus()
            shell.tree.outline.keyDown(with: key(","))
            guard shell.window.firstResponder === shell.editor
            else { fail("that config's leader did not go to the editor") }
            step("the tree learns the leader of the config nvim runs, and hands that one over")
        }
        await wait("the grid again") { shell.editor.screen.grids[1] != nil }
        do { _ = try await shell.session.channel.command("FrameConfig sill") } catch {
            fail("FrameConfig sill: \(error)")
        }
        await wait("nvim to restart under sill's own") { shell.current == .builtIn }
        let back = await (try? shell.session.channel.lua("return vim.g.frame_marker or ''"))?.stringValue
        guard back == "" else { fail("the first config's settings are still there: \(back ?? "nil")") }
        step("and back to sill's own, with nothing of the other config left")
        guard !shell.tree.leaders.contains(",")
        else { fail("the other config's leader is still the tree's: \(shell.tree.leaders)") }
        let complete = await (try? shell.session.channel.lua("return vim.fn.getcompletion('FrameConfig ', 'cmdline')"))?
            .arrayValue?.compactMap(\.stringValue)
        guard complete == ["sill", target.appName] else { fail("FrameConfig completes \(complete ?? [])") }
        step(":FrameConfig completes the configs there are")
        _ = try? await shell.session.channel.command("FrameConfig nosuchconfig")
        try? await Task.sleep(for: .milliseconds(400))
        let messages = await (try? shell.session.channel.lua("return vim.fn.execute('messages')"))?.stringValue ?? ""
        guard messages.contains("no config named nosuchconfig")
        else { fail("an unknown config is not named: \(messages)") }
        guard shell.current == .builtIn else { fail("an unknown config switched") }
        step("an unknown config is named and nothing switches")
    }

    /// The window as it shows: its background, the grid at its margin, corners rounded by the window's radius.
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
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { throw ShotFailure() }
        try data.write(to: URL(fileURLWithPath: path))
    }

    struct ShotFailure: Error {}
}
