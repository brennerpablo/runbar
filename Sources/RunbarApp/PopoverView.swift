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
    /// Screenshots: the "ports in use outside Runbar" card open, or a port being moved into Runbar.
    var initialShowOthers = false
    var initialImport: Listener?
    @ViewState private var tab: PanelTab = .services
    @ViewState private var query = ""
    /// Search is closed until ⌘K, the magnifier or typing opens it in place of the header.
    @ViewState private var searching = false
    @ViewState private var filter: StatusFilter = .all
    @ViewState private var expanded: Set<String> = []
    @ViewState private var expandedReady = false
    @ViewState private var showOthers = false
    /// Project order, set each time the panel opens: a project that starts or stops doesn't move under the pointer.
    @ViewState private var order: [String] = []
    /// The port held outside Runbar being moved into it (its listener).
    @ViewState private var importing: Listener?
    @FocusState private var searchFocused: Bool

    var body: some View {
        let theme = model.theme
        VStack(spacing: 0) {
            if let id = selected, let rt = model.runtimes[id] {
                ServiceDetailView(runtime: rt, open: { selected = $0 }) { selected = nil }
            } else if let listener = importing, let job = model.launchdJobs[listener.pid] {
                LaunchdImportView(listener: listener, job: job) { opened in
                    importing = nil
                    if let opened { selected = opened }
                }
            } else {
                list(theme)
            }
        }
        .frame(width: Layout.width)
        .rbPanel(theme)
        .environment(\.theme, theme)
        .onAppear {
            prepareExpanded()
            settleOrder()
            listenToPanel()
            if selected == nil, let initialSelection { selected = initialSelection }
            if let initialTab { tab = initialTab }
            if let initialQuery {
                query = initialQuery
                searching = true
            }
            if initialShowOthers { showOthers = true }
            if let initialImport { importing = initialImport }
        }
        .onChange(of: model.config.settings.activeProjectsFirst) { settleOrder() }
    }

    // MARK: - List

    private func list(_ t: Theme) -> some View {
        let alerts = model.alertingServices
        let awake = KeepAwake.shared
        return VStack(spacing: 0) {
            header(t)
                .padding(.horizontal, t.gutter)
                .padding(.top, 12)
            if awake.isOn {
                coffeeStrip(awake, t)
                    .padding(.horizontal, t.gutter)
                    .padding(.top, 10)
            }
            tiles(t)
                .padding(.horizontal, t.gutter)
                .padding(.top, 10)
            // While searching, the matches matter more; the rows still show who has an alert.
            if tab == .services && !alerts.isEmpty && trimmedQuery.isEmpty {
                needsYou(alerts, t)
                    .padding(.horizontal, t.gutter)
                    .padding(.top, 12)
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
                AdaptiveScroll(maxHeight: listMaxHeight(alerts: tab == .services && trimmedQuery.isEmpty ? alerts.count : 0), holdHeight: isFiltering) {
                    VStack(alignment: .leading, spacing: 8) {
                        if tab == .services {
                            groupsList(t)
                            if !model.otherListeners.isEmpty { othersSection(t) }
                        } else {
                            DiskPanel(query: query)
                        }
                    }
                    .padding(.horizontal, t.gutter)
                    .padding(.bottom, t.gutter)
                }
            }
        }
    }

    /// The panel stays within a laptop's height: what sits above the list takes space from it.
    private func listMaxHeight(alerts: Int) -> CGFloat {
        var height: CGFloat = 500
        if KeepAwake.shared.isOn { height -= 42 }
        if alerts > 0 { height -= 40 + 51 * CGFloat(alerts) }
        if model.configError != nil { height -= 106 }
        return max(height, 160)
    }

    // MARK: - Header

    private func header(_ t: Theme) -> some View {
        Group {
            if searching { searchField(t) } else { titleBar(t) }
        }
        .frame(height: 32)
        .background {
            // Shortcuts without visible buttons.
            Group {
                Button("Search") { openSearch() }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Refresh") { model.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    private func titleBar(_ t: Theme) -> some View {
        let awake = KeepAwake.shared
        return HStack(alignment: .center, spacing: 10) {
            AppLogo()
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                // While it's on, the strip below the header is the state and the off switch.
                if !awake.isOn { coffeeButton(awake) }
                Button { openSearch() } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(IconButtonStyle())
                    .help("Search (⌘K, or just start typing)")
                    .accessibilityLabel("Search")
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
            .padding(.trailing, -4)
        }
    }

    /// Search in place of the header. Return opens the first match, Esc gives the header back.
    private func searchField(_ t: Theme) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let matches = tab == .services && !trimmedQuery.isEmpty ? matchCount : nil
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.rbText2)
            TextField(searchPrompt, text: $query, prompt: Text(searchPrompt).foregroundStyle(Color.rbText3))
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .focused($searchFocused)
                .onSubmit(openFirstMatch)
                .onExitCommand(perform: closeSearch)
                .onAppear(perform: focusSearch)
            if let matches {
                Text(matches == 1 ? "1 match" : "\(matches) matches")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Color.rbText3)
                    .lineLimit(1)
                    .fixedSize()
            }
            Button(action: closeSearch) {
                Text("esc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.rbText2)
                    .padding(.horizontal, 7)
                    .frame(height: 22)
                    .background(Color.rbControl, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close search (Esc)")
            .accessibilityLabel("Close search")
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .frame(height: 32)
        .background(Color.rbSearchField, in: shape)
        .overlay(shape.strokeBorder(searchFocused ? Color.rbLiveFill.opacity(0.55) : Color.rbCardBorder, lineWidth: 1))
    }

    private var searchPrompt: String { tab == .services ? "Search services, proxies or ports" : "Filter projects or folders" }

    private func openSearch() {
        if !searching { searching = true }
        focusSearch()
    }

    /// Focusing a field selects its text; the cursor goes to the end so typing carries on.
    private func focusSearch() {
        DispatchQueue.main.async {
            searchFocused = true
            DispatchQueue.main.async {
                (NSApp.keyWindow?.firstResponder as? NSTextView)?.moveToEndOfDocument(nil)
            }
        }
    }

    private func closeSearch() {
        query = ""
        searching = false
        searchFocused = false
    }

    private func openFirstMatch() {
        guard tab == .services, !trimmedQuery.isEmpty,
              let first = orderedGroups().flatMap(\.runtimes).first(where: visible) else { return }
        selected = first.id
    }

    /// Esc, typing and opening reach the view through the panel.
    private func listenToPanel() {
        let events = PanelEvents.shared
        events.escape = {
            guard searching, selected == nil, importing == nil else { return false }
            closeSearch()
            return true
        }
        events.typed = { text in
            guard selected == nil, importing == nil else { return false }
            query += text
            openSearch()
            return true
        }
        events.opened = {
            if searching { closeSearch() }
            settleOrder()
        }
        events.openAgent = { openAgentWindow() }
    }

    // MARK: - Menus and coffee mode

    private func stopAllHelp(running: Int, proxies: Int) -> String {
        var parts: [String] = []
        if running > 0 { parts.append(running == 1 ? "the running service" : "the \(running) running services") }
        if proxies > 0 { parts.append(proxies == 1 ? "close the open proxy" : "close the \(proxies) open proxies") }
        return "Stop " + parts.joined(separator: " and ")
    }

    /// Coffee mode keeps the Mac from sleeping while you're away and agents keep working (see `KeepAwake`).
    private func coffeeButton(_ awake: KeepAwake) -> some View {
        Button { awake.toggle() } label: { Image(systemName: "cup.and.saucer") }
            .buttonStyle(IconButtonStyle())
            .help(coffeeHelp(awake))
            .accessibilityLabel("Coffee mode")
            .accessibilityValue("Off")
            .accessibilityAddTraits(.isToggle)
    }

    /// While coffee mode is on: what it covers, for how long, and the way to turn it off.
    private func coffeeStrip(_ awake: KeepAwake, _ t: Theme) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        // `model.now` ticks every 2 s and redraws this; the wall clock keeps it exact.
        let elapsed = awake.since.map { Format.duration(max(model.now, Date()).timeIntervalSince($0)) } ?? ""
        // How long first: it's what changes. The lid's state only when there is a lid.
        let lid: String
        switch awake.lid {
        case .none: lid = ""
        case .asking: lid = LidSleep.grantInstalled ? " · covering the lid…" : " · waiting for your password"
        case .covered: lid = " · lid closed too"
        case .uncovered: lid = " · closing the lid still sleeps"
        }
        return HStack(spacing: 8) {
            Image(systemName: "cup.and.heat.waves.fill")
                .font(.system(size: 11.5, weight: .semibold))
            Text("\(Text("Coffee mode").fontWeight(.semibold)) · \(elapsed)\(lid)")
                .font(.system(size: 12))
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Button("Turn off") { awake.toggle() }
                .buttonStyle(TextButtonStyle(accent: true, size: 11.5))
                .accessibilityLabel("Turn coffee mode off")
        }
        .foregroundStyle(Color.rbLive)
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .frame(height: 32)
        .background(Color.rbLiveSoft, in: shape)
        .help(coffeeHelp(awake))
        .accessibilityElement(children: .contain)
    }

    private func coffeeHelp(_ awake: KeepAwake) -> String {
        guard let since = awake.since else {
            let what = LidSleep.hasLid
                ? "Coffee mode: keep the Mac awake while you're away, lid closed too. The display still turns off and locks."
                : "Coffee mode: keep the Mac awake while you're away. The display still turns off and locks."
            return awake.stopReason.map { "Turned itself off: \($0). \(what)" } ?? what
        }
        let base = "Keeping the Mac awake since \(Format.clock(since))"
        switch awake.lid {
        case .none:
            return "\(base)."
        case .asking:
            return LidSleep.grantInstalled ? "\(base). Turning lid-close sleep off…" : "\(base). Waiting for your password to cover closing the lid too."
        case .covered:
            return "\(base), lid closed too. On battery it stops at \(KeepAwake.batteryFloor)%."
        case .uncovered:
            return "\(base), but closing the lid will still put it to sleep. Turn it off and on to try again."
        }
    }

    /// Everything that used to live in the footer: refresh, config, look, folders and quit. A right click on
    /// the menu bar icon shows the same options (`StatusBarController.optionsMenu`).
    private var moreMenu: some View {
        Menu {
            Button("Refresh") { model.refresh() }
                .keyboardShortcut("r", modifiers: .command)
            Divider()
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
            Toggle("Active projects first", isOn: Binding(
                get: { model.config.settings.activeProjectsFirst },
                set: { model.setActiveProjectsFirst($0) }
            ))
            .disabled(model.configError != nil)
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

    // MARK: - Tiles

    /// Services and Disk are also the tabs: the raised one is the view below.
    private func tiles(_ t: Theme) -> some View {
        let running = model.runningCount
        let proxies = model.openProxyCount
        let live = running + proxies > 0
        let disk = DiskModel.shared
        let diskSize = Format.memory(disk.total).split(separator: " ").map(String.init)
        return HStack(spacing: 8) {
            Button { show(.services) } label: {
                StatTile(label: "Services", value: "\(running)", unit: "of \(model.serviceCount)",
                         accent: proxies > 0 ? "+\(proxies) \(proxies == 1 ? "proxy" : "proxies")" : nil,
                         raised: tab == .services,
                         note: live ? "\(Format.memory(model.totalMemory)) · \(Int(model.totalCPU.rounded()))% CPU" : nil) {
                    MiniBars(values: Metrics.buckets(model.totalHistory(\.memHistory), count: 7).map(\.value), floorAtZero: false, height: 14)
                }
            }
            .buttonStyle(.plain)
            .help("Memory and CPU of everything running")
            .accessibilityAddTraits(tab == .services ? .isSelected : [])
            .accessibilityHint("Show services")
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
        closeSearch()
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

    // MARK: - Needs you

    /// Services with an alert, each with what's wrong and the fix one click away.
    private func needsYou(_ alerts: [ServiceRuntime], _ t: Theme) -> some View {
        let shape = RoundedRectangle(cornerRadius: t.cardRadius, style: .continuous)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11, weight: .semibold))
                Text("Needs you")
                    .font(.system(size: 12.5, weight: .semibold))
                Text("\(alerts.count)")
                    .font(.system(size: 12.5))
                    .monospacedDigit()
                    .foregroundStyle(Color.rbText3)
            }
            .foregroundStyle(Color.rbWarn)
            .padding(.leading, 2)
            .frame(height: 22)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(alerts.enumerated()), id: \.element.id) { index, rt in
                    if index > 0 {
                        Rectangle()
                            .fill(Color.rbWarnBorder)
                            .frame(height: 1)
                            .padding(.leading, 46)
                    }
                    NeedsYouRow(runtime: rt) { selected = rt.id }
                }
            }
            .background(Color.rbWarnSoft, in: shape)
            .overlay(shape.strokeBorder(Color.rbWarnBorder))
        }
    }

    // MARK: - Filter and list

    private func listHeader(_ t: Theme) -> some View {
        let running = model.runningCount
        let proxies = model.openProxyCount
        return HStack(alignment: .center, spacing: 6) {
            SegmentedFilter(selection: $filter, counts: statusCounts()).fixedSize()
            Spacer(minLength: 8)
            if running + proxies > 0 {
                Button { model.stopAllServices() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 7.5, weight: .bold))
                        Text("Stop all")
                    }
                }
                .buttonStyle(TextButtonStyle(size: 11.5))
                .padding(.trailing, -6)
                .help(stopAllHelp(running: running, proxies: proxies))
                .accessibilityLabel("Stop all running services")
            }
        }
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces).lowercased() }

    private var isFiltering: Bool { filter != .all || !trimmedQuery.isEmpty }

    private func matchesQuery(_ rt: ServiceRuntime) -> Bool {
        let q = trimmedQuery
        guard !q.isEmpty else { return true }
        let ports = ([rt.config.port].compactMap { $0 } + rt.listening + (rt.external?.ports ?? [])).map(String.init).joined(separator: " ")
        let tool = rt.config.isProxy ? rt.config.proxyTool.label : ""
        let kind = ServiceKind.of(rt.config).label
        let hay = "\(rt.id) \(rt.config.command) \(rt.config.type.label) \(kind) \(tool) \(rt.config.projectName) \(ports)".lowercased()
        return hay.contains(q)
    }

    private func matchesFilter(_ rt: ServiceRuntime) -> Bool {
        switch filter {
        case .all: return true
        case .running: return rt.isRunningAnywhere
        case .stopped: return !rt.isRunningAnywhere
        }
    }

    private func visible(_ rt: ServiceRuntime) -> Bool { matchesQuery(rt) && matchesFilter(rt) }

    /// How many rows each filter would show, within the search.
    private func statusCounts() -> [StatusFilter: Int] {
        let rows = model.groups.flatMap(\.runtimes).filter(matchesQuery)
        let running = rows.filter(\.isRunningAnywhere).count
        return [.all: rows.count, .running: running, .stopped: rows.count - running]
    }

    /// Services and ports outside Runbar that match the search.
    private var matchCount: Int {
        let q = trimmedQuery
        let others = model.otherListeners.filter { "\($0.port) \($0.name)".lowercased().contains(q) }.count
        return model.groups.flatMap(\.runtimes).filter(matchesQuery).count + others
    }

    /// Projects with something running first (when the setting is on), in the order taken when the panel
    /// opened. Projects added since then go after, in config.json's order.
    private func orderedGroups() -> [ServiceGroup] {
        let groups = model.groups
        guard model.config.settings.activeProjectsFirst, !order.isEmpty else { return groups }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return groups.enumerated()
            .sorted { a, b in
                let ra = rank[a.element.id] ?? Int.max, rb = rank[b.element.id] ?? Int.max
                return ra != rb ? ra < rb : a.offset < b.offset
            }
            .map(\.element)
    }

    private func settleOrder() {
        let groups = model.groups.filter { !$0.isOrphanGroup }
        let active = groups.filter { $0.runtimes.contains(where: \.isRunningAnywhere) }
        let rest = groups.filter { !$0.runtimes.contains(where: \.isRunningAnywhere) }
        // Services no longer in config.json stay last.
        order = (active + rest).map(\.id) + [AppModel.orphanGroupID]
    }

    @ViewBuilder
    private func groupsList(_ t: Theme) -> some View {
        let groups = orderedGroups()
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
            AppMark(size: 36)
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
                        if let job = model.launchdJobs[l.pid] {
                            launchdRow(l, job, t)
                        } else {
                            HStack(spacing: 10) {
                                Pill(text: ":\(l.port)")
                                Text(l.name).font(.system(size: 12)).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(verbatim: "PID \(l.pid)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Color.rbText2)
                                Button("Kill") { model.killOther(pid: l.pid) }
                                    .rbButton(t)
                                    .controlSize(.small)
                            }
                            .frame(height: 34)
                        }
                    }
                }
                .padding(.leading, Layout.rowInset)
                .padding(.trailing, 7)
                .padding(.bottom, 6)
            }
        }
        .rbCard(t)
    }

    /// A port held by a launchd job: Kill would only make launchd start it again, so the row says so and
    /// offers what does work.
    private func launchdRow(_ l: Listener, _ job: LaunchdJob, _ t: Theme) -> some View {
        HStack(spacing: 10) {
            Pill(text: ":\(l.port)")
            VStack(alignment: .leading, spacing: 2) {
                Text(l.name).font(.system(size: 12)).lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: job.keepAlive ? "arrow.clockwise" : "gearshape")
                        .font(.system(size: 9, weight: .semibold))
                    Text(job.keepAlive ? "kept alive by launchd · \(job.label)" : "launchd job · \(job.label)")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.system(size: 11))
                .foregroundStyle(job.keepAlive ? Color.rbWarn : Color.rbText2)
            }
            .help("\(job.label)\(job.plistPath.map { "\n\(Paths.abbreviate($0))" } ?? "")")
            Spacer(minLength: 4)
            Menu {
                Button("Move into Runbar…") { importing = l }
                Button("Turn off (won't start at login)") { model.turnOff(job) }
                if let plist = job.plistPath {
                    Button("Show plist in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: plist)]) }
                }
                Divider()
                Button(job.keepAlive ? "Kill once (launchd starts it again)" : "Kill") { model.killOther(pid: l.pid) }
            } label: {
                HStack(spacing: 4) {
                    Text("Manage")
                    Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .bold))
                }
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .rbButton(t)
            .controlSize(.small)
            .fixedSize()
            .accessibilityLabel("Manage \(l.name) on port \(l.port)")
        }
        .frame(minHeight: 44)
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

