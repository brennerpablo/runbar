import AppKit
import RunbarCore
import SwiftUI

struct ServiceDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let runtime: ServiceRuntime
    /// Opens another service's detail (a proxy's client, a service's need).
    var open: ((String) -> Void)?
    let onBack: () -> Void
    @ViewState private var copied = false
    @ViewState private var copiedURL = false

    private var isProxy: Bool { runtime.config.isProxy }

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
                        Banner(
                            text: banner, actionLabel: d.fixLabel, action: d.fix.map { fix in { model.perform(fix, for: runtime) } },
                            secondaryLabel: d.alert ? "Dismiss" : nil,
                            secondary: { withAnimation(.snappy(duration: 0.2)) { model.dismissAlert(runtime.id) } }
                        )
                    } else if let info = d.info {
                        Banner(text: info, tone: .info, actionLabel: d.fixLabel, action: d.fix.map { fix in { model.perform(fix, for: runtime) } })
                    }
                    if let note = d.note {
                        Banner(text: note, actionLabel: "Restart now", action: { runtime.restart() })
                    }
                    actions(d)
                    if isProxy {
                        if d.isAlive || d.isExternal {
                            facts(d)
                            connectedNow
                        }
                        opensWith
                        idlePicker
                        command
                    } else {
                        if d.isAlive || d.isExternal { facts(d) }
                        if !runtime.config.needs.isEmpty { needsSection }
                        if d.isAlive { charts }
                        command
                        folder
                        DiskSection(runtime: runtime)
                    }
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
            Text("\(runtime.config.projectName) · \(isProxy ? runtime.config.proxyTool.label : runtime.config.type.label)")
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

    @ViewBuilder
    private func actions(_ d: ServiceDisplay) -> some View {
        if runtime.phase == .waiting {
            HStack(spacing: 8) {
                Button("Don't start") { runtime.stop() }.rbButton(theme)
            }
            .controlSize(.regular)
        } else if isProxy {
            proxyActions(d)
        } else {
            serviceActions(d)
        }
    }

    /// A proxy has nothing to open in a browser: its main action is the URL clients connect to.
    private func proxyActions(_ d: ServiceDisplay) -> some View {
        HStack(spacing: 8) {
            if d.isAlive || d.isExternal {
                if let url = runtime.config.url(port: d.realPort ?? runtime.expectedPort) {
                    Button {
                        Pasteboard.copy(url.absoluteString)
                        copiedURL = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedURL = false }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: copiedURL ? "checkmark" : "doc.on.doc").font(.system(size: 10, weight: .semibold))
                            Text(copiedURL ? "Copied" : "Copy \(url.scheme ?? "connection") URL")
                        }
                    }
                    .rbButton(theme, prominent: true)
                    .help(url.absoluteString)
                }
                if d.isExternal {
                    Button("Stop") { runtime.stopExternal() }.rbButton(theme)
                } else {
                    Button("Restart") { runtime.restart() }.rbButton(theme)
                    Button("Close") { runtime.stop() }.rbButton(theme).disabled(runtime.phase == .stopping)
                }
            } else {
                Button {
                    runtime.start()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: d.action == .retry ? "arrow.clockwise" : "play.fill").font(.system(size: 9.5, weight: .bold))
                        Text(d.action == .retry ? "Try again" : "Open\(runtime.expectedPort.map { " :\($0)" } ?? "")")
                    }
                }
                .rbButton(theme, prominent: true)
            }
        }
        .controlSize(.regular)
    }

    private func serviceActions(_ d: ServiceDisplay) -> some View {
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
        if isProxy {
            items = [
                ("Port", d.portLabel ?? "—"), ("Connections", "\(runtime.connectionCount)"), ("PID", pid.map(String.init) ?? "—"),
                ("Since", since), ("Uptime", uptime), ("Closes", d.isExternal ? "—" : model.closesText(runtime)),
            ]
        } else if d.isExternal {
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

    // MARK: - Proxies and what services need

    /// Who holds the proxy's connections right now.
    private var connectedNow: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Connected now").padding(.leading, 2)
            VStack(spacing: 0) {
                if runtime.clients.isEmpty {
                    Text(nobodyConnected)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.rbText2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Layout.rowInset)
                        .padding(.vertical, 11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(Array(runtime.clients.enumerated()), id: \.element.id) { index, client in
                    if index > 0 { Rectangle().fill(Color.rbHairline).frame(height: 1) }
                    clientRow(client)
                }
            }
            .rbCard(theme, radius: 12)
        }
    }

    private var nobodyConnected: String {
        if !runtime.heldBy.isEmpty {
            return "Nothing is connected, but \(runtime.heldBy.joined(separator: ", ")) \(runtime.heldBy.count == 1 ? "keeps" : "keep") it open."
        }
        if runtime.closesAt != nil { return "Nothing is connected. It closes \(model.closesText(runtime)) unless something connects." }
        return "Nothing is connected."
    }

    @ViewBuilder
    private func clientRow(_ client: ProxyClient) -> some View {
        let row = HStack(spacing: Layout.dotGap) {
            if client.serviceID != nil {
                StatusDot(dot: .running)
            } else {
                Image(systemName: "terminal").font(.system(size: 10)).foregroundStyle(Color.rbText3).frame(width: Layout.dot)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(client.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text(verbatim: client.serviceID.flatMap { model.config.service($0) }.map { "Runbar service · \($0.projectName)" } ?? "PID \(client.pid)")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.rbText2)
            }
            Spacer(minLength: 4)
            Text("\(client.connections) conn")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.rbText2)
        }
        .padding(.horizontal, Layout.rowInset)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        if let sid = client.serviceID, let open {
            Button { open(sid) } label: { row }.buttonStyle(.plain).accessibilityHint("Open \(sid)")
        } else {
            row
        }
    }

    /// Services that open this proxy before they start; added and removed here, saved to their `needs`.
    private var opensWith: some View {
        let deps = model.config.dependents(of: runtime.id)
        let candidates = model.config.projects.map { p in
            (p, p.services.filter { !$0.isProxy && !$0.needs.contains(runtime.id) })
        }.filter { !$0.1.isEmpty }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                SectionLabel(text: "Opens with").padding(.leading, 2)
                Spacer()
                Menu {
                    ForEach(candidates, id: \.0.id) { project, services in
                        Section(project.name) {
                            ForEach(services) { svc in
                                Button(svc.id) { model.setNeeds(svc.id, opens: runtime.id, true) }
                            }
                        }
                    }
                } label: {
                    Text("Add service…")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(TextButtonStyle(accent: true, size: 11.5))
                .fixedSize()
                .padding(.trailing, -6)
                .disabled(candidates.isEmpty || model.configError != nil)
            }
            .frame(height: 18)
            VStack(spacing: 0) {
                if deps.isEmpty {
                    Text("No service opens \(runtime.id) yet. Add the ones that use it: starting one opens \(runtime.id) first.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.rbText2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Layout.rowInset)
                        .padding(.vertical, 11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(Array(deps.enumerated()), id: \.element.id) { index, svc in
                    if index > 0 { Rectangle().fill(Color.rbHairline).frame(height: 1) }
                    if let rt = model.runtimes[svc.id] {
                        linkedRow(rt, trailing: {
                            Button { model.setNeeds(svc.id, opens: runtime.id, false) } label: {
                                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            }
                            .buttonStyle(IconButtonStyle())
                            .help("\(svc.id) stops opening \(runtime.id)")
                            .accessibilityLabel("Remove \(svc.id)")
                        })
                    }
                }
            }
            .rbCard(theme, radius: 12)
            if !deps.isEmpty {
                Text("Starting one of these opens \(runtime.id) first and waits for its port. While any of them runs, \(runtime.id) stays open.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.rbText2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }

    private var idlePicker: some View {
        let current = IdleSetting.text(runtime.config.idle)
        var options = IdleSetting.presets
        if !options.contains(current) { options.insert(current, at: options.count - 1) }
        return VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Close when idle").padding(.leading, 2)
            IdleSegments(options: options, selection: current) { model.setIdle($0, for: runtime.id) }
                .disabled(model.configError != nil)
            Text("Idle means no connections and nothing from Opens with running. Saved to config.json as \"idle\": \"\(current)\".")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.rbText2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
        }
    }

    /// What a service opens before it starts (`needs`).
    private var needsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Opens first").padding(.leading, 2)
            VStack(spacing: 0) {
                ForEach(Array(runtime.config.needs.enumerated()), id: \.element) { index, id in
                    if index > 0 { Rectangle().fill(Color.rbHairline).frame(height: 1) }
                    if let rt = model.runtimes[id] { linkedRow(rt, trailing: { EmptyView() }) }
                }
            }
            .rbCard(theme, radius: 12)
        }
    }

    /// Another service as a row: dot, id, its second line, port; opens its detail.
    @ViewBuilder
    private func linkedRow<Trailing: View>(_ rt: ServiceRuntime, @ViewBuilder trailing: () -> Trailing) -> some View {
        let d = model.display(rt)
        HStack(spacing: 8) {
            Button { open?(rt.id) } label: {
                HStack(spacing: Layout.dotGap) {
                    StatusDot(dot: d.dot)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rt.id).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                        Text(d.subtitle)
                            .font(d.subtitleMono ? .system(size: 10.5, design: .monospaced) : .system(size: 11))
                            .foregroundStyle(d.warn ? Color.rbWarn : Color.rbText2)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if let label = d.portLabel { Pill(text: label, tone: rt.isRunningAnywhere ? .live : .idle) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Open \(rt.id)")
            trailing()
        }
        .padding(.leading, Layout.rowInset)
        .padding(.trailing, 6)
        .frame(minHeight: 44)
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

// MARK: - Close-when-idle choice

/// 5 min / 15 min / 1 hour / Never, in the look of the status filter.
struct IdleSegments: View {
    let options: [String]
    let selection: String
    let pick: (String) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        let outer = RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
        let inner = RoundedRectangle(cornerRadius: theme.controlRadius - 2, style: .continuous)
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let on = option == selection
                Button { if !on { pick(option) } } label: {
                    Text(Self.label(option))
                        .font(.system(size: 11.5, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.primary : Color.rbText2)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background {
                            if on {
                                inner.fill(Color.rbSegmentOn).shadow(color: .black.opacity(0.14), radius: 0.5, y: 0.5)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.rbControl, in: outer)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Close when idle")
    }

    static func label(_ option: String) -> String {
        switch IdleSetting.parse(option) {
        case .never: return "Never"
        case .after(let seconds): return IdleSetting.human(seconds)
        case .invalid: return option
        }
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
