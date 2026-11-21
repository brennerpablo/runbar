import AppKit
import RunbarCore
import SwiftUI

struct StatusDot: View {
    let dot: ServiceDisplay.Dot
    var size: CGFloat = Layout.dot
    /// Soft halo around filled dots (off for the small dots in the project header).
    var halo = true

    var body: some View {
        let ring = size >= 8 ? 1.5 : 1.25
        Group {
            switch dot {
            case .running: filled(Color.rbLiveFill)
            case .warning, .error: filled(Color.rbWarnFill)
            case .busy: SpinnerArc(color: .rbWarnFill, lineWidth: ring, track: true)
            case .stopped: Circle().strokeBorder(Color.rbRing, lineWidth: ring)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func filled(_ color: Color) -> some View {
        if halo {
            Circle().fill(color).background(Circle().fill(color.opacity(0.18)).padding(-3))
        } else {
            Circle().fill(color)
        }
    }
}

/// A ring with an arc going round: something is between states (starting, stopping). Under Reduce Motion
/// it stays still, a full ring.
struct SpinnerArc: View {
    var color: Color
    var lineWidth: CGFloat = 1.5
    /// A faint full ring under the arc, so the shape reads as the same dot it was.
    var track = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            Circle().strokeBorder(color, lineWidth: lineWidth)
        } else {
            TimelineView(.animation) { context in
                let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
                ZStack {
                    if track { Circle().strokeBorder(color.opacity(0.3), lineWidth: lineWidth) }
                    Circle()
                        .inset(by: lineWidth / 2)
                        .trim(from: 0, to: 0.62)
                        .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(turn * 360))
                }
            }
        }
    }
}

/// One small dot per service in the project header: state stays visible with the group collapsed.
struct Pips: View {
    let dots: [ServiceDisplay.Dot]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(dots.enumerated()), id: \.offset) { _, dot in
                StatusDot(dot: dot, size: 6, halo: false)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Section label: the same style for metrics, command, folder and output.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Color.rbText2)
            .lineLimit(1)
    }
}

/// Chevron for groups that expand and collapse.
struct DisclosureChevron: View {
    let open: Bool
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Color.rbText3)
            .frame(width: 11, height: 11)
            .rotationEffect(.degrees(open ? 90 : 0))
            .accessibilityHidden(true)
    }
}

/// Runbar mark: the `>_` prompt from the menu bar icon.
struct RunbarGlyph: View {
    var size: CGFloat = 16