// MARK: - Needs you

/// One alert: what runs, what's wrong in a line, the fix, and dismiss. The row opens the service.
private struct NeedsYouRow: View {
    @Environment(AppModel.self) private var model
    let runtime: ServiceRuntime
    let open: () -> Void

    var body: some View {
        let d = model.display(runtime)
        HStack(spacing: 10) {
            Button(action: open) {
                HStack(spacing: 10) {
                    ServiceIcon(config: runtime.config, dot: d.dot, size: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(runtime.id)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                            Text(runtime.config.projectName)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.rbText3)
                                .lineLimit(1)
                        }
                        Text(d.alertLine)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.rbTextDim)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(d.banner ?? d.alertLine)
            .accessibilityLabel("\(runtime.id), \(d.statusLabel): \(d.alertLine)")
            .accessibilityHint("Open details")

            if let fix = primary(d) {
                Button(fix.label, action: fix.action)
                    .buttonStyle(RBButtonStyle(prominent: true, warn: true))
                    .controlSize(.small)
                    .fixedSize()
                    .help(fix.help)
            }
            Button {
                withAnimation(.snappy(duration: 0.2)) { model.dismissAlert(runtime.id) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(Color.rbText2)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(DismissText.help(runtime))
            .accessibilityLabel("Dismiss the alert for \(runtime.id)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(minHeight: 50)
    }

    /// The fix in a word or two; the tooltip says it in full.
    private func primary(_ d: ServiceDisplay) -> (label: String, help: String, action: () -> Void)? {
        if let fix = d.fix, let full = d.fixLabel {
            let label: String
            switch fix {
            case .stopService, .killProcess, .turnOffLaunchd:
                label = (runtime.expectedPort ?? runtime.config.port).map { "Free :\($0)" } ?? "Fix"
            case .signIn: label = "Sign in"
            case .takeOverExternal: label = "Take over"
            case .openNeeds: label = "Open needs"
            }
            return (label, full, { model.perform(fix, for: runtime) })
        }
        if d.action == .retry {
            let help = d.isProxy ? "Try opening \(runtime.id) again" : "Try starting \(runtime.id) again"
            return ("Try again", help, { model.toggle(runtime.id) })
        }
        return ("Details", "Open \(runtime.id)", open)
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
        // Proxies open and close on their own: the header's dots, count and Start all are about services.
        let counted = group.services.isEmpty ? group.runtimes : group.services
        let alive = counted.filter(\.isRunningAnywhere).count
        let allOn = alive == counted.count && alive > 0
        // Services first, then proxies; each proxy says so in its row.
        let ordered = rows.filter { !$0.config.isProxy } + rows.filter { $0.config.isProxy }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Button(action: toggle) {
                    HStack(spacing: 8) {
                        DisclosureChevron(open: isExpanded)
                        Text(group.name)
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)
                        Pips(dots: counted.map { model.display($0).dot })
                            .padding(.leading, 2)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(group.name), \(alive) of \(counted.count) running")
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
            .frame(height: 34)

            if isExpanded && !ordered.isEmpty {
                ForEach(Array(ordered.enumerated()), id: \.element.id) { index, rt in
                    if index > 0 {
                        Rectangle()
                            .fill(Color.rbHairline)
                            .frame(height: 1)
                            .padding(.leading, ServiceRow.inset + Layout.icon + 10)
                    }
                    ServiceRow(runtime: rt) { open(rt.id) }
                }
                .padding(.bottom, 2)
            }
        }
        .rbCard(theme)
    }
}

// MARK: - Service row

/// One line: what it runs, the name, memory (or connections), the port and the action. A second line only
/// when there's something to say that "Needs you" doesn't (waiting, a port in use).
private struct ServiceRow: View {
    static let inset: CGFloat = 10
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let runtime: ServiceRuntime
    let open: () -> Void
    @ViewState private var hover = false

    var body: some View {
        let d = model.display(runtime)
        let stopped = d.dot == .stopped
        let note = secondLine(d)
        HStack(spacing: 8) {
            Button(action: open) {
                HStack(alignment: .center, spacing: 10) {
                    ServiceIcon(config: runtime.config, dot: d.dot)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(runtime.id)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(stopped ? Color.rbTextDim : Color.primary)
                                .lineLimit(1)
                            if d.isProxy { RowTag(text: "proxy", symbol: "arrow.left.arrow.right") }
                            if d.isExternal { RowTag(text: "outside Runbar") }
                        }
                        if let note {
                            Text(note)
                                .font(.system(size: 11))
                                .foregroundStyle(d.warn ? Color.rbWarn : Color.rbText2)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(d.subtitle)
            .accessibilityLabel("\(runtime.id), \(ServiceKind.of(runtime.config).label)\(d.isProxy ? " proxy" : ""), \(d.statusLabel): \(d.subtitle)")
            .accessibilityHint("Open details")

            metric(d)
                .frame(width: 54, alignment: .trailing)

            if let label = d.portLabel {
                if d.isProxy {
                    Pill(text: label, tone: d.warn ? .warn : (runtime.isRunningAnywhere && runtime.phase != .stopping ? .live : .idle))
                        .help(d.url.map { "\($0.absoluteString) · right-click to copy" } ?? "Local port")
                } else if let url = d.url, runtime.phase == .running || d.isExternal {
                    Button { NSWorkspace.shared.open(url) } label: { Pill(text: label, tone: d.warn ? .warn : .live) }
                        .buttonStyle(.plain)
                        .help("Open \(url.absoluteString)")
                } else {
                    Pill(text: label)
                }
            } else {
                Color.clear.frame(width: Layout.pillWidth, height: 1)
            }

            Button { model.toggle(runtime.id) } label: { Image(systemName: d.actionSymbol) }
                .buttonStyle(RowActionButtonStyle(tone: actionTone(d), size: Layout.rowAction))
                .help(actionHelp(d))
                .accessibilityLabel(actionHelp(d))
        }
        .padding(.leading, Self.inset)
        .padding(.trailing, 7)
        .frame(height: note == nil ? Layout.compactRow : Layout.rowHeight)
        .background(hover ? Color.rbControl.opacity(0.6) : Color.clear)
        .onHover { hover = $0 }
        .contextMenu {
            if d.alert {
                Button("Dismiss alert") { model.dismissAlert(runtime.id) }
                    .help(DismissText.help(runtime))
                Divider()
            }
            if d.isProxy, let url = runtime.config.url(port: runtime.expectedPort) {
                Button("Copy \(url.scheme ?? "connection") URL") { Pasteboard.copy(url.absoluteString) }
            }
            Button("Open full log") { NSWorkspace.shared.open(runtime.logURL) }
        }
    }

    /// Alerts say theirs in "Needs you"; this is for what's left: waiting, a port in use, a dismissed alert.
    private func secondLine(_ d: ServiceDisplay) -> String? {
        if runtime.phase == .waiting { return d.subtitle }
        if d.warn && !d.alert { return d.subtitle }
        return nil
    }

    /// Memory, a proxy's connections, or what a service in motion is doing.
    @ViewBuilder
    private func metric(_ d: ServiceDisplay) -> some View {
        let busy: String? = switch runtime.phase {
        case .starting: d.isProxy ? "opening…" : "starting…"
        case .stopping: d.isProxy ? "closing…" : "stopping…"
        default: nil
        }
        if let busy {
            Text(busy)
                .font(.system(size: 11))
                .foregroundStyle(Color.rbText3)
                .lineLimit(1)
        } else if d.isProxy, let connections = d.connections {
            Text("\(connections) conn")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(connections > 0 ? Color.rbText2 : Color.rbText3)
                .lineLimit(1)
                .help(connections == 1 ? "1 connection open through this proxy" : "\(connections) connections open through this proxy")
        } else if let memory = d.memory {
            Text(Format.memory(memory))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.rbText2)
                .lineLimit(1)
                .help("\(Format.memory(memory)) · \(Format.cpu(d.cpu ?? 0)) CPU, the process and its children")
        } else {
            Color.clear.frame(height: 1)
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
        if runtime.phase == .waiting { return "Don't start \(runtime.id)" }
        switch d.action {
        case .start: return d.isProxy ? "Open \(runtime.id)" : "Start \(runtime.id)"
        case .stop: return d.isProxy ? "Close \(runtime.id)" : "Stop \(runtime.id)"
        case .retry: return d.isProxy ? "Try opening \(runtime.id) again" : "Try starting \(runtime.id) again"
        }
    }
}

/// A small label beside a service's name: "proxy", "outside Runbar".
private struct RowTag: View {
    let text: String
    var symbol: String?

    var body: some View {
        HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 7.5, weight: .bold))
            }
            Text(text).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(Color.rbText2)
        .padding(.horizontal, 5)
        .frame(height: 16)
        .background(Color.rbControl, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .fixedSize()
        .accessibilityHidden(true)
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
