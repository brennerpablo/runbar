import AppKit
import RunbarCore
import SwiftUI

enum StatusFilter: Hashable { case all, running, stopped }

/// What the panel lists below the tiles: services, or what projects take on disk.
enum PanelTab: Hashable { case services, disk }

struct PopoverView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @ViewState private var selected: String?
    var initialSelection: String?
    var initialTab: PanelTab?
    var initialQuery: String?
    @ViewState private var tab: PanelTab = .services
    @ViewState private var query = ""
    @ViewState private var filter: StatusFilter = .all
    @ViewState private var expanded: Set<String> = []
    @ViewState private var expandedReady = false
    @ViewState private var showOthers = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        let theme = model.theme
        VStack(spacing: 0) {
            if let id = selected, let rt = model.runtimes[id] {
                ServiceDetailView(runtime: rt) { selected = nil }
            } else {
                list(theme)
            }
        }
        .frame(width: Layout.width)
        .rbPanel(theme)
        .environment(\.theme, theme)
        .onAppear {
            prepareExpanded()
            if selected == nil, let initialSelection { selected = initialSelection }
            if let initialTab { tab = initialTab }
            if let initialQuery { query = initialQuery }
        }
    }

    // MARK: - List

    private func list(_ t: Theme) -> some View {
        let alerts = model.alertingServices
        return VStack(spacing: 0) {
            header(t)
                .padding(.leading, t.gutter)
                .padding(.trailing, t.gutter - 4)
                .padding(.top, 14)
            tiles(t)
                .padding(.horizontal, t.gutter)
                .padding(.top, 12)
            if let first = alerts.first {
                alertStrip(first, count: alerts.count, t)
                    .padding(.horizontal, t.gutter)
                    .padding(.top, 10)
            }
            if let issue = model.configError {
                Banner(
                    text: "config.json has an error\(issue.line > 0 ? " at line \(issue.line), column \(issue.column)" : ""): \(issue.message). Runbar keeps using the last valid version.",
                    actionLabel: "Open in editor", action: { model.openConfigFile() },
                    secondaryLabel: "Copy error for your agent",
                    secondary: { Pasteboard.copy(AgentPrompt.fixError(issue)) }
                )
                .padding(.horizontal, t.gutter)
                .padding(.top, 10)
            }
            if tab == .services && model.groups.isEmpty {
                emptyState(t)
                    .padding(.horizontal, t.gutter)
                    .padding(.top, 12)
                    .padding(.bottom, t.gutter)
            } else {
                Group {
                    if tab == .services { listHeader(t) } else { diskHeader(t) }
                }
                .padding(.horizontal, t.gutter)
                .padding(.top, 12)
                .padding(.bottom, 8)
                ZStack(alignment: .bottom) {
                    AdaptiveScroll(maxHeight: listMaxHeight(alerts: !alerts.isEmpty), holdHeight: isFiltering) {
                        VStack(alignment: .leading, spacing: 8) {
                            if tab == .services {
                                groupsList(t)
                                if !model.otherListeners.isEmpty { othersSection(t) }
                            } else {
                                DiskPanel(query: query)
                            }
                        }
                        .padding(.horizontal, t.gutter)
                        // Room for the last row to scroll above the floating search.
                        .padding(.bottom, Layout.searchHeight + 24)
                    }
                    LinearGradient(
                        stops: [
                            .init(color: t.panelFade.opacity(0), location: 0),
                            .init(color: t.panelFade.opacity(0.9), location: 0.6),
                            .init(color: t.panelFade.opacity(0.96), location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: Layout.searchHeight + 36)
                    .allowsHitTesting(false)
                    searchBar(t)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                }
            }
        }
    }

    /// The panel stays within a laptop's height: notices at the top take space from the list.
    private func listMaxHeight(alerts: Bool) -> CGFloat {
        500 - (alerts ? 44 : 0) - (model.configError == nil ? 0 : 96)
    }

    private func header(_ t: Theme) -> some View {
        let running = model.runningCount
        return HStack(alignment: .center, spacing: 10) {
            AppMark()
            Text("Runbar")
                .font(.system(size: 15, weight: .semibold))
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                if running > 0 {
                    Button { model.stopAllServices() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 8, weight: .bold))
                            Text("Stop all")
                        }
                    }
                    .rbButton(t)
                    .controlSize(.small)
                    .fixedSize()
                    .padding(.trailing, 6)
                    .help(running == 1 ? "Stop the running service" : "Stop the \(running) running services")
                    .accessibilityLabel("Stop all running services")
                }
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(IconButtonStyle())
                    .help("Reload config.json and refresh")
                    .accessibilityLabel("Refresh")
                Menu {
                    Button("Ask an agent…") { openAgentWindow() }
                    Button("Edit config.json") { model.openConfigFile() }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.button)
                .buttonStyle(IconButtonStyle())
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add service")
                .accessibilityLabel("Add service")
                moreMenu
            }
        }
        .frame(height: Layout.control)
    }

    /// Everything that used to live in the footer: config, look, folders and quit.
    private var moreMenu: some View {
        Menu {
            Button("Open config.json") { model.openConfigFile() }
            Button("Set up with an agent…") { openAgentWindow() }
            Divider()
            Picker("Look", selection: Binding(get: { model.config.settings.look }, set: { model.setLook($0) })) {
                Text("Automatic").tag(LookSetting.auto)
                Text("Solid").tag(LookSetting.solid)
                Text("Liquid Glass").tag(LookSetting.glass)
            }
            .disabled(model.configError != nil)
            Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            Divider()
            Button("Install the runbar command") { _ = model.installCLI() }
            Button("Show config folder") { model.revealConfigDir() }
            Button("Open logs folder") { model.openLogsDir() }
            Divider()
            Button("Quit and keep services running") { model.quit(stopServices: false) }
            Button("Quit and stop services") { model.quit(stopServices: true) }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(IconButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More options")
        .accessibilityLabel("More options")
    }

    /// Running and Disk are also the tabs: the raised one is the view below.
    private func tiles(_ t: Theme) -> some View {
        let running = model.runningCount
        let memory = Format.memory(model.totalMemory).split(separator: " ").map(String.init)
        let disk = DiskModel.shared
        let diskSize = Format.memory(disk.total).split(separator: " ").map(String.init)
        return HStack(spacing: 8) {
            Button { show(.services) } label: {
                StatTile(label: "Running", value: "\(running)", raised: tab == .services, live: running > 0) {
                    Text("of \(model.config.services.count)")
                        .font(.system(size: 11.5))
                        .monospacedDigit()
                        .foregroundStyle(Color.rbText2)
                }
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(tab == .services ? .isSelected : [])
            .accessibilityHint("Show services")
            StatTile(label: "Memory", value: running > 0 ? (memory.first ?? "—") : "—", unit: running > 0 ? memory.dropFirst().first : nil,
                     note: running > 0 ? "\(Int(model.totalCPU.rounded()))% CPU" : nil) {
                MiniBars(values: Metrics.buckets(model.totalHistory(\.memHistory), count: 7).map(\.value), floorAtZero: false)
            }
            Button { show(.disk) } label: {
                StatTile(label: "Disk", value: disk.hasMeasured ? (diskSize.first ?? "—") : "—", unit: disk.hasMeasured ? diskSize.dropFirst().first : nil,
                         raised: tab == .disk, note: disk.freeBytes.map { "\(DiskText.roundedSize($0)) free" },
                         noteColor: disk.lowOnSpace ? .rbWarn : .rbText3) {
                    EmptyView()
                }
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(tab == .disk ? .isSelected : [])
            .accessibilityHint("Show what projects take on disk")
        }
    }

    private func show(_ next: PanelTab) {
        guard tab != next else { return }
        query = ""
        tab = next
        if next == .disk { DiskModel.shared.scanIfStale() }
    }

    private func diskHeader(_ t: Theme) -> some View {
        let disk = DiskModel.shared
        let current = disk.scanning.compactMap { id in model.config.projects.first { $0.id == id }?.name }.sorted().first
        return HStack(alignment: .center, spacing: 6) {
            Text("Disk")
                .font(.system(size: 12.5, weight: .semibold))
            Text(disk.isScanning ? "measuring\(current.map { " \($0)" } ?? "")…" : DiskText.scanned(disk.scannedAt))
                .font(.system(size: 12))
                .foregroundStyle(Color.rbText3)
                .lineLimit(1)
            Spacer(minLength: 8)
            if disk.isScanning {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 26, height: 26)
            } else {
                Button { disk.scan() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10.5, weight: .bold))
                        Text("Measure again")
                    }
                }
                .buttonStyle(TextButtonStyle(accent: true, size: 11.5))
                .padding(.trailing, -6)
            }
        }
        .padding(.leading, 2)
        .frame(height: 26)
    }

    /// One line for the first alert; clicking it opens the service.
    private func alertStrip(_ rt: ServiceRuntime, count: Int, _ t: Theme) -> some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        let title = count == 1 ? "1 alert" : "\(count) alerts"
        let d = model.display(rt)
        return HStack(spacing: 0) {
            Button { selected = rt.id } label: {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11.5, weight: .semibold))
                    Text("\(Text(title).fontWeight(.semibold)) · \(rt.id): \(d.subtitle)")
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                }
                .padding(.leading, 11)
                .padding(.trailing, 8)
                .frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title). \(rt.id): \(d.subtitle)")
            .accessibilityHint("Open details")
            Rectangle()
                .fill(Color.rbWarnBorder)
                .frame(width: 1, height: 18)
            Button {
                withAnimation(.snappy(duration: 0.2)) { model.dismissAlert(rt.id) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(DismissText.help(rt))
            .accessibilityLabel("Dismiss the alert for \(rt.id)")
        }
        .foregroundStyle(Color.rbWarn)
        .background(Color.rbWarnSoft, in: shape)
        .overlay(shape.strokeBorder(Color.rbWarnBorder))
    }

    private func listHeader(_ t: Theme) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Text("Services")
                .font(.system(size: 12.5, weight: .semibold))
            Text("\(model.groups.reduce(0) { $0 + $1.runtimes.count })")
                .font(.system(size: 12.5))
                .monospacedDigit()
                .foregroundStyle(Color.rbText3)
            Spacer(minLength: 8)
            SegmentedFilter(selection: $filter).fixedSize()
        }
        .padding(.leading, 2)
    }

    /// Floating search over the end of the list. ⌘K moves the cursor into it.
    private func searchBar(_ t: Theme) -> some View {
        let shape = RoundedRectangle(cornerRadius: t.cardRadius, style: .continuous)
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.rbText2)
            TextField(searchPrompt, text: $query, prompt: Text(searchPrompt).foregroundStyle(Color.rbText3))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
            if query.isEmpty {
                Text("⌘K")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(0.4)
                    .foregroundStyle(Color.rbText2)
                    .padding(.horizontal, 7)
                    .frame(height: 22)
                    .background(Color.rbControl, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .accessibilityHidden(true)
            } else {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color.rbText3)
                }
                .buttonStyle(.plain)
                .frame(width: 22, height: 22)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: Layout.searchHeight)
        .background(Color.rbSearchField, in: shape)
        .overlay(shape.strokeBorder(Color.rbCardBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 12, y: 6)
        .background {
            // Shortcut without a visible button.
            Button("Search") { searchFocused = true }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private var searchPrompt: String { tab == .services ? "Search services or ports" : "Filter projects or folders" }

    private var isFiltering: Bool { filter != .all || !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private func visible(_ rt: ServiceRuntime) -> Bool {
        switch filter {
        case .running where !rt.isRunningAnywhere: return false
        case .stopped where rt.isRunningAnywhere: return false
        default: break
        }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        let ports = ([rt.config.port].compactMap { $0 } + rt.listening + (rt.external?.ports ?? [])).map(String.init).joined(separator: " ")
        let hay = "\(rt.id) \(rt.config.command) \(rt.config.type.label) \(rt.config.projectName) \(ports)".lowercased()
        return hay.contains(q)
    }

    @ViewBuilder
    private func groupsList(_ t: Theme) -> some View {
        let groups = model.groups
        ForEach(groups) { group in
            let rows = group.runtimes.filter(visible)
            if !(isFiltering && rows.isEmpty) {
                GroupSection(
                    group: group,
                    rows: rows,
                    isExpanded: isFiltering || expanded.contains(group.id),
                    toggle: {
                        withAnimation(.snappy(duration: 0.2)) {
                            if expanded.contains(group.id) { expanded.remove(group.id) } else { expanded.insert(group.id) }
                        }
                    },
                    open: { selected = $0 }
                )
            }
        }
        if isFiltering && !groups.contains(where: { $0.runtimes.contains(where: visible) }) {
            Text("No matching services.")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.rbText2)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
        }
    }

    private func emptyState(_ t: Theme) -> some View {
        VStack(spacing: 8) {
            AppMark(size: 40)
                .padding(.bottom, 4)
            Text("No services configured")
                .font(.system(size: 13.5, weight: .semibold))
            Text("Ask an agent to set up config.json, or edit the file yourself.")
                .font(.system(size: 12))
                .lineSpacing(2)
                .foregroundStyle(Color.rbText2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            HStack(spacing: 8) {
                Button("Set up with an agent…") { openAgentWindow() }.rbButton(t, prominent: true)
                Button("Open config.json") { model.openConfigFile() }.rbButton(t)
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 24)
        .padding(.top, 26)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
        .rbCard(t)
    }

    /// Ports held by processes that aren't Runbar services: the last card in the list.
    private func othersSection(_ t: Theme) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { showOthers.toggle() }
            } label: {
                HStack(spacing: 8) {
                    DisclosureChevron(open: showOthers)
                    let n = model.otherListeners.count
                    Text(n == 1 ? "1 port in use outside Runbar" : "\(n) ports in use outside Runbar")
                        .font(.system(size: 12))
                    Spacer()
                }
                .padding(.horizontal, Layout.rowInset)
                .frame(height: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(showOthers ? "Collapse" : "Expand")

            if showOthers {
                VStack(spacing: 0) {
                    ForEach(model.otherListeners) { l in
                        HStack(spacing: 10) {
                            Pill(text: ":\(l.port)")
                            Text(l.name).font(.system(size: 12)).lineLimit(1)
                            Spacer(minLength: 4)
                            Text("PID \(l.pid)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.rbText2)
                            Button("Kill") { model.killOther(pid: l.pid) }
                                .rbButton(t)
                                .controlSize(.small)
                        }
                        .frame(height: 34)
                    }
                }
                .padding(.leading, Layout.rowInset)
                .padding(.trailing, 7)
                .padding(.bottom, 6)
            }
        }
        .rbCard(t)
    }

    // MARK: - Helpers

    private func openAgentWindow() {
        openWindow(id: "agent")
        NSApp.activate()
    }

    private func prepareExpanded() {
        guard !expandedReady else { return }
        expandedReady = true
        let groups = model.groups
        if groups.count <= 3 {
            expanded = Set(groups.map(\.id))
        } else {
            expanded = Set(groups.filter { $0.runtimes.contains(where: \.isRunningAnywhere) || $0.isOrphanGroup }.map(\.id))
            if expanded.isEmpty, let first = groups.first { expanded.insert(first.id) }
        }
    }
}

// MARK: - Project

/// One card per project: a header with a dot per service and, when open, the rows.
private struct GroupSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let group: ServiceGroup
    let rows: [ServiceRuntime]
    let isExpanded: Bool
    let toggle: () -> Void
    let open: (String) -> Void

    var body: some View {
        let alive = group.runtimes.filter(\.isRunningAnywhere).count
        let allOn = alive == group.runtimes.count && alive > 0
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Button(action: toggle) {
                    HStack(spacing: 8) {
                        DisclosureChevron(open: isExpanded)
                        Text(group.name)
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)
                        Pips(dots: group.runtimes.map { model.display($0).dot })
                            .padding(.leading, 2)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(group.name), \(alive) of \(group.runtimes.count) running")
                .accessibilityHint(isExpanded ? "Collapse" : "Expand")

                if !group.isOrphanGroup {
                    Button(allOn ? "Stop all" : "Start all") {
                        if allOn { model.stopAll(group) } else { model.startAll(group) }
                    }
                    .buttonStyle(TextButtonStyle(accent: !allOn, size: 11.5))
                }
            }
            .padding(.leading, 4)
            .padding(.trailing, 5)
            .frame(height: 38)

            if isExpanded && !rows.isEmpty {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, rt in
                    if index > 0 {
                        Rectangle()
                            .fill(Color.rbHairline)
                            .frame(height: 1)
                            .padding(.leading, Layout.rowInset + Layout.dot + Layout.dotGap)
                    }
                    ServiceRow(runtime: rt) { open(rt.id) }
                }
            }
        }
        .rbCard(theme)
    }
}

