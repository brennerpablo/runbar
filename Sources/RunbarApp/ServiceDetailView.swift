import AppKit
import RunbarCore
import SwiftUI

struct ServiceDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let runtime: ServiceRuntime
    let onBack: () -> Void
    @ViewState private var copied = false

    var body: some View {
        let d = model.display(runtime)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Button(action: onBack) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text("Services")
                    }
                }
                .buttonStyle(TextButtonStyle(size: 13))
                .keyboardShortcut(.cancelAction)
                Spacer(minLength: 8)
                statusChip(d)
            }
            .padding(.leading, 6)
            .padding(.trailing, theme.gutter)
            .padding(.top, 12)

            AdaptiveScroll(maxHeight: 700) {
                VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                    header(d)
                    if let banner = d.banner {
                        Banner(text: banner, actionLabel: d.fixLabel, action: d.fix.map { fix in { model.perform(fix, for: runtime) } })
                    } else if let info = d.info {
                        Banner(text: info, tone: .info, actionLabel: d.fixLabel, action: d.fix.map { fix in { model.perform(fix, for: runtime) } })
                    }
                    if let note = d.note {
                        Banner(text: note, actionLabel: "Restart now", action: { runtime.restart() })
                    }
                    actions(d)
                    if d.isAlive || d.isExternal { facts(d) }
                    if d.isAlive { charts }
                    command
                    folder
                    logs
                }
                .padding(.horizontal, theme.gutter)
                .padding(.top, 10)
                .padding(.bottom, theme.gutter)
            }
        }
    }

    // MARK: - Header and actions

    private func header(_ d: ServiceDisplay) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(runtime.id)
                .font(.system(size: 19, weight: .semibold))
                .tracking(-0.2)
                .lineLimit(1)
            Text("\(runtime.config.projectName) · \(runtime.config.type.label)")
                .font(.system(size: 12))
                .foregroundStyle(Color.rbText2)
        }
    }

    private func statusChip(_ d: ServiceDisplay) -> some View {
        HStack(spacing: 6) {
            StatusDot(dot: d.dot, size: 6, halo: false)
            Text(d.statusLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(chipForeground(d))
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .frame(height: 22)
        .background(chipBackground(d), in: Capsule())
    }

    private func chipForeground(_ d: ServiceDisplay) -> Color {
        switch d.dot {
        case .running: return .rbLive
        case .warning, .error, .busy: return .rbWarn
        case .stopped: return .rbText2
        }
    }

    private func chipBackground(_ d: ServiceDisplay) -> Color {
        switch d.dot {
        case .running: return .rbLiveSoft
        case .warning, .error, .busy: return .rbWarnSoft
        case .stopped: return .rbControl
        }
    }

    private func actions(_ d: ServiceDisplay) -> some View {
        HStack(spacing: 8) {
            if let url = d.url, d.isAlive || d.isExternal {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    HStack(spacing: 6) {
                        Text("Open \(url.host ?? "localhost")\(url.port.map { ":\($0)" } ?? "")")
                        Image(systemName: "arrow.up.right").font(.system(size: 9.5, weight: .bold))
                    }
                }
                .rbButton(theme, prominent: true)
            }
            if d.isExternal {
                Button("Stop") { runtime.stopExternal() }.rbButton(theme)
            } else if d.isAlive {
                Button("Restart") { runtime.restart() }.rbButton(theme)
                Button("Stop") { runtime.stop() }.rbButton(theme).disabled(runtime.phase == .stopping)
            } else {
                Button {
                    runtime.start()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: d.action == .retry ? "arrow.clockwise" : "play.fill").font(.system(size: 9.5, weight: .bold))
                        Text(d.action == .retry ? "Try again" : "Start")
                    }
                }
                .rbButton(theme, prominent: true)
            }
        }
        .controlSize(.regular)
    }

    // MARK: - Numbers

    /// Six numbers in one card, three per row.
    private func facts(_ d: ServiceDisplay) -> some View {
        let ext = runtime.external
        let started = d.isExternal ? ext?.startedAt : runtime.startedAt
        let pid = runtime.pid ?? ext?.rootPID
        let since = started.map { Format.clock($0, now: model.now) } ?? "—"
        let uptime = started.map { Format.duration(model.now.timeIntervalSince($0)) } ?? "—"
        let items: [(String, String)]
        if d.isExternal {
            // No history or log: memory and CPU go here instead.
            items = [
                ("Port", d.portLabel ?? "—"), ("PID", pid.map(String.init) ?? "—"), ("Memory", d.memory.map { Format.memory($0) } ?? "—"),
                ("CPU", d.cpu.map { Format.cpu($0) } ?? "—"), ("Since", since), ("Uptime", uptime),
            ]
        } else {
            items = [
                ("Port", d.portLabel ?? "—"), ("PID", pid.map(String.init) ?? "—"), ("Processes", "\(runtime.processCount)"),
                ("Since", since), ("Uptime", uptime),
                ("Last log", runtime.lastLogAt.map { Format.ago($0, now: model.now) } ?? "—"),
            ]
        }
        let rows = [Array(items.prefix(3)), Array(items.dropFirst(3))]
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                if rowIndex > 0 { Rectangle().fill(Color.rbHairline).frame(height: 1) }
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { columnIndex, item in
                        if columnIndex > 0 { Rectangle().fill(Color.rbHairline).frame(width: 1) }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.0)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.rbText2)
                                .lineLimit(1)
                            Text(item.1)
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Layout.rowInset)
                        .padding(.top, 9)
                        .padding(.bottom, 10)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .rbCard(theme)
    }

    @ViewBuilder
    private var charts: some View {
        if runtime.memHistory.count >= 2 {
            HStack(spacing: 8) {
                BarHistory(title: "Memory", points: runtime.memHistory, floorAtZero: false) { Format.memory(UInt64(max(0, $0))) }
                BarHistory(title: "CPU", points: runtime.cpuHistory, floorAtZero: true) { Format.cpu($0) }
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Collecting memory and CPU. Charts appear in a few seconds.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.rbText2)
            }
        }
    }

    // MARK: - Command, folder and output

    private var command: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Command").padding(.leading, 2)
            HStack(spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("$").foregroundStyle(Color.rbText3)
                    Text(runtime.config.command(port: runtime.expectedPort))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .font(.system(size: 12, design: .monospaced))
                .padding(.vertical, 9)
                Spacer(minLength: 4)
                Button(copied ? "Copied" : "Copy") {
                    Pasteboard.copy(runtime.config.command(port: runtime.expectedPort))
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                .rbButton(theme)
                .controlSize(.small)
            }
            .padding(.leading, Layout.rowInset)
            .padding(.trailing, 7)
            .frame(minHeight: 40)
            .rbCard(theme, radius: 12)
        }
    }

    private var folder: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Folder").padding(.leading, 2)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.rbText3)
                        .accessibilityHidden(true)
                    Text(Paths.abbreviate(runtime.config.cwd))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Color.rbText2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Layout.rowInset)
                .frame(height: 38)
                // With many editors installed the row scrolls instead of overflowing the panel.
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        Button("Finder") {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: runtime.config.cwd)
                        }
                        ForEach(Editors.installed, id: \.bundleID) { editor in
                            Button(editor.name) { Editors.open(runtime.config.cwd, with: editor) }
                        }
                    }
                    .rbButton(theme)
                    .controlSize(.small)
                    .padding(.horizontal, 8)
                }
                .scrollIndicators(.hidden)
                .padding(.bottom, 8)
            }
            .rbCard(theme, radius: 12)
        }
    }

    private var logs: some View {
        let shape = RoundedRectangle(cornerRadius: theme.logRadius, style: .continuous)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                SectionLabel(text: "Output").padding(.leading, 2)
                Spacer()
                Button("Open full log") { NSWorkspace.shared.open(runtime.logURL) }
                    .buttonStyle(TextButtonStyle(accent: true, size: 11.5))
                    .padding(.trailing, -6)
            }
            .frame(height: 18)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(runtime.logs.suffix(300)) { line in
                        Text(line.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(color(for: line.kind))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                    if runtime.logs.isEmpty {
                        Text("No output yet. Start the service to follow its logs here.")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(white: 0.68))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 44)
                    }
                }
                .textSelection(.enabled)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
            }
            .defaultScrollAnchor(.bottom)
            .frame(height: 150)
            .background(Color.rbLogBackground, in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
            .environment(\.colorScheme, .dark)
        }
    }

    private func color(for kind: LogLine.Kind) -> Color {
        switch kind {
        case .normal: return Color(white: 0.84)
        case .error: return Color(red: 1.0, green: 0.54, blue: 0.5)
        case .warning: return Color(red: 1.0, green: 0.71, blue: 0.36)
        case .success: return Color(red: 0.49, green: 0.89, blue: 0.63)
        case .meta: return Color(white: 0.56)
        }
    }
}

