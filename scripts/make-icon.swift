// Draws the squick-share app icon and writes every size the AppIcon set needs.
// Usage: swift scripts/make-icon.swift SquickShare/Assets.xcassets/AppIcon.appiconset
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
}

/// The mark: an "S" of two arcs with ball ends, whose middle bar is split into two arrows meeting
/// in the centre (→ ←): two devices sharing with each other.
func addMark(to ctx: CGContext, size: CGFloat) {
    let center = CGPoint(x: size / 2, y: size / 2)
    let radius = size * 0.255        // the S is drawn on one circle
    let stroke = size * 0.066        // line thickness
    let gap = size * 0.05            // half the space between the two arrow tips
    let armWidth = stroke * 0.55     // arrowhead arms, thinner than the line so the tips stay sharp
    let armLength = size * 0.078
    let spread = 40 * CGFloat.pi / 180
    let topEnd = 48 * CGFloat.pi / 180, bottomEnd = -132 * CGFloat.pi / 180
    func point(_ angle: CGFloat) -> CGPoint {
        CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
    }

    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    // Upper bowl: from the upper-right end over the top and down the left side; then the bar → .
    let upper = CGMutablePath()
    upper.addArc(center: center, radius: radius, startAngle: topEnd, endAngle: .pi, clockwise: false)
    upper.addLine(to: CGPoint(x: center.x - gap - armWidth * 0.6, y: center.y))
    // Lower bowl: the bar ← from the right side, then down and around the bottom to the lower-left end.
    let lower = CGMutablePath()
    lower.move(to: CGPoint(x: center.x + gap + armWidth * 0.6, y: center.y))
    lower.addLine(to: point(0))
    lower.addArc(center: center, radius: radius, startAngle: 0, endAngle: bottomEnd, clockwise: true)
    for path in [upper, lower] {
        ctx.addPath(path)
        ctx.setLineWidth(stroke)
        ctx.strokePath()
    }

    // Arrowheads: open chevrons meeting in the middle.
    let arrows = CGMutablePath()
    for (tip, direction) in [(CGPoint(x: center.x - gap, y: center.y), CGFloat(1)),
                             (CGPoint(x: center.x + gap, y: center.y), CGFloat(-1))] {
        for side in [CGFloat(1), -1] {
            arrows.move(to: tip)
            arrows.addLine(to: CGPoint(x: tip.x - direction * armLength * cos(spread), y: tip.y + side * armLength * sin(spread)))
        }
    }
    ctx.addPath(arrows)
    ctx.setLineWidth(armWidth)
    ctx.strokePath()

    // Ball ends on the two open ends of the S.
    let ball = stroke * 0.82
    for angle in [topEnd, bottomEnd] {
        let p = point(angle)
        ctx.fillEllipse(in: CGRect(x: p.x - ball, y: p.y - ball, width: ball * 2, height: ball * 2))
    }
}

func drawIcon(pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: the rounded square fills ~80% of the canvas.
    let inset = size * 0.1
    let tile = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let corner = tile.width * 0.225
    let tilePath = CGPath(roundedRect: tile, cornerWidth: corner, cornerHeight: corner, transform: nil)

    // Shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.04, color: color(0, 0, 0, 0.38))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0, 82, 224))
    ctx.fillPath()
    ctx.restoreGState()

    // Tile: a rich, saturated blue running from sky blue at the top to deep blue at the bottom, like
    // Apple's own blue icons, with just a hint of light at the top and depth at the bottom.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(28, 160, 255), color(0, 82, 224)]),
                           start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
    let light = CGPoint(x: size * 0.5, y: size * 0.88)
    ctx.drawRadialGradient(gradient([color(255, 255, 255, 0.10), color(255, 255, 255, 0)]),
                           startCenter: light, startRadius: 0, endCenter: light, endRadius: size * 0.55, options: [])
    let shade = CGPoint(x: size * 0.5, y: size * 0.02)
    ctx.drawRadialGradient(gradient([color(0, 20, 120, 0.12), color(0, 20, 120, 0)]),
                           startCenter: shade, startRadius: 0, endCenter: shade, endRadius: size * 0.55, options: [])
    ctx.restoreGState()

    // A thin light rim, brightest at the top.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.setLineWidth(max(1, size * 0.006))
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(255, 255, 255, 0.45), color(255, 255, 255, 0)]),
                           start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.midY), options: [])
    ctx.restoreGState()

    // The white mark, lifted off the tile by one soft shadow (a transparency layer, so overlapping
    // parts don't darken the shadow).
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.016), blur: size * 0.035, color: color(6, 32, 120, 0.5))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.setStrokeColor(color(248, 251, 255))
    ctx.setFillColor(color(248, 251, 255))
    addMark(to: ctx, size: size)
    ctx.endTransparencyLayer()
    ctx.restoreGState()

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