    var body: some View {
        Canvas { context, canvas in
            let s = canvas.width / 16
            for cell in RunbarMark.cells {
                let rect = CGRect(x: cell.minX * s, y: cell.minY * s, width: cell.width * s, height: cell.height * s)
                context.fill(Path(rect), with: .foreground)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The official logo mark, as in docs/assets/logo-*.svg: the chevron in the text color, the cursor in green.
struct AppMark: View {
    var size: CGFloat = 12

    var body: some View {
        Canvas { context, canvas in
            let b = RunbarMark.Official.bounds
            let s = canvas.width / b.width
            func path(_ cells: [CGRect]) -> Path {
                Path { p in
                    for c in cells {
                        p.addRect(CGRect(x: (c.minX - b.minX) * s, y: (c.minY - b.minY) * s, width: c.width * s, height: c.height * s))
                    }
                }
            }
            context.fill(path(RunbarMark.Official.chevron), with: .color(.primary))
            context.fill(path([RunbarMark.Official.cursor]), with: .color(.rbLiveFill))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// ScrollView that grows up to `maxHeight` and only scrolls beyond it (the panel follows the content).
struct AdaptiveScroll<Content: View>: View {
    let maxHeight: CGFloat
    /// While true, the area only grows (filtering doesn't make the panel shrink and jump).
    var holdHeight = false
    @ViewBuilder var content: Content
    @ViewState private var height: CGFloat = 240

    var body: some View {
        ScrollView {
            content.background(
                GeometryReader { geo in
                    Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                }
            )
        }
        .scrollIndicators(.automatic)
        .frame(height: min(max(height, 40), maxHeight))
        .onPreferenceChange(ContentHeightKey.self) { measured in
            height = holdHeight ? max(height, measured) : measured
        }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Port in a pill, fixed width so it lines up in a column.
struct Pill: View {
    /// `live`: port open and clickable. `warn`: open, but not where expected. `idle`: nothing listening.
    enum Tone { case idle, live, warn }
    let text: String
    var tone: Tone = .idle
    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .frame(minWidth: Layout.pillWidth - 4, minHeight: 22)
            .padding(.horizontal, 2)
            .background(background, in: RoundedRectangle(cornerRadius: theme.pillRadius, style: .continuous))
    }

    private var foreground: Color {
        switch tone {
        case .idle: return .rbText3
        case .live: return .rbLive
        case .warn: return .rbWarn
        }
    }

    private var background: Color {
        switch tone {
        case .idle: return .rbControl
        case .live: return .rbLiveSoft
        case .warn: return .rbWarnSoft
        }
    }
}

struct Banner: View {
    enum Tone { case warning, info }
    let text: String
    var tone: Tone = .warning
    var actionLabel: String?
    var action: (() -> Void)?
    var secondaryLabel: String?
    var secondary: (() -> Void)?
    @Environment(\.theme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 9) {
            Text(text)
                .font(.system(size: 12))
                .lineSpacing(2)
                .foregroundStyle(tone == .warning ? Color.rbWarn : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
            if actionLabel != nil || secondaryLabel != nil {
                HStack(spacing: 6) {
                    if let actionLabel, let action {
                        Button(actionLabel, action: action).rbButton(theme).controlSize(.small)
                    }
                    if let secondaryLabel, let secondary {
                        Button(secondaryLabel, action: secondary).rbButton(theme).controlSize(.small)
                    }
                }
            }
        }
        .padding(.horizontal, Layout.rowInset)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone == .warning ? Color.rbWarnSoft : Color.rbCardFill, in: shape)
        .overlay(shape.strokeBorder(tone == .warning ? Color.rbWarnBorder : Color.rbCardBorder))
    }
}

// MARK: - Summary tiles

/// Top tile: label, large number and something on the right (a total or mini bars).
struct StatTile<Trailing: View>: View {
    let label: String
    let value: String
    var unit: String?
    /// Green text after the unit ("+1 proxy").
    var accent: String?
    /// Lighter step: the tile whose view is showing.
    var raised = false
    var live = false
    /// Small text at the right of the label ("6% CPU", "28 GB free").
    var note: String?
    var noteColor: Color = .rbText3
    @ViewBuilder var trailing: Trailing
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                // The label never truncates; the note gives way first.
                Text(label)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.rbText2)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 0)
                if let note {
                    Text(note)
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(noteColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                if live { StatusDot(dot: .running, size: 7).padding(.trailing, 3) }
            }
            Spacer(minLength: 0)
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 20, weight: .semibold))
                    .monospacedDigit()
                    .tracking(-0.5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .layoutPriority(1)
                if let unit {
                    // The unit never wraps: if space runs out, the number shrinks.
                    Text(unit)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.rbText2)
                        .lineLimit(1)
                        .fixedSize()
                }
                if let accent {
                    Text(accent)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.rbLive)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.leading, 3)
                }
                Spacer(minLength: 4)
                trailing
            }
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 7, trailing: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Layout.tileHeight)
        .rbCard(theme, raised: raised)
        .accessibilityElement(children: .combine)
    }
}

/// History as mini bars; the last one (now) uses the app color.
struct MiniBars: View {
    let values: [Double]
    var floorAtZero = true
    var height: CGFloat = 16

