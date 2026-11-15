import AppKit
import RunbarCore
import SwiftUI

/// `Runbar --snapshot <pasta> [id-do-serviço]` desenha o popover fora da tela e salva PNGs.
/// Serve para revisar o visual sem clicar na menu bar. Não abre socket nem mexe em serviços.
@MainActor
enum Snapshotter {
    static func run(into dir: URL, detail: String?) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AppModel.shared
        model.prepareForSnapshot()
        let detailID = detail ?? model.runtimes.values.first(where: \.isRunningAnywhere)?.id
        var written: [String] = []
        for look in [LookSetting.solid, .glass] {
            model.lookOverride = look
            for dark in [false, true] {
                let suffix = "\(look.rawValue)-\(dark ? "dark" : "light")"
                let glass = look == .glass
                written.append(render(backdrop(PopoverView().environment(model), glass: glass, dark: dark), name: "list-\(suffix)", dir: dir, dark: dark))
                if let detailID {
                    written.append(render(backdrop(PopoverView(initialSelection: detailID).environment(model), glass: glass, dark: dark), name: "detail-\(suffix)", dir: dir, dark: dark))
                }
            }
        }
        model.lookOverride = nil
        written.append(render(AgentView().environment(model).frame(width: 881), name: "agent-light", dir: dir, dark: false))
        print(written.joined(separator: "\n"))
        exit(0)
    }

    /// Fora da tela não existe desfoque: no vidro, simula um papel de parede atrás do véu do painel.
    @ViewBuilder
    private static func backdrop<V: View>(_ view: V, glass: Bool, dark: Bool) -> some View {
        if glass {
            view.background {
                ZStack {
                    Color(red: 0.55, green: 0.62, blue: 0.72)
                    Circle().fill(Color(red: 0.61, green: 0.76, blue: 0.93)).frame(width: 420).offset(x: -170, y: -120)
                    Circle().fill(Color(red: 0.96, green: 0.75, blue: 0.6)).frame(width: 460).offset(x: 190, y: 260)
                }
            }
        } else {
            view
        }
    }

    private static func render<V: View>(_ view: V, name: String, dir: URL, dark: Bool) -> String {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 400, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        // Duas passadas de layout: a AdaptiveScroll mede o conteúdo na primeira.
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            let size = host.fittingSize
            window.setContentSize(NSSize(width: max(size.width, 100), height: max(size.height, 100)))
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        let bounds = host.bounds
        guard let rep = host.bitmapImageRepForCachingDisplay(in: bounds) else { return "falhou: \(name)" }
        host.cacheDisplay(in: bounds, to: rep)
        let url = dir.appendingPathComponent("\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        return url.path
    }
}
