import AppKit
import RunbarCore
import SwiftUI

@main
struct RunbarMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The menu bar icon and panel live in StatusPanel.swift.
        Window("Set up with an agent", id: "agent") {
            AgentView()
                .environment(AppModel.shared)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        // Without a second scene the Window would be the only one, and the app would quit with the agent window.
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
        #if DEBUG
        if let i = args.firstIndex(of: "--readme-shots"), i + 1 < args.count {
            DemoShots.run(into: URL(fileURLWithPath: args[i + 1], isDirectory: true))
            return
        }
        #endif
        AppModel.shared.start()
        StatusBarController.shared.install()
        // First disk measurement a little after launch, in the background, so the Disk tile has a number.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            MainActor.assumeIsolated { DiskModel.shared.scanIfStale() }
        }
    }

    /// The app lives in the menu bar: closing the panel or the agent window quits nothing.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }
}
