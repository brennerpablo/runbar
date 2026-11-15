import AppKit
import Charts
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
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    Text("Serviços").font(.system(size: 13))
                }
                .foregroundStyle(Color.accentColor)
                .frame(height: Layout.control)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .padding(.horizontal, theme.gutter)
            .padding(.top, 8)

            AdaptiveScroll(maxHeight: 680) {
                VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                    header(d)
                    if let banner = d.banner {
                        Banner(text: banner, actionLabel: d.fixLabel, action: d.fix.map { fix in { model.perform(fix, for: runtime) } })
                    } else if let info = d.info {
                        Banner(text: info, tone: .info, actionLabel: d.fixLabel, action: d.fix.map { fix in { model.perform(fix, for: runtime) } })
                    }
                    if let note = d.note {
                        Banner(text: note, actionLabel: "Reiniciar agora", action: { runtime.restart() })
                    }
                    actions(d)
                    if d.isAlive || d.isExternal { facts(d) }
                    if d.isAlive { charts }
                    command
                    folder
                    logs
                }
                .padding(.horizontal, theme.gutter)
                .padding(.top, 8)
                .padding(.bottom, theme.gutter)
            }
        }
    }

    // MARK: - Cabeçalho e ações

    private func header(_ d: ServiceDisplay) -> some View {
        HStack(alignment: .top, spacing: Layout.dotGap) {
            StatusDot(dot: d.dot, size: 9).padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(runtime.id)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                Text("\(runtime.config.projectName) · \(runtime.config.type.label)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(d.statusLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(chipForeground(d))
                .padding(.horizontal, 9)
                .frame(height: 20)
                .background(chipBackground(d), in: Capsule())
                .padding(.top, 1)
        }
    }

    private func chipForeground(_ d: ServiceDisplay) -> Color {
        switch d.dot {
        case .running: return Color(nsColor: .systemGreen)
        case .warning, .error, .busy: return .rbWarn
        case .stopped: return .secondary
        }
    }

    private func chipBackground(_ d: ServiceDisplay) -> Color {
        switch d.dot {
        case .running: return Color.rbGreen.opacity(0.15)
        case .warning, .error, .busy: return Color.rbOrange.opacity(0.15)
        case .stopped: return Color.primary.opacity(0.07)
        }
    }

    private func actions(_ d: ServiceDisplay) -> some View {
        HStack(spacing: 8) {
            if let url = d.url, d.isAlive || d.isExternal {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Abrir \(url.host ?? "localhost")\(url.port.map { ":\($0)" } ?? "")", systemImage: "arrow.up.right")
                }
                .rbButton(theme, prominent: true)
            }
            if d.isExternal {
                Button("Parar") { runtime.stopExternal() }.rbButton(theme)
            } else if d.isAlive {
                Button("Reiniciar") { runtime.restart() }.rbButton(theme)
                Button("Parar") { runtime.stop() }.rbButton(theme).disabled(runtime.phase == .stopping)
            } else {
                Button {
                    runtime.start()
                } label: {
                    Label(d.action == .retry ? "Tentar de novo" : "Iniciar", systemImage: "play.fill")
                }
                .rbButton(theme, prominent: true)
            }
        }
        .controlSize(.regular)
    }

    // MARK: - Números

    private func facts(_ d: ServiceDisplay) -> some View {
        let ext = runtime.external
        let started = d.isExternal ? ext?.startedAt : runtime.startedAt
        let pid = runtime.pid ?? ext?.rootPID
        let since = started.map { Format.clock($0, now: model.now) } ?? "—"
        let uptime = started.map { Format.duration(model.now.timeIntervalSince($0)) } ?? "—"
        let items: [(String, String)]
        if d.isExternal {
            // Sem histórico nem log: memória e CPU entram aqui.
            items = [
                ("Porta", d.portLabel ?? "—"), ("PID", pid.map(String.init) ?? "—"), ("Memória", d.memory.map { Format.memory($0) } ?? "—"),
                ("CPU", d.cpu.map { Format.cpu($0) } ?? "—"), ("Desde", since), ("No ar há", uptime),
            ]
        } else {
            items = [
                ("Porta", d.portLabel ?? "—"), ("PID", pid.map(String.init) ?? "—"), ("Processos", "\(runtime.processCount)"),
                ("Desde", since), ("No ar há", uptime),
                ("Último log", runtime.lastLogAt.map { Format.ago($0, now: model.now) } ?? "—"),
            ]
        }
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(items, id: \.0) { item in
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel(text: item.0)
                    Text(item.1)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .rbCard(theme)
            }
        }
    }

    @ViewBuilder
    private var charts: some View {
        if runtime.memHistory.count >= 2 {
            HStack(spacing: 8) {
                Sparkline(title: "Memória", points: runtime.memHistory, floorAtZero: false) { Format.memory(UInt64(max(0, $0))) }
                Sparkline(title: "CPU", points: runtime.cpuHistory, floorAtZero: true) { Format.cpu($0) }
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Coletando memória e CPU. Os gráficos aparecem em alguns segundos.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Comando, pasta e saída

    private var command: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Comando")
            HStack(spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("$").foregroundStyle(.tertiary)
                    Text(runtime.config.command(port: runtime.expectedPort))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .font(.system(size: 12, design: .monospaced))
                .padding(.vertical, 8)
                Spacer(minLength: 4)
                Button(copied ? "Copiado" : "Copiar") {
                    Pasteboard.copy(runtime.config.command(port: runtime.expectedPort))
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                .rbButton(theme)
                .controlSize(.small)
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .frame(minHeight: 34)
            .rbCard(theme)
        }
    }

    private var folder: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Pasta")
            Text(Paths.abbreviate(runtime.config.cwd))
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
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
        }
    }

    private var logs: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                SectionLabel(text: "Saída")
                Spacer()
                Button("Abrir log completo") { NSWorkspace.shared.open(runtime.logURL) }
                    .buttonStyle(TextButtonStyle(accent: true, size: 11.5))
                    .padding(.trailing, -8)
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
                        Text("Sem saída ainda. Inicie o serviço para acompanhar os logs aqui.")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(white: 0.68))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 44)
                    }
                }
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom)
            .frame(height: 150)
            .background(Color.rbLogBackground, in: RoundedRectangle(cornerRadius: theme.logRadius, style: .continuous))
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

