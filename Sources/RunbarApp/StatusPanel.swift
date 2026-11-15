import AppKit
import Observation
import RunbarCore
import SwiftUI

/// Ícone na menu bar e o painel que ele abre.
///
/// O painel é nosso, não o do MenuBarExtra: a janela do sistema trazia o próprio vidro e, depois de
/// fechar e abrir, voltava sem os cantos e solta da menu bar. Aqui o formato e o fundo são desenhados
/// pela view, e a posição é recalculada a partir do ícone toda vez que o painel abre.
@MainActor
final class StatusBarController: NSObject {
    static let shared = StatusBarController()

    private var item: NSStatusItem?
    let panel = PanelController()

    func install() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
        self.item = item
        panel.statusButton = item.button
        observe()
    }

    @objc private func clicked() { panel.toggle() }

    /// Redesenha ícone e número sempre que algo que eles mostram muda.
    private func observe() {
        withObservationTracking { render() } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.observe() } }
        }
    }

    private func render() {
        let model = AppModel.shared
        let badge: MenuBarIcon.Badge = model.alertCount > 0 ? .alert : (model.isBusy ? .busy : .none)
        let count = model.runningCount
        guard let button = item?.button else { return }
        button.image = MenuBarIcon.image(badge)
        button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        button.title = count > 0 ? "\(count)" : ""
        button.imagePosition = count > 0 ? .imageLeading : .imageOnly
        button.setAccessibilityLabel(count == 1 ? "Runbar, 1 service running" : "Runbar, \(count) services running")
    }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    /// Distância entre a menu bar e o topo do painel.
    static let gap: CGFloat = 6

    weak var statusButton: NSStatusBarButton?
    private(set) var panel: RunbarPanel?
    private var outsideClick: Any?

    var isOpen: Bool { panel?.isVisible == true }

    /// App que estava na frente quando o painel abriu, para devolver o foco ao fechar com Esc ou no ícone.
    private var previousApp: NSRunningApplication?
    private var resignActive: NSObjectProtocol?

    func toggle() { isOpen ? close(restoreFocus: true) : open() }

    func open() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        place(panel)
        // Com o app ativo, nenhum outro app tira o foco do painel enquanto ele está aberto.
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        if resignActive == nil {
            resignActive = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
        }
        // O botão desmarca sozinho ao soltar o mouse; marca de novo depois que o clique termina.
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isOpen else { return }
                self.statusButton?.highlight(true)
                self.panel?.invalidateShadow()
            }
        }
        if outsideClick == nil {
            outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
        }
    }

    /// `restoreFocus`: fechou por Esc ou pelo ícone, então o foco volta para o app de antes. Num clique
    /// em outro app, quem decide o foco é esse clique.
    func close(restoreFocus: Bool = false) {
        if let outsideClick { NSEvent.removeMonitor(outsideClick) }
        outsideClick = nil
        if let resignActive { NotificationCenter.default.removeObserver(resignActive) }
        resignActive = nil
        statusButton?.highlight(false)
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        let previous = previousApp
        previousApp = nil
        // A janela do agente aberta segura o foco no Runbar.
        let ownWindowOpen = NSApp.windows.contains { $0.isVisible && $0.level == .normal && $0 !== panel }
        guard restoreFocus, NSApp.isActive, !ownWindowOpen else { return }
        if let previous, !previous.isTerminated {
            NSApp.yieldActivation(to: previous)
            previous.activate()
        } else {
            NSApp.hide(nil)
        }
    }

    /// Com o Runbar ativo, perder o foco é a janela do agente abrindo ou o app saindo da frente: fecha.
    /// Sem o Runbar ativo, outro app retomou o foco sem clique do usuário; o painel continua aberto.
    func windowDidResignKey(_ notification: Notification) {
        if NSApp.isActive { close() }
    }

    private func makePanel() -> RunbarPanel {
        let panel = RunbarPanel(
            contentRect: NSRect(x: 0, y: 0, width: Layout.width, height: 400),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.delegate = self
        let root = PopoverView()
            .environment(AppModel.shared)
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self] size in
                MainActor.assumeIsolated { self?.resize(to: size) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        let host = NSHostingView(rootView: root)
        // O tamanho é a gente que aplica (com o topo preso); o hosting view não mexe na janela.
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }

    /// Embaixo do ícone, alinhado pela esquerda dele, sem sair da tela.
    private func place(_ panel: RunbarPanel) {
        guard let itemWindow = statusButton?.window else { return }
        let item = itemWindow.frame
        let visible = (itemWindow.screen ?? NSScreen.main)?.visibleFrame ?? item
        var frame = panel.frame
        frame.origin.x = min(max(item.minX, visible.minX + 8), visible.maxX - frame.width - 8)
        panel.pinnedTop = item.minY - Self.gap
        panel.maxHeight = max(200, item.minY - Self.gap - visible.minY - 8)
        panel.setFrame(frame, display: false)
    }

    /// O conteúdo mudou de altura: a janela acompanha e o topo fica onde está.
    func resize(to size: CGSize) {
        guard let panel, size.width > 0, size.height > 0 else { return }
        let target = CGSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
        guard abs(panel.frame.width - target.width) > 0.5 || abs(panel.frame.height - target.height) > 0.5 else { return }
        panel.setFrame(NSRect(origin: panel.frame.origin, size: target), display: true)
        panel.invalidateShadow()
    }
}

/// Painel sem moldura: o fundo, os cantos e a borda vêm da view (`rbPanel`).
final class RunbarPanel: NSPanel {
    /// Topo fixo na tela; toda mudança de tamanho cresce ou encolhe para baixo.
    var pinnedTop: CGFloat?
    var maxHeight: CGFloat = .greatestFiniteMagnitude

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var frame = frameRect
        frame.size.height = min(frame.height, maxHeight)
        if let pinnedTop { frame.origin.y = pinnedTop - frame.height }
        super.setFrame(frame, display: flag)
    }

    override func cancelOperation(_ sender: Any?) {
        (delegate as? PanelController)?.close(restoreFocus: true)
    }
}
