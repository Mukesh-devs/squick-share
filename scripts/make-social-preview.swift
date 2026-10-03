// Draws the 1200×630 social preview image (link previews in WhatsApp, Slack, X, LinkedIn…)
// from the app icon and the UI screenshots in docs/images/.
// Usage: swift scripts/make-social-preview.swift   (run from the repository root)
import AppKit

let images = URL(fileURLWithPath: "docs/images")
let output = images.appendingPathComponent("social-preview.png")
let width = 1200, height = 630

func load(_ name: String) -> NSImage {
    guard let image = NSImage(contentsOf: images.appendingPathComponent(name)) else {
        fatalError("missing docs/images/\(name); run scripts/make-screenshots.sh first")
    }
    return image
}

/// Draws `image` scaled to `targetWidth`, with rounded corners, a soft shadow and a hairline border.
func drawScreenshot(_ image: NSImage, origin: NSPoint, targetWidth: CGFloat, maxHeight: CGFloat) {
    let pixels = image.representations.first.map { NSSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? image.size
    let scale = targetWidth / pixels.width
    let fullHeight = pixels.height * scale
    let shownHeight = min(fullHeight, maxHeight)
    let rect = NSRect(x: origin.x, y: origin.y, width: targetWidth, height: shownHeight)
    let path = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 30
    shadow.set()
    NSColor.white.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    // Show the top part of the screenshot if it's taller than the space.
    let source = NSRect(x: 0, y: pixels.height - shownHeight / scale, width: pixels.width, height: shownHeight / scale)
    image.draw(in: rect, from: source.applying(scaleToImagePoints(image, pixels)), operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    NSColor.white.withAlphaComponent(0.25).setStroke()
    path.lineWidth = 1
    path.stroke()
}

/// Converts a rect in pixel units to the image's point units.
func scaleToImagePoints(_ image: NSImage, _ pixels: NSSize) -> CGAffineTransform {
    CGAffineTransform(scaleX: image.size.width / pixels.width, y: image.size.height / pixels.height)
}

func drawText(_ text: String, at point: NSPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor, kern: CGFloat = 0) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .kern: kern,
    ]
    NSAttributedString(string: text, attributes: attributes).draw(at: point)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: width, height: height)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
let canvas = NSRect(x: 0, y: 0, width: width, height: height)

// Background: deep blue to teal, matching the app icon, with a soft glow behind the screenshots.
NSGradient(colors: [NSColor(srgbRed: 0.04, green: 0.13, blue: 0.33, alpha: 1),
                    NSColor(srgbRed: 0.05, green: 0.36, blue: 0.62, alpha: 1),
                    NSColor(srgbRed: 0.06, green: 0.55, blue: 0.58, alpha: 1)])!
    .draw(in: canvas, angle: -25)
NSGradient(colors: [NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0)])!
    .draw(in: NSBezierPath(ovalIn: NSRect(x: 640, y: 40, width: 560, height: 560)), relativeCenterPosition: .zero)

// Left: icon, name, tagline, highlights.
load("app-icon.png").draw(in: NSRect(x: 72, y: 418, width: 128, height: 128))
drawText("squick-share", at: NSPoint(x: 70, y: 318), size: 72, weight: .bold, color: .white, kern: -1.5)
drawText("Quick Share for your Mac", at: NSPoint(x: 72, y: 266), size: 34, weight: .medium,
         color: NSColor.white.withAlphaComponent(0.92))
let highlights = ["Send files between Mac and Android", "Straight over Wi-Fi, ~35–40 MB/s", "No cable · No cloud · No account"]
for (index, line) in highlights.enumerated() {
    let y = CGFloat(206 - index * 40)
    NSColor(srgbRed: 0.35, green: 0.95, blue: 0.85, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 74, y: y + 9, width: 10, height: 10)).fill()
    drawText(line, at: NSPoint(x: 96, y: y), size: 24, weight: .regular, color: NSColor.white.withAlphaComponent(0.88))
}
drawText("Free & open source  ·  macOS 13+  ·  Apple Silicon & Intel", at: NSPoint(x: 72, y: 50), size: 18,
         weight: .medium, color: NSColor.white.withAlphaComponent(0.65))

// Right: two real screenshots, overlapping.
drawScreenshot(load("popover-idle-light.png"), origin: NSPoint(x: 700, y: 150), targetWidth: 300, maxHeight: 420)
drawScreenshot(load("request-dark.png"), origin: NSPoint(x: 850, y: 40), targetWidth: 310, maxHeight: 400)

NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: output)
print("wrote \(output.path) (\(width)×\(height))")