// MARK: - Gráfico pequeno com leitura ao passar o mouse

private struct Sparkline: View {
    @Environment(\.theme) private var theme
    let title: String
    let points: [MetricPoint]
    let floorAtZero: Bool
    let format: (Double) -> String
    @ViewState private var hover: MetricPoint?

    var body: some View {
        let values = points.map(\.value)
        let lo = floorAtZero ? 0 : (values.min() ?? 0)
        let hiRaw = values.max() ?? 1
        let span = max(hiRaw - lo, floorAtZero ? 5 : hiRaw * 0.05 + 1)
        let low = floorAtZero ? 0 : lo - span * 0.5
        let high = lo + span * 1.15
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: title)
                Spacer()
                Text(format(hover?.value ?? points.last?.value ?? 0))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
            }
            Chart {
                ForEach(points) { p in
                    AreaMark(x: .value("Hora", p.date), yStart: .value("Base", low), yEnd: .value(title, p.value))
                        .foregroundStyle(Color.accentColor.opacity(0.12))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Hora", p.date), y: .value(title, p.value))
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
                if let h = hover ?? points.last {
                    PointMark(x: .value("Hora", h.date), y: .value(title, h.value))
                        .foregroundStyle(Color.accentColor)
                        .symbolSize(30)
                }
                if let h = hover {
                    RuleMark(x: .value("Hora", h.date)).foregroundStyle(Color.secondary.opacity(0.35))
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .chartYScale(domain: low...high)
            .frame(height: 36)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                guard let plot = proxy.plotFrame else { return }
                                let x = location.x - geo[plot].origin.x
                                if let date: Date = proxy.value(atX: x) {
                                    hover = points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
                                }
                            case .ended:
                                hover = nil
                            }
                        }
                }
            }
            .accessibilityLabel("\(title) nos últimos \(minutes) minutos, agora \(format(points.last?.value ?? 0))")
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .rbCard(theme)
    }

    private var minutes: Int {
        guard let first = points.first, let last = points.last else { return 0 }
        return max(1, Int(last.date.timeIntervalSince(first.date) / 60))
    }

    private var caption: String {
        if let h = hover, let last = points.last {
            let ago = Int(last.date.timeIntervalSince(h.date) / 60)
            return ago <= 0 ? "agora" : "há \(ago) min"
        }
        if minutes >= 30 { return "últimos 30 min" }
        return minutes <= 1 ? "último minuto" : "últimos \(minutes) min"
    }
}

// MARK: - Editores e terminais instalados

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
