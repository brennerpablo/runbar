import AppKit
import SwiftUI

/// Mantém o painel da menu bar preso no topo quando o conteúdo muda de altura.
///
/// O MenuBarExtra redimensiona a janela mantendo a origem (canto de baixo), então ao encolher
/// a borda de cima desce e o painel se solta da menu bar. Aqui guardamos onde está o topo
/// quando o painel abre e, a cada redimensionamento, movemos a janela de volta para lá.
struct MenuBarWindowAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ nsView: AnchorView, context: Context) {}

    final class AnchorView: NSView {
        private var top: CGFloat?
        private var observers: [NSObjectProtocol] = []
        private var adjusting = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            guard let window else { return }
            top = window.isKeyWindow ? window.frame.maxY : nil
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.repin() }
            })
            // O painel ganha foco já posicionado sob o ícone: esse é o topo certo.
            observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.top = self?.window?.frame.maxY }
            })
            // Fechou: esquece o topo; na próxima abertura o sistema reposiciona.
            observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.top = nil }
            })
        }

        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }

        private func repin() {
            guard let window, let top, !adjusting, window.isVisible, window.isKeyWindow else { return }
            let frame = window.frame
            guard abs(frame.maxY - top) > 0.5 else { return }
            if let screen = window.screen, top > screen.frame.maxY + 1 { return }
            adjusting = true
            window.setFrameOrigin(NSPoint(x: frame.minX, y: top - frame.height))
            adjusting = false
        }
    }
}