// MARK: - Service row

private struct ServiceRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let runtime: ServiceRuntime
    let open: () -> Void
    @ViewState private var hover = false

    var body: some View {
        let d = model.display(runtime)
        let stopped = d.dot == .stopped
        HStack(spacing: 10) {
            Button(action: open) {
                HStack(alignment: .center, spacing: Layout.dotGap) {
                    StatusDot(dot: d.dot)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(runtime.id)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(stopped ? Color.rbTextDim : Color.primary)
                            .lineLimit(1)
                        Text(d.subtitle)
                            .font(d.subtitleMono ? .system(size: 10.5, design: .monospaced) : .system(size: 11))
                            .foregroundStyle(d.warn ? Color.rbWarn : (stopped ? Color.rbText3 : Color.rbText2))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(runtime.id), \(d.statusLabel)")
            .accessibilityHint("Open details")

            if let memory = d.memory {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Format.memory(memory))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                    Text(Format.cpu(d.cpu ?? 0))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Color.rbText2)
                }
                .lineLimit(1)
                .frame(width: Layout.metricsWidth, alignment: .trailing)
                .help("Memory and CPU of the process and its children")
                .accessibilityElement(children: .combine)
            }

            if let label = d.portLabel {
                if let url = d.url, runtime.phase == .running || d.isExternal {
                    Button { NSWorkspace.shared.open(url) } label: { Pill(text: label, tone: d.warn ? .warn : .live) }
                        .buttonStyle(.plain)
                        .help("Open \(url.absoluteString)")
                } else {
                    Pill(text: label)
                }
            }

            Button { model.toggle(runtime.id) } label: { Image(systemName: d.actionSymbol) }
                .buttonStyle(RowActionButtonStyle(tone: actionTone(d)))
                .help(actionHelp(d))
                .accessibilityLabel(actionHelp(d))
        }
        .padding(.leading, Layout.rowInset)
        .padding(.trailing, 9)
        .frame(height: Layout.rowHeight)
        .background(hover ? Color.rbControl.opacity(0.6) : Color.clear)
        .onHover { hover = $0 }
        .contextMenu {
            if d.alert {
                Button("Dismiss alert") { model.dismissAlert(runtime.id) }
                    .help(DismissText.help(runtime))
                Divider()
            }
            Button("Open full log") { NSWorkspace.shared.open(runtime.logURL) }
        }
    }

    private func actionTone(_ d: ServiceDisplay) -> RowActionButtonStyle.Tone {
        switch d.action {
        case .start: return .live
        case .stop: return .neutral
        case .retry: return .warn
        }
    }

    private func actionHelp(_ d: ServiceDisplay) -> String {
        switch d.action {
        case .start: return "Start \(runtime.id)"
        case .stop: return "Stop \(runtime.id)"
        case .retry: return "Try starting \(runtime.id) again"
        }
    }
}

/// What dismissing an alert does, in the words of its tooltip.
enum DismissText {
    @MainActor
    static func help(_ rt: ServiceRuntime) -> String {
        switch rt.phase {
        case .crashed, .failed: return "Dismiss: mark \(rt.id) as stopped"
        default: return "Dismiss until this changes"
        }
    }
}
