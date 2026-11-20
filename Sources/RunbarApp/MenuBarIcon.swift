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

    /// The official mark (docs/assets/logo-*.svg) on its 48-unit grid: a chevron of seven 12×4 bars
    /// stepping 6 units, and the cursor, drawn in the app's green. It spans x and y 4–44. The menu bar
    /// keeps the coarser grid above, which stays sharp at 16 pt.
    enum Official {
        static let chevron: [CGRect] = [4, 10, 16, 22, 16, 10, 4].enumerated().map { i, x in
            CGRect(x: x, y: 4 + CGFloat(i) * 6, width: 12, height: 4)
        }
        static let cursor = CGRect(x: 28, y: 40, width: 16, height: 4)
        static let bounds = CGRect(x: 4, y: 4, width: 40, height: 40)
    }
}

/// Menu bar icon drawn as a template image (macOS paints it black or white). In coffee mode it's the
/// app's green instead, a shade for a light menu bar and one for a dark one.
enum MenuBarIcon {
    enum Badge { case none, alert, busy }

    private struct Key: Hashable { let badge: Badge; let awake: Bool }
    private static var cache: [Key: NSImage] = [:]

    static func image(_ badge: Badge, awake: Bool = false) -> NSImage {
        let key = Key(badge: badge, awake: awake)
        if let cached = cache[key] { return cached }
        // Drawn when shown, in the menu bar's appearance, so the dynamic green picks the right shade.
        let image = NSImage(size: NSSize(width: 19, height: 16), flipped: true) { _ in
            let color = awake ? Self.coffee : NSColor.black
            color.setStroke()
            color.setFill()
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
        image.isTemplate = !awake
        cache[key] = image
        return image
    }

    /// `rbLiveFill`: the dots' green, light and dark.
    private static let coffee = NSColor(name: "RunbarCoffee") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x4A / 255, green: 0xDE / 255, blue: 0x9A / 255, alpha: 1)
            : NSColor(srgbRed: 0x17 / 255, green: 0xA8 / 255, blue: 0x65 / 255, alpha: 1)
    }
}
