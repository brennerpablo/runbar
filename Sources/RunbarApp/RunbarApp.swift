import AppKit
import RunbarCore
import SwiftUI

@main
struct RunbarMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ViewState private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("Configurar com um agente", id: "agent") {
            AgentView()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        let badge: MenuBarIcon.Badge = model.alertCount > 0 ? .alert : (model.isBusy ? .busy : .none)
        let count = model.runningCount
        HStack(spacing: 3) {
            Image(nsImage: MenuBarIcon.image(badge))
            if count > 0 {
                Text("\(count)").monospacedDigit()
            }
        }
        .accessibilityLabel(count == 1 ? "Runbar, 1 serviço rodando" : "Runbar, \(count) serviços rodando")
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
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }
}
