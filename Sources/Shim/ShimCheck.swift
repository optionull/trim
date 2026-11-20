import AppKit
import Metal
import SillCore
import SillEditor
import SillRender

/// The shim's check (`SILL_SHIM_CHECK=1`, nvim without the person's config): what is typed reaches nvim and comes
/// back as the grid; the window has no title bar's buttons but stays a titled window (macOS rounds those) and moves by
/// its margin; `SILL_CHECK_SHOT` saves a picture of the window, its corners rounded as on screen.
@MainActor
struct ShimCheck {
    let shell: ShimDelegate

    init(_ shell: ShimDelegate) { self.shell = shell }

    private func step(_ text: String) {
        print("ok    " + text)
        fflush(stdout)
    }

    private func fail(_ text: String) -> Never {
        print("shim check: FAILED: " + text)
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

    func run() async {
        guard let editor = shell.editor, let window = shell.window else { fail("no window") }
        await wait("nvim's grid") { editor.screen.grids[1] != nil }
        shell.session.channel.send(keys: "ihello from the shim<Esc>")
        // Each window is a grid of its own (multigrid): the text is in one of them.
        await wait("the text in the grid") {
            editor.screen.grids.values
                .contains { grid in (0 ..< grid.rows).contains { grid.line($0).contains("hello from the shim") } }
        }
        step("typed keys reach nvim and come back as the grid")
        let hidden = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .allSatisfy { window.standardWindowButton($0)?.isHidden ?? true }
        guard hidden, window.styleMask.contains(.titled), window.titlebarAppearsTransparent,
              window.styleMask.contains(.fullSizeContentView)
        else { fail("no title bar, still a titled window: \(window.styleMask)") }
        guard shell.view.mouseDownCanMoveWindow, editor.frame.minX == ShimView.margin,
              editor.frame.minY == ShimView.margin
        else { fail("the grid inside its margin: \(editor.frame)") }
        step(
            "no title bar or buttons; a titled window (rounded by macOS) that moves by its \(Int(ShimView.margin))-point margin"
        )
        if let path = ProcessInfo.processInfo.environment["SILL_CHECK_SHOT"] {
            do {
                try shot(editor: editor, to: path)
                step("saved \(path)")
            } catch {
                fail("the shot: \(error)")
            }
        }
        print("shim check: passed")
        fflush(stdout)
        exit(0)
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
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { throw ShotFailure() }
        try data.write(to: URL(fileURLWithPath: path))
    }

    struct ShotFailure: Error {}
}
