import AppKit
import RunbarCore
import SwiftUI

@main
struct RunbarMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // O ícone da menu bar e o painel ficam em StatusPanel.swift.
        Window("Set up with an agent", id: "agent") {
            AgentView()
                .environment(AppModel.shared)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        // Sem uma segunda cena o Window seria a única, e o app fecharia junto com a janela do agente.
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        NSApp.setActivationPolicy(.accessory)
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            Snapshotter.run(into: URL(fileURLWithPath: args[i + 1], isDirectory: true), detail: args.dropFirst(i + 2).first)
            return
        }
        AppModel.shared.start()
        StatusBarController.shared.install()
    }

    /// O app vive na menu bar: fechar o painel ou a janela do agente não encerra nada.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }
}
