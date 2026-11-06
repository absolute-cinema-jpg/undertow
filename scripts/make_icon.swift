// Draws the app icon: three swells of a current over a deep gradient.
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.09
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let shape = NSBezierPath(roundedRect: rect, xRadius: s * 0.19, yRadius: s * 0.19)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.03, green: 0.11, blue: 0.24, alpha: 1),
        NSColor(calibratedRed: 0.05, green: 0.30, blue: 0.50, alpha: 1),
    ])!.draw(in: shape, angle: 90)
    shape.addClip()
    let bands: [(y: CGFloat, color: NSColor)] = [
        (0.66, NSColor(calibratedRed: 0.36, green: 0.78, blue: 0.98, alpha: 1)),
        (0.48, NSColor(calibratedRed: 0.62, green: 0.90, blue: 1.00, alpha: 0.85)),
        (0.30, NSColor(calibratedRed: 1.00, green: 0.66, blue: 0.36, alpha: 1)),
    ]
    for (i, band) in bands.enumerated() {
        let p = NSBezierPath()
        let y = s * band.y
        let amp = s * 0.055
        let phase = CGFloat(i) * s * 0.07
        p.move(to: NSPoint(x: rect.minX - s * 0.1 + phase, y: y))
        p.curve(
            to: NSPoint(x: rect.maxX + s * 0.1 + phase, y: y),
            controlPoint1: NSPoint(x: s * 0.36 + phase, y: y + amp * 2.6),
            controlPoint2: NSPoint(x: s * 0.62 + phase, y: y - amp * 2.6))
        p.lineWidth = s * 0.052
        p.lineCapStyle = .round
        band.color.setStroke()
        p.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! draw(size).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size).png"))
    try! draw(size * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size)@2x.png"))
}
