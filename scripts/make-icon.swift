// Draws the app icon (a white microphone on a rounded square) and writes
// Resources/AppIcon.icns. Run: swift scripts/make-icon.swift
// The microphone is drawn here from plain shapes: Apple's SF Symbols license
// doesn't allow symbols in app icons.
import AppKit

func render(_ size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // macOS icon grid: an 824 pt rounded square centred in 1024, with a soft shadow.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowBlurRadius = 24 * s
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [NSColor(srgbRed: 0.42, green: 0.36, blue: 0.98, alpha: 1),
                        NSColor(srgbRed: 0.16, green: 0.20, blue: 0.62, alpha: 1)])!
        .draw(in: shape, angle: -90)

    // White microphone: capsule head, cradle arc, stem and base.
    NSColor.white.setFill()
    NSColor.white.setStroke()
    let cx = tile.midX
    let head = NSRect(x: cx - 105 * s, y: 430 * s, width: 210 * s, height: 340 * s)
    NSBezierPath(roundedRect: head, xRadius: 105 * s, yRadius: 105 * s).fill()

    let cradle = NSBezierPath()
    cradle.lineWidth = 46 * s
    cradle.lineCapStyle = .round
    cradle.appendArc(withCenter: NSPoint(x: cx, y: 560 * s), radius: 175 * s, startAngle: 180, endAngle: 360, clockwise: false)
    // up the sides to the cradle's top
    let left = NSBezierPath(); left.lineWidth = 46 * s; left.lineCapStyle = .round
    left.move(to: NSPoint(x: cx - 175 * s, y: 560 * s)); left.line(to: NSPoint(x: cx - 175 * s, y: 610 * s))
    let right = NSBezierPath(); right.lineWidth = 46 * s; right.lineCapStyle = .round
    right.move(to: NSPoint(x: cx + 175 * s, y: 560 * s)); right.line(to: NSPoint(x: cx + 175 * s, y: 610 * s))
    for path in [cradle, left, right] { path.stroke() }

    let stem = NSBezierPath(); stem.lineWidth = 46 * s; stem.lineCapStyle = .round
    stem.move(to: NSPoint(x: cx, y: 385 * s)); stem.line(to: NSPoint(x: cx, y: 300 * s))
    stem.stroke()
    let base = NSBezierPath(); base.lineWidth = 46 * s; base.lineCapStyle = .round
    base.move(to: NSPoint(x: cx - 110 * s, y: 280 * s)); base.line(to: NSPoint(x: cx + 110 * s, y: 280 * s))
    base.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appending(path: "AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(CGFloat(base)).write(to: iconset.appending(path: "icon_\(base)x\(base).png"))
    try render(CGFloat(base * 2)).write(to: iconset.appending(path: "icon_\(base)x\(base)@2x.png"))
}
let out = root.appending(path: "Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote \(out.path)" : "iconutil failed")
