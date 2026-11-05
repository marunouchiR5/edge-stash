// Renders Resources/AppIcon.icns. Run: swift Scripts/make_icon.swift
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.1, body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: body, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.30, alpha: 1),
               ending: NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.13, alpha: 1))!.draw(in: bg, angle: -90)
    // Screen with a panel sliding in from the right edge.
    let screen = body.insetBy(dx: s * 0.12, dy: s * 0.18)
    NSColor(white: 1, alpha: 0.18).setFill()
    NSBezierPath(roundedRect: screen, xRadius: s * 0.04, yRadius: s * 0.04).fill()
    let panel = NSRect(x: screen.maxX - screen.width * 0.42, y: screen.minY, width: screen.width * 0.42, height: screen.height)
    NSColor(calibratedRed: 0.42, green: 0.62, blue: 1.0, alpha: 1).setFill()
    NSBezierPath(roundedRect: panel, xRadius: s * 0.04, yRadius: s * 0.04).fill()
    let arrow = NSBezierPath()
    let cy = screen.midY, ax = panel.minX - s * 0.05
    arrow.move(to: NSPoint(x: ax, y: cy + s * 0.07)); arrow.line(to: NSPoint(x: ax - s * 0.08, y: cy)); arrow.line(to: NSPoint(x: ax, y: cy - s * 0.07))
    arrow.lineWidth = s * 0.035; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    NSColor.white.setStroke(); arrow.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
