import AppKit
import RunbarCore
import SwiftUI

/// Os dois visuais do app. Mesmo layout e mesmas cores; muda só o fundo do painel (opaco ou vidro).
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

    /// Margem lateral única do painel: cabeçalho, blocos, cartões e busca alinham nela.
    var gutter: CGFloat { 14 }
    var cardRadius: CGFloat { 14 }
    var controlRadius: CGFloat { 9 }
    var buttonRadius: CGFloat { 10 }
    var pillRadius: CGFloat { 8 }
    var logRadius: CGFloat { 12 }
}

/// Medidas fixas, para que linhas, botões e pílulas fiquem alinhados em qualquer estado.
enum Layout {
    static let width: CGFloat = 400
    static let rowHeight: CGFloat = 46
    static let rowInset: CGFloat = 12
    static let dot: CGFloat = 8
    static let dotGap: CGFloat = 10
    static let control: CGFloat = 28
    static let pillWidth: CGFloat = 52
    static let metricsWidth: CGFloat = 56
    static let sectionSpacing: CGFloat = 14
    static let tileHeight: CGFloat = 72
    static let searchHeight: CGFloat = 40
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
    /// Cor que muda entre o modo claro e o escuro.
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

    // Texto: secundário e apagado passam contraste sobre o painel e sobre os cartões.
    static let rbText2 = rb(light: hex(0x454D59), dark: hex(0xB4BBC7))
    static let rbText3 = rb(light: hex(0x555D6A), dark: hex(0xA0A8B5))
    /// Nome de serviço parado: um degrau abaixo do texto principal.
    static let rbTextDim = rb(light: hex(0x2F3742), dark: hex(0xD5DAE2))

    // "No ar": a cor do app. Texto e ícone usam `rbLive`; pontos e barras usam `rbLiveFill`.
    static let rbLive = rb(light: hex(0x086B3C), dark: hex(0x4ADE9A))
    static let rbLiveFill = rb(light: hex(0x17A865), dark: hex(0x4ADE9A))
    static let rbLiveSoft = rb(light: hex(0x17A865, 0.13), dark: hex(0x4ADE9A, 0.14))
    /// Botão principal: fundo verde com texto escuro nos dois modos.
    static let rbPrimary = rb(light: hex(0x3DD68C), dark: hex(0x4ADE9A))
    static let rbOnPrimary = Color(nsColor: hex(0x06281A))

    // Atenção: laranja de texto que passa contraste nos dois modos.
    static let rbWarn = rb(light: hex(0xA84205), dark: hex(0xFFB55C))
    static let rbWarnFill = rb(light: hex(0xF2901F), dark: hex(0xFFB55C))
    static let rbWarnSoft = rb(light: hex(0xFF9500, 0.14), dark: hex(0xFFB55C, 0.13))
    static let rbWarnBorder = rb(light: hex(0xD67800, 0.30), dark: hex(0xFFB55C, 0.27))

    // Superfícies sobre o painel.
    static let rbCardFill = rb(light: white(0.64), dark: white(0.055))
    static let rbCardRaised = rb(light: white(0.90), dark: white(0.10))
    static let rbCardBorder = rb(light: ink(0.07), dark: white(0.07))
    static let rbHairline = rb(light: ink(0.07), dark: white(0.06))
    static let rbControl = rb(light: ink(0.07), dark: white(0.08))
    static let rbControlHover = rb(light: ink(0.12), dark: white(0.15))
    static let rbSegmentOn = rb(light: white(1), dark: white(0.15))
    static let rbRing = rb(light: ink(0.40), dark: white(0.42))
    static let rbBar = rb(light: ink(0.20), dark: white(0.26))
    static let rbSearchField = rb(light: white(0.95), dark: hex(0x323944, 0.94))

    // Painel: opaco no sólido; no vidro, um véu da mesma cor sobre o material do sistema.
    static let rbPanelSolid = rb(light: hex(0xF1F3F6), dark: hex(0x1A1F27))
    static let rbPanelTint = rb(light: hex(0xF0F3F7), dark: hex(0x151A22))

    static let rbLogBackground = Color(nsColor: hex(0x0B0E13))

    // Usadas pela janela do agente.
    static let rbGreen = Color(nsColor: .systemGreen)
    static let rbOrange = Color(nsColor: .systemOrange)
}

extension View {
    /// Cartão que agrupa linhas (projeto, métricas, comando). `raised` é o degrau mais claro.
    func rbCard(_ t: Theme, radius: CGFloat? = nil, raised: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius ?? t.cardRadius, style: .continuous)
        return self
            .background(raised ? Color.rbCardRaised : Color.rbCardFill, in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.rbCardBorder, lineWidth: 1))
    }

    /// Botões de texto. O tamanho vem do `controlSize` (.small ou .regular).
    func rbButton(_ t: Theme, prominent: Bool = false) -> some View {
        buttonStyle(RBButtonStyle(prominent: prominent))
    }

    /// Fundo do painel.
    @ViewBuilder
    func rbPanel(_ t: Theme) -> some View {
        if t.glass {
            self.background(Color.rbPanelTint.opacity(0.55))
        } else {
            self.background(Color.rbPanelSolid)
        }
    }
}

extension Theme {
    /// Cor para onde a lista desbota por baixo da busca flutuante.
    var panelFade: Color { glass ? .rbPanelTint : .rbPanelSolid }
}
