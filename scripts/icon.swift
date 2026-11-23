// Draws the app icons: Trim (a window frame split by a mullion into four panes) and Shim (one pane).
//   swift scripts/icon.swift <output folder>   writes Trim-1024.png and Shim-1024.png
import AppKit

func draw(panes: Bool, to path: String) {
    let size = 1024
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let canvas = NSRect(x: 0, y: 0, width: size, height: size)
    // macOS icon grid: the shape is 824 of 1024, centred.
    let body = canvas.insetBy(dx: 100, dy: 100)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.set()
    NSColor(red: 0.07, green: 0.08, blue: 0.11, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    shape.addClip()
    NSGradient(colors: [
        NSColor(red: 0.13, green: 0.15, blue: 0.24, alpha: 1), NSColor(red: 0.05, green: 0.06, blue: 0.09, alpha: 1),
    ])!.draw(in: body, angle: -60)
    // The window: a rounded frame, drawn as a stroke in the accent colour.
    let teal = NSColor(red: 0.18, green: 0.90, blue: 0.77, alpha: 1)
    let violet = NSColor(red: 0.56, green: 0.48, blue: 1.0, alpha: 1)
    let frame = body.insetBy(dx: 150, dy: 150)
    let line: CGFloat = 46
    let outer = NSBezierPath(roundedRect: frame, xRadius: 70, yRadius: 70)
    outer.lineWidth = line
    // The gradient shows through the stroke only: the stroke becomes the clip.
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.saveGState()
    ctx.setLineWidth(line)
    ctx.addPath(outer.cgPath)
    ctx.replacePathWithStrokedPath()
    if panes {
        let mullion = CGMutablePath()
        mullion.addRect(CGRect(x: frame.midX - line / 2, y: frame.minY + line / 2, width: line, height: frame.height - line))
        mullion.addRect(CGRect(x: frame.minX + line / 2, y: frame.midY - line / 2, width: frame.width - line, height: line))
        ctx.addPath(mullion)
    }
    ctx.clip()
    NSGradient(colors: [teal, violet])!.draw(from: NSPoint(x: frame.minX, y: frame.maxY), to: NSPoint(x: frame.maxX, y: frame.minY), options: [])
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
draw(panes: true, to: out + "/Trim-1024.png")
draw(panes: false, to: out + "/Shim-1024.png")