    var body: some View {
        let scale = Metrics.scale(values, floorAtZero: floorAtZero)
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                Capsule()
                    .fill(index == values.count - 1 ? Color.rbLiveFill : Color.rbBar)
                    .frame(width: 3, height: max(2, height * scale.fraction(value)))
            }
        }
        .frame(height: height, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

enum Metrics {
    struct Bucket: Equatable {
        let date: Date
        let value: Double
    }

    struct Scale {
        let low: Double
        let high: Double

        func fraction(_ value: Double) -> CGFloat {
            guard high > low else { return 0 }
            return CGFloat(min(max((value - low) / (high - low), 0), 1))
        }
    }

    /// Groups the points into up to `count` buckets (each one's average), oldest to newest.
    static func buckets(_ points: [MetricPoint], count: Int) -> [Bucket] {
        guard count > 0, !points.isEmpty else { return [] }
        guard points.count > count else { return points.map { Bucket(date: $0.date, value: $0.value) } }
        let size = Int((Double(points.count) / Double(count)).rounded(.up))
        var out: [Bucket] = []
        // Group from the end: the last bucket is always the most recent and complete.
        var end = points.count
        while end > 0 {
            let start = max(0, end - size)
            let slice = points[start..<end]
            out.append(Bucket(date: slice[slice.endIndex - 1].date, value: slice.reduce(0) { $0 + $1.value } / Double(slice.count)))
            end = start
        }
        return out.reversed()
    }

    /// Vertical range of the chart. Memory doesn't start at zero, so changes show.
    static func scale(_ values: [Double], floorAtZero: Bool) -> Scale {
        let lo = floorAtZero ? 0 : (values.min() ?? 0)
        let hi = values.max() ?? 1
        let span = max(hi - lo, floorAtZero ? 5 : hi * 0.05 + 1)
        return Scale(low: floorAtZero ? 0 : lo - span * 0.5, high: lo + span * 1.15)
    }
}

// MARK: - Button styles (with hover; the state lives in an inner view)

/// Text button: solid green for the primary action, a neutral tint otherwise.
struct RBButtonStyle: ButtonStyle {
    var prominent = false
    /// Amber fill, for actions that can't be undone.
    var warn = false

    func makeBody(configuration: Configuration) -> some View {
        RBButtonBody(configuration: configuration, prominent: prominent, warn: warn)
    }
}

private struct RBButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    var warn = false
    @Environment(\.theme) private var theme
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled
    @ViewState private var hover = false

    var body: some View {
        let small = controlSize == .small || controlSize == .mini
        let shape = RoundedRectangle(cornerRadius: small ? 8 : theme.buttonRadius, style: .continuous)
        configuration.label
            .font(.system(size: small ? 11.5 : 12.5, weight: prominent ? .semibold : .medium))
            .foregroundStyle(prominent ? (warn ? Color.rbOnWarn : Color.rbOnPrimary) : Color.primary)
            .lineLimit(1)
            .padding(.horizontal, small ? 10 : 13)
            .frame(height: small ? 26 : 32)
            .background {
                if prominent {
                    shape.fill(warn ? Color.rbWarnFill : Color.rbPrimary)
                    shape.fill(Color.white.opacity(hover && !configuration.isPressed ? 0.16 : 0))
                    shape.fill(Color.black.opacity(configuration.isPressed ? 0.10 : 0))
                } else {
                    shape.fill(hover || configuration.isPressed ? Color.rbControlHover : Color.rbControl)
                    if !small { shape.strokeBorder(Color.rbCardBorder, lineWidth: 1) }
                }
            }
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(shape)
            .onHover { hover = $0 }
    }
}

/// Round row action button (stop, start, try again), always the same size.
struct RowActionButtonStyle: ButtonStyle {
    enum Tone { case neutral, live, warn }
    var tone: Tone = .neutral
    var size: CGFloat = Layout.control

    func makeBody(configuration: Configuration) -> some View {
        RowActionBody(configuration: configuration, tone: tone, size: size)
    }
}

private struct RowActionBody: View {
    let configuration: ButtonStyleConfiguration
    let tone: RowActionButtonStyle.Tone
    let size: CGFloat
    @ViewState private var hover = false

    var body: some View {
        let active = hover || configuration.isPressed
        configuration.label
            .font(.system(size: size < Layout.control ? 8.5 : 9.5, weight: .bold))
            .foregroundStyle(foreground)
            .frame(width: size, height: size)
            .background {
                switch tone {
                case .neutral:
                    Circle().fill(active ? Color.rbControlHover : Color.rbControl)
                case .live:
                    Circle().fill(Color.rbLiveSoft)
                    Circle().fill(Color.rbLiveFill.opacity(active ? 0.14 : 0))
                case .warn:
                    Circle().fill(Color.rbWarnSoft)
                    Circle().fill(Color.rbWarnFill.opacity(active ? 0.14 : 0))
                }
            }
            .contentShape(Circle())
            .onHover { hover = $0 }
    }