// MARK: - Bar history with a hover readout

/// Thirty bars for the last 30 minutes; the current one uses the app color.
private struct BarHistory: View {
    @Environment(\.theme) private var theme
    let title: String
    let points: [MetricPoint]
    let floorAtZero: Bool
    let format: (Double) -> String
    @ViewState private var hover: Int?

    private static let slots = 30
    private static let gap: CGFloat = 2

    var body: some View {
        let buckets = Metrics.buckets(points, count: Self.slots)
        let scale = Metrics.scale(buckets.map(\.value), floorAtZero: floorAtZero)
        let hovered = hover.flatMap { buckets.indices.contains($0) ? $0 : nil }
        // Without hover, the number is the latest sample (the bar is the minute's average).
        let value = hovered.map { buckets[$0].value } ?? points.last?.value ?? 0
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.rbText2)
                Spacer()
                Text(format(value))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
            }
            GeometryReader { geo in
                let width = (geo.size.width - Self.gap * CGFloat(Self.slots - 1)) / CGFloat(Self.slots)
                // Bars hug the right edge: "now" is always at the edge, even with little history.
                let lead = geo.size.width - (CGFloat(buckets.count) * (width + Self.gap) - Self.gap)
                HStack(alignment: .bottom, spacing: Self.gap) {
                    ForEach(Array(buckets.enumerated()), id: \.offset) { index, bucket in
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(highlighted(index, hovered: hovered, last: buckets.count - 1) ? Color.rbLiveFill : Color.rbBar)
                            .frame(width: max(width, 1), height: max(2, geo.size.height * scale.fraction(bucket.value)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        let index = Int(((location.x - lead) / (width + Self.gap)).rounded(.down))
                        hover = buckets.indices.contains(index) ? index : nil
                    case .ended:
                        hover = nil
                    }
                }
            }
            .frame(height: 44)
            .accessibilityLabel("\(title) over the last \(minutes) minutes, now \(format(points.last?.value ?? 0))")
            Text(caption(shown: hovered.map { buckets[$0] }))
                .font(.system(size: 11))
                .foregroundStyle(Color.rbText3)
        }
        .padding(.horizontal, Layout.rowInset)
        .padding(.top, 10)
        .padding(.bottom, 9)
        .rbCard(theme)
    }

    private func highlighted(_ index: Int, hovered: Int?, last: Int) -> Bool {
        if let hovered { return index == hovered }
        return index == last
    }

    private var minutes: Int {
        guard let first = points.first, let last = points.last else { return 0 }
        return max(1, Int(last.date.timeIntervalSince(first.date) / 60))
    }

    private func caption(shown: Metrics.Bucket?) -> String {
        if let shown, let last = points.last {
            let ago = Int(last.date.timeIntervalSince(shown.date) / 60)
            return ago <= 0 ? "now" : "\(ago) min ago"
        }
        if minutes >= 30 { return "last 30 min" }
        return minutes <= 1 ? "last minute" : "last \(minutes) min"
    }
}

// MARK: - Installed editors and terminals

enum Editors {
    struct App {
        let name: String
        let bundleID: String
    }

    static let candidates = [
        App(name: "VS Code", bundleID: "com.microsoft.VSCode"),
        App(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92"),
        App(name: "Zed", bundleID: "dev.zed.Zed"),
        App(name: "Terminal", bundleID: "com.apple.Terminal"),
        App(name: "Warp", bundleID: "dev.warp.Warp-Stable"),
        App(name: "iTerm", bundleID: "com.googlecode.iterm2"),
        App(name: "Ghostty", bundleID: "com.mitchellh.ghostty"),
    ]

    static let installed: [App] = candidates.filter {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil
    }

    static func open(_ path: String, with app: App) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([URL(fileURLWithPath: path, isDirectory: true)], withApplicationAt: appURL, configuration: config)
    }
}
