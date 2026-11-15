import AppKit
import RunbarCore
import SwiftUI

/// Os dois visuais do app. Mesmo layout; muda material, raio e estilo dos controles.
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

    /// Margem lateral única do painel: cabeçalho, busca, cartões, rótulos e rodapé alinham nela.
    var gutter: CGFloat { glass ? 14 : 12 }
    var cardRadius: CGFloat { glass ? 14 : 8 }
    var controlRadius: CGFloat { glass ? 13 : 6 }
    var logRadius: CGFloat { glass ? 12 : 7 }
}

/// Medidas fixas, para que linhas, botões e pílulas fiquem alinhados em qualquer estado.
enum Layout {
    static let width: CGFloat = 400
    static let rowHeight: CGFloat = 46
    static let rowInset: CGFloat = 12
    static let dot: CGFloat = 8
    static let dotGap: CGFloat = 10
    static let control: CGFloat = 26
    static let pillWidth: CGFloat = 50
    static let metricsWidth: CGFloat = 56
    static let sectionSpacing: CGFloat = 14
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
    /// Laranja de texto que passa contraste nos dois modos.
    static let rbWarn = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1.0, green: 0.71, blue: 0.36, alpha: 1)
            : NSColor(srgbRed: 0.66, green: 0.26, blue: 0.02, alpha: 1)
    })
    static let rbGreen = Color(nsColor: .systemGreen)
    static let rbOrange = Color(nsColor: .systemOrange)
    static let rbLogBackground = Color(nsColor: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1))
    static let rbSeparator = Color(nsColor: .separatorColor)
    /// Cartão sobre vidro: branco translúcido no claro, véu leve no escuro.
    static let rbGlassCard = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.07)
            : NSColor(white: 1, alpha: 0.5)
    })
}

extension View {
    /// Cartão que agrupa linhas (serviços, métricas, comando).
    @ViewBuilder
    func rbCard(_ t: Theme) -> some View {
        let shape = RoundedRectangle(cornerRadius: t.cardRadius, style: .continuous)
        if t.glass {
            self
                .background(Color.rbGlassCard, in: shape)
                .clipShape(shape)
                .overlay(shape.strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
        } else {
            self
                .background(Color(nsColor: .controlBackgroundColor), in: shape)
                .clipShape(shape)
                .overlay(shape.strokeBorder(Color.rbSeparator.opacity(0.8), lineWidth: 1))
        }
    }

    /// Botões de texto: vidro em cápsula no Liquid Glass, bordered no sólido.
    @ViewBuilder
    func rbButton(_ t: Theme, prominent: Bool = false) -> some View {
        if #available(macOS 26, *), t.glass {
            if prominent {
                self.buttonStyle(.glassProminent).buttonBorderShape(.capsule)
            } else {
                self.buttonStyle(.glass).buttonBorderShape(.capsule)
            }
        } else {
            if prominent {
                self.buttonStyle(.borderedProminent)
            } else {
                self.buttonStyle(.bordered)
            }
        }
    }

    /// Fundo do painel: opaco no sólido; no vidro, deixa o material do sistema aparecer.
    @ViewBuilder
    func rbPanel(_ t: Theme) -> some View {
        if t.glass {
            self
        } else {
            self.background(Color(nsColor: .windowBackgroundColor))
        }
    }
}