    private var foreground: Color {
        switch tone {
        case .neutral: return .primary
        case .live: return .rbLive
        case .warn: return .rbWarn
        }
    }
}

/// Header icon (refresh, add, more): no border, highlight on hover.
struct IconButtonStyle: ButtonStyle {
    /// A toggle that is on: tinted in the app's color.
    var on = false

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, on: on)
    }
}

private struct IconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let on: Bool
    @Environment(\.theme) private var theme
    @ViewState private var hover = false

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(on ? Color.rbLive : Color.rbText2)
            .frame(width: Layout.control, height: Layout.control)
            .background(
                configuration.isPressed ? Color.rbControlHover : (on ? Color.rbLiveSoft : (hover ? Color.rbControl : Color.clear)),
                in: RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
            )
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}

/// A toggle inside a tinted strip (coffee mode's No lock): an icon and a short label. The strip already
/// wears the app's color, so on is a deeper tint of it and off is the label alone, a step fainter.
struct StripToggleStyle: ButtonStyle {
    var on: Bool

    func makeBody(configuration: Configuration) -> some View {
        StripToggleBody(configuration: configuration, on: on)
    }
}

private struct StripToggleBody: View {
    let configuration: ButtonStyleConfiguration
    let on: Bool
    @Environment(\.theme) private var theme
    @ViewState private var hover = false

    var body: some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Color.rbLive.opacity(on || hover ? 1 : 0.75))
            .padding(.horizontal, 7)
            .frame(minWidth: 26, minHeight: 26)
            .background(
                Color.rbLive.opacity(configuration.isPressed ? 0.26 : (on ? 0.18 : (hover ? 0.1 : 0))),
                in: RoundedRectangle(cornerRadius: theme.pillRadius, style: .continuous)
            )
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}

/// Clickable text for low-key actions (start all, open full log, back).
struct TextButtonStyle: ButtonStyle {
    var accent = false
    var size: CGFloat = 12.5

    func makeBody(configuration: Configuration) -> some View {
        TextButtonBody(configuration: configuration, accent: accent, size: size)
    }
}

private struct TextButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let accent: Bool
    let size: CGFloat
    @Environment(\.theme) private var theme
    @ViewState private var hover = false

    var body: some View {
        configuration.label
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(accent ? Color.rbLive : Color.rbText2)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                configuration.isPressed ? Color.rbControlHover : (hover ? Color.rbControl : Color.clear),
                in: RoundedRectangle(cornerRadius: theme.pillRadius, style: .continuous)
            )
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}

/// All / Running / Stopped filter, with how many rows each one shows.
struct SegmentedFilter: View {
    @Binding var selection: StatusFilter
    var counts: [StatusFilter: Int] = [:]
    @Environment(\.theme) private var theme

    private let options: [(StatusFilter, String)] = [(.all, "All"), (.running, "Running"), (.stopped, "Stopped")]

    var body: some View {
        let outer = RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
        let inner = RoundedRectangle(cornerRadius: theme.controlRadius - 2, style: .continuous)
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { option, label in
                let on = selection == option
                Button { selection = option } label: {
                    HStack(spacing: 5) {
                        Text(label)
                            .font(.system(size: 11.5, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? Color.primary : Color.rbText2)
                        if let n = counts[option] {
                            Text("\(n)")
                                .font(.system(size: 11.5))
                                .monospacedDigit()
                                .foregroundStyle(Color.rbText3)
                        }
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .background {
                        if on {
                            inner.fill(Color.rbSegmentOn)
                                .shadow(color: .black.opacity(0.14), radius: 0.5, y: 0.5)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(counts[option].map { "\(label), \($0)" } ?? label)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .frame(height: 26)
        .background(Color.rbControl, in: outer)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filter by status")
    }
}

enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
