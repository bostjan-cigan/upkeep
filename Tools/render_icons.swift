// Renders a contact sheet of the device SVGs on colored tiles, and the app icon PNGs.
// Usage: swift Tools/render_icons.swift <repo-root> [contact-sheet.png]
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let iconsDir = root.appendingPathComponent("Upkeep/Icons")

func png(_ size: CGFloat, _ draw: (CGContext) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSGraphicsContext.current!.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func tile(_ rect: CGRect, _ top: NSColor, _ bottom: NSColor) {
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(starting: top, ending: bottom)!.draw(in: path, angle: -90)
}

// Contact sheet
if CommandLine.arguments.count > 2 {
    let files = try FileManager.default.contentsOfDirectory(at: iconsDir, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "svg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    let cell: CGFloat = 160, cols = 6
    let rows = Int(ceil(Double(files.count) / Double(cols)))
    let colors: [NSColor] = [.systemBlue, .systemTeal, .systemOrange, .systemGreen, .systemPurple, .systemRed, .systemIndigo, .systemBrown]
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(cell) * cols, pixelsHigh: Int(cell) * rows,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.windowBackgroundColor.setFill()
    NSRect(x: 0, y: 0, width: cell * CGFloat(cols), height: cell * CGFloat(rows)).fill()
    for (i, f) in files.enumerated() {
        let x = CGFloat(i % cols) * cell, y = CGFloat(rows - 1 - i / cols) * cell
        let c = colors[i % colors.count]
        let r = CGRect(x: x + 16, y: y + 24, width: 128, height: 128)
        tile(r, c.blended(withFraction: 0.25, of: .white)!, c)
        guard let img = NSImage(contentsOf: f) else { print("FAILED to load \(f.lastPathComponent)"); continue }
        img.draw(in: r.insetBy(dx: 20, dy: 20))
        (f.deletingPathExtension().lastPathComponent as NSString).draw(at: CGPoint(x: x + 16, y: y + 4), withAttributes: [.font: NSFont.systemFont(ofSize: 12)])
    }
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}

// App icon: blue squircle, white house glyph, green check badge.
let appIconSVG = iconsDir.appendingPathComponent("generic.svg")
let house = NSImage(contentsOf: appIconSVG)!

/// The artwork inside `body`. `rounded` draws the macOS squircle with its shadow; the phone icons
/// are full-bleed squares instead, because iOS rounds them itself. `content` shrinks the glyph and
/// badge toward the middle (maskable icons get cropped to a circle on some platforms).
func drawIcon(_ body: CGRect, rounded: Bool, content: CGFloat = 1) {
    let top = NSColor(srgbRed: 0.35, green: 0.68, blue: 1, alpha: 1)
    let bottom = NSColor(srgbRed: 0.13, green: 0.36, blue: 0.93, alpha: 1)
    if rounded {
        NSGraphicsContext.current!.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowBlurRadius = body.width * 0.022; shadow.shadowOffset = NSSize(width: 0, height: -body.width * 0.011)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3); shadow.set()
        tile(body, top, bottom)
        NSGraphicsContext.current!.restoreGraphicsState()
    } else {
        NSGradient(starting: top, ending: bottom)!.draw(in: body, angle: -90)
    }
    let art = body.insetBy(dx: body.width * (1 - content) / 2, dy: body.height * (1 - content) / 2)
    house.draw(in: art.insetBy(dx: art.width * 0.14, dy: art.width * 0.14))
    let b = art.width * 0.3
    let badge = CGRect(x: art.maxX - b - art.width * 0.06, y: art.minY + art.width * 0.06, width: b, height: b)
    NSColor(srgbRed: 0.2, green: 0.78, blue: 0.35, alpha: 1).setFill()
    NSBezierPath(ovalIn: badge).fill()
    NSColor.white.setStroke()
    let check = NSBezierPath()
    check.move(to: CGPoint(x: badge.minX + b * 0.27, y: badge.midY))
    check.line(to: CGPoint(x: badge.minX + b * 0.44, y: badge.minY + b * 0.32))
    check.line(to: CGPoint(x: badge.minX + b * 0.74, y: badge.minY + b * 0.68))
    check.lineWidth = b * 0.12; check.lineCapStyle = .round; check.lineJoinStyle = .round
    check.stroke()
}

// Mac: squircle with the standard transparent margin.
let outDir = root.appendingPathComponent("Upkeep/Assets.xcassets/AppIcon.appiconset")
for px in [16, 32, 64, 128, 256, 512, 1024] {
    let s = CGFloat(px)
    let inset = s * 100 / 1024
    try png(s) { _ in drawIcon(CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2), rounded: true) }
        .write(to: outDir.appendingPathComponent("icon_\(px).png"))
}

// Phone web app: the same artwork, full-bleed and opaque — iOS adds the rounded corners.
// The artwork is scaled up to match the Mac tile's proportions (its squircle fills ~80% of the canvas).
let webDir = root.appendingPathComponent("Web/public/icons")
try FileManager.default.createDirectory(at: webDir, withIntermediateDirectories: true)
for px in [180, 192, 512] {
    let s = CGFloat(px)
    try png(s) { _ in drawIcon(CGRect(x: 0, y: 0, width: s, height: s), rounded: false) }
        .write(to: webDir.appendingPathComponent("icon-\(px).png"))
}
// iOS also looks for these at the site root when a page doesn't name its icon.
let publicDir = root.appendingPathComponent("Web/public")
for name in ["apple-touch-icon.png", "apple-touch-icon-precomposed.png"] {
    try png(180) { _ in drawIcon(CGRect(x: 0, y: 0, width: 180, height: 180), rounded: false) }
        .write(to: publicDir.appendingPathComponent(name))
}
try png(32) { _ in drawIcon(CGRect(x: 0, y: 0, width: 32, height: 32), rounded: false) }
    .write(to: publicDir.appendingPathComponent("favicon.png"))
// Notification badge: the house glyph alone, white on transparent. Platforms that draw a small
// monochrome mark beside a push notification (Android, desktop Chrome) use this; iOS ignores it
// and shows the installed web app's own icon instead.
try png(96) { _ in
    house.draw(in: CGRect(x: 8, y: 8, width: 80, height: 80))
}.write(to: webDir.appendingPathComponent("badge-96.png"))

// Maskable (Android and others crop to a circle): keep the artwork inside the central safe zone.
try png(512) { _ in drawIcon(CGRect(x: 0, y: 0, width: 512, height: 512), rounded: false, content: 0.8) }
    .write(to: webDir.appendingPathComponent("icon-maskable-512.png"))
print("ok")
