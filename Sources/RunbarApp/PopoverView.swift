import AppKit
import RunbarCore
import SwiftUI

enum StatusFilter: Hashable { case all, running, stopped }

struct PopoverView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @ViewState private var selected: String?
    var initialSelection: String?
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
        .background(MenuBarWindowAnchor())
        .environment(\.theme, theme)
        .onAppear {
            prepareExpanded()
            if selected == nil, let initialSelection { selected = initialSelection }
        }
    }

    // MARK: - Lista

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
                    text: "O config.json tem um erro\(issue.line > 0 ? " na linha \(issue.line), coluna \(issue.column)" : ""): \(issue.message). Continuo usando a última versão válida.",
                    actionLabel: "Abrir no editor", action: { model.openConfigFile() },
                    secondaryLabel: "Copiar erro para o agente",
                    secondary: { Pasteboard.copy(AgentPrompt.fixError(issue)) }
                )
                .padding(.horizontal, t.gutter)
                .padding(.top, 10)
            }
            if model.groups.isEmpty {
                emptyState(t)
                    .padding(.horizontal, t.gutter)
                    .padding(.top, 12)
                    .padding(.bottom, t.gutter)
            } else {
                listHeader(t)
                    .padding(.horizontal, t.gutter)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                ZStack(alignment: .bottom) {
                    AdaptiveScroll(maxHeight: listMaxHeight(alerts: !alerts.isEmpty), holdHeight: isFiltering) {
                        VStack(alignment: .leading, spacing: 8) {
                            groupsList(t)
                            if !model.otherListeners.isEmpty { othersSection(t) }
                        }
                        .padding(.horizontal, t.gutter)
                        // Espaço para a última linha rolar acima da busca flutuante.
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

    /// O painel não passa da altura de um notebook: avisos no topo tiram espaço da lista.
    private func listMaxHeight(alerts: Bool) -> CGFloat {
        500 - (alerts ? 44 : 0) - (model.configError == nil ? 0 : 96)
    }

    private func header(_ t: Theme) -> some View {
        HStack(alignment: .center, spacing: 10) {
            AppMark()
            Text("Runbar")
                .font(.system(size: 15, weight: .semibold))
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(IconButtonStyle())
                    .help("Reler o config.json e atualizar")
                    .accessibilityLabel("Atualizar")
                Menu {
                    Button("Pedir para um agente…") { openAgentWindow() }
                    Button("Editar config.json") { model.openConfigFile() }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.button)
                .buttonStyle(IconButtonStyle())
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Adicionar serviço")
                .accessibilityLabel("Adicionar serviço")
                moreMenu
            }
        }
        .frame(height: Layout.control)
    }

    /// Tudo que morava no rodapé: configuração, visual, pastas e sair.
    private var moreMenu: some View {
        Menu {
            Button("Abrir config.json") { model.openConfigFile() }
            Button("Configurar com agente…") { openAgentWindow() }
            Divider()
            Picker("Visual", selection: Binding(get: { model.config.settings.look }, set: { model.setLook($0) })) {
                Text("Automático").tag(LookSetting.auto)
                Text("Sólido").tag(LookSetting.solid)
                Text("Liquid Glass").tag(LookSetting.glass)
            }
            .disabled(model.configError != nil)
            Toggle("Abrir ao iniciar sessão", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            Divider()
            Button("Instalar comando runbar no Terminal") { _ = model.installCLI() }
            Button("Mostrar pasta da configuração") { model.revealConfigDir() }
            Button("Abrir pasta de logs") { model.openLogsDir() }
            Divider()
            Button("Sair e deixar os serviços rodando") { model.quit(stopServices: false) }
            Button("Sair e parar os serviços") { model.quit(stopServices: true) }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(IconButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Mais opções")
        .accessibilityLabel("Mais opções")
    }

    private func tiles(_ t: Theme) -> some View {
        let running = model.runningCount
        let memory = Format.memory(model.totalMemory).split(separator: " ").map(String.init)
        return HStack(spacing: 8) {
            StatTile(label: "Rodando", value: "\(running)", raised: true, live: running > 0) {
                Text("de \(model.config.services.count)")
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(Color.rbText2)
            }
            StatTile(label: "Memória", value: running > 0 ? (memory.first ?? "—") : "—", unit: running > 0 ? memory.dropFirst().first : nil) {
                MiniBars(values: Metrics.buckets(model.totalHistory(\.memHistory), count: 7).map(\.value), floorAtZero: false)
            }
            StatTile(label: "CPU", value: running > 0 ? "\(Int(model.totalCPU.rounded()))" : "—", unit: running > 0 ? "%" : nil) {
                MiniBars(values: Metrics.buckets(model.totalHistory(\.cpuHistory), count: 7).map(\.value))
            }
        }
    }

    /// Uma linha para o primeiro alerta; o toque abre o serviço.
    private func alertStrip(_ rt: ServiceRuntime, count: Int, _ t: Theme) -> some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        let title = count == 1 ? "1 alerta" : "\(count) alertas"
        return Button { selected = rt.id } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11.5, weight: .semibold))
                Text("\(Text(title).fontWeight(.semibold)) · \(rt.id): \(model.display(rt).subtitle)")
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(Color.rbWarn)
            .padding(.leading, 11)
            .padding(.trailing, 9)
            .frame(height: 34)
            .background(Color.rbWarnSoft, in: shape)
            .overlay(shape.strokeBorder(Color.rbWarnBorder))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title). \(rt.id): \(model.display(rt).subtitle)")
        .accessibilityHint("Abrir detalhes")
    }

    private func listHeader(_ t: Theme) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Text("Serviços")
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

    /// Busca flutuante sobre o fim da lista. ⌘K leva o cursor para ela.
    private func searchBar(_ t: Theme) -> some View {
        let shape = RoundedRectangle(cornerRadius: t.cardRadius, style: .continuous)
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.rbText2)
            TextField("Buscar serviço ou porta", text: $query, prompt: Text("Buscar serviço ou porta").foregroundStyle(Color.rbText3))
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
                .accessibilityLabel("Limpar busca")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: Layout.searchHeight)
        .background(Color.rbSearchField, in: shape)
        .overlay(shape.strokeBorder(Color.rbCardBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 12, y: 6)
        .background {
            // Atalho sem botão visível.
            Button("Buscar") { searchFocused = true }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

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
            Text("Nenhum serviço encontrado.")
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
            Text("Nenhum serviço configurado")
                .font(.system(size: 13.5, weight: .semibold))
            Text("Peça para um agente montar o config.json ou edite o arquivo direto.")
                .font(.system(size: 12))
                .lineSpacing(2)
                .foregroundStyle(Color.rbText2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            HStack(spacing: 8) {
                Button("Configurar com agente…") { openAgentWindow() }.rbButton(t, prominent: true)
                Button("Abrir config.json") { model.openConfigFile() }.rbButton(t)
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 24)
        .padding(.top, 26)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
        .rbCard(t)
    }

    /// Portas ocupadas por processos que não são serviços do Runbar: último cartão da lista.
    private func othersSection(_ t: Theme) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { showOthers.toggle() }
            } label: {
                HStack(spacing: 8) {
                    DisclosureChevron(open: showOthers)
                    let n = model.otherListeners.count
                    Text(n == 1 ? "1 porta em uso fora do Runbar" : "\(n) portas em uso fora do Runbar")
                        .font(.system(size: 12))
                    Spacer()
                }
                .padding(.horizontal, Layout.rowInset)
                .frame(height: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(showOthers ? "Recolher" : "Expandir")

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
                            Button("Encerrar") { model.killOther(pid: l.pid) }
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

    // MARK: - Ajudantes

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

// MARK: - Projeto

/// Um cartão por projeto: cabeçalho com um pontinho por serviço e, aberto, as linhas.
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
                .accessibilityLabel("\(group.name), \(alive) de \(group.runtimes.count) rodando")
                .accessibilityHint(isExpanded ? "Recolher" : "Expandir")

                if !group.isOrphanGroup {
                    Button(allOn ? "Parar todos" : "Iniciar todos") {
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

// MARK: - Linha do serviço

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
            .accessibilityHint("Abrir detalhes")

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
                .help("Memória e CPU do processo e dos filhos")
                .accessibilityElement(children: .combine)
            }

            if let label = d.portLabel {
                if let url = d.url, runtime.phase == .running || d.isExternal {
                    Button { NSWorkspace.shared.open(url) } label: { Pill(text: label, tone: d.warn ? .warn : .live) }
                        .buttonStyle(.plain)
                        .help("Abrir \(url.absoluteString)")
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
        case .start: return "Iniciar \(runtime.id)"
        case .stop: return "Parar \(runtime.id)"
        case .retry: return "Tentar iniciar \(runtime.id) de novo"
        }
    }
}
