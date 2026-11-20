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
    let shell: FrameDelegate

    init(_ shell: FrameDelegate) { self.shell = shell }

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
        await layoutSteps()
        await switchSteps()
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

    private func key(_ characters: String, code: UInt16 = 0) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: shell.window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
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
        await wait("the grid again") { shell.editor.screen.grids[1] != nil }
        do { _ = try await shell.session.channel.command("FrameConfig sill") } catch {
            fail("FrameConfig sill: \(error)")
        }
        await wait("nvim to restart under sill's own") { shell.current == .builtIn }
        let back = await (try? shell.session.channel.lua("return vim.g.frame_marker or ''"))?.stringValue
        guard back == "" else { fail("the first config's settings are still there: \(back ?? "nil")") }
        step("and back to sill's own, with nothing of the other config left")
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
