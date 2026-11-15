import AppKit

/// Menu bar icon drawn as a template image (macOS paints it black or white).
enum MenuBarIcon {
    enum Badge { case none, alert, busy }

    private static var cache: [Badge: NSImage] = [:]

    static func image(_ badge: Badge) -> NSImage {
        if let cached = cache[badge] { return cached }
        let image = NSImage(size: NSSize(width: 19, height: 16), flipped: true) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            for y in [2.2, 9.0] as [CGFloat] {
                let rect = NSBezierPath(roundedRect: NSRect(x: 2, y: y, width: 13, height: 4.8), xRadius: 1.6, yRadius: 1.6)
                rect.lineWidth = 1.4
                rect.stroke()
                NSBezierPath(ovalIn: NSRect(x: 4.1, y: y + 1.5, width: 1.8, height: 1.8)).fill()
            }
            guard badge != .none, let ctx = NSGraphicsContext.current else { return true }
            // Cut a hole in the corner and draw the badge inside it.
            ctx.compositingOperation = .clear
            NSBezierPath(ovalIn: NSRect(x: 11, y: -1, width: 9, height: 9)).fill()
            ctx.compositingOperation = .sourceOver
            switch badge {
            case .alert:
                NSBezierPath(ovalIn: NSRect(x: 12.6, y: 0.6, width: 5.8, height: 5.8)).fill()
            case .busy:
                let arc = NSBezierPath()
                arc.appendArc(withCenter: NSPoint(x: 15.5, y: 3.5), radius: 2.6, startAngle: 200, endAngle: 470)
                arc.lineWidth = 1.4
                arc.stroke()
            case .none:
                break
            }
            return true
        }
        image.isTemplate = true
        cache[badge] = image
        return image
    }
}
