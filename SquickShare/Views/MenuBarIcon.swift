import AppKit

/// What the menu bar icon shows.
struct MenuBarState: Equatable {
    enum Activity: Equatable {
        case idle(hidden: Bool)
        /// `progress` is 0...1, quantized so the icon only redraws on visible changes.
        case transferring(progress: Double, incoming: Bool, outgoing: Bool)
    }

    var activity: Activity
    /// A request is waiting for Accept/Decline.
    var needsAttention: Bool
}

/// Draws the menu bar icon as a template image, so it follows the menu bar's light/dark look
/// like the system icons: an antenna when idle, a progress ring with a direction arrow during
/// transfers, and a dot when a request needs an answer.
enum MenuBarIcon {
    static let size = NSSize(width: 20, height: 18)

    static func image(for state: MenuBarState) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            draw(state, in: rect)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func draw(_ state: MenuBarState, in rect: NSRect) {
        let ring = NSRect(x: rect.midX - 8, y: rect.midY - 8, width: 16, height: 16)
        switch state.activity {
        case .idle(let hidden):
            symbol(hidden ? "antenna.radiowaves.left.and.right.slash" : "antenna.radiowaves.left.and.right",
                   pointSize: 14, weight: .regular, in: ring)
        case .transferring(let progress, let incoming, let outgoing):
            let center = NSPoint(x: ring.midX, y: ring.midY)
            let radius = ring.width / 2 - 1.25
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = 2
            NSColor.black.withAlphaComponent(0.3).setStroke()
            track.stroke()
            if progress > 0 {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius, startAngle: 90,
                              endAngle: 90 - 360 * min(progress, 1), clockwise: true)
                arc.lineWidth = 2
                arc.lineCapStyle = .round
                NSColor.black.setStroke()
                arc.stroke()
            }
            let glyph = incoming && outgoing ? "arrow.up.arrow.down" : (incoming ? "arrow.down" : "arrow.up")
            symbol(glyph, pointSize: 8, weight: .bold, in: ring)
        }
        if state.needsAttention {
            let dot = NSRect(x: rect.maxX - 6.5, y: rect.maxY - 6.5, width: 6, height: 6)
            // Clear a thin gap around the dot so it reads as a badge on top of the icon.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
    }

    private static func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, in rect: NSRect) {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let size = image.size
        image.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                              width: size.width, height: size.height))
    }
}
