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
            written.append(render(framed(PopoverView(initialSelection: "finch-app").environment(model), dark: dark), name: "conflict-\(suffix)", dir: dir, dark: dark))
            written.append(render(framed(PopoverView(initialSelection: "moonbase-db").environment(model), dark: dark), name: "outside-\(suffix)", dir: dir, dark: dark))
            DiskModel.shared.confirming = Self.path("acme/acme-web/node_modules")
            written.append(render(framed(PopoverView(initialTab: .disk, initialQuery: "node_modules").environment(model), dark: dark), name: "reinstall-\(suffix)", dir: dir, dark: dark))
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
        written.append(render(alone(PopoverView(initialSelection: "acme-web").environment(model)), name: "panel-detail", dir: dir, dark: true))
        written.append(render(alone(PopoverView(initialTab: .disk).environment(model)), name: "panel-disk", dir: dir, dark: true))
        written.append(render(alone(PopoverView(initialSelection: "finch-app").environment(model)), name: "panel-conflict", dir: dir, dark: true))
        written.append(render(alone(PopoverView(initialSelection: "moonbase-db").environment(model)), name: "panel-outside", dir: dir, dark: true))
        DiskModel.shared.confirming = Self.path("acme/acme-web/node_modules")
        written.append(render(alone(PopoverView(initialTab: .disk, initialQuery: "node_modules").environment(model)), name: "panel-reinstall", dir: dir, dark: true))
        DiskModel.shared.confirming = nil
        written.append(render(alone(agentWindow(model), radius: 12), name: "panel-agent", dir: dir, dark: true))
        written.append(render(alone(PopoverView(initialSelection: "acme-db").environment(model)), name: "panel-proxy", dir: dir, dark: true))
        written.append(render(alone(PopoverView(initialSelection: "finch-db").environment(model)), name: "panel-proxy-closed", dir: dir, dark: true))
        written.append(render(alone(PopoverView(initialQuery: "6379", initialShowOthers: true).environment(model)), name: "panel-launchd", dir: dir, dark: true))
        if let redis = model.otherListeners.first(where: { $0.port == 6379 }) {
            written.append(render(alone(PopoverView(initialImport: redis).environment(model)), name: "panel-import", dir: dir, dark: true))
        }
        print(written.joined(separator: "\n"))
        exit(0)
    }

    // MARK: - Layouts

    /// The three main views side by side: services, a running service, disk.
    private static func hero(_ model: AppModel) -> some View {
        HStack(alignment: .top, spacing: 36) {
            panel(PopoverView().environment(model))
            panel(PopoverView(initialSelection: "acme-web").environment(model))
            panel(PopoverView(initialTab: .disk).environment(model))
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

    /// A desktop behind the panels: dusk in dark mode, a clear sky in light mode.
    private struct Wallpaper: View {
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            GeometryReader { geo in
                let size = geo.size
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
        "acme": { "name": "Acme Store", "root": "~/Developer/acme", "services": {
          "acme-web": { "cwd": "acme-web", "type": "nextjs", "command": "npm run dev -- -p {port}", "port": 3000 },
          "acme-api": { "cwd": "acme-api", "type": "python", "command": ".venv/bin/uvicorn app.main:app --reload --port {port}", "port": 8000, "open": "http://localhost:{port}/docs", "needs": ["acme-db"] },
          "acme-worker": { "cwd": "acme-worker", "type": "node", "command": "npm run worker" },
          "acme-admin": { "cwd": "acme-admin", "type": "nextjs", "command": "pnpm dev --port {port}", "port": 3001 },
          "acme-db": { "type": "proxy", "command": "cloud-sql-proxy --port {port} acme-prod:us-central1:acme", "port": 5434, "open": "postgres://localhost:{port}/acme" }
        }},
        "finch": { "name": "Blue Finch", "root": "~/Developer/finch", "services": {
          "finch-app": { "cwd": "finch-app", "type": "nextjs", "command": "npm run dev -- -p {port}", "port": 3100 },
          "finch-docs": { "cwd": "finch-docs", "type": "nextjs", "command": "npm run dev -- -p {port}", "port": 3101 },
          "finch-db": { "type": "proxy", "command": "kubectl port-forward svc/postgres {port}:5432", "port": 5435 }
        }},
        "moonbase": { "name": "Moonbase", "root": "~/Developer/moonbase", "services": {
          "moonbase-api": { "cwd": "api", "type": "python", "command": ".venv/bin/uvicorn main:app --reload --port {port}", "port": 8100 },
          "moonbase-db": { "cwd": "db", "type": "docker", "command": "docker compose up", "stop": "docker compose down", "port": 5433 }
        }},
        "kite": { "name": "Paper Kite", "root": "~/Developer/kite", "services": {
          "kite-site": { "cwd": "kite-site", "type": "node", "command": "npm run dev -- --port {port}", "port": 4321 }
        }}
      }
    }
    """

    private static func load(_ model: AppModel) {
        guard let cfg = ConfigLoader.load(data: Data(config.utf8)).config else { fatalError("demo config doesn't parse") }
        var parts = DateComponents()
        parts.year = 2026; parts.month = 11; parts.day = 12; parts.hour = 10; parts.minute = 41
        let now = Calendar.current.date(from: parts) ?? Date()
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
        rt["acme-web"]?.loadDemo(
            phase: .running, pid: 48213, startedAt: ago(149), lastLogAt: now.addingTimeInterval(-3), memoryMB: 412, cpu: 3.1,
            processCount: 3, listening: [3000],
            memHistoryMB: series(120) { i in 300 + Double(i % 48) * 2.2 + Double(i) * 0.25 },
            cpuSeries: series(120) { i in i % 37 == 20 ? 46 : (i % 13 == 5 ? 18 : 2.5 + Double((i * 5) % 7)) },
            at: now,
            logs: [
                "── Runbar · Nov 12 2026 08:12:04 · npm run dev -- -p 3000 · in ~/Developer/acme/acme-web",
                "> acme-web@0.1.0 dev",
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
        rt["acme-api"]?.loadDemo(
            phase: .running, pid: 48230, startedAt: ago(149), lastLogAt: now.addingTimeInterval(-41), memoryMB: 186, cpu: 0.6,
            processCount: 2, listening: [8000],
            memHistoryMB: series(120) { i in 180 + Double((i * 7) % 9) }, cpuSeries: series(120) { i in 0.3 + Double((i * 3) % 5) * 0.1 }, at: now,
            logs: ["INFO:     Application startup complete.", "INFO:     127.0.0.1:52811 - \"GET /orders?limit=20 HTTP/1.1\" 200 OK"]
        )
        rt["acme-worker"]?.loadDemo(
            phase: .running, pid: 48251, startedAt: ago(148), lastLogAt: now.addingTimeInterval(-12), memoryMB: 96, cpu: 0.2,
            processCount: 1, memHistoryMB: series(120) { i in 92 + Double(i % 5) }, cpuSeries: series(120) { _ in 0.2 }, at: now,
            logs: ["[worker] sent 3 order confirmation emails"]
        )
        rt["finch-app"]?.loadDemo(
            phase: .running, pid: 51877, startedAt: ago(38), lastLogAt: now.addingTimeInterval(-6), memoryMB: 356, cpu: 1.8,
            processCount: 3, listening: [3102],
            memHistoryMB: series(120) { i in 330 + Double((i * 7) % 11) * 2 }, cpuSeries: series(120) { i in 1 + Double((i * 3) % 4) * 0.5 }, at: now,
            logs: [" ⚠ Port 3100 is in use, trying 3102 instead.", "   - Local:        http://localhost:3102", " ✓ Ready in 1.1s"]
        )
        rt["finch-docs"]?.loadDemo(
            phase: .starting, pid: 52010, startedAt: now.addingTimeInterval(-9), lastLogAt: now.addingTimeInterval(-2), memoryMB: 64, cpu: 12,
            processCount: 2, at: now, logs: ["> next dev -p 3101"]
        )
        rt["moonbase-api"]?.loadDemo(
            phase: .crashed(1), exitedAt: ago(6), exitCode: 1, at: now,
            logs: [
                "Traceback (most recent call last):",
                "  File \"/Users/you/Developer/moonbase/api/main.py\", line 3, in <module>",
                "ModuleNotFoundError: No module named 'httpx'",
            ]
        )
        rt["moonbase-db"]?.loadDemo(
            phase: .stopped, at: now,
            external: ExternalRun(rootPID: 7712, pids: [7712, 7720], ports: [5433], memory: 220 * 1_048_576, cpu: 0.4,
                                  startedAt: now.addingTimeInterval(-16 * 3600 - 39 * 60))
        )
        rt["kite-site"]?.loadDemo(phase: .stopped, exitedAt: ago(130), exitCode: 0, at: now)
        rt["acme-db"]?.loadDemo(
            phase: .running, pid: 48202, startedAt: ago(149), lastLogAt: ago(3), memoryMB: 18, cpu: 0.1, processCount: 1, listening: [5434], at: now,
            logs: [
                "── Runbar · Nov 12 2026 08:12:01 · cloud-sql-proxy --port 5434 acme-prod:us-central1:acme · in ~/Developer/acme",
                "2026/11/12 08:12:01 Authorizing with Application Default Credentials",
                "2026/11/12 08:12:02 [acme-prod:us-central1:acme] Listening on 127.0.0.1:5434",
                "2026/11/12 08:12:02 The proxy has started successfully and is ready for new connections!",
                "2026/11/12 08:12:09 [acme-prod:us-central1:acme] Accepted connection from 127.0.0.1:61022",
                "2026/11/12 10:38:47 [acme-prod:us-central1:acme] Accepted connection from 127.0.0.1:63518",
            ]
        )
        rt["acme-db"]?.loadDemoUsage(
            clients: [
                ProxyClient(id: "acme-api", name: "acme-api", serviceID: "acme-api", pid: 48230, connections: 3),
                ProxyClient(id: "pid-61022", name: "psql", serviceID: nil, pid: 61022, connections: 1),
            ],
            heldBy: ["acme-api"]
        )
        rt["finch-db"]?.loadDemo(phase: .stopped, exitedAt: ago(12), exitCode: 0, at: now,
                                 logs: ["── Runbar · Nov 12 2026 10:29:00 · closed after 15 min with no connections"])
        rt["finch-db"]?.loadDemoUsage(closedIdleAt: ago(12))

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
                ProjectDisk(id: "acme", name: "Acme Store", root: path("acme"), items: [
                    item("acme", "acme-web", ".next", .build, gb(18.4), service: "acme-web"),
                    item("acme", "acme-admin", ".next", .build, gb(2.1), service: "acme-admin"),
                    item("acme", "acme-web", "node_modules", .dependencies, gb(1.24), service: "acme-web", install: "npm ci", source: "package-lock.json"),
                    item("acme", "wt-checkout-redesign", "node_modules", .dependencies, gb(1.18), worktree: true, install: "npm ci", source: "package-lock.json"),
                    item("acme", "acme-admin", "node_modules", .dependencies, mb(980), service: "acme-admin", install: "pnpm install --frozen-lockfile", source: "pnpm-lock.yaml"),
                    item("acme", "wt-checkout-redesign", ".next", .build, mb(860), worktree: true),
                    item("acme", "acme-api", ".venv", .dependencies, mb(640), service: "acme-api", install: venv("3.12"), source: "requirements.txt", detail: "Python 3.12"),
                    tools("acme", "acme-api", [".mypy_cache", ".pytest_cache", ".ruff_cache"], mb(118)),
                ].sorted { $0.bytes > $1.bytes }, worktreeCount: 2),
                ProjectDisk(id: "finch", name: "Blue Finch", root: path("finch"), items: [
                    item("finch", "finch-app", ".next", .build, gb(6.2), service: "finch-app"),
                    item("finch", "finch-app", "node_modules", .dependencies, gb(1.1), service: "finch-app", install: "npm ci", source: "package-lock.json"),
                    item("finch", "finch-docs", "node_modules", .dependencies, mb(720), service: "finch-docs", install: "npm ci", source: "package-lock.json"),
                    item("finch", "finch-docs", ".next", .build, mb(410), service: "finch-docs"),
                ]),
                ProjectDisk(id: "moonbase", name: "Moonbase", root: path("moonbase"), items: [
                    item("moonbase", "api", ".venv", .dependencies, mb(520), service: "moonbase-api", install: venv("3.11"), source: "requirements.txt", detail: "Python 3.11"),
                    tools("moonbase", "api", [".mypy_cache", ".pytest_cache"], mb(64)),
                ]),
                ProjectDisk(id: "kite", name: "Paper Kite", root: path("kite"), items: [
                    item("kite", "kite-site", "node_modules", .dependencies, mb(380), service: "kite-site", install: "npm ci", source: "package-lock.json"),
                ]),
            ],
            free: gb(38), capacity: gb(460), scannedAt: Date().addingTimeInterval(-120)
        )
    }
}
#endif
