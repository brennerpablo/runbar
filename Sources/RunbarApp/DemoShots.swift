#if DEBUG
import AppKit
import RunbarCore
import SwiftUI

/// `RunbarApp --readme-shots <dir>` draws the README's screenshots from made-up projects, services
/// and disk usage (nothing is read from this Mac), light and dark, at 2x. `make screenshots` runs it.
@MainActor
enum DemoShots {
    static func run(into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AppModel.shared
        load(model)
        var written: [String] = []
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            DiskModel.shared.confirming = nil
            written.append(render(hero(model), name: "hero-\(suffix)", dir: dir, dark: dark))
            written.append(render(framed(PopoverView(initialSelection: "elrond-app", fixedHeight: panelHeight).environment(model), dark: dark), name: "conflict-\(suffix)", dir: dir, dark: dark))
            written.append(render(framed(PopoverView(initialSelection: "saruman-db", fixedHeight: panelHeight).environment(model), dark: dark), name: "outside-\(suffix)", dir: dir, dark: dark))
            DiskModel.shared.confirming = Self.path("fellowship/gandalf-app/node_modules")
            written.append(render(framed(PopoverView(initialTab: .disk, initialQuery: "node_modules", fixedHeight: panelHeight).environment(model), dark: dark), name: "reinstall-\(suffix)", dir: dir, dark: dark))
            DiskModel.shared.confirming = nil
            written.append(render(framed(agentWindow(model), dark: dark, radius: 12), name: "agent-\(suffix)", dir: dir, dark: dark))
        }
        print(written.joined(separator: "\n"))
        exit(0)
    }

    /// `--panel-shots <dir>`: the same views alone on a transparent background (dark), shadow included,
    /// for pages that draw their own backdrop (the landing page at runbar.pbrenner.com).
    static func runPanels(into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AppModel.shared
        load(model)
        func alone<V: View>(_ view: V, radius: CGFloat? = nil) -> some View { panel(view, radius: radius).padding(48) }
        var written: [String] = []
        DiskModel.shared.confirming = nil
        written.append(render(alone(PopoverView().environment(model)), name: "panel-list", dir: dir, dark: true))
        written.append(render(alone(PopoverView(initialSelection: "gandalf-app").environment(model)), name: "panel-detail", dir: dir, dark: true))
        written.append(render(alone(PopoverView(initialTab: .disk).environment(model)), name: "panel-disk", dir: dir, dark: true))
        written.append(render(alone(PopoverView(initialSelection: "elrond-app").environment(model)), name: "panel-conflict", dir: dir, dark: true))
        written.append(render(alone(PopoverView(initialSelection: "saruman-db").environment(model)), name: "panel-outside", dir: dir, dark: true))
        DiskModel.shared.confirming = Self.path("fellowship/gandalf-app/node_modules")
        written.append(render(alone(PopoverView(initialTab: .disk, initialQuery: "node_modules").environment(model)), name: "panel-reinstall", dir: dir, dark: true))
        DiskModel.shared.confirming = nil
        written.append(render(alone(agentWindow(model), radius: 12), name: "panel-agent", dir: dir, dark: true))
        written.append(render(alone(PopoverView(initialSelection: "boromir-db").environment(model)), name: "panel-proxy", dir: dir, dark: true))
        written.append(render(alone(PopoverView(initialSelection: "bilbo-db").environment(model)), name: "panel-proxy-closed", dir: dir, dark: true))
        written.append(render(alone(PopoverView(initialQuery: "6379", initialShowOthers: true).environment(model)), name: "panel-launchd", dir: dir, dark: true))
        if let redis = model.otherListeners.first(where: { $0.port == 6379 }) {
            written.append(render(alone(PopoverView(initialImport: redis).environment(model)), name: "panel-import", dir: dir, dark: true))
        }
        KeepAwake.shared.showForDemo(since: Date().addingTimeInterval(-(2 * 3600 + 14 * 60)), screenOn: true)
        written.append(render(alone(PopoverView().environment(model)), name: "panel-coffee", dir: dir, dark: true))
        KeepAwake.shared.showForDemo(since: nil)
        written += clipFrames(model, into: dir, alone: { AnyView(alone($0)) })
        print(written.joined(separator: "\n"))
        exit(0)
    }

    /// The landing page's clips: the moments between the shots above, from the same data, so that from one frame
    /// to the next only what the click changed changes. Drawn last, they leave the shots above as they were.
    private static func clipFrames(_ model: AppModel, into dir: URL, alone: (AnyView) -> AnyView) -> [String] {
        let now = demoNow
        let rt = model.runtimes
        var written: [String] = []
        func shot(_ view: some View, _ name: String) {
            written.append(render(alone(AnyView(view.environment(model))), name: name, dir: dir, dark: true))
        }

        // Services: ▶ on gimli-admin, starting, then running on :3001.
        rt["gimli-admin"]?.loadDemo(phase: .starting, pid: 61204, startedAt: now.addingTimeInterval(-1), lastLogAt: now, memoryMB: 52, cpu: 31,
                                   processCount: 2, at: now, logs: ["> pnpm dev --port 3001"])
        shot(PopoverView(), "clip-start-starting")
        rt["gimli-admin"]?.loadDemo(phase: .running, pid: 61204, startedAt: now.addingTimeInterval(-4), lastLogAt: now, memoryMB: 274, cpu: 4.6,
                                   processCount: 3, listening: [3001], at: now,
                                   logs: ["> pnpm dev --port 3001", "   ▲ Next.js 16.0.3 (Turbopack)", " ✓ Ready in 1.9s"])
        shot(PopoverView(), "clip-start-running")
        rt["gimli-admin"]?.loadDemo(phase: .stopped, at: now)

        // Disk, before anything below changes the header: the filtered list, Reinstall's confirmation (panel-reinstall),
        // then the reinstall under way.
        let modules = path("fellowship/gandalf-app/node_modules")
        DiskModel.shared.confirming = nil
        shot(PopoverView(initialTab: .disk, initialQuery: "node_modules"), "clip-disk-filtered")
        if let item = DiskModel.shared.projects.flatMap(\.items).first(where: { $0.id == modules }) {
            DiskModel.shared.loadDemoJob(DiskJob(item: item, action: .reinstall, services: ["gandalf-app"], step: .installing,
                                                 stepStartedAt: Date().addingTimeInterval(-9), startedAt: Date().addingTimeInterval(-14),
                                                 lastLine: "added 1184 packages, and audited 1185 packages in 9s"))
            shot(PopoverView(initialTab: .disk, initialQuery: "node_modules"), "clip-disk-installing")
            DiskModel.shared.loadDemoJob(nil)
        }

        // Ports: "Kill node and restart this one", then elrond-app back on :3100.
        let listeners = model.otherListeners.filter { $0.port != 3100 }
        model.loadDemo(config: model.config, now: now, portOwners: [:], otherListeners: listeners, launchdJobs: model.launchdJobs)
        rt["elrond-app"]?.loadDemo(phase: .starting, pid: 61377, startedAt: now.addingTimeInterval(-1), lastLogAt: now, memoryMB: 88, cpu: 38,
                                  processCount: 2, at: now, logs: ["> next dev -p 3100"])
        shot(PopoverView(initialSelection: "elrond-app"), "clip-port-starting")
        rt["elrond-app"]?.loadDemo(phase: .running, pid: 61377, startedAt: now.addingTimeInterval(-5), lastLogAt: now, memoryMB: 341, cpu: 2.2,
                                  processCount: 3, listening: [3100],
                                  memHistoryMB: (0..<120).map { i in 330 + Double((i * 7) % 11) * 2 },
                                  cpuSeries: (0..<120).map { i in 1 + Double((i * 3) % 4) * 0.5 }, at: now,
                                  logs: ["   ▲ Next.js 16.0.3 (Turbopack)", "   - Local:        http://localhost:3100", " ✓ Ready in 1.2s"])
        shot(PopoverView(initialSelection: "elrond-app"), "clip-port-fixed")

        // Proxies: boromir-db closed with aragorn-api stopped; starting aragorn-api opens it first.
        rt["aragorn-api"]?.loadDemo(phase: .stopped, exitedAt: now.addingTimeInterval(-13 * 60), exitCode: 0, at: now)
        rt["boromir-db"]?.loadDemo(phase: .stopped, exitedAt: now.addingTimeInterval(-60), exitCode: 0, at: now,
                                logs: ["── Runbar · Nov 12 2026 10:40:00 · closed after 15 min with no connections"])
        rt["boromir-db"]?.loadDemoUsage(closedIdleAt: now.addingTimeInterval(-60))
        shot(PopoverView(initialSelection: "boromir-db"), "clip-proxy-closed")
        shot(PopoverView(), "clip-proxy-list-closed")
        rt["aragorn-api"]?.loadDemo(phase: .waiting, at: now, waitingFor: ["boromir-db"])
        rt["boromir-db"]?.loadDemo(phase: .starting, pid: 61450, startedAt: now.addingTimeInterval(-1), lastLogAt: now, memoryMB: 12, cpu: 8,
                                processCount: 1, at: now, logs: ["2026/11/12 10:41:02 Authorizing with Application Default Credentials"])
        rt["boromir-db"]?.loadDemoUsage(heldBy: ["aragorn-api"])
        shot(PopoverView(), "clip-proxy-list-opening")
        rt["boromir-db"]?.loadDemo(phase: .running, pid: 61450, startedAt: now.addingTimeInterval(-3), lastLogAt: now, memoryMB: 17, cpu: 0.4,
                                processCount: 1, listening: [5434], at: now,
                                logs: [
                                    "── Runbar · Nov 12 2026 10:41:02 · opened for aragorn-api",
                                    "2026/11/12 10:41:02 Authorizing with Application Default Credentials",
                                    "2026/11/12 10:41:03 [fellowship-prod:us-central1:fellowship] Listening on 127.0.0.1:5434",
                                    "2026/11/12 10:41:03 The proxy has started successfully and is ready for new connections!",
                                    "2026/11/12 10:41:04 [fellowship-prod:us-central1:fellowship] Accepted connection from 127.0.0.1:64110",
                                ])
        rt["aragorn-api"]?.loadDemo(phase: .running, pid: 61461, startedAt: now.addingTimeInterval(-1), lastLogAt: now, memoryMB: 162, cpu: 6.1,
                                 processCount: 2, listening: [8000], at: now, logs: ["INFO:     Application startup complete."])
        rt["boromir-db"]?.loadDemoUsage(clients: [ProxyClient(id: "aragorn-api", name: "aragorn-api", serviceID: "aragorn-api", pid: 61461, connections: 1)],
                                     heldBy: ["aragorn-api"])
        shot(PopoverView(), "clip-proxy-list-open")
        shot(PopoverView(initialSelection: "boromir-db"), "clip-proxy-open")

        return written
    }

    // MARK: - Layouts

    /// Every panel in the README's shots is this tall, whatever it shows: side by side, and from one
    /// shot to the next, they're the same window.
    private static let panelHeight: CGFloat = 740

    /// The three main views side by side: services, a running service, disk.
    private static func hero(_ model: AppModel) -> some View {
        HStack(alignment: .top, spacing: 36) {
            panel(PopoverView(fixedHeight: panelHeight).environment(model))
            panel(PopoverView(initialSelection: "gandalf-app", fixedHeight: panelHeight).environment(model))
            panel(PopoverView(initialTab: .disk, fixedHeight: panelHeight).environment(model))
        }
        .padding(56)
        .background(Wallpaper())
    }

    private static func framed<V: View>(_ view: V, dark: Bool, radius: CGFloat? = nil) -> some View {
        panel(view, radius: radius)
            .padding(40)
            .background(Wallpaper())
    }

    private static func panel<V: View>(_ view: V, radius: CGFloat? = nil) -> some View {
        Group {
            if let radius {
                view.clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            } else {
                view
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 30, y: 22)
        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
    }

    private static func agentWindow(_ model: AppModel) -> some View {
        AgentView()
            .environment(model)
            .frame(width: 881)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Real wallpapers behind the panels, from the image files in `WALLPAPER_LIGHT` and `WALLPAPER_DARK`
    /// (`make screenshots` passes them on; one alone serves both looks). Without them, `Wallpaper` draws one.
    private static let wallpapers: (light: NSImage?, dark: NSImage?) = {
        let env = ProcessInfo.processInfo.environment
        let light = env["WALLPAPER_LIGHT"].flatMap { NSImage(contentsOfFile: Paths.expand($0)) }
        let dark = env["WALLPAPER_DARK"].flatMap { NSImage(contentsOfFile: Paths.expand($0)) }
        return (light ?? dark, dark ?? light)
    }()

    /// A desktop behind the panels: the wallpaper given, or else dusk in dark mode and a clear sky in light mode.
    private struct Wallpaper: View {
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            GeometryReader { geo in
                let size = geo.size
                if let image = scheme == .dark ? DemoShots.wallpapers.dark : DemoShots.wallpapers.light {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size.width, height: size.height)
                        .clipped()
                } else {
                    drawn(size)
                }
            }
        }

        private func drawn(_ size: CGSize) -> some View {
            ZStack {
                if scheme == .dark {
                    LinearGradient(colors: [rgb(0x172635), rgb(0x1F3446), rgb(0x2B4658)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    RadialGradient(colors: [rgb(0xECCE9E).opacity(0.85), rgb(0xD6AA80).opacity(0.4), .clear],
                                   center: UnitPoint(x: 0.05, y: 1.05), startRadius: 0, endRadius: max(size.width, size.height) * 0.55)
                    RadialGradient(colors: [rgb(0x568CA8).opacity(0.5), .clear],
                                   center: UnitPoint(x: 1.05, y: 0.05), startRadius: 0, endRadius: max(size.width, size.height) * 0.5)
                } else {
                    LinearGradient(colors: [rgb(0x8FB9E0), rgb(0xC3D9EE), rgb(0xECEFF3)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    RadialGradient(colors: [rgb(0xFFD6AA).opacity(0.9), .clear],
                                   center: UnitPoint(x: 0.08, y: 1.02), startRadius: 0, endRadius: max(size.width, size.height) * 0.55)
                }
            }
        }

        private func rgb(_ hex: UInt32) -> Color {
            Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
        }
    }

    // MARK: - Rendering

    private static func render<V: View>(_ view: V, name: String, dir: URL, dark: Bool) -> String {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 400, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        // A few layout passes: AdaptiveScroll measures its content on the first one.
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            let size = host.fittingSize
            window.setContentSize(NSSize(width: max(size.width, 100), height: max(size.height, 100)))
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        let bounds = host.bounds
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return "failed: \(name)" }
        rep.size = bounds.size
        host.cacheDisplay(in: bounds, to: rep)
        let url = dir.appendingPathComponent("\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        return url.path
    }

    // MARK: - The made-up machine

    static func path(_ relative: String) -> String { Paths.expand("~/Developer/" + relative) }

    private static let config = """
    {
      "version": 1,
      "projects": {
        "fellowship": { "name": "Fellowship", "root": "~/Developer/fellowship", "services": {
          "gandalf-app": { "cwd": "gandalf-app", "type": "nextjs", "command": "npm run dev -- -p {port}", "port": 3000 },
          "aragorn-api": { "cwd": "aragorn-api", "type": "python", "command": ".venv/bin/uvicorn app.main:app --reload --port {port}", "port": 8000, "open": "http://localhost:{port}/docs", "needs": ["boromir-db"] },
          "legolas-worker": { "cwd": "legolas-worker", "type": "node", "command": "npm run worker" },
          "gimli-admin": { "cwd": "gimli-admin", "type": "nextjs", "command": "pnpm dev --port {port}", "port": 3001 },
          "boromir-db": { "type": "proxy", "command": "cloud-sql-proxy --port {port} fellowship-prod:us-central1:fellowship", "port": 5434, "open": "postgres://localhost:{port}/fellowship" }
        }},
        "rivendell": { "name": "Rivendell", "root": "~/Developer/rivendell", "services": {
          "elrond-app": { "cwd": "elrond-app", "type": "nextjs", "command": "npm run dev -- -p {port}", "port": 3100 },
          "arwen-docs": { "cwd": "arwen-docs", "type": "nextjs", "command": "npm run dev -- -p {port}", "port": 3101 },
          "bilbo-db": { "type": "proxy", "command": "kubectl port-forward svc/postgres {port}:5432", "port": 5435 }
        }},
        "mordor": { "name": "Mordor", "root": "~/Developer/mordor", "services": {
          "sauron-api": { "cwd": "api", "type": "python", "command": ".venv/bin/uvicorn main:app --reload --port {port}", "port": 8100 },
          "saruman-db": { "cwd": "db", "type": "docker", "command": "docker compose up", "stop": "docker compose down", "port": 5433 }
        }},
        "shire": { "name": "The Shire", "root": "~/Developer/shire", "services": {
          "frodo-site": { "cwd": "frodo-site", "type": "node", "command": "npm run dev -- --port {port}", "port": 4321 }
        }}
      }
    }
    """

    /// The made-up machine's clock: Nov 12 2026, 10:41.
    private static var demoNow: Date {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 11; parts.day = 12; parts.hour = 10; parts.minute = 41
        return Calendar.current.date(from: parts) ?? Date()
    }

    private static func load(_ model: AppModel) {
        guard let cfg = ConfigLoader.load(data: Data(config.utf8)).config else { fatalError("demo config doesn't parse") }
        let now = demoNow
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func series(_ n: Int, _ f: (Int) -> Double) -> [Double] { (0..<n).map(f) }

        model.loadDemo(
            config: cfg, now: now,
            portOwners: [3100: PortOwner(pid: 4821, name: "node", serviceID: nil)],
            otherListeners: [
                Listener(port: 3100, pid: 4821, name: "node", path: "/opt/homebrew/bin/node"),
                Listener(port: 5432, pid: 612, name: "postgres", path: "/opt/homebrew/bin/postgres"),
                Listener(port: 6379, pid: 640, name: "redis-server", path: "/opt/homebrew/bin/redis-server"),
            ],
            launchdJobs: [
                640: LaunchdJob(label: "homebrew.mxcl.redis", pid: 640, plistPath: Paths.home + "/Library/LaunchAgents/homebrew.mxcl.redis.plist",
                                keepAlive: true, runAtLoad: true, programArguments: ["/opt/homebrew/opt/redis/bin/redis-server", "/opt/homebrew/etc/redis.conf"]),
            ]
        )
        let rt = model.runtimes
        rt["gandalf-app"]?.loadDemo(
            phase: .running, pid: 48213, startedAt: ago(149), lastLogAt: now.addingTimeInterval(-3), memoryMB: 412, cpu: 3.1,
            processCount: 3, listening: [3000],
            memHistoryMB: series(120) { i in 300 + Double(i % 48) * 2.2 + Double(i) * 0.25 },
            cpuSeries: series(120) { i in i % 37 == 20 ? 46 : (i % 13 == 5 ? 18 : 2.5 + Double((i * 5) % 7)) },
            at: now,
            logs: [
                "── Runbar · Nov 12 2026 08:12:04 · npm run dev -- -p 3000 · in ~/Developer/fellowship/gandalf-app",
                "> gandalf-app@0.1.0 dev",
                "> next dev -p 3000",
                "   ▲ Next.js 16.0.3 (Turbopack)",
                "   - Local:        http://localhost:3000",
                " ✓ Ready in 1.4s",
                " ○ Compiling /products ...",
                " ✓ Compiled /products in 2.1s",
                " GET /products 200 in 2318ms",
                " GET /api/cart 200 in 42ms",
                " ⚠ Fast Refresh had to perform a full reload",
                " GET /products/aurora-lamp 200 in 96ms",
            ]
        )
        rt["aragorn-api"]?.loadDemo(
            phase: .running, pid: 48230, startedAt: ago(149), lastLogAt: now.addingTimeInterval(-41), memoryMB: 186, cpu: 0.6,
            processCount: 2, listening: [8000],
            memHistoryMB: series(120) { i in 180 + Double((i * 7) % 9) }, cpuSeries: series(120) { i in 0.3 + Double((i * 3) % 5) * 0.1 }, at: now,
            logs: ["INFO:     Application startup complete.", "INFO:     127.0.0.1:52811 - \"GET /orders?limit=20 HTTP/1.1\" 200 OK"]
        )
        rt["legolas-worker"]?.loadDemo(
            phase: .running, pid: 48251, startedAt: ago(148), lastLogAt: now.addingTimeInterval(-12), memoryMB: 96, cpu: 0.2,
            processCount: 1, memHistoryMB: series(120) { i in 92 + Double(i % 5) }, cpuSeries: series(120) { _ in 0.2 }, at: now,
            logs: ["[worker] sent 3 order confirmation emails"]
        )
        rt["elrond-app"]?.loadDemo(
            phase: .running, pid: 51877, startedAt: ago(38), lastLogAt: now.addingTimeInterval(-6), memoryMB: 356, cpu: 1.8,
            processCount: 3, listening: [3102],
            memHistoryMB: series(120) { i in 330 + Double((i * 7) % 11) * 2 }, cpuSeries: series(120) { i in 1 + Double((i * 3) % 4) * 0.5 }, at: now,
            logs: [" ⚠ Port 3100 is in use, trying 3102 instead.", "   - Local:        http://localhost:3102", " ✓ Ready in 1.1s"]
        )
        rt["arwen-docs"]?.loadDemo(
            phase: .starting, pid: 52010, startedAt: now.addingTimeInterval(-9), lastLogAt: now.addingTimeInterval(-2), memoryMB: 64, cpu: 12,
            processCount: 2, at: now, logs: ["> next dev -p 3101"]
        )
        rt["sauron-api"]?.loadDemo(
            phase: .crashed(1), exitedAt: ago(6), exitCode: 1, at: now,
            logs: [
                "Traceback (most recent call last):",
                "  File \"/Users/you/Developer/mordor/api/main.py\", line 3, in <module>",
                "ModuleNotFoundError: No module named 'httpx'",
            ]
        )
        rt["saruman-db"]?.loadDemo(
            phase: .stopped, at: now,
            external: ExternalRun(rootPID: 7712, pids: [7712, 7720], ports: [5433], memory: 220 * 1_048_576, cpu: 0.4,
                                  startedAt: now.addingTimeInterval(-16 * 3600 - 39 * 60))
        )
        rt["frodo-site"]?.loadDemo(phase: .stopped, exitedAt: ago(130), exitCode: 0, at: now)
        rt["boromir-db"]?.loadDemo(
            phase: .running, pid: 48202, startedAt: ago(149), lastLogAt: ago(3), memoryMB: 18, cpu: 0.1, processCount: 1, listening: [5434], at: now,
            logs: [
                "── Runbar · Nov 12 2026 08:12:01 · cloud-sql-proxy --port 5434 fellowship-prod:us-central1:fellowship · in ~/Developer/fellowship",
                "2026/11/12 08:12:01 Authorizing with Application Default Credentials",
                "2026/11/12 08:12:02 [fellowship-prod:us-central1:fellowship] Listening on 127.0.0.1:5434",
                "2026/11/12 08:12:02 The proxy has started successfully and is ready for new connections!",
                "2026/11/12 08:12:09 [fellowship-prod:us-central1:fellowship] Accepted connection from 127.0.0.1:61022",
                "2026/11/12 10:38:47 [fellowship-prod:us-central1:fellowship] Accepted connection from 127.0.0.1:63518",
            ]
        )
        rt["boromir-db"]?.loadDemoUsage(
            clients: [
                ProxyClient(id: "aragorn-api", name: "aragorn-api", serviceID: "aragorn-api", pid: 48230, connections: 3),
                ProxyClient(id: "pid-61022", name: "psql", serviceID: nil, pid: 61022, connections: 1),
            ],
            heldBy: ["aragorn-api"]
        )
        rt["bilbo-db"]?.loadDemo(phase: .stopped, exitedAt: ago(12), exitCode: 0, at: now,
                                 logs: ["── Runbar · Nov 12 2026 10:29:00 · closed after 15 min with no connections"])
        rt["bilbo-db"]?.loadDemoUsage(closedIdleAt: ago(12))

        let gb: (Double) -> UInt64 = { UInt64($0 * 1_073_741_824) }
        let mb: (Double) -> UInt64 = { UInt64($0 * 1_048_576) }
        func item(_ project: String, _ folder: String, _ name: String, _ category: DiskCategory, _ bytes: UInt64, service: String? = nil,
                  worktree: Bool = false, install: String? = nil, source: String? = nil, detail: String? = nil) -> DiskItem {
            let parent = path("\(project)/\(folder)")
            return DiskItem(id: parent + "/" + name, name: name, category: category, paths: [parent + "/" + name], bytes: bytes,
                            folder: folder, parent: parent, serviceID: service, worktree: worktree,
                            install: install, installSource: source, detail: detail)
        }
        func tools(_ project: String, _ folder: String, _ names: [String], _ bytes: UInt64) -> DiskItem {
            DiskItem(id: "\(project)#tools", name: "Tool caches", category: .tools, paths: names.map { path("\(project)/\(folder)/\($0)") },
                     bytes: bytes, folder: "", parent: path(project), detail: "\(names.count) folders")
        }
        let venv = { (python: String) in "/opt/homebrew/opt/python@\(python)/bin/python3 -m venv .venv && .venv/bin/pip install -r requirements.txt" }
        DiskModel.shared.loadDemo(
            projects: [
                ProjectDisk(id: "fellowship", name: "Fellowship", root: path("fellowship"), items: [
                    item("fellowship", "gandalf-app", ".next", .build, gb(18.4), service: "gandalf-app"),
                    item("fellowship", "gimli-admin", ".next", .build, gb(2.1), service: "gimli-admin"),
                    item("fellowship", "gandalf-app", "node_modules", .dependencies, gb(1.24), service: "gandalf-app", install: "npm ci", source: "package-lock.json"),
                    item("fellowship", "wt-checkout-redesign", "node_modules", .dependencies, gb(1.18), worktree: true, install: "npm ci", source: "package-lock.json"),
                    item("fellowship", "gimli-admin", "node_modules", .dependencies, mb(980), service: "gimli-admin", install: "pnpm install --frozen-lockfile", source: "pnpm-lock.yaml"),
                    item("fellowship", "wt-checkout-redesign", ".next", .build, mb(860), worktree: true),
                    item("fellowship", "aragorn-api", ".venv", .dependencies, mb(640), service: "aragorn-api", install: venv("3.12"), source: "requirements.txt", detail: "Python 3.12"),
                    tools("fellowship", "aragorn-api", [".mypy_cache", ".pytest_cache", ".ruff_cache"], mb(118)),
                ].sorted { $0.bytes > $1.bytes }, worktreeCount: 2),
                ProjectDisk(id: "rivendell", name: "Rivendell", root: path("rivendell"), items: [
                    item("rivendell", "elrond-app", ".next", .build, gb(6.2), service: "elrond-app"),
                    item("rivendell", "elrond-app", "node_modules", .dependencies, gb(1.1), service: "elrond-app", install: "npm ci", source: "package-lock.json"),
                    item("rivendell", "arwen-docs", "node_modules", .dependencies, mb(720), service: "arwen-docs", install: "npm ci", source: "package-lock.json"),
                    item("rivendell", "arwen-docs", ".next", .build, mb(410), service: "arwen-docs"),
                ]),
                ProjectDisk(id: "mordor", name: "Mordor", root: path("mordor"), items: [
                    item("mordor", "api", ".venv", .dependencies, mb(520), service: "sauron-api", install: venv("3.11"), source: "requirements.txt", detail: "Python 3.11"),
                    tools("mordor", "api", [".mypy_cache", ".pytest_cache"], mb(64)),
                ]),
                ProjectDisk(id: "shire", name: "The Shire", root: path("shire"), items: [
                    item("shire", "frodo-site", "node_modules", .dependencies, mb(380), service: "frodo-site", install: "npm ci", source: "package-lock.json"),
                ]),
            ],
            free: gb(38), capacity: gb(460), scannedAt: Date().addingTimeInterval(-120)
        )
    }
}
#endif
