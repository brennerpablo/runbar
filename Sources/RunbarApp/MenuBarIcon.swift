import AppKit

/// The Runbar mark, a `>_` prompt, on a 16 pt grid (y down): a chevron in five steps and the cursor.
/// The menu bar icon and the panel's mark both draw it from here.
enum RunbarMark {
    static let chevron: [CGRect] = [
        CGRect(x: 1, y: 1, width: 4, height: 2),
        CGRect(x: 3, y: 4, width: 4, height: 2),
        CGRect(x: 5, y: 7, width: 4, height: 2),
        CGRect(x: 3, y: 10, width: 4, height: 2),
        CGRect(x: 1, y: 13, width: 4, height: 2),
    ]
    static let cursor = CGRect(x: 8, y: 13, width: 7, height: 2)
    static let cells = chevron + [cursor]
}

/// Menu bar icon drawn as a template image (macOS paints it black or white).
enum MenuBarIcon {
    enum Badge { case none, alert, busy }

    private static var cache: [Badge: NSImage] = [:]

    static func image(_ badge: Badge) -> NSImage {
        if let cached = cache[badge] { return cached }
        let image = NSImage(size: NSSize(width: 19, height: 16), flipped: true) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            for cell in RunbarMark.cells {
                NSBezierPath(rect: cell.offsetBy(dx: 1, dy: 0)).fill()
            }
            guard badge != .none, let ctx = NSGraphicsContext.current else { return true }
            // Cut a hole in the corner (empty above the chevron) and draw the badge inside it.
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
