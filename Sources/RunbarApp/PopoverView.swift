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

    var body: some View {
        let theme = model.theme
        VStack(spacing: 0) {
            if let id = selected, let rt = model.runtimes[id] {
                ServiceDetailView(runtime: rt) { selected = nil }
            } else {
                list(theme)
            }
            Divider()
            footer(theme)
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
        VStack(spacing: 0) {
            header(t)
                .padding(.horizontal, t.gutter)
                .padding(.top, 12)
                .padding(.bottom, 10)
            if let issue = model.configError {
                Banner(
                    text: "O config.json tem um erro\(issue.line > 0 ? " na linha \(issue.line), coluna \(issue.column)" : ""): \(issue.message). Continuo usando a última versão válida.",
                    actionLabel: "Abrir no editor", action: { model.openConfigFile() },
                    secondaryLabel: "Copiar erro para o agente",
                    secondary: { Pasteboard.copy(AgentPrompt.fixError(issue)) }
                )
                .padding(.horizontal, t.gutter)
                .padding(.bottom, 10)
            }
            HStack(spacing: 8) {
                searchField(t)
                SegmentedFilter(selection: $filter).fixedSize()
            }
            .padding(.horizontal, t.gutter)
            .padding(.bottom, 10)
            Divider()
            if model.groups.isEmpty {
                emptyState(t)
            } else {
                AdaptiveScroll(maxHeight: model.configError == nil ? 540 : 440, holdHeight: isFiltering) {
                    groupsList(t)
                        .padding(.horizontal, t.gutter)
                        .padding(.bottom, t.gutter)
                }
            }
            if !model.otherListeners.isEmpty {
                Divider()
                othersSection(t)
            }
        }
    }

    private func header(_ t: Theme) -> some View {
        HStack(alignment: .center, spacing: 2) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Serviços").font(.system(size: 14, weight: .semibold))
                Text(model.summary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
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
        }
        // O ícone tem respiro interno; puxa para o glifo alinhar com a borda dos cartões.
        .padding(.trailing, -6)
    }

    private func searchField(_ t: Theme) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            TextField("Buscar serviço ou porta", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Limpar busca")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: Layout.control)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: t.controlRadius, style: .continuous))
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
        VStack(alignment: .leading, spacing: 0) {
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
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            }
        }
    }

    private func emptyState(_ t: Theme) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "server.rack")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            Text("Nenhum serviço configurado")
                .font(.system(size: 13.5, weight: .semibold))
            Text("Peça para um agente montar o config.json ou edite o arquivo direto.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                Button("Configurar com agente…") { openAgentWindow() }.rbButton(t, prominent: true)
                Button("Abrir config.json") { model.openConfigFile() }.rbButton(t)
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, t.gutter + 12)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
    }

    private func othersSection(_ t: Theme) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { showOthers.toggle() }
            } label: {
                HStack(spacing: 6) {
                    DisclosureChevron(open: showOthers)
                    let n = model.otherListeners.count
                    Text(n == 1 ? "1 porta em uso fora do Runbar" : "\(n) portas em uso fora do Runbar")
                        .font(.system(size: 12))
                    Spacer()
                }
                .frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, t.gutter)
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
                                .foregroundStyle(.secondary)
                            Button("Encerrar") { model.killOther(pid: l.pid) }
                                .rbButton(t)
                                .controlSize(.small)
                        }
                        .frame(height: 32)
                    }
                }
                .padding(.leading, t.gutter + 16)
                .padding(.trailing, t.gutter)
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Rodapé

    private func footer(_ t: Theme) -> some View {
        HStack(spacing: 0) {
            Button("Abrir config.json") { model.openConfigFile() }
            Button("Configurar com agente…") { openAgentWindow() }
            Spacer(minLength: 4)
            Menu {
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
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(IconButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Mais opções")
            Button("Sair") { model.quit(stopServices: true) }
                .help("Sai e para todos os serviços")
        }
        .buttonStyle(TextButtonStyle())
        // Os botões de texto têm 8 de respiro: o texto fica na mesma margem do resto.
        .padding(.horizontal, t.gutter - 8)
        .frame(height: 42)
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

// MARK: - Grupo

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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button(action: toggle) {
                    HStack(spacing: 6) {
                        DisclosureChevron(open: isExpanded)
                        SectionLabel(text: group.name)
                        Text("\(alive)/\(group.runtimes.count)")
                            .font(.system(size: 10.5, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .frame(height: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(group.name), \(alive) de \(group.runtimes.count) rodando")
                .accessibilityHint(isExpanded ? "Recolher" : "Expandir")

                if !group.isOrphanGroup {
                    Button(allOn ? "Parar todos" : "Iniciar todos") {
                        if allOn { model.stopAll(group) } else { model.startAll(group) }
                    }
                    .buttonStyle(TextButtonStyle(accent: true, size: 11.5))
                    .padding(.trailing, -8)
                }
            }

            if isExpanded && !rows.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, rt in
                        if index > 0 {
                            Divider().padding(.leading, Layout.rowInset + Layout.dot + Layout.dotGap)
                        }
                        ServiceRow(runtime: rt) { open(rt.id) }
                    }
                }
                .rbCard(theme)
            }
        }
        .padding(.top, 10)
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
        HStack(spacing: 10) {
            Button(action: open) {
                HStack(alignment: .top, spacing: Layout.dotGap) {
                    StatusDot(dot: d.dot).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(runtime.id)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(d.subtitle)
                            .font(d.subtitleMono ? .system(size: 10.5, design: .monospaced) : .system(size: 11))
                            .foregroundStyle(d.warn ? Color.rbWarn : Color.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
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
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .frame(width: Layout.metricsWidth, alignment: .trailing)
                .help("Memória e CPU do processo e dos filhos")
                .accessibilityElement(children: .combine)
            }

            if let label = d.portLabel {
                if let url = d.url, runtime.phase == .running || d.isExternal {
                    Button { NSWorkspace.shared.open(url) } label: { Pill(text: label, active: true) }
                        .buttonStyle(.plain)
                        .help("Abrir \(url.absoluteString)")
                } else {
                    Pill(text: label)
                }
            }

            Button { model.toggle(runtime.id) } label: { Image(systemName: d.actionSymbol) }
                .buttonStyle(RowActionButtonStyle())
                .foregroundStyle(d.action == .stop ? Color.primary : Color.accentColor)
                .help(actionHelp(d))
                .accessibilityLabel(actionHelp(d))
        }
        .padding(.leading, Layout.rowInset)
        .padding(.trailing, Layout.rowInset - 2)
        .frame(height: Layout.rowHeight)
        .background(hover ? Color.primary.opacity(0.04) : Color.clear)
        .onHover { hover = $0 }
    }

    private func actionHelp(_ d: ServiceDisplay) -> String {
        switch d.action {
        case .start: return "Iniciar \(runtime.id)"
        case .stop: return "Parar \(runtime.id)"
        case .retry: return "Tentar iniciar \(runtime.id) de novo"
        }
    }
}
