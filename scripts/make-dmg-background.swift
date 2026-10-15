// Draws the DMG window background (an arrow from the app to Applications) and
// writes Resources/dmg-background.tiff (1x + 2x). Run: swift scripts/make-dmg-background.swift
// Layout must match scripts/package.sh: window 660x400, icons centred at x=165 and x=495, y=190.
import AppKit

let width: CGFloat = 660, height: CGFloat = 400

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)  // points, so 2x is Retina
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let bounds = NSRect(x: 0, y: 0, width: width, height: height)
    NSGradient(colors: [NSColor(srgbRed: 0.97, green: 0.97, blue: 1.0, alpha: 1),
                        NSColor(srgbRed: 0.90, green: 0.90, blue: 0.97, alpha: 1)])!
        .draw(in: bounds, angle: -90)

    // Arrow between the two icons (Finder y=190 from the top = 210 from the bottom).
    let y: CGFloat = height - 190
    let accent = NSColor(srgbRed: 0.36, green: 0.32, blue: 0.86, alpha: 0.85)
    accent.setStroke()
    accent.setFill()
    let shaft = NSBezierPath()
    shaft.lineWidth = 6
    shaft.lineCapStyle = .round
    shaft.move(to: NSPoint(x: 268, y: y))
    shaft.line(to: NSPoint(x: 378, y: y))
    shaft.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 396, y: y))
    head.line(to: NSPoint(x: 374, y: y + 14))
    head.line(to: NSPoint(x: 374, y: y - 14))
    head.close()
    head.fill()

    let title = NSAttributedString(string: "Drag Loquor to Applications to install", attributes: [
        .font: NSFont.systemFont(ofSize: 15, weight: .medium),
        .foregroundColor: NSColor(white: 0.25, alpha: 1),
    ])
    let size = title.size()
    title.draw(at: NSPoint(x: (width - size.width) / 2, y: 62))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let image = NSImage(size: NSSize(width: width, height: height))
image.addRepresentation(render(scale: 1))
image.addRepresentation(render(scale: 2))
let out = root.appending(path: "Resources/dmg-background.tiff")
try image.tiffRepresentation(using: .lzw, factor: 0)!.write(to: out)
print("Wrote \(out.path)")
