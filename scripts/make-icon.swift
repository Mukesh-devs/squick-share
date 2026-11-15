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

/// The mark: two curved arrows passing over and under each other, an oval "exchange" between two devices.
/// The top arrow travels left to right (send), the bottom one right to left (receive).
func addMark(to ctx: CGContext, size: CGFloat) {
    let cx = size / 2, cy = size / 2
    let halfWidth = size * 0.265     // half the width of the oval
    let bulge = size * 0.15          // how far each arc rises above / falls below the middle
    let gap = size * 0.06            // space between the two arrows
    let stroke = size * 0.078
    let radius = (halfWidth * halfWidth + bulge * bulge) / (2 * bulge)
    let half = asin(halfWidth / radius)

    // (circle centre, start angle, end angle); both arcs run clockwise (decreasing angle).
    let upper = (CGPoint(x: cx, y: cy + bulge + gap / 2 - radius), CGFloat.pi / 2 + half * 0.98, CGFloat.pi / 2 - half * 0.72)
    let lower = (CGPoint(x: cx, y: cy - bulge - gap / 2 + radius), -CGFloat.pi / 2 + half * 0.98, -CGFloat.pi / 2 - half * 0.72)

    for (center, start, end) in [upper, lower] {
        // Shaft.
        let shaft = CGMutablePath()
        shaft.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
        ctx.addPath(shaft)
        ctx.setLineWidth(stroke)
        ctx.setLineCap(.round)
        ctx.strokePath()

        // Arrowhead along the direction of travel at the end of the arc.
        let tip0 = CGPoint(x: center.x + radius * cos(end), y: center.y + radius * sin(end))
        let dir = CGVector(dx: sin(end), dy: -cos(end))            // clockwise tangent
        let normal = CGVector(dx: -dir.dy, dy: dir.dx)
        let length = size * 0.135, headHalf = size * 0.085
        let base = CGPoint(x: tip0.x - dir.dx * length * 0.25, y: tip0.y - dir.dy * length * 0.25)
        let head = CGMutablePath()
        head.move(to: CGPoint(x: base.x + dir.dx * length, y: base.y + dir.dy * length))
        head.addLine(to: CGPoint(x: base.x + normal.dx * headHalf, y: base.y + normal.dy * headHalf))
        head.addLine(to: CGPoint(x: base.x - normal.dx * headHalf, y: base.y - normal.dy * headHalf))
        head.closeSubpath()
        // Filled and stroked with round joins: a triangle with softly rounded corners.
        ctx.addPath(head)
        ctx.setLineWidth(size * 0.022)
        ctx.setLineJoin(.round)
        ctx.drawPath(using: .fillStroke)
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
    ctx.setFillColor(color(20, 74, 214))
    ctx.fillPath()
    ctx.restoreGState()

    // Tile: diagonal blue gradient, a soft light from the top left, and depth towards the bottom right.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(86, 156, 255), color(20, 74, 214)]),
                           start: CGPoint(x: tile.minX + tile.width * 0.15, y: tile.maxY),
                           end: CGPoint(x: tile.maxX - tile.width * 0.15, y: tile.minY), options: [])
    let light = CGPoint(x: size * 0.32, y: size * 0.78)
    ctx.drawRadialGradient(gradient([color(255, 255, 255, 0.24), color(255, 255, 255, 0)]),
                           startCenter: light, startRadius: 0, endCenter: light, endRadius: size * 0.5, options: [])
    let shade = CGPoint(x: size * 0.7, y: size * 0.05)
    ctx.drawRadialGradient(gradient([color(8, 30, 110, 0.35), color(8, 30, 110, 0)]),
                           startCenter: shade, startRadius: 0, endCenter: shade, endRadius: size * 0.55, options: [])
    ctx.restoreGState()

    // A thin light rim, brightest at the top.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.setLineWidth(max(1, size * 0.006))
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(255, 255, 255, 0.55), color(255, 255, 255, 0)]),
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
