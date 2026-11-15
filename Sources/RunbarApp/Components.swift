import AppKit
import RunbarCore
import SwiftUI

struct StatusDot: View {
    let dot: ServiceDisplay.Dot
    var size: CGFloat = Layout.dot

    var body: some View {
        Group {
            switch dot {
            case .running: Circle().fill(Color.rbGreen)
            case .warning, .error: Circle().fill(Color.rbOrange)
            case .busy: Circle().strokeBorder(Color.rbOrange, lineWidth: 1.5)
            case .stopped: Circle().strokeBorder(Color.secondary.opacity(0.7), lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Rótulo de seção: o mesmo estilo em grupos, métricas, comando, pasta e saída.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// Chevron dos grupos que abrem e fecham.
struct DisclosureChevron: View {
    let open: Bool
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 10, height: 10)
            .rotationEffect(.degrees(open ? 90 : 0))
            .accessibilityHidden(true)
    }
}

/// ScrollView que cresce até `maxHeight` e só rola depois disso (o painel acompanha o conteúdo).
struct AdaptiveScroll<Content: View>: View {
    let maxHeight: CGFloat
    /// Enquanto verdadeiro, a área só cresce (filtrar não faz o painel encolher e pular).
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

/// Porta em pílula, com largura fixa para alinhar em coluna.
struct Pill: View {
    let text: String
    var active = false
    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(active ? Color.accentColor : Color.secondary)
            .lineLimit(1)
            .frame(minWidth: Layout.pillWidth, minHeight: 20)
            .padding(.horizontal, 2)
            .background(
                active ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: theme.glass ? 10 : 5, style: .continuous)
            )
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
        let tint = tone == .warning ? Color.rbOrange : Color.accentColor
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(.system(size: 12))
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
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(tone == .warning ? 0.11 : 0.08), in: shape)
        .overlay(shape.strokeBorder(tint.opacity(tone == .warning ? 0.32 : 0.22)))
    }
}

// MARK: - Estilos de botão (com hover; o estado fica numa view interna)

/// Botão quadrado de ação da linha (play/stop), sempre do mesmo tamanho.
struct RowActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowActionBody(configuration: configuration)
    }
}

private struct RowActionBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.theme) private var theme
    @ViewState private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.glass ? Layout.control / 2 : 6, style: .continuous)
        let overlayOpacity = configuration.isPressed ? 0.14 : (hover ? 0.07 : 0)
        configuration.label
            .font(.system(size: 9.5, weight: .bold))
            .frame(width: Layout.control, height: Layout.control)
            .background {
                if theme.glass {
                    shape.fill(Color.primary.opacity(0.08 + overlayOpacity))
                } else {
                    shape.fill(Color(nsColor: .controlBackgroundColor))
                    shape.fill(Color.primary.opacity(overlayOpacity))
                    shape.strokeBorder(Color.rbSeparator, lineWidth: 1)
                }
            }
            .contentShape(shape)
            .onHover { hover = $0 }
    }
}

/// Ícone do cabeçalho (atualizar, adicionar): sem borda, realce no hover.
struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration)
    }
}

private struct IconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.theme) private var theme
    @ViewState private var hover = false

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: Layout.control, height: Layout.control)
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.12 : (hover ? 0.07 : 0)),
                in: RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
            )
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}

/// Texto clicável do rodapé e de ações discretas.
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
            .font(.system(size: size, weight: accent ? .medium : .regular))
            .foregroundStyle(accent ? Color.accentColor : Color.primary)
            .padding(.horizontal, 8)
            .frame(height: Layout.control)
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.12 : (hover ? 0.07 : 0)),
                in: RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
            )
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}

/// Filtro Todos / Rodando / Parados, com a mesma altura do campo de busca.
struct SegmentedFilter: View {
    @Binding var selection: StatusFilter
    @Environment(\.theme) private var theme

    private let options: [(StatusFilter, String)] = [(.all, "Todos"), (.running, "Rodando"), (.stopped, "Parados")]

    var body: some View {
        let outer = RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
        let inner = RoundedRectangle(cornerRadius: theme.glass ? theme.controlRadius - 2 : 4, style: .continuous)
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { option, label in
                let on = selection == option
                Button { selection = option } label: {
                    Text(label)
                        .font(.system(size: 11.5, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.primary : Color.secondary)
                        .padding(.horizontal, 9)
                        .frame(height: Layout.control - 4)
                        .background {
                            if on {
                                inner.fill(theme.glass ? Color.primary.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
                                    .shadow(color: .black.opacity(theme.glass ? 0 : 0.12), radius: 0.5, y: 0.5)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .frame(height: Layout.control)
        .background(Color.primary.opacity(0.06), in: outer)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filtrar por status")
    }
}

enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
