// Draws the squick-share app icon and writes every size the AppIcon set needs.
// Usage: swift scripts/make-icon.swift SquickShare/Assets.xcassets/AppIcon.appiconset
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

func drawIcon(pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: the rounded square fills ~80% of the canvas.
    let inset = size * 0.1
    let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.01)
    shadow.shadowBlurRadius = size * 0.02
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSGradient(colors: [NSColor(srgbRed: 0.10, green: 0.42, blue: 0.95, alpha: 1),
                        NSColor(srgbRed: 0.10, green: 0.78, blue: 0.80, alpha: 1)])!
        .draw(in: path, angle: -60)
    NSGraphicsContext.restoreGraphicsState()

    // Two arcs ("radio waves") around a centre dot, in white.
    NSColor.white.setStroke()
    NSColor.white.setFill()
    let center = NSPoint(x: size / 2, y: size / 2)
    let dot = size * 0.075
    NSBezierPath(ovalIn: NSRect(x: center.x - dot, y: center.y - dot, width: dot * 2, height: dot * 2)).fill()
    for (radius, width) in [(size * 0.17, size * 0.045), (size * 0.27, size * 0.045)] {
        for start in [135.0, -45.0] {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: start - 45 + 90, endAngle: start + 45 + 90)
            arc.lineWidth = width
            arc.lineCapStyle = .round
            arc.stroke()
        }
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try drawIcon(pixels: base * scale).write(to: output.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(base)x\(base)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: output.appendingPathComponent("Contents.json"))
print("wrote \(images.count) icons to \(output.path)")
