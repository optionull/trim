import AppKit
import FrameModes
import FrameRun
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

    private func wait(_ what: String, seconds: Int = 10, _ ready: () -> Bool) async {
        for _ in 0 ..< seconds * 50 {
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
        // Not in a plain run: it builds a real solution (a copy of a folder named by FRAME_LOAD_FOLDER) and measures.
        if only?.contains("load") == true { await group("load") { await loadSteps() } }
        await group("tree") { await treeSteps() }
        await group("focus") { await focusSteps() }
        await group("forward") { await forwardSteps() }
        await group("layout") { await layoutSteps() }
        await group("isolation") { await isolationSteps() }
        await group("status") { await statusSteps() }
        await group("tabs") { await tabsSteps() }
        await group("scroll") { await scrollSteps() }
        await group("pixel") { await pixelSteps() }
        await group("theme") { await themeSteps() }
        await group("whichkey") { await whichKeySteps() }
        await group("lsp") {
            await lspSteps()
            await dotnetSteps()
            await startupSteps()
        }
        await group("zen") { await zenSteps() }
        await group("links") { await linkSteps() }
        await group("actions") { await actionSteps() }
        await group("run") { await runSteps() }
        await group("problems") { await problemsSteps() }
        await group("finder") { await finderSteps() }
        await group("packages") { await packagesSteps() }
        await group("settings") { await settingsSteps() }
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
        // A file that is only written again changes no folder: nothing is read again however often (a build does it by
        // the thousand), and a name that is gone is.
        try? "gone soon\n".write(toFile: folder + "/src/Gone.cs", atomically: true, encoding: .utf8)
        await wait("a throwaway file to show") { names().contains("Gone.cs") }
        try? await Task.sleep(for: .milliseconds(1200))
        let reads = tree.reloadsDone
        for round in 0 ..< 6 {
            try? "again \(round)\n".write(toFile: folder + "/src/New.cs", atomically: false, encoding: .utf8)
            try? await Task.sleep(for: .milliseconds(150))
        }
        try? await Task.sleep(for: .milliseconds(1200))
        guard tree.reloadsDone == reads
        else { fail("a file written again made the tree read its folder again (\(tree.reloadsDone - reads) times)") }
        try? FileManager.default.removeItem(atPath: folder + "/src/Gone.cs")
        await wait("a removed file to go from the tree") { !names().contains("Gone.cs") }
        guard tree.reloadsDone > reads else { fail("the folder was not read again when a name left it") }
        step("a file written again does not make the tree read its folder; a name that goes does")
        // A new folder with files in it shows in the open folder it is in (only its files are reported).
        try? FileManager.default.createDirectory(
            atPath: folder + "/src/fresh/deeper",
            withIntermediateDirectories: true
        )
        try? "x\n".write(toFile: folder + "/src/fresh/deeper/a.cs", atomically: true, encoding: .utf8)
        await wait("a new folder to appear in the open one") { names().contains("fresh") }
        step("a new folder, reported only by the files in it, appears in the open folder it is in")
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
        let niceness = await (try? FrameServers.run("/bin/ps", ["-o", "nice=", "-p", "\(pids[0])"]))?.output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Relative to nvim's own (the editor may itself have been started niced).
        let editorNiceness = await (try? FrameServers.run("/bin/ps", ["-o", "nice=", "-p", "\(nvimPid)"]))?.output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let own = editorNiceness.flatMap({ Int($0) }), niceness == String(own + 6)
        else {
            fail(
                "the language server is not at a lower priority than the editor: nice \(niceness ?? "?") (editor \(editorNiceness ?? "?"))"
            )
        }
        step("a language server runs at a lower priority than the editor, so it yields while it works")
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
        // The panel of the servers: how each is, what it uses (from ps), and keys to restart or stop one.
        guard shell.view.statusBar.onLspClick != nil else { fail("the servers in the status bar are not clickable") }
        shell.showLspPanel(nil)
        await wait("the language server panel") { shell.listPicker != nil }
        guard let panel = shell.listPicker, shell.modes.label(editorMode: "normal") == "LANGUAGE SERVERS"
        else { fail("no panel of the servers") }
        await wait("sourcekit-lsp in it, with what it uses") {
            panel.all.contains { $0.id == "sourcekit" && $0.detail.contains("MB") && $0.detail.contains("CPU") }
        }
        guard let row = panel.all.first(where: { $0.id == "sourcekit" }), row.title.hasPrefix("sourcekit-lsp"),
              row.subtitle.contains("frame-lsp-")
              || row.subtitle.contains("Package")
        else { fail("the row does not say what the server is or where: \(String(describing: panel.all.first))") }
        for _ in 0 ..< 12 where panel.cursor != "sourcekit" {
            panel.keyDown(with: key("j", code: 38))
        }
        guard panel.cursor == "sourcekit"
        else { fail("the keyboard cannot reach the sourcekit row: \(String(describing: panel.cursor))") }
        panel.keyDown(with: key("s", code: 1))
        await waitAsync("the server to be stopped from the panel") {
            await lua("return require('frame.lsp').state.sourcekit.status")?.stringValue == "stopped"
        }
        shell.escape()
        step("the panel lists each server with what it uses and where it is rooted, and s stops one")
        _ = await lua("require('frame.lsp').stop('sourcekit')")
        try? FileManager.default.removeItem(atPath: folder)
    }

    /// Running and building: a command goes to a real terminal pane (libghostty) beside the code when the window is
    /// wide
    /// and under it when it is not, the keyboard stays in the code, ⌘J goes into the pane and back, and the pane
    /// closes. What is run comes from the folder (Makefile, VS Code, project files): see `RunEntriesTests`.
    private func runSteps() async {
        shell.problemScope = .project
        let channel = shell.session.channel
        func lua(_ code: String) async -> MessagePackValue? { try? await channel.lua(code) }
        #if SILL_GHOSTTY
            let folder = RealPath.of(NSTemporaryDirectory()) + "/frame-run-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: folder) }
            shell.focusEditor()
            let before = shell.editor.frame
            shell.run(RunEntry(
                title: "marker", source: "make", kind: .run, command: "echo frame-run-marker-$((6*7)); pwd",
                directory: folder, environment: ["FRAME_RUN_ENV": "yes"]
            ))
            await wait("the terminal pane") { shell.runPane != nil && shell.view.terminal != nil }
            guard let pane = shell.runPane else { fail("no pane") }
            await wait("the command's output in the pane") {
                pane.screenText()?.contains("frame-run-marker-42") == true
            }
            guard pane.screenText()?.contains(folder) == true
            else { fail("the command did not run in its folder: \(pane.screenText() ?? "")") }
            step("a command runs in a real terminal pane, in its folder, and its output stays")
            guard shell.modes.surface == .editor else { fail("running took the keyboard: \(shell.modes.surface)") }
            let width = shell.view.bounds.width
            let editorNow = shell.editor.frame, paneFrame = pane.frame
            switch RunPlacement.for(width: width) {
            case .right: guard paneFrame.minX >= editorNow.maxX, paneFrame.height == editorNow.height else {
                    fail("a wide window should have the pane at the right: \(paneFrame) \(editorNow)")
                }
            case .bottom: guard paneFrame.minY >= editorNow.maxY, paneFrame.width == editorNow.width else {
                    fail("a narrow window should have the pane under the code: \(paneFrame) \(editorNow)")
                }
            }
            guard editorNow != before else { fail("the code did not make room") }
            step(
                "the pane is at the \(RunPlacement.for(width: width) == .right ? "right" : "bottom") of this \(Int(width))pt window, the code made room"
            )
            // The other placement.
            let original = shell.window.frame
            let wide = RunPlacement.for(width: width) == .bottom
            shell.window.setContentSize(NSSize(width: wide ? 1500 : 900, height: original.height))
            await wait("the pane to change sides") {
                shell.view.layoutSubtreeIfNeeded()
                return wide ? pane.frame.minX >= shell.editor.frame.maxX : pane.frame.minY >= shell.editor.frame.maxY
            }
            shell.window.setFrame(original, display: true)
            shell.view.layoutSubtreeIfNeeded()
            step("a wide window puts the pane beside the code, a narrow one under it")
            // The keyboard: ⌘J into the pane, and back.
            shell.toggleTerminal(nil)
            guard shell.modes.surface == .terminal, shell.window.firstResponder === pane.terminal
            else { fail("⌘J did not go into the pane: \(shell.modes.surface)") }
            shell.toggleTerminal(nil)
            guard shell.modes.surface == .editor, shell.window.firstResponder === shell.editor
            else { fail("⌘J did not come back: \(shell.modes.surface)") }
            step("⌘J goes into the pane and back to the code")
            // The default build is the task marked as one; a run that was chosen is run again.
            let build = RunEntry(title: "b1", source: "make", kind: .build, command: "make b1", directory: folder)
            let marked = RunEntry(
                title: "b2",
                source: "VS Code",
                kind: .build,
                command: "x",
                directory: folder,
                isDefault: true
            )
            let program = RunEntry(title: "p", source: "dotnet", kind: .run, command: "dotnet run", directory: folder)
            guard shell.defaultBuild(from: [build, marked, program]) == marked,
                  shell.defaultBuild(from: [build, program]) == build,
                  shell.defaultRun(from: [build, program]) == program
            else { fail("the default build and run are not picked as they should be") }
            step("the default build is the one marked as such, else the first; the default run the program")
            // A build that failed: its problems are read out of the pane and listed; Return opens the file at the line.
            try? "one\ntwo\nthree\nfour\n".write(toFile: folder + "/A.cs", atomically: true, encoding: .utf8)
            shell.run(RunEntry(
                title: "build", source: "make", kind: .build,
                command: "printf '%s\\n' 'A.cs(3,2): error CS1002: boom [x.csproj]' 'A.cs(4,1): warning CS0168: quiet'",
                directory: folder
            ))
            guard let buildPane = shell.runPane else { fail("no pane for the build") }
            await wait("the build's output") { buildPane.screenText()?.contains("boom") == true }
            await wait("the Problems tab to come up by itself when the build goes quiet", seconds: 10) {
                buildPane.tab == .problems && buildPane.problems.all.count == 2
            }
            let list = buildPane.problems
            guard list.all.map(\.title) == ["boom", "quiet"], list.all[0].detail.hasSuffix("A.cs:3"),
                  shell.modes.surface == .editor, shell.listPicker == nil
            else {
                fail("the problems are not the build's: \(list.all.map(\.title)) \(shell.modes.surface)")
            }
            guard buildPane.terminal != nil else { fail("the build's output went with the problems") }
            buildPane.select(.output)
            guard buildPane.tab == .output, buildPane.terminal?.isHidden == false, list.isHidden else {
                fail("the Output tab does not show the terminal")
            }
            // The minimize button puts the pane away, and the code has its room; ⌘J brings it back.
            buildPane.onMinimize?()
            shell.view.layoutSubtreeIfNeeded()
            guard buildPane.isHidden, shell.editor.frame == before, shell.modes.surface == .editor
            else { fail("minimize did not put the pane away: \(shell.editor.frame) \(before)") }
            shell.toggleTerminal(nil)
            guard !buildPane.isHidden,
                  shell.modes.surface == .terminal else { fail("⌘J did not bring the minimized pane back") }
            step("the minimize button puts the pane away, the code gets its room, and ⌘J brings it back")
            buildPane.select(.problems)
            shell.focus(.terminal)
            guard shell.window.firstResponder === list, shell.modes.label(editorMode: "normal") == "BUILD"
            else { fail("the keyboard is not in the problems list: \(String(describing: shell.window.firstResponder))")
            }
            list.keyDown(with: key("\r", code: 36))
            await waitAsync("the file to open at the error") {
                let name = await lua("return vim.api.nvim_buf_get_name(0)")?.stringValue
                let at = await lua("return vim.api.nvim_win_get_cursor(0)")?.arrayValue?.compactMap(\.integerValue)
                return name == folder + "/A.cs" && at?.first == 3
            }
            step(
                "one pane, one mode: a build that goes quiet shows its problems on the pane's Problems tab, beside its Output; Return goes to the line"
            )
            shell.closeTerminal(nil)
            guard shell.runPane == nil, shell.view.terminal == nil else { fail("the pane did not close") }
            shell.view.layoutSubtreeIfNeeded()
            guard shell.editor.frame == before
            else { fail("the code did not take its room back: \(shell.editor.frame) \(before)") }
            step("closing the pane gives the code its room back")
            // A build yields to the editor: it and what it starts run at a lower priority.
            shell.run(RunEntry(
                title: "nice", source: "make", kind: .build, command: "echo level-$(ps -o nice= -p $$ | tr -d ' ')-end",
                directory: folder
            ))
            let ownText = await (try? FrameServers.run("/bin/ps", ["-o", "nice=", "-p", "\(getpid())"]))?.output
            let own = Int(ownText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
            await wait("the build to say how nice it is") {
                shell.runPane?.screenText()?.contains("level-\(own + 10)-end") == true
            }
            await wait("that build to end", seconds: 20) { shell.status.building.isEmpty }
            step("a build runs at a lower priority than the editor")
            shell.closeTerminal(nil)
            // A clean build runs unseen: a loader in the status bar, then a line; no pane.
            shell.run(RunEntry(title: "clean", source: "make", kind: .build, command: "echo fine", directory: folder))
            await wait("the loader in the status bar") { shell.status.building == "clean" }
            guard shell.view.progress.items.contains(where: { $0.id == "build" && $0.title == "clean" })
            else { fail("the build is not a row of the progress toast") }
            shell.view.statusBar.displayIfNeeded()
            guard shell.view.statusBar.isSpinning, shell.view.statusBar.spinnerFrame.width > 8,
                  shell.view.statusBar.spinnerFrame.maxX < shell.view.statusBar.bounds.width
            else { fail("the build's loader in the status bar is not turning: \(shell.view.statusBar.spinnerFrame)") }
            guard shell.runPane?.isHidden == true, shell.editor.frame == before
            else { fail("a build that has nothing to say took room from the code") }
            await wait("the build to end with a line in the status bar", seconds: 20) {
                shell.status.building.isEmpty && shell.status.buildResult == "✓ Build succeeded"
            }
            guard shell.runPane?.isHidden == true,
                  shell.modes.surface == .editor else { fail("a clean build brought up the pane") }
            step("a clean build runs unseen: a loader in the status bar, then a line; the pane stays away")
            shell.view.statusBar.onBuildClick?()
            guard shell.runPane?.isHidden == false, shell.runPane?.tab == .output, shell.modes.surface == .terminal
            else { fail("clicking the build did not show its output") }
            step("clicking the build in the status bar shows its output")
            shell.closeTerminal(nil)
            // One that fails with nothing to list shows its output.
            shell.run(RunEntry(
                title: "broken",
                source: "make",
                kind: .build,
                command: "echo oops; exit 3",
                directory: folder
            ))
            await wait("the failed build to bring up the pane", seconds: 20) { shell.runPane?.isHidden == false }
            guard shell.runPane?.tab == .output, shell.status.buildFailed, shell.status.buildResult == "✗ Build failed"
            else {
                fail(
                    "a failed build did not show its output: \(String(describing: shell.runPane?.tab)) \(shell.status.buildResult)"
                )
            }
            step("a build that fails shows its output, and the status bar says so")
            // The failed build in the status bar opens its output, wherever the pane is; the next click folds it.
            if let failed = shell.runPane {
                failed.onMinimize?()
                shell.view.statusBar.onBuildClick?()
                guard !failed.isHidden,
                      failed.tab == .output
                else { fail("the failed build did not open its output from the status bar") }
                failed.select(.problems)
                shell.view.statusBar.onBuildClick?()
                guard !failed.isHidden,
                      failed.tab == .output else { fail("the build did not switch the pane to its output") }
                shell.view.statusBar.onBuildClick?()
                guard failed.isHidden else { fail("a click on the build while its output shows did not fold the pane") }
                step(
                    "the failed build in the status bar opens its output (from folded, or from Problems), and folds the pane on the output"
                )
                // The button next to Output runs it again.
                let first = failed.terminal
                failed.onRebuild?()
                guard failed.terminal !== first,
                      failed.entry?.title == "broken" else { fail("the rebuild button did not run it again") }
                await wait("the second run to end", seconds: 20) { shell.status.building.isEmpty }
                step("the button next to Output runs the last thing again")
            }
            shell.closeTerminal(nil)
            shell.view.layoutSubtreeIfNeeded()
        #else
            step("built without GhosttyKit: the terminal pane was not exercised")
        #endif
    }

    /// Diagnostics: the worst level of each file as a wavy line in the tree, folders taking the worst below them
    /// (folded
    /// off the main thread), and every problem in one list with a toggle per level and Alt+Enter on a row.
    private func problemsSteps() async {
        let channel = shell.session.channel
        func lua(_ code: String) async -> MessagePackValue? { try? await channel.lua(code) }
        shell.takeBuildProblems([])
        shell.problemScope = .project
        let folder = (shell.tree.rootPath ?? shell.workspace) + "/problems-fixture"
        try? FileManager.default.createDirectory(atPath: folder + "/sub/deep", withIntermediateDirectories: true)
        try? "one\ntwo\nthree\n".write(toFile: folder + "/sub/deep/a.txt", atomically: true, encoding: .utf8)
        try? "one\ntwo\nthree\n".write(toFile: folder + "/sub/b.txt", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let a = RealPath.of(folder) + "/sub/deep/a.txt", b = RealPath.of(folder) + "/sub/b.txt"
        shell.focusEditor()
        // nvim's report of what it just did (a file written) is not a popup over the code; an error still is.
        _ = await lua("vim.cmd('edit ' .. vim.fn.fnameescape('\(b)')); vim.cmd('write')")
        await wait("the write message") { shell.editor.screen.messages.contains { $0.text.contains("written") } }
        try? await Task.sleep(for: .milliseconds(300))
        guard !shell.view.overlay.subviews
            .contains(where: { ($0 as? ToastView)?.message?.text.contains("written") == true })
        else {
            fail(
                "a file written popped up over the code: \(shell.editor.screen.messages.map { $0.kind + "/" + $0.text })"
            )
        }
        // A server asking for a folder that is not there to be watched is nvim's own noise, not the person's business.
        _ = await lua("vim.notify_once('watch.watch: ENOENT', vim.log.levels.INFO)")
        await wait("the watcher's message to arrive") {
            shell.editor.screen.messages.contains { $0.text.hasPrefix("watch.watch") }
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard !shell.view.overlay.subviews
            .contains(where: { ($0 as? ToastView)?.message?.text.hasPrefix("watch.watch") == true })
        else { fail("the file watcher's ENOENT popped up over the code") }
        _ = await lua("vim.api.nvim_echo({ { 'broken thing' } }, true, { err = true })")
        await wait("an error to still be shown") { shell.view.overlay.subviews.contains { $0 is ToastView } }
        step("routine messages (a file written) stay quiet; errors still show")
        shell.focusEditor()
        _ = await lua("vim.cmd('edit ' .. vim.fn.fnameescape('\(a)'))")
        _ = await lua("""
        local ns = vim.api.nvim_create_namespace('frame_check')
        vim.diagnostic.set(ns, 0, { { lnum = 0, col = 0, message = 'boom', severity = 1, code = 'X1' } })
        vim.cmd('edit ' .. vim.fn.fnameescape('\(b)'))
        vim.diagnostic.set(ns, 0, {
          { lnum = 1, col = 2, message = 'careful', severity = 2 },
          { lnum = 2, col = 0, message = 'consider', severity = 4 },
        })
        """)
        func level(_ path: String) -> DiagnosticLevel? { shell.tree.tree?.node(at: path)?.diagnostic }
        let top = RealPath.of(folder)
        await wait("the folder to take the worst of what is below it") { level(top) == .error }
        shell.tree.reveal(a)
        await wait("the files' wavy lines in the tree") { level(a) == .error && level(top + "/sub") == .error }
        guard level(b) == .warning, level(top + "/sub/deep") == .error
        else { fail("the folders did not take the worst below them: \(String(describing: level(top + "/sub/deep")))") }
        step("a file's worst diagnostic marks it in the tree, and every folder above takes the worst below")
        await wait("the row's wavy line") { shell.tree.cell(for: a)?.squiggle.level == .error }
        if let cell = shell.tree.cell(for: a) {
            // Drawn for real, and measured: the red of the wave must start where the text ends and be as wide as it.
            cell.layoutSubtreeIfNeeded()
            guard let rep = cell.bitmapImageRepForCachingDisplay(in: cell.bounds) else { fail("no bitmap of the row") }
            cell.cacheDisplay(in: cell.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / cell.bounds.width
            let nameFrom = Int(cell.name.frame.minX * scale), nameTo = Int(cell.name.frame.maxX * scale)
            struct Box {
                var x0 = Int.max, x1 = Int.min, y0 = Int.max, y1 = Int.min
                mutating func add(_ x: Int, _ y: Int) {
                    x0 = min(x0, x)
                    x1 = max(x1, x)
                    y0 = min(y0, y)
                    y1 = max(y1, y)
                }
            }
            var text = Box(), wave = Box()
            for y in 0 ..< rep.pixelsHigh {
                for x in nameFrom ..< min(nameTo, rep.pixelsWide) {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
                    if r > 0.85, g < 0.55, b < 0.55 {
                        wave.add(x, y)
                    } else if r > 0.6, g > 0.6, b > 0.6 {
                        text.add(x, y)
                    }
                }
            }
            guard wave.x0 != .max, text.x0 != .max else { fail("no wave or no text in the row's picture") }
            let tolerance = Int(3 * scale)
            guard wave.y0 >= (text.y0 + text.y1) / 2, wave.y0 <= text.y1 + tolerance
            else {
                fail(
                    "the wave is not at the foot of the text: wave rows \(wave.y0)-\(wave.y1), text rows \(text.y0)-\(text.y1)"
                )
            }
            guard abs(wave.x0 - text.x0) <= tolerance, abs(wave.x1 - text.x1) <= tolerance
            else { fail("the wave is not as wide as the text: wave \(wave.x0)-\(wave.x1), text \(text.x0)-\(text.x1)") }
            step("the wavy line is drawn at the foot of the name, as wide as it (measured in the row's pixels)")
        }
        _ = await lua("vim.diagnostic.reset()")
        await wait("the marks to go") { level(a) == nil && level(top) == nil }
        step("marks go when the diagnostics do")
        _ = await lua("""
        local ns = vim.api.nvim_create_namespace('frame_check')
        vim.diagnostic.set(ns, vim.fn.bufnr('\(
            a
        )'), { { lnum = 0, col = 0, message = 'boom', severity = 1, code = 'X1' } })
        vim.diagnostic.set(ns, vim.fn.bufnr('\(b)'), {
          { lnum = 1, col = 2, message = 'careful', severity = 2 },
          { lnum = 2, col = 0, message = 'consider', severity = 4 },
        })
        """)
        await wait("the status bar to count every problem, not only the file in the window") {
            shell.status.errors == 1 && shell.status.warnings == 1 && shell.status.hints == 1
        }
        step("the status bar counts the problems of every file")
        shell.view.statusBar.onProblemsClick?()
        guard shell.runPane?.isHidden == false, shell.runPane?.tab == .problems, shell.modes.surface == .terminal
        else { fail("clicking the counts did not open the problems") }
        await wait("the problem counts to be a clickable section with a pointer") {
            shell.view.statusBar.displayIfNeeded()
            return shell.view.statusBar.pointerRects().contains {
                $0.width > 10 && $0.minX > shell.view.statusBar.bounds.width / 2
            }
        }
        shell.view.statusBar.onProblemsClick?()
        guard shell.runPane?.isHidden == true,
              shell.modes.surface == .editor else { fail("a second click did not fold the pane away") }
        step("the status bar's section for the pane has a pointer, opens the pane on a click and folds it on the next")
        shell.showProblems(nil)
        guard let pane = shell.runPane, pane.tab == .problems, shell.modes.label(editorMode: "normal") == "BUILD",
              shell.window.firstResponder === pane.problems else { fail("no problems tab with the keyboard in it") }
        let list = pane.problems
        await wait("the problems") { list.all.count == 3 }
        guard list.all.map(\.title) == ["boom", "careful", "consider"], list.chips.map(\.count) == [1, 1, 0, 1]
        else { fail("not the problems in order, or the counts: \(list.all.map(\.title)) \(list.chips.map(\.count))") }
        step("the problems of every open file in one list, worst first, with a count per level")
        list.keyDown(with: key("w", code: 13))
        await wait("w to switch the warnings off") {
            list.all.count == 2 && list.chips.first(where: { $0.id == "2" })?.on == false
        }
        list.onChip?("2")
        await wait("a click on the chip to switch warnings back on") { list.all.count == 3 }
        step("each level is switched off and on by its key or by a click")
        pane.layoutSubtreeIfNeeded()
        pane.displayIfNeeded()
        let chips = pane.chipsView
        let frames = chips.chipFrames()
        let scopes = BuildPane.scopeGroup(in: pane.bounds, header: BuildPane.headerHeight(for: pane.look))
        guard frames.count == 4, !chips.isHidden, let last = frames.last,
              chips.frame.minX + last.rect.maxX >= scopes.minX - 24, scopes.maxX <= pane.minimizeRect.minX,
              chips.frame.minX + last.rect.maxX <= scopes.minX,
              chips.frame.minX >= pane.rebuildRect.maxX, list.chips.allSatisfy({ !$0.glyph.isEmpty }),
              list.chipFrames.isEmpty || list.isHidden || list.frame.minY >= BuildPane.headerHeight(for: list.look)
        else {
            fail(
                "the toggles are not icons at the right of the header, next to the scope buttons and minimize: \(frames) \(pane.minimizeRect)"
            )
        }
        step("the toggles are icons with their counts, in the header, right next to the minimize button")
        // The controls of the header have a pointer and a hover, the rebuild button runs again, and Output opens with
        // nothing run.
        guard pane.pointerRects().count(where: { !$0.isEmpty }) == 7, !pane.minimizeRect.isEmpty,
              !pane.rebuildRect.isEmpty
        else { fail("the header's controls are not all pointers: \(pane.pointerRects())") }
        func sample(_ rect: NSRect) -> NSColor? {
            pane.layoutSubtreeIfNeeded()
            guard let rep = pane.bitmapImageRepForCachingDisplay(in: pane.bounds) else { return nil }
            pane.cacheDisplay(in: pane.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / pane.bounds.width
            return rep.colorAt(x: Int((rect.minX + 3) * scale), y: Int(rect.midY * scale))
        }
        let resting = sample(pane.minimizeRect)
        pane.hover(.minimize)
        let hovering = sample(pane.minimizeRect)
        pane.hover(nil)
        guard let resting, let hovering, resting != hovering else { fail("minimize looks the same under the pointer") }
        let restingRebuild = sample(pane.rebuildRect)
        pane.hover(.rebuild)
        guard sample(pane.rebuildRect) != restingRebuild
        else { fail("the rebuild button looks the same under the pointer") }
        pane.hover(nil)
        step("minimize, rebuild and the tabs have a pointer, and a hover that shows")
        pane.select(.output)
        guard pane.tab == .output, pane.showsHint else { fail("Output with nothing run does not say what to do") }
        pane.select(.problems)
        step("Output opens even before anything has run, and says how to run something")
        // The row's quiet text (its place and code) is readable on the selection's fill.
        func luminance(_ color: NSColor) -> CGFloat {
            let c = color.usingColorSpace(.sRGB) ?? color
            func channel(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 *
                channel(c.blueComponent)
        }
        let look = list.look
        let fill = look.focusedSelection.usingColorSpace(.sRGB) ?? look.focusedSelection
        let quiet = RowColors.quiet(look, selected: true).usingColorSpace(.sRGB) ?? look.text
        let blended = NSColor(
            srgbRed: quiet.redComponent * quiet.alphaComponent + fill.redComponent * (1 - quiet.alphaComponent),
            green: quiet.greenComponent * quiet.alphaComponent + fill.greenComponent * (1 - quiet.alphaComponent),
            blue: quiet.blueComponent * quiet.alphaComponent + fill.blueComponent * (1 - quiet.alphaComponent), alpha: 1
        )
        let (lighter, darker) = (max(luminance(blended), luminance(fill)), min(luminance(blended), luminance(fill)))
        let ratio = (lighter + 0.05) / (darker + 0.05)
        guard ratio >= 4.0
        else { fail("the selected row's quiet text is not readable on the selection: contrast \(ratio)") }
        step(
            "the selected row's place and code are readable on the selection (contrast \(String(format: "%.1f", ratio)))"
        )
        // Alt+Enter on the warning: the list goes, the cursor is at the problem.
        _ =
            await lua(
                "vim.g.asked_actions = false; vim.lsp.buf.code_action = function() vim.g.asked_actions = true end"
            )
        list.keyDown(with: key("j", code: 38))
        list.keyDown(with: key("\r", code: 36, flags: [.option]))
        await waitAsync("Alt+Enter to go to the problem") {
            let name = await lua("return vim.api.nvim_buf_get_name(0)")?.stringValue
            let at = await lua("return vim.api.nvim_win_get_cursor(0)")?.arrayValue?.compactMap(\.integerValue)
            return name == b && at == [2, 2]
        }
        await waitAsync("the code actions to be asked for") {
            await lua("return vim.g.asked_actions")?.boolValue == true
        }
        guard shell.modes.surface == .editor,
              shell.runPane != nil else { fail("Alt+Enter did not leave the keyboard in the code") }
        step("Alt+Enter on a row goes to the problem (and asks for its code actions)")
        // The list does not shuffle: problems that agree on what is shown keep their places, however they come, and the
        // row that is clicked is the row the keyboard is on afterwards.
        let sample = (0 ..< 8).map {
            ProblemRow(path: "/x", line: 1, column: 1, level: .info, message: "m\($0)", code: "C", source: "s")
        }
        let order = ProblemRow.merged(nvim: sample, build: [])
        for _ in 0 ..< 20 where ProblemRow.merged(nvim: sample.shuffled(), build: []) != order {
            fail("the problems change places between listings")
        }
        shell.showProblems(nil)
        let pick = list.all.count - 1
        let picked = list.all[pick].id
        list.rows.onChoose?(picked)
        try? await Task.sleep(for: .milliseconds(700))
        guard list.cursor == picked
        else { fail("the list jumped away from the row that was clicked: \(String(describing: list.cursor))") }
        step("problems keep their places between listings, and a click leaves the keyboard on the row clicked")
        // How much the list covers: this file, its folder, or all of it.
        try? "one\n".write(toFile: folder + "/sub/c.txt", atomically: true, encoding: .utf8)
        let c = RealPath.of(folder) + "/sub/c.txt"
        _ = await lua("""
        vim.cmd('edit ' .. vim.fn.fnameescape('\(c)'))
        vim.diagnostic.set(vim.api.nvim_create_namespace('frame_check'), 0, { { lnum = 0, col = 0, message = 'neighbour', severity = 3 } })
        vim.cmd('edit ' .. vim.fn.fnameescape('\(b)'))
        """)
        await wait("the file in the window to be known") { shell.activeFile == b }
        await wait("all four problems") { list.all.count == 4 }
        pane.onScope?(.file)
        await wait("the list to cover only this file") { list.all.map(\.title) == ["careful", "consider"] }
        pane.onScope?(.folder)
        await wait("the list to cover this folder") {
            Set(list.all.map(\.title)) == ["careful", "consider", "neighbour"]
        }
        pane.onScope?(.project)
        await wait("the list to cover the whole project") { list.all.count == 4 }
        step("the problems can be scoped to this file, its folder, or the whole project")
        shell.lspProgress = [ProgressItem(
            id: "x",
            client: "Roslyn",
            title: "Analysing files",
            message: "",
            percentage: nil
        )]
        pane.loading = true
        pane.layoutSubtreeIfNeeded()
        pane.displayIfNeeded()
        guard pane.showsLoader else { fail("no loader on the Problems tab while the servers are working") }
        pane.loading = false
        shell.lspProgress = []
        guard !pane.showsLoader else { fail("the loader stayed on the Problems tab") }
        step("a loader turns on the Problems tab while the servers are still sending problems")
        // The list follows the diagnostics as they change, without being asked.
        _ = await lua("vim.diagnostic.reset()")
        await wait("the list to follow the diagnostics going") { list.all.isEmpty }
        step("the pane's list follows the diagnostics as they change")
        shell.closeTerminal(nil)
        _ = await lua("vim.cmd('silent! %bwipeout!')")
    }

    /// Zen: the sidebar, tabs, status bar and build pane out of the way, the text in the middle as wide as a page of
    /// code,
    /// and everything as it was when it is over.
    private func zenSteps() async {
        let channel = shell.session.channel
        shell.focusEditor()
        shell.showProblems(nil)
        shell.focusEditor()
        shell.view.layoutSubtreeIfNeeded()
        let before = shell.editor.frame
        guard let pane = shell.runPane, !pane.isHidden else { fail("no pane to put away") }
        shell.toggleZen(nil)
        shell.view.layoutSubtreeIfNeeded()
        let view = shell.view!
        guard view.zen, view.sidebar.isHidden, view.statusBar.isHidden, view.tabStrip.isHidden, view.tabList.isHidden,
              pane.frame.maxX < 0
        else { fail("zen left chrome on screen") }
        let editor = shell.editor.frame
        guard editor.width < before.width, editor.height >= before.height, abs(editor.midX - view.bounds.midX) < 2
        else { fail("the text is not in the middle: \(editor) in \(view.bounds), was \(before)") }
        await waitAsync("nvim to have a page of code for a width") {
            let columns = await (try? channel.lua("return vim.o.columns"))?.integerValue ?? 999
            return columns <= 110
        }
        step("zen puts the chrome away (the pane too) and the text in the middle, as wide as a page of code")
        shell.toggleZen(nil)
        shell.view.layoutSubtreeIfNeeded()
        guard !view.sidebar.isHidden, !view.statusBar.isHidden, !pane.isHidden, pane.frame.maxX > 0,
              shell.editor.frame == before
        else { fail("zen did not leave everything as it was: \(shell.editor.frame) was \(before)") }
        shell.closeTerminal(nil)
        step("and when it is over everything is as it was, the pane too")
    }

    /// Links into the app: `frame://open?path=…&line=…&column=…` and a file handed over open the file at its place, in
    /// the
    /// window that is on its folder.
    private func linkSteps() async {
        let channel = shell.session.channel
        let folder = (shell.tree.rootPath ?? shell.workspace) + "/links-fixture"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? "one\ntwo three\nfour\n".write(toFile: folder + "/a.txt", atomically: true, encoding: .utf8)
        try? "x\ny\n".write(toFile: folder + "/b.txt", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let a = RealPath.of(folder) + "/a.txt", b = RealPath.of(folder) + "/b.txt"
        let windows = app.controllers.count
        guard let link = URL(string: "frame://open?path=\(a)&line=2&column=5"), app.handle(link)
        else { fail("the link was not handled") }
        await waitAsync("the link to open the file at its place") {
            let name = await (try? channel.lua("return vim.api.nvim_buf_get_name(0)"))?.stringValue
            let at = await (try? channel.lua("return vim.api.nvim_win_get_cursor(0)"))?.arrayValue?
                .compactMap(\.integerValue)
            return name == a && at == [2, 4]
        }
        guard app.controllers.count == windows else { fail("a link opened a window although one is on the folder") }
        step("a frame:// link opens the file at its line and column, in the window that is on its folder")
        guard app.handle(URL(fileURLWithPath: b)) else { fail("a file handed over was not handled") }
        await waitAsync("a file handed over to open") {
            await (try? channel.lua("return vim.api.nvim_buf_get_name(0)"))?.stringValue == b
        }
        guard !app.handle(URL(string: "frame://nothing")!) else { fail("a link that asks nothing was taken") }
        step("a file handed to the app opens, and a link that asks nothing is left")
    }

    /// What can be done here: Alt+Enter (and Cmd+.) asks the server for code actions and the answer is the frame's own
    /// list, filtered by typing, Return applying the one chosen, Escape leaving the text alone. The server is a fake
    /// one,
    /// in nvim, that offers two edits; any `vim.ui.select` goes to the same list.
    private func actionSteps() async {
        let channel = shell.session.channel
        func lua(_ code: String) async -> MessagePackValue? { try? await channel.lua(code) }
        let file = RealPath.of(NSTemporaryDirectory()) + "/frame-actions-\(UUID().uuidString).txt"
        try? "alpha beta\ngamma\n".write(toFile: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: file) }
        _ = await lua("""
        vim.cmd('edit ' .. vim.fn.fnameescape('\(file)'))
        local uri = vim.uri_from_bufnr(0)
        local function edit(text) return { changes = { [uri] = { { range = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 5 } }, newText = text } } } } end
        vim.lsp.start({ name = 'fake', root_dir = vim.uv.cwd(), cmd = function()
          local closing = false
          return {
            request = function(method, _, callback)
              vim.schedule(function()
                if method == 'initialize' then callback(nil, { capabilities = { codeActionProvider = true, referencesProvider = true, definitionProvider = true, completionProvider = { triggerCharacters = { '.' } } } })
                elseif method == 'textDocument/codeAction' then
                  callback(nil, {
                    { title = 'Use primary constructor', kind = 'refactor', edit = edit('FIRST') },
                    { title = 'Remove unused usings', kind = 'quickfix', edit = edit('SECOND') },
                  })
                elseif method == 'textDocument/references' then
                  callback(nil, {
                    { uri = uri, range = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 5 } } },
                    { uri = uri, range = { start = { line = 1, character = 2 }, ['end'] = { line = 1, character = 4 } } },
                  })
                elseif method == 'textDocument/completion' then
                  callback(nil, { isIncomplete = false, items = {
                    { label = 'alphabet', kind = 6, detail = 'string', insertText = 'alphabet' },
                    { label = 'alpha', kind = 3, detail = 'int', insertText = 'alpha' },
                    { label = 'beta', kind = 3, detail = 'int', insertText = 'beta' },
                  } })
                elseif method == 'textDocument/definition' then
                  callback(nil, { { uri = uri, range = { start = { line = 1, character = 3 }, ['end'] = { line = 1, character = 5 } } } })
                else callback(nil, nil) end
              end)
              return true, 1
            end,
            notify = function() return true end,
            is_closing = function() return closing end,
            terminate = function() closing = true end,
          }
        end }, { bufnr = 0 })
        """)
        func first() async -> String { await lua("return vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]")?
            .stringValue ?? ""
        }
        await waitAsync("the fake server to attach") {
            await lua("return #vim.lsp.get_clients({ bufnr = 0, name = 'fake' })")?.integerValue == 1
        }
        // What the servers are busy with is a row of the progress toast each, and gone when it is done.
        _ = await lua("""
        local id = vim.lsp.get_clients({ name = 'fake' })[1].id
        local function event(token, value) vim.api.nvim_exec_autocmds('LspProgress', { data = { client_id = id, params = { token = token, value = value } } }) end
        event('a', { kind = 'begin', title = 'Loading projects', percentage = 10 })
        event('b', { kind = 'begin', title = 'Indexing', message = '12 of 40' })
        """)
        let toast = shell.view.progress
        await wait("a row for each thing the server is busy with") {
            toast.items.count == 2 && toast.items
                .contains { $0.title == "Loading projects" && $0.percentage == 10 && $0.client == "fake" }
                && toast.items.contains { $0.title == "Indexing" && $0.message == "12 of 40" && $0.percentage == nil }
        }
        shell.view.layoutSubtreeIfNeeded()
        guard !toast.isHidden, toast.frame.height > 0, toast.frame.maxX < shell.editor.frame.maxX
        else { fail("the progress toast is not showing: \(toast.frame)") }
        toast.layoutSubtreeIfNeeded()
        guard toast.loaders == 2, toast.movingBars == 1
        else {
            fail(
                "the toast's loaders are not going: \(toast.loaders) spinners, \(toast.movingBars) moving bars for two rows"
            )
        }
        // Where they are, as AppKit places them: each spinner in its row beside the name, the bar at the foot of its
        // row,
        // below the text and not through it.
        let spinners = toast.spinnerFrames, bars = toast.barFrames
        let rowHeight = ProgressToastView.rowHeight
        guard spinners.count == 2, bars.count == 1, spinners[0].minY > 4, spinners[0].maxY < rowHeight,
              spinners[0].maxX <= 36, spinners[1].minY - spinners[0].minY >= rowHeight - 1,
              bars[0].minY >= spinners[1].minY + 16
        else { fail("the loaders are not in their rows: spinners \(spinners), bars \(bars)") }
        _ = await lua("""
        local id = vim.lsp.get_clients({ name = 'fake' })[1].id
        vim.api.nvim_exec_autocmds('LspProgress', { data = { client_id = id, params = { token = 'a', value = { kind = 'end' } } } })
        """)
        await wait("a row to go when its work is done") {
            toast.items.count == 1 && toast.items.first?.title == "Indexing"
        }
        _ = await lua("""
        local id = vim.lsp.get_clients({ name = 'fake' })[1].id
        vim.api.nvim_exec_autocmds('LspProgress', { data = { client_id = id, params = { token = 'b', value = { kind = 'end' } } } })
        """)
        await wait("the toast to go when nothing is going on") { toast.items.isEmpty && toast.isHidden }
        // A server that gives workspace diagnostics says nothing while it analyses: shown as busy until they stop
        // arriving.
        _ = await lua("""
        local lsp = require('frame.lsp')
        lsp.analysis_quiet = 400
        lsp.track_analysis(vim.lsp.get_clients({ name = 'fake' })[1])
        """)
        await wait("the analysis as a row") { toast.items.contains { $0.title == "Analysing files" } }
        await wait("the analysis to end once diagnostics have stopped arriving", seconds: 10) { toast.items.isEmpty }
        step(
            "what the servers are busy with, and the analysis of files, are rows of one progress toast that comes and goes"
        )
        guard await lua("return vim.fn.maparg('<M-CR>', 'n')")?.stringValue != ""
        else { fail("no Alt+Enter on a buffer with a server") }
        shell.focusEditor()
        channel.send(keys: "<M-CR>")
        await wait("Alt+Enter to bring up the code actions") { shell.listPicker != nil }
        guard let picker = shell.listPicker, shell.modes.label(editorMode: "normal") == "CODE ACTIONS"
        else { fail("not the code actions mode: \(shell.modes.label(editorMode: "normal"))") }
        await wait("the actions") { picker.all.count == 2 }
        guard picker.all.map(\.title) == ["Use primary constructor", "Remove unused usings"]
        else { fail("the actions are not their titles: \(picker.all.map(\.title))") }
        step("Alt+Enter lists what the server can do here, in the frame's own list")
        // Typing narrows, Return applies the one left.
        for letter in "/unus" {
            picker.keyDown(with: key(String(letter), code: 0))
        }
        await wait("the filter") { picker.visible.count == 1 }
        picker.keyDown(with: key("\r", code: 36))
        await waitAsync("the second action to be applied") { await first() == "SECOND beta" }
        guard shell.listPicker == nil,
              shell.modes.surface == .editor else { fail("the list stayed up or the keys did not come back") }
        step("filtering and Return apply the action chosen, and the keys go back to the text")
        // Cmd+. again, put away: nothing changes.
        channel.send(keys: "<D-.>")
        await wait("Cmd+. to bring up the list") { shell.listPicker != nil }
        shell.escape()
        try? await Task.sleep(for: .milliseconds(200))
        guard shell.listPicker == nil,
              await first() == "SECOND beta" else { await fail("Escape changed the text: \(first())") }
        step("Cmd+. does the same and Escape leaves the text alone")
        // Usages: the lines as a list, the file beside each, Return going there; one answer is gone to at once.
        channel.send(keys: "gr")
        await wait("gr to list the usages") { shell.listPicker != nil }
        guard let usages = shell.listPicker,
              usages.all.count == 2 else { fail("not two usages: \(shell.listPicker?.all.count ?? -1)") }
        guard usages.all[0].title == "SECOND beta", usages.all[1].title == "gamma",
              usages.all[0].detail.hasSuffix(":1"), usages.all[1].detail.hasSuffix(":2"),
              usages.all[1].file == (file as NSString).lastPathComponent
        else { fail("the usages are not the lines with their places: \(usages.all)") }
        usages.keyDown(with: key("j", code: 38))
        usages.keyDown(with: key("\r", code: 36))
        await waitAsync("Return to go to the second usage") {
            let at = await lua("return vim.api.nvim_win_get_cursor(0)")?.arrayValue?.compactMap(\.integerValue)
            return at == [2, 2]
        }
        step("gr lists the usages with their lines and places, and Return goes to the one chosen")
        channel.send(keys: "gg0gd")
        await waitAsync("gd to go straight to the one definition") {
            let at = await lua("return vim.api.nvim_win_get_cursor(0)")?.arrayValue?.compactMap(\.integerValue)
            return at == [2, 3]
        }
        guard shell.listPicker == nil else { fail("a single definition opened a list") }
        step("a single answer is gone to without a list")
        // Completion as you type: the server's candidates come up by themselves, in the popup, matched to what is
        // typed;
        // Tab walks them and Enter takes the one chosen.
        _ =
            await lua(
                "require('frame.lsp').complete(vim.lsp.get_clients({ name = 'fake' })[1], vim.api.nvim_get_current_buf())"
            )
        shell.focusEditor()
        channel.send(keys: "Go")
        try? await Task.sleep(for: .milliseconds(200))
        channel.send(keys: "alp")
        await wait("the completion menu to come up as a word is typed") {
            shell.editor.screen.popupMenu?.items.count ?? 0 >= 2
        }
        guard let menu = shell.editor.screen.popupMenu, menu.items.map(\.word).contains("alpha"),
              !menu.items.map(\.word).contains("beta")
        else {
            fail("the menu is not the candidates that match: \(shell.editor.screen.popupMenu?.items.map(\.word) ?? [])")
        }
        channel.send(keys: "<Tab><CR>")
        await waitAsync("the candidate chosen to be taken") {
            let line = await lua("return vim.api.nvim_get_current_line()")?.stringValue ?? ""
            return line == "alpha" || line == "alphabet"
        }
        channel.send(keys: "<Esc>")
        step("completion comes up as a word is typed, matched to it; Tab chooses and Enter takes")
        // Any prompt of nvim's: the answer comes back, put away it is nil.
        _ =
            await lua(
                "vim.g.picked = nil; vim.ui.select({ 'red', 'green' }, { prompt = 'Colour:' }, function(item, index) vim.g.picked = { item or vim.NIL, index or vim.NIL } end)"
            )
        await wait("vim.ui.select as a list") { shell.listPicker != nil }
        shell.listPicker?.keyDown(with: key("j", code: 38))
        shell.listPicker?.keyDown(with: key("\r", code: 36))
        await waitAsync("the choice to come back") {
            await lua("return vim.g.picked and vim.g.picked[1]")?.stringValue == "green"
        }
        _ =
            await lua(
                "vim.g.picked = nil; vim.ui.select({ 'red' }, {}, function(item) vim.g.picked = { item or 'none' } end)"
            )
        await wait("a second list") { shell.listPicker != nil }
        shell.escape()
        await waitAsync("nothing to come back") {
            await lua("return vim.g.picked and vim.g.picked[1]")?.stringValue == "none"
        }
        _ =
            await lua(
                "require('frame.lsp'); for _, c in ipairs(vim.lsp.get_clients({ name = 'fake' })) do c:stop(true) end; vim.cmd('silent! bwipeout!')"
            )
        step("vim.ui.select goes to the list too: a choice comes back by value and index, put away it is nil")
    }

    /// C#: Roslyn, installed as a .NET tool, started for a `.cs` file, told which project to load, and reporting what
    /// is wrong with it.
    private func dotnetSteps() async {
        let channel = shell.session.channel
        func lua(_ code: String) async -> MessagePackValue? { try? await channel.lua(code) }
        guard FrameServers.onPath("dotnet") != nil
        else { return step("no dotnet here: Roslyn was not exercised") }
        let folder = RealPath.of(NSTemporaryDirectory()) + "/frame-cs-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? """
        <Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType>
        <TargetFramework>net10.0</TargetFramework></PropertyGroup></Project>
        """.write(toFile: folder + "/App.csproj", atomically: true, encoding: .utf8)
        try? "class Program { static void Main() { int x = ; } }\n"
            .write(toFile: folder + "/Program.cs", atomically: true, encoding: .utf8)
        try? "class Other { void M() { string s = ; } }\n"
            .write(toFile: folder + "/Other.cs", atomically: true, encoding: .utf8)
        _ = await lua("vim.cmd('edit ' .. vim.fn.fnameescape('\(folder)/Program.cs'))")
        func diagnostics() async -> Int {
            await lua("return #vim.diagnostic.get(0)")?.integerValue.map(Int.init) ?? 0
        }
        for _ in 0 ..< 600 {
            if await diagnostics() > 0 { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard await diagnostics() > 0 else {
            let state = await lua("return require('frame.lsp').report()")?.stringValue ?? ""
            fail("Roslyn gave no diagnostic for a syntax error: \(state)")
        }
        step("a real server (Roslyn, as a .NET tool) starts for a C# file and reports its syntax error")
        // The file that was never opened: Roslyn is asked for the whole solution's diagnostics.
        func other() async -> Int {
            await lua("""
            local n = 0
            for _, d in ipairs(require('frame.diag').list({ limit = 10000 })) do
              if d.path:find('Other.cs', 1, true) then n = n + 1 end
            end
            return n
            """)?.integerValue.map(Int.init) ?? 0
        }
        for _ in 0 ..< 300 {
            if await other() > 0 { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard await other() > 0 else { fail("Roslyn did not report the file that was never opened") }
        step("the server's workspace diagnostics reach files that were never opened")
        _ = await lua("require('frame.lsp').stop('csharp'); vim.diagnostic.reset(); vim.cmd('silent! %bwipeout!')")
        try? FileManager.default.removeItem(atPath: folder)
        // F#: fsautocomplete, told to load the project by itself.
        let fsFolder = RealPath.of(NSTemporaryDirectory()) + "/frame-fs-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: fsFolder, withIntermediateDirectories: true)
        try? """
        <Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType>
        <TargetFramework>net10.0</TargetFramework></PropertyGroup>
        <ItemGroup><Compile Include="Program.fs" /></ItemGroup></Project>
        """.write(toFile: fsFolder + "/App.fsproj", atomically: true, encoding: .utf8)
        try? "module Program\nlet x : int = \"text\"\n"
            .write(toFile: fsFolder + "/Program.fs", atomically: true, encoding: .utf8)
        _ = await lua("vim.cmd('edit ' .. vim.fn.fnameescape('\(fsFolder)/Program.fs'))")
        for _ in 0 ..< 600 {
            if await diagnostics() > 0 { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard await diagnostics() > 0 else {
            let state = await lua("return require('frame.lsp').report()")?.stringValue ?? ""
            fail("fsautocomplete gave no diagnostic for a type error: \(state)")
        }
        step("a real server (fsautocomplete) starts for an F# file and reports its error")
        _ =
            await lua(
                "require('frame.lsp').stop('fsautocomplete'); vim.diagnostic.reset(); vim.cmd('silent! %bwipeout!')"
            )
        try? FileManager.default.removeItem(atPath: fsFolder)
    }

    /// How the window behaves while a real solution builds with its language server analysing: how long the main thread
    /// is held up, and how long nvim takes to answer a request. Opt in with SILL_FRAME_CHECK_ONLY=load and
    /// FRAME_LOAD_FOLDER (a copy is built, never the folder itself).
    private func loadSteps() async {
        let channel = shell.session.channel
        func lua(_ code: String) async -> MessagePackValue? { try? await channel.lua(code) }
        guard let source = ProcessInfo.processInfo.environment["FRAME_LOAD_FOLDER"]
        else { return step("FRAME_LOAD_FOLDER is not set: the load was not measured") }
        let copy = RealPath.of(NSTemporaryDirectory()) + "/frame-load-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: copy) }
        guard let done = try? await FrameServers.run(
            "/usr/bin/rsync", [
                "-a",
                "--exclude",
                "bin",
                "--exclude",
                "obj",
                "--exclude",
                "node_modules",
                source + "/",
                copy + "/",
            ]
        ), done.code == 0 else { fail("could not copy \(source)") }
        _ = await lua("vim.cmd.cd('\(copy)')")
        for _ in 0 ..< 600 {
            let n = await lua("return #vim.lsp.get_clients()")?.integerValue ?? 0
            if n > 0 { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // Clicks: files of the solution opened one after another, each timed from the request to nvim showing it.
        let sources = (FileManager.default.enumerator(atPath: copy)?.allObjects as? [String] ?? [])
            .filter { $0.hasSuffix(".cs") && !$0.contains("/obj/") && !$0.contains("/bin/") }.sorted()
        var clicks: [Double] = []
        var nextClick = 0
        func click() async {
            guard !sources.isEmpty else { return }
            let path = RealPath.of(copy + "/" + sources[(nextClick * 37) % sources.count])
            nextClick += 1
            // Each click is profiled on its own, and the profile kept when it was slow.
            let slowProfile = ProcessInfo.processInfo.environment["FRAME_LOAD_SLOW_CLICKS"]
            let temp = NSTemporaryDirectory() + "frame-click-profile.txt"
            if slowProfile != nil { _ = await lua("require('frame.profile').start('\(temp)')") }
            let began = Date()
            shell.open(file: path, toEditor: true)
            for _ in 0 ..< 400 {
                if await lua("return vim.api.nvim_buf_get_name(0)")?.stringValue == path { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            let took = Date().timeIntervalSince(began)
            clicks.append(took)
            if let slowProfile {
                _ = await lua("require('frame.profile').stop()")
                if took > 0.5, let text = try? String(contentsOfFile: temp, encoding: .utf8) {
                    let header = "=== a click on \(sources[(nextClick - 1) * 0 + ((nextClick - 1) * 37) % sources.count]) took \(Int(took * 1000))ms\n"
                    let old = (try? String(contentsOfFile: slowProfile, encoding: .utf8)) ?? ""
                    try? (old + header + text + "\n").write(toFile: slowProfile, atomically: true, encoding: .utf8)
                }
            }
        }
        // Give the server time to load its projects and analyse, as it does for a person who has just opened the
        // folder:
        // nvim is asked for something every 50ms all the while (a click on a file is such a request), and its Lua
        // profiled.
        let profile = ProcessInfo.processInfo.environment["FRAME_LOAD_PROFILE"]
        if let profile { _ = await lua("require('frame.profile').start('\(profile)')") }
        var warm: [Double] = []
        let warmStart = Date()
        while Date().timeIntervalSince(warmStart) < 45 {
            let t = Date()
            _ = await lua("return 1")
            warm.append(Date().timeIntervalSince(t))
            if warm.count % 20 == 0 { await click() }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if profile != nil { _ = await lua("require('frame.profile').stop()") }
        let clients = await lua("""
        local out = {}
        for _, c in ipairs(vim.lsp.get_clients()) do out[#out + 1] = c.name .. ' @ ' .. tostring(c.root_dir) end
        return table.concat(out, ' | ')
        """)?.stringValue ?? ""
        print("load  servers after the clicks: \(clients)")
        clicks.sort()
        print(String(
            format: "load  clicking a file while the server analyses (no build): shown after at most %.0fms (median %.0fms) over %d clicks",
            (clicks.last ?? 0) * 1000, (clicks.isEmpty ? 0 : clicks[clicks.count / 2]) * 1000, clicks.count
        ))
        clicks = []
        warm.sort()
        print(String(
            format: "load  while the server analysed (no build): nvim answered in at most %.0fms (p95 %.0fms, %d over 100ms) over %d requests",
            (warm.last ?? 0) * 1000,
            (warm.isEmpty ? 0 : warm[min(warm.count - 1, Int(Double(warm.count) * 0.95))]) * 1000,
            warm.count(where: { $0 > 0.1 }), warm.count
        ))
        if ProcessInfo.processInfo.environment["FRAME_LOAD_NO_BUILD"] != nil { return }
        let stalls = StallMonitor()
        stalls.start()
        var trips: [Double] = []
        if let profile = ProcessInfo.processInfo.environment["FRAME_LOAD_PROFILE_BUILD"] {
            _ = await lua("require('frame.profile').start('\(profile)')")
        }
        let build = RunEntry(
            title: "Build proc.slnx", source: "dotnet", kind: .build,
            command: "dotnet build \(ProcessInfo.processInfo.environment["FRAME_LOAD_SOLUTION"] ?? "proc.slnx")",
            directory: copy
        )
        shell.run(build)
        let began = Date()
        while Date().timeIntervalSince(began) < 240 {
            let t = Date()
            _ = await lua("return 1")
            trips.append(Date().timeIntervalSince(t))
            if shell.status.building.isEmpty { break }
            if trips.count % 10 == 0 { await click() }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if ProcessInfo.processInfo.environment["FRAME_LOAD_PROFILE_BUILD"] != nil {
            _ = await lua("require('frame.profile').stop()")
        }
        clicks.sort()
        print(String(
            format: "load  clicking a file while it builds: shown after at most %.0fms (p95 %.0fms) over %d clicks",
            (clicks.last ?? 0) * 1000, (clicks.isEmpty ? 0 : clicks[min(
                clicks.count - 1,
                Int(Double(clicks.count) * 0.95)
            )]) * 1000,
            clicks.count
        ))
        let (worst, count) = stalls.stop()
        trips.sort()
        let p95 = trips.isEmpty ? 0 : trips[min(trips.count - 1, Int(Double(trips.count) * 0.95))]
        print(String(
            format: "load  build took %.1fs, main thread held up at most %.0fms (%d stalls over 100ms); nvim answered in at most %.0fms (p95 %.0fms) over %d requests",
            Date().timeIntervalSince(began), worst * 1000, count, (trips.last ?? 0) * 1000, p95 * 1000, trips.count
        ))
        let problemsNow = await lua("return #vim.diagnostic.get()")?.integerValue ?? 0
        print("load  diagnostics now: \(problemsNow), the window's totals: \(shell.problemTotals ?? [:])")
        // The numbers are what this is for (a machine with every core busy varies a good deal): a build is not failed
        // over them.
        step("a real build with the server analysing was measured (see the line above)")
    }

    /// A folder's project files start the servers they call for at launch, without a file open: Roslyn begins on the
    /// solution and the problems of files never opened reach the list; a file opened later finds the same server.
    private func startupSteps() async {
        let channel = shell.session.channel
        func lua(_ code: String) async -> MessagePackValue? { try? await channel.lua(code) }
        guard FrameServers.onPath("dotnet") != nil
        else { return step("no dotnet here: the server at launch was not exercised") }
        let folder = RealPath.of(NSTemporaryDirectory()) + "/frame-warm-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: folder + "/src/App", withIntermediateDirectories: true)
        try? "<Project Sdk=\"Microsoft.NET.Sdk\"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework></PropertyGroup></Project>"
            .write(toFile: folder + "/src/App/App.csproj", atomically: true, encoding: .utf8)
        try? "<Solution><Project Path=\"src/App/App.csproj\" /></Solution>"
            .write(toFile: folder + "/App.slnx", atomically: true, encoding: .utf8)
        try? "class Program { static void Main() { int x = ; } }\n"
            .write(toFile: folder + "/src/App/Program.cs", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        _ =
            await lua(
                "vim.cmd('enew'); require('frame.lsp').state.csharp = nil; require('frame.lsp').autostart('\(folder)')"
            )
        func clients() async -> Int {
            await lua("""
            local n = 0
            for _, c in ipairs(vim.lsp.get_clients({ name = 'frame_csharp' })) do
              if c.root_dir == '\(folder)' then n = n + 1 end
            end
            return n
            """)?.integerValue.map(Int.init) ?? 0
        }
        for _ in 0 ..< 100 {
            if await clients() == 1 { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard await clients() == 1 else { fail("Roslyn did not start on the solution at launch") }
        func found() async -> Bool {
            await lua("""
            for _, d in ipairs(require('frame.diag').list({ limit = 10000 })) do
              if d.path:find('Program.cs', 1, true) then return vim.fn.bufexists(d.path) == 0 end
            end
            return false
            """)?.boolValue == true
        }
        for _ in 0 ..< 300 {
            if await found() { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard await found()
        else { fail("the problems of a file never opened did not arrive from the server started at launch") }
        guard await lua("""
        local c = vim.lsp.get_clients({ name = 'frame_csharp' })[1]
        return c.capabilities.workspace.didChangeWatchedFiles.dynamicRegistration == false
        """)?.boolValue == true
        else { fail("the running server was told nvim watches files for it") }
        step(
            "the folder's solution starts Roslyn at launch, and the problems of files never opened arrive in the background"
        )
        _ = await lua("vim.cmd('edit ' .. vim.fn.fnameescape('\(folder)/src/App/Program.cs'))")
        try? await Task.sleep(for: .milliseconds(800))
        guard await clients() == 1,
              await lua("return #vim.lsp.get_clients({ name = 'frame_csharp' })")?.integerValue == 1,
              await lua("return #vim.lsp.get_clients({ bufnr = 0, name = 'frame_csharp' })")?.integerValue == 1
        else { fail("opening a file started a second server instead of using the one running") }
        step(
            "a file opened later is attached to the server already running (one per solution, whatever the file's folder)"
        )
        _ =
            await lua(
                "require('frame.lsp').stop('csharp'); require('frame.lsp').warm = {}; vim.diagnostic.reset(); vim.cmd('silent! %bwipeout!')"
            )
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

    /// The packages as a mode: the catalog with what is bundled, left out or available; Return on a bundled one
    /// switches it off
    /// and on in the settings; Return on an available one downloads it from GitHub (its commit checked), loads it
    /// without a
    /// restart, and `x` removes it. The download is real; without the network it says so and is not counted.
    private func packagesSteps() async {
        let channel = shell.session.channel
        func lua(_ code: String) async -> MessagePackValue? { try? await channel.lua(code) }
        let saved = NSTemporaryDirectory() + "frame-packages-\(UUID().uuidString).toml"
        setenv("FRAME_SETTINGS", saved, 1)
        defer { unsetenv("FRAME_SETTINGS") }
        func savedText() -> String { (try? String(contentsOfFile: saved, encoding: .utf8)) ?? "" }
        func type(_ text: String, into picker: ListPickerView) {
            for letter in text {
                picker.keyDown(with: key(String(letter), code: 0))
            }
        }
        shell.focusEditor()
        shell.showPackages(nil)
        await wait("the packages as a list") { shell.listPicker != nil }
        guard let picker = shell.listPicker, shell.modes.surface == .list,
              shell.modes.label(editorMode: "normal") == "PACKAGES"
        else { fail("the packages did not come up as a mode") }
        guard picker.all.first(where: { $0.id == "tokyonight.nvim" })?.detail.hasSuffix("bundled") == true,
              picker.all.first(where: { $0.id == "gruvbox.nvim" })?.detail.contains("2.0.0") == true,
              picker.all.first(where: { $0.id == "gitsigns.nvim" })?.subtitle.isEmpty == false
        else { fail("the rows do not say bundled and available: \(picker.all.map(\.detail))") }
        step("the packages are a list: what is bundled, and what can be installed with its version, and what each is")
        // Switch a bundled one off and on: the settings change, the list stays.
        picker.keyDown(with: key("/", code: 44))
        type("gitsigns", into: picker)
        picker.keyDown(with: key("\r", code: 36))
        await wait("the bundled package to be left out") { savedText().contains("disabled = [\"gitsigns.nvim\"]") }
        guard shell.listPicker != nil else { fail("the list went away after a choice") }
        picker.keyDown(with: key("\r", code: 36))
        await wait("the bundled package to be back") { savedText().contains("disabled = []") }
        step("Return on a bundled package leaves it out of the next start, and again brings it back; the list stays up")
        // A real install, if the network is there and the package is not.
        let dir = await lua("return require('frame.catalog').dir('indent-blankline.nvim')")?.stringValue ?? ""
        guard !dir.isEmpty, !FileManager.default.fileExists(atPath: dir) else {
            return step("indent-blankline.nvim is installed already: the install was not exercised")
        }
        guard await (try? URLSession.shared.data(from: URL(string: "https://codeload.github.com")!)) != nil else {
            return step("no network: the install was not exercised")
        }
        defer { try? FileManager.default.removeItem(atPath: dir) }
        picker.keyDown(with: key("\u{1B}", code: 53))
        picker.keyDown(with: key("/", code: 44))
        type("indent", into: picker)
        picker.keyDown(with: key("\r", code: 36))
        await wait("the install to be done", seconds: 90) {
            picker.all.first(where: { $0.id == "indent-blankline.nvim" })?.detail.hasSuffix("installed") == true
        }
        guard FileManager.default.fileExists(atPath: dir + "/lua/ibl/init.lua")
        else { fail("the package is not where it goes") }
        guard await lua("return package.loaded['ibl'] ~= nil or pcall(require, 'ibl')")?.boolValue == true
        else { fail("the package was not loaded without a restart") }
        step(
            "Return on an available package downloads it, checks its commit, unpacks it and loads it without a restart"
        )
        // Removed with x (the filter ends first: x is a letter while typing).
        shell.escape()
        guard shell.listPicker != nil, picker.filter == nil else { fail("Escape did not end the filter first") }
        picker.keyDown(with: key("x", code: 7))
        await wait("the package to be removed") { !FileManager.default.fileExists(atPath: dir) }
        shell.escape()
        guard shell.listPicker == nil else { fail("Escape did not close") }
        step("x removes an installed package")
    }

    /// The settings window: every control writes the settings file in place and changes the running editor (or the
    /// layout) at
    /// once, and says which need a restart.
    private func settingsSteps() async {
        let channel = shell.session.channel
        func lua(_ code: String) async -> MessagePackValue? { try? await channel.lua(code) }
        let saved = NSTemporaryDirectory() + "frame-settings-\(UUID().uuidString).toml"
        setenv("FRAME_SETTINGS", saved, 1)
        defer { unsetenv("FRAME_SETTINGS") }
        func savedText() -> String { (try? String(contentsOfFile: saved, encoding: .utf8)) ?? "" }
        shell.focusEditor()
        shell.openSettings(nil)
        await wait("the settings window") { shell.app.settings?.window?.isVisible == true }
        guard let settings = shell.app.settings, let window = settings.window else { fail("no settings window") }
        defer { window.orderOut(nil) }
        func control<Control: NSControl>(_ key: String, as _: Control.Type = NSControl.self) -> Control {
            guard let found = settings.controls[key] as? Control else { fail("no control for \(key)") }
            return found
        }
        func fire(_ control: NSControl) { _ = control.sendAction(control.action, to: control.target) }
        if let path = ProcessInfo.processInfo.environment["SILL_CHECK_SHOT"], let view = window.contentView,
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-settings.png")))
        }
        step("⌘, brings up the settings window, with a control for each setting")
        // The editor: changed in the running nvim at once, and written to the file.
        control("editor.tabwidth").integerValue = 2
        fire(control("editor.tabwidth"))
        await waitAsync("the tab width to reach nvim") { await lua("return vim.o.shiftwidth")?.integerValue == 2 }
        await wait("the tab width to be saved") { savedText().contains("tabwidth = 2") }
        let wrap = control("editor.wrap", as: NSButton.self)
        wrap.state = .on
        fire(wrap)
        await waitAsync("wrapping to reach nvim") { await lua("return vim.wo.wrap")?.boolValue == true }
        await wait("wrapping to be saved") { savedText().contains("wrap = true") }
        let pixelBox = control("editor.pixelscroll", as: NSButton.self)
        pixelBox.state = .off
        fire(pixelBox)
        await wait("pixel scrolling to go off") { shell.editor.pixelScrolling == false }
        await wait("it to be saved") { savedText().contains("pixelscroll = false") }
        pixelBox.state = .on
        fire(pixelBox)
        await wait("pixel scrolling to come back") { shell.editor.pixelScrolling }
        let numbers = control("editor.number", as: NSButton.self)
        numbers.state = .off
        fire(numbers)
        await waitAsync("the line numbers to go") { await lua("return vim.wo.number")?.boolValue == false }
        step("tab width, wrapping and line numbers change the running editor and are saved")
        // The scheme: the popup's choice is applied and saved.
        let scheme = control("theme.colorscheme", as: NSPopUpButton.self)
        guard let item = scheme.itemTitles.first(where: { $0.hasPrefix("tokyonight-storm") })
        else { fail("no storm in the schemes") }
        scheme.selectItem(withTitle: item)
        fire(scheme)
        await waitAsync("the scheme to reach nvim") {
            await lua("return vim.g.colors_name")?.stringValue == "tokyonight-storm"
        }
        await wait("the scheme to be saved") { savedText().contains("colorscheme = \"tokyonight-storm\"") }
        step("the colour scheme is applied and saved")
        // Keys: from the next start, saved only.
        let leader = control("editor.leader", as: NSTextField.self)
        leader.stringValue = ";"
        fire(leader)
        control("whichkey.delay").integerValue = 700
        fire(control("whichkey.delay"))
        await wait("the leader and the delay to be saved") {
            savedText().contains("leader = \";\"") && savedText().contains("delay = 700")
        }
        step("the leader and which-key's delay are saved for the next start")
        // The layout: the window's own.
        let bar = control("layout.status", as: NSPopUpButton.self)
        bar.selectItem(at: 1)
        fire(bar)
        await wait("the status bar across the window") { shell.view.statusPlacement == .window }
        bar.selectItem(at: 0)
        fire(bar)
        await wait("the status bar beside the sidebar") { shell.view.statusPlacement == .editor }
        let tabs = control("layout.tabs", as: NSPopUpButton.self)
        tabs.selectItem(at: TabsPlacement.allCases.firstIndex(of: .hidden)!)
        fire(tabs)
        await wait("the tabs hidden") { shell.view.tabsPlacement == .hidden }
        tabs.selectItem(at: TabsPlacement.allCases.firstIndex(of: .statusbar)!)
        fire(tabs)
        await wait("the tabs in the status bar") { shell.view.tabsPlacement == .statusbar }
        step("the status bar and the tabs move at once")
        // What it hands on to.
        fire(control("packages"))
        await wait("the packages to come up") { shell.listPicker != nil }
        shell.escape()
        guard shell.listPicker == nil else { fail("Escape did not close the packages") }
        step("Packages… brings up the package mode")
        // The file it wrote keeps its comments and is valid for what reads it.
        guard savedText().contains("[editor]"), savedText().contains("[whichkey]"),
              savedText().contains("[theme]")
        else {
            fail("the file lost its tables: \(savedText())")
        }
        let reread = FrameSettings.json()
        guard reread.contains("\"tabwidth\":2"),
              reread.contains("tokyonight-storm") else { fail("the file does not read back: \(reread)") }
        step("the file reads back as what was set")
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

    /// Scrolling by the pixel: the text follows a trackpad's deltas by less than a line (what is drawn is the rows
    /// between nvim's
    /// last two scrolls, how far along the finger says), nvim is a line ahead, whole lines cross to it, turning round
    /// works, and
    /// when the events stop the text settles. The deltas are given to the view's own scroll (an `NSEvent` carries no
    /// window).
    private func pixelSteps() async {
        let channel = shell.session.channel
        func lua(_ code: String) async -> MessagePackValue? { try? await channel.lua(code) }
        let file = RealPath.of(NSTemporaryDirectory()) + "/frame-pixel-\(UUID().uuidString).txt"
        try? (1 ... 400).map { "line \($0)" }.joined(separator: "\n").write(
            toFile: file,
            atomically: true,
            encoding: .utf8
        )
        _ =
            await lua(
                "vim.o.scrolloff = 0; vim.o.smoothscroll = false; vim.cmd('edit ' .. vim.fn.fnameescape('\(file)')); vim.cmd('normal! gg')"
            )
        let editor = shell.editor!
        defer { editor.pixelScrolling = true }
        editor.pixelScrolling = true
        let height = editor.metrics.height
        let target = editor.screen.hit(row: 3, col: 12)
        guard target.grid != 1 || editor.screen.placements[target.grid]?.kind == .window
        else { fail("no window to scroll") }
        func top() async -> Int { await lua("return vim.fn.line('w0')")?.integerValue.map(Int.init) ?? 0 }
        func move(_ lines: Double) {
            editor.pixelScroll(
                deltaX: 0,
                deltaY: CGFloat(-lines) * height,
                grid: target.grid,
                row: target.row,
                col: target.col,
                modifiers: ""
            )
        }
        func progress() -> Double? { editor.currentFrame.scrolls[target.grid].map { Double($0.progress) } }
        func lines() -> Int? { editor.currentFrame.scrolls[target.grid]?.lines }
        guard await top() == 1 else { await fail("not at the top to begin with: \(top())") }
        move(0.3)
        await waitAsync("nvim to be a line ahead of a third of a line") { await top() == 2 }
        await wait("the slide the finger holds") { lines() == 1 }
        guard let first = progress(),
              abs(first - 0.3) < 0.02
        else { fail("a third of a line is not drawn a third along: \(String(describing: progress()))") }
        move(0.4)
        try? await Task.sleep(for: .milliseconds(30))
        guard let second = progress(), abs(second - 0.7) < 0.02, await top() == 2
        else { await fail("0.7 of a line: \(String(describing: progress())), top \(top())") }
        step("the text follows the finger by less than a line, nvim a line ahead")
        move(0.5)
        await waitAsync("the second line to cross") { await top() == 3 }
        await wait("the next slide") { lines() == 1 && (progress() ?? 0) < 0.5 }
        guard let third = progress(),
              abs(third - 0.2) < 0.02
        else { fail("1.2 lines is not 0.2 along the second: \(String(describing: progress()))") }
        step("past a line the next one is already there, and the text goes on from where it was")
        // The events stop: it settles on its own and nothing is left sliding.
        try? await Task.sleep(for: .milliseconds(Int(EditorView.pixelSettleDelay * 1000) + 60))
        _ = editor.currentFrame
        await wait("the text to settle") { _ = editor.currentFrame; return !editor.isSliding }
        guard await top() == 3 else { await fail("nvim moved by the settling: \(top())") }
        step("when the events stop the text settles where nvim is")
        // Turning round: back by half a line, and nvim goes a line back.
        move(-0.5)
        await waitAsync("nvim to go back a line") { await top() == 2 }
        await wait("the slide back") { lines() == -1 }
        guard let back = progress(),
              abs(back - 0.5) < 0.02
        else { fail("half a line back is not half along: \(String(describing: progress()))") }
        try? await Task.sleep(for: .milliseconds(Int(EditorView.pixelSettleDelay * 1000) + 60))
        await wait("the text to settle again") { _ = editor.currentFrame; return !editor.isSliding }
        step("turning round goes back by the pixel too")
        // The end of a file: scrolling on does not take the last line up the window; a short file stays where it is.
        let short = RealPath.of(NSTemporaryDirectory()) + "/frame-pixel-short-\(UUID().uuidString).txt"
        try? (1 ... 10).map { "short \($0)" }.joined(separator: "\n").write(
            toFile: short,
            atomically: true,
            encoding: .utf8
        )
        _ = await lua("vim.cmd('edit ' .. vim.fn.fnameescape('\(short)')); vim.cmd('normal! gg')")
        for _ in 0 ..< 20 {
            move(1)
        }
        try? await Task.sleep(for: .milliseconds(Int(EditorView.pixelSettleDelay * 1000) + 300))
        await wait("the text to settle at the end") { _ = editor.currentFrame; return !editor.isSliding }
        guard await top() == 1 else { await fail("a ten line file was scrolled up to line \(top())") }
        _ = await lua("vim.cmd('edit ' .. vim.fn.fnameescape('\(file)'))")
        _ = await lua("vim.cmd('normal! G')")
        for _ in 0 ..< 20 {
            move(1)
            try? await Task.sleep(for: .milliseconds(16))
        }
        try? await Task.sleep(for: .milliseconds(Int(EditorView.pixelSettleDelay * 1000) + 300))
        await wait("the text to settle at the end of a long file") { _ = editor.currentFrame; return !editor.isSliding }
        let rows = await lua("return vim.api.nvim_win_get_height(0)")?.integerValue.map(Int.init) ?? 0
        guard await top() == 400 - rows + 3
        else { await fail("the last line of 400 should sit two rows off the bottom of \(rows): top \(top())") }
        step("past the end the last line stays near the bottom of the window")
        _ = await lua("vim.cmd('normal! gg')")
        await wait("the text to be back at the top") { _ = editor.currentFrame; return !editor.isSliding }
        // A mouse wheel and a trackpad with it off still slide by lines.
        editor.pixelScrolling = false
        channel.send(keys: "<C-e>")
        await wait("a line slide, not held") { lines() == 1 }
        await wait("it ends by itself") { _ = editor.currentFrame; return !editor.isSliding }
        _ = await lua("vim.cmd('silent! bwipeout!')")
        step("with pixel scrolling off, scrolls slide by lines as before")
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
        await wait("the chip to name the repository's branch") { shell.chip.branch == "main" }
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

/// Watches how long the main thread is held up: a thread asks it to answer every 50ms and times the wait.
final class StallMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var worst = 0.0
    private var count = 0
    private var captured = 0

    func start() {
        lock.lock()
        running = true
        lock.unlock()
        Thread.detachNewThread { [self] in
            while true {
                lock.lock()
                let go = running
                lock.unlock()
                if !go { return }
                let asked = Date()
                let semaphore = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { semaphore.signal() }
                semaphore.wait()
                let waited = Date().timeIntervalSince(asked)
                lock.lock()
                worst = max(worst, waited)
                if waited > 0.1 { count += 1 }
                let capture = waited > 0.4 && captured < 4
                if capture { captured += 1 }
                lock.unlock()
                // A long stall is looked at: where the main thread is, a moment after it is seen to be stuck.
                if capture, let path = ProcessInfo.processInfo.environment["FRAME_LOAD_SAMPLES"] {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                    process.arguments = ["\(getpid())", "1", "1", "-file", "\(path)/stall-\(captured).txt"]
                    try? process.run()
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }

    func stop() -> (Double, Int) {
        lock.lock()
        defer { lock.unlock() }
        running = false
        return (worst, count)
    }
}
