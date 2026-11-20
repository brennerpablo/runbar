import AppKit
import RunbarCore
import SwiftUI

/// The app's two looks. Same layout and colors; only the panel background changes (opaque or glass).
struct Theme: Equatable {
    var glass: Bool

    static func resolve(_ setting: LookSetting) -> Theme {
        switch setting {
        case .solid: return Theme(glass: false)
        case .glass: return Theme(glass: true)
        case .auto:
            if #available(macOS 26, *) { return Theme(glass: true) }
            return Theme(glass: false)
        }
    }

    /// The panel's single side margin: header, tiles, cards and search all align to it.
    var gutter: CGFloat { 14 }
    var cardRadius: CGFloat { 14 }
    var controlRadius: CGFloat { 9 }
    var buttonRadius: CGFloat { 10 }
    var pillRadius: CGFloat { 8 }
    var logRadius: CGFloat { 12 }
}

/// Fixed sizes, so rows, buttons and pills line up in every state.
enum Layout {
    static let width: CGFloat = 400
    static let panelRadius: CGFloat = 22
    static let rowHeight: CGFloat = 46
    /// Service rows in a project card: one line, two when something needs saying.
    static let compactRow: CGFloat = 36
    static let rowInset: CGFloat = 12
    /// The tile beside a service's name that says what it runs.
    static let icon: CGFloat = 20
    static let rowAction: CGFloat = 24
    static let dot: CGFloat = 8
    static let dotGap: CGFloat = 10
    static let control: CGFloat = 28
    static let pillWidth: CGFloat = 52
    static let metricsWidth: CGFloat = 56
    static let sectionSpacing: CGFloat = 14
    static let tileHeight: CGFloat = 60
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme(glass: false)
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

extension Color {
    /// Color that differs between light and dark mode.
    static func rb(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    private static func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: alpha
        )
    }

    private static func white(_ alpha: CGFloat) -> NSColor { NSColor(white: 1, alpha: alpha) }
    private static func ink(_ alpha: CGFloat) -> NSColor { hex(0x0D141E, alpha) }

    // Text: secondary and muted both pass contrast on the panel and on cards.
    static let rbText2 = rb(light: hex(0x454D59), dark: hex(0xB4BBC7))
    static let rbText3 = rb(light: hex(0x555D6A), dark: hex(0xA0A8B5))
    /// Stopped service name: one step below primary text.
    static let rbTextDim = rb(light: hex(0x2F3742), dark: hex(0xD5DAE2))

    // "Live": the app's color. Text and icons use `rbLive`; dots and bars use `rbLiveFill`.
    static let rbLive = rb(light: hex(0x086B3C), dark: hex(0x4ADE9A))
    static let rbLiveFill = rb(light: hex(0x17A865), dark: hex(0x4ADE9A))
    static let rbLiveSoft = rb(light: hex(0x17A865, 0.13), dark: hex(0x4ADE9A, 0.14))
    /// Primary button: green fill with dark text in both modes.
    static let rbPrimary = rb(light: hex(0x3DD68C), dark: hex(0x4ADE9A))
    static let rbOnPrimary = Color(nsColor: hex(0x06281A))

    // Attention: an orange that passes text contrast in both modes.
    static let rbWarn = rb(light: hex(0xA84205), dark: hex(0xFFB55C))
    static let rbWarnFill = rb(light: hex(0xF2901F), dark: hex(0xFFB55C))
    static let rbWarnSoft = rb(light: hex(0xFF9500, 0.14), dark: hex(0xFFB55C, 0.13))
    static let rbWarnBorder = rb(light: hex(0xD67800, 0.30), dark: hex(0xFFB55C, 0.27))

    // Surfaces on top of the panel.
    static let rbCardFill = rb(light: white(0.64), dark: white(0.055))
    static let rbCardRaised = rb(light: white(0.90), dark: white(0.10))
    static let rbCardBorder = rb(light: ink(0.07), dark: white(0.07))
    static let rbHairline = rb(light: ink(0.07), dark: white(0.06))
    static let rbControl = rb(light: ink(0.07), dark: white(0.08))
    static let rbControlHover = rb(light: ink(0.12), dark: white(0.15))
    static let rbSegmentOn = rb(light: white(1), dark: white(0.15))
    static let rbRing = rb(light: ink(0.40), dark: white(0.42))
    static let rbBar = rb(light: ink(0.20), dark: white(0.26))
    // Disk bars: dependencies and tool caches, two steps lighter than build output (green).
    static let rbDepsBar = rb(light: ink(0.38), dark: white(0.42))
    static let rbToolsBar = rb(light: ink(0.18), dark: white(0.20))
    static let rbOnWarn = Color(nsColor: hex(0x3A2003))
    static let rbSearchField = rb(light: white(0.95), dark: hex(0x323944, 0.94))

    // Panel: opaque when solid; for glass, an 84% tint of the same color over the blur of what's behind.
    static let rbPanelSolid = rb(light: hex(0xF1F3F6), dark: hex(0x1A1F27))
    static let rbPanelTint = rb(light: hex(0xF0F3F7), dark: hex(0x151A22))
    static let rbPanelBorder = rb(light: white(0.75), dark: white(0.13))
    /// 1 px highlight along the top edge.
    static let rbPanelHighlight = rb(light: white(0.85), dark: white(0.09))

    static let rbLogBackground = Color(nsColor: hex(0x0B0E13))

    // Used by the agent window.
    static let rbGreen = Color(nsColor: .systemGreen)
    static let rbOrange = Color(nsColor: .systemOrange)
}

extension View {
    /// Card that groups rows (project, metrics, command). `raised` is the lighter step.
    func rbCard(_ t: Theme, radius: CGFloat? = nil, raised: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius ?? t.cardRadius, style: .continuous)
        return self
            .background(raised ? Color.rbCardRaised : Color.rbCardFill, in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.rbCardBorder, lineWidth: 1))
    }

    /// Text buttons. Size comes from `controlSize` (.small or .regular).
    func rbButton(_ t: Theme, prominent: Bool = false) -> some View {
        buttonStyle(RBButtonStyle(prominent: prominent))
    }

    /// The whole panel: 22 pt corners, background (glass or solid), light border and top highlight.
    func rbPanel(_ t: Theme) -> some View {
        let shape = RoundedRectangle(cornerRadius: Layout.panelRadius, style: .circular)
        return self
            .background { PanelBackground(glass: t.glass) }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(Color.rbPanelBorder, lineWidth: 1)
                shape.inset(by: 1)
                    .stroke(LinearGradient(colors: [.rbPanelHighlight, .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.05)), lineWidth: 1)
            }
    }
}

private struct PanelBackground: View {
    let glass: Bool

    var body: some View {
        if glass {
            ZStack {
                BehindWindowBlur(radius: Layout.panelRadius)
                Color.rbPanelTint.opacity(0.84)
            }
        } else {
            Color.rbPanelSolid
        }
    }
}

/// Blur of what's behind the window. The shape comes from `maskImage`: the blur is done by the
/// system and ignores the view's `clipShape`.
private struct BehindWindowBlur: NSViewRepresentable {
    let radius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.maskImage = Self.mask(radius: radius)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}

    private static func mask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

