import AppKit
import Darwin
import Foundation
import Observation
import RunbarCore
import ServiceManagement
@preconcurrency import UserNotifications

struct PortOwner: Equatable {
    var pid: Int32
    var name: String
    var serviceID: String?
    var label: String { serviceID ?? "\(name) (PID \(pid))" }
}

struct ServiceGroup: Identifiable {
    let id: String
    let name: String
    let runtimes: [ServiceRuntime]
    var isOrphanGroup: Bool { id == AppModel.orphanGroupID }
}

private struct PersistedState: Codable {
    struct Entry: Codable {
        var pid: Int32
        var processStart: Double
        var startedAt: Date
        var signature: String
        var command: String
        var cwd: String
        var port: Int?
        var project: String
        var activePort: Int?
    }
    var services: [String: Entry] = [:]
}

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()
    nonisolated static let orphanGroupID = "__fora-da-config"

    private(set) var config = RunbarConfig()
    private(set) var configError: ConfigIssue?
    private(set) var configWarnings: [ConfigIssue] = []
    private(set) var configLoadedAt: Date?
    private(set) var runtimes: [String: ServiceRuntime] = [:]
    private(set) var portOwners: [Int: PortOwner] = [:]
    private(set) var otherListeners: [Listener] = []
    private(set) var now = Date()
    private(set) var launchAtLogin = false

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var control: ControlServer?
    @ObservationIgnored private var dirSource: DispatchSourceFileSystemObject?
    @ObservationIgnored private var fileSource: DispatchSourceFileSystemObject?
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var scanning = false
    @ObservationIgnored private var lastHistoryAt = Date.distantPast
    @ObservationIgnored private var lastConfigData: Data?
    @ObservationIgnored private var lastConfigStamp: Date?
    @ObservationIgnored private var started = false
    @ObservationIgnored var stopServicesOnQuit = true
    @ObservationIgnored private let scanQueue = DispatchQueue(label: "runbar.scan", qos: .utility)

    /// Used by --snapshot mode to draw both looks.
    var lookOverride: LookSetting?
    @ObservationIgnored var snapshotMode = false

    var theme: Theme { Theme.resolve(lookOverride ?? config.settings.look) }

    /// --snapshot mode: reads config and processes without opening the socket, watching files or touching services.
    func prepareForSnapshot() {
        snapshotMode = true
        reloadConfig(force: true)
        adoptFromState()
        for _ in 0..<4 {
            apply(ProcSnapshot.take(), forceHistory: true)
            usleep(400_000)
        }
        now = Date()
    }

    // MARK: - Start and stop

    func start() {
        guard !started else { return }
        started = true
        if ControlClient.ping(timeout: 0.5) {
            // Another Runbar is already open: this one quits.
            NSApp.terminate(nil)
            return
        }
        ConfigBootstrap.ensureFiles()
        reloadConfig(force: true)
        adoptFromState()
        startControlServer()
        watchConfigDir()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
        for svc in config.services where svc.autostart {
            if let rt = runtimes[svc.id], !rt.isAlive { rt.start() }
        }
    }

    func shutdown() {
        control?.stop()
        guard stopServicesOnQuit else {
            persistState()
            return
        }
        let alive = runtimes.values.filter(\.isAlive)
        alive.forEach { $0.terminateNow() }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, alive.contains(where: { kill($0.pid ?? 0, 0) == 0 }) {
            usleep(100_000)
        }
        alive.forEach { $0.forceKillIfAlive() }
        try? FileManager.default.removeItem(at: Paths.stateFile)
    }

    func quit(stopServices: Bool) {
        stopServicesOnQuit = stopServices
        NSApp.terminate(nil)
    }

    // MARK: - Config

    func reloadConfig(force: Bool = false) {
        let data = try? Data(contentsOf: Paths.configFile)
        lastConfigStamp = LogTailer.modificationDate(Paths.configFile)
        if !force, data == lastConfigData { return }
        lastConfigData = data
        let result = data.map { ConfigLoader.load(data: $0) } ?? ConfigLoader.load(from: Paths.configFile)
        configLoadedAt = Date()
        if let cfg = result.config {
            config = cfg
            configError = nil
            configWarnings = result.warnings
            syncRuntimes()
        } else {
            configError = result.errors.first
        }
    }

    private func syncRuntimes() {
        let ids = Set(config.services.map(\.id))
        for svc in config.services {
            if let rt = runtimes[svc.id] {
                rt.update(config: svc)
            } else {
                runtimes[svc.id] = ServiceRuntime(config: svc, model: self)
            }
        }
        for (id, rt) in runtimes where !ids.contains(id) {
            if rt.isAlive { rt.orphaned = true } else { runtimes[id] = nil }
        }
    }

    func dropOrphan(_ id: String) {
        if let rt = runtimes[id], rt.orphaned, !rt.isAlive { runtimes[id] = nil }
    }

    private func watchConfigDir() {
        let fd = open(Paths.configDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend, .attrib], queue: .main)
        src.setEventHandler { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                MainActor.assumeIsolated { self?.reloadConfig() }
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        dirSource = src
        watchConfigFile()
    }

    /// Edits to the file itself don't touch the folder, so the file is watched too.
    private func watchConfigFile() {
        fileSource?.cancel()
        fileSource = nil
        let fd = open(Paths.configFile.path, O_EVTONLY)
        guard fd >= 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { self.watchConfigFile() } }
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .attrib], queue: .main)
        src.setEventHandler { [weak self, weak src] in
            let replaced = src.map { $0.data.contains(.delete) || $0.data.contains(.rename) } ?? false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                MainActor.assumeIsolated {
                    self?.reloadConfig()
                    if replaced { self?.watchConfigFile() }
                }
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        fileSource = src
    }

    var groups: [ServiceGroup] {
        var out = config.projects.map { p in
            ServiceGroup(id: p.id, name: p.name, runtimes: p.services.compactMap { runtimes[$0.id] })
        }
        let orphans = runtimes.values.filter(\.orphaned).sorted { $0.id < $1.id }
        if !orphans.isEmpty { out.append(ServiceGroup(id: Self.orphanGroupID, name: "Not in config.json", runtimes: orphans)) }
        return out
    }

    func setLook(_ look: LookSetting) {
        try? ConfigEditor.set(.string(look.rawValue), at: ["settings", "look"])
        reloadConfig(force: true)
    }

    // MARK: - Actions

    func toggle(_ id: String) {
        guard let rt = runtimes[id] else { return }
        if rt.isAlive {
            rt.stop()
        } else if rt.external != nil {
            rt.stopExternal()
        } else {
            rt.start()
        }
    }

    func startAll(_ group: ServiceGroup) {
        group.runtimes.filter { !$0.isRunningAnywhere }.forEach { $0.start() }
    }

    func stopAll(_ group: ServiceGroup) {
        for rt in group.runtimes {
            if rt.isAlive { rt.stop() } else if rt.external != nil { rt.stopExternal() }
        }
    }

    /// Stops whoever holds the port and (re)starts the service.
    func perform(_ fix: FixAction, for rt: ServiceRuntime) {
        switch fix {
        case .stopService(let blockerID):
            if let blocker = runtimes[blockerID] {
                if blocker.isAlive { blocker.stop() } else { blocker.stopExternal() }
            }
        case .killProcess(let pid):
            kill(pid, SIGTERM)
        case .takeOverExternal:
            rt.stopExternal()
        }
        let target = rt.id
        Task { @MainActor in
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(250))
                let blocked: Bool
                switch fix {
                case .stopService(let b): blocked = self.runtimes[b]?.isRunningAnywhere == true
                case .killProcess(let p): blocked = kill(p, 0) == 0
                case .takeOverExternal: blocked = self.runtimes[target]?.external.map { kill($0.rootPID, 0) == 0 } ?? false
                }
                if !blocked { break }
            }
            // Wait until the port is actually free before starting.
            if let port = self.runtimes[target]?.config.port {
                for _ in 0..<40 where PortProbe.isInUse(port) {
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            guard let rt = self.runtimes[target] else { return }
            rt.restart()
        }
    }

    /// Next free port after `port`, skipping ports reserved for other services in the config.
    func nextFreePort(after port: Int, for id: String) -> Int? {
        var reserved = Set(config.services.filter { $0.id != id }.compactMap(\.port))
        for rt in runtimes.values where rt.id != id {
            if let p = rt.activePort { reserved.insert(p) }
        }
        var candidate = port + 1
        while candidate <= min(port + 200, 65535) {
            if !reserved.contains(candidate), !PortProbe.isInUse(candidate) { return candidate }
            candidate += 1
        }
        return nil
    }

    func killOther(pid: Int32) {
        Darwin.kill(pid, SIGTERM)
    }

    func refresh() {
        reloadConfig(force: true)
        tick()
    }

    // MARK: - Monitoring

    private func tick() {
        now = Date()
        tickCount += 1
        if LogTailer.modificationDate(Paths.configFile) != lastConfigStamp { reloadConfig() }
        runtimes.values.forEach { $0.pollLog() }
        if tickCount % 3 == 0 { runHealthChecks() }
        guard !scanning else { return }
        scanning = true
        scanQueue.async {
            let snapshot = ProcSnapshot.take()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.apply(snapshot)
                    self.scanning = false
                }
            }
        }
    }

    private func apply(_ snap: ProcSnapshot, forceHistory: Bool = false) {
        let sampleHistory = forceHistory || snap.time.timeIntervalSince(lastHistoryAt) >= 15
        if sampleHistory { lastHistoryAt = snap.time }
        let openPorts = snap.allListeningPorts
        for rt in runtimes.values where rt.isAlive {
            rt.apply(snap, sampleHistory: sampleHistory, portOpenAnywhere: rt.config.port.map(openPorts.contains) ?? false)
        }

        var managed: [Int32: String] = [:]
        for rt in runtimes.values where rt.isAlive {
            for p in rt.treePIDs { managed[p] = rt.id }
        }
        let me = getpid()

        // Services started outside Runbar: something listening on a port, running in the service's folder.
        var byCwd: [String: [Int32]] = [:]
        for pid in snap.listening.keys.sorted() where managed[pid] == nil && pid != me {
            guard let cwd = snap.cwds[pid], !(snap.paths[pid] ?? "").contains(".app/Contents/") else { continue }
            byCwd[cwd, default: []].append(pid)
        }
        var cwdUse: [String: Int] = [:]
        for rt in runtimes.values { cwdUse[rt.config.cwd, default: 0] += 1 }
        var claimed = Set<Int32>()
        for rt in runtimes.values.sorted(by: { $0.id < $1.id }) where !rt.isAlive {
            let candidates = (byCwd[rt.config.cwd] ?? []).filter { !claimed.contains($0) }
            let byPort = candidates.first { pid in rt.config.port.map { snap.listening[pid]?.contains($0) == true } ?? false }
            let pick = byPort ?? (cwdUse[rt.config.cwd] == 1 ? candidates.first : nil)
            guard let pick else {
                rt.applyExternal(root: nil, snap: snap)
                continue
            }
            rt.applyExternal(root: snap.serviceRoot(from: pick, cwd: rt.config.cwd), snap: snap)
            for p in rt.external?.pids ?? [] {
                managed[p] = rt.id
                claimed.insert(p)
            }
        }
        var owners: [Int: PortOwner] = [:]
        var others: [Int: Listener] = [:]
        for (pid, ports) in snap.listening where pid != me {
            let name = snap.procs[pid]?.name ?? "?"
            let path = snap.paths[pid] ?? ""
            for port in ports {
                owners[port] = PortOwner(pid: pid, name: name, serviceID: managed[pid])
                let system = ["/System/", "/usr/libexec/", "/usr/sbin/", "/Library/Apple/"].contains { path.hasPrefix($0) }
                    || (path.contains(".app/Contents/") && !["Docker", "OrbStack", "Postgres"].contains { path.contains($0) })
                if managed[pid] == nil, !system, port < 49152, others[port] == nil {
                    others[port] = Listener(port: port, pid: pid, name: name, path: path)
                }
            }
        }
        if owners != portOwners { portOwners = owners }
        let sortedOthers = others.values.sorted { $0.port < $1.port }
        if sortedOthers != otherListeners { otherListeners = sortedOthers }
    }

    private func runHealthChecks() {
        for rt in runtimes.values where rt.isAlive {
            guard let health = rt.config.health, let port = rt.realPort ?? rt.config.port else { continue }
            let text = health.hasPrefix("http") ? health.replacingOccurrences(of: "{port}", with: String(port)) : "http://127.0.0.1:\(port)\(health)"
            guard let url = URL(string: text) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 2
            let id = rt.id
            URLSession.shared.dataTask(with: request) { _, response, _ in
                let ok = (response as? HTTPURLResponse).map { (200..<400).contains($0.statusCode) } ?? false
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let rt = self.runtimes[id] else { return }
                        rt.healthy = ok
                        rt.evaluateStarting()
                    }
                }
            }.resume()
        }
    }

    // MARK: - State across launches

    func persistState() {
        guard !snapshotMode else { return }
        var state = PersistedState()
        for rt in runtimes.values {
            guard let pid = rt.pid, let processStart = rt.processStart else { continue }
            state.services[rt.id] = .init(
                pid: pid, processStart: processStart, startedAt: rt.startedAt ?? Date(),
                signature: rt.appliedSignature ?? rt.config.launchSignature, command: rt.config.command,
                cwd: rt.config.cwd, port: rt.config.port, project: rt.config.projectID, activePort: rt.activePort
            )
        }
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: Paths.stateFile, options: .atomic)
        }
    }

    private func adoptFromState() {
        guard let data = try? Data(contentsOf: Paths.stateFile),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else { return }
        for (id, entry) in state.services {
            guard let sample = ProcScanner.sample(pid: entry.pid),
                  abs(sample.startTime.timeIntervalSince1970 - entry.processStart) < 1,
                  sample.pgid == entry.pid else { continue }
            let rt: ServiceRuntime
            if let existing = runtimes[id] {
                rt = existing
            } else {
                let cfg = ServiceConfig(id: id, projectID: entry.project, projectName: entry.project, command: entry.command, cwd: entry.cwd, port: entry.port)
                rt = ServiceRuntime(config: cfg, model: self)
                rt.orphaned = true
                runtimes[id] = rt
            }
            rt.adopt(pid: entry.pid, startedAt: entry.startedAt, processStart: entry.processStart, signature: entry.signature, activePort: entry.activePort)
        }
        persistState()
    }

    // MARK: - Notifications

    func serviceCrashed(_ rt: ServiceRuntime) {
        guard config.settings.notifyOnCrash, Bundle.main.bundleIdentifier != nil else { return }
        let title = "\(rt.id) crashed"
        let code = rt.lastExitCode.map { "exit code \($0)" } ?? "no exit code"
        let body = [code, rt.lastLine].compactMap { $0 }.joined(separator: " · ")
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    // MARK: - CLI socket

    private func startControlServer() {
        let server = ControlServer { [weak self] request, reply in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    reply(self?.handle(request) ?? ControlResponse(ok: false, error: "Runbar is quitting"))
                }
            }
        }
        do {
            try server.start()
            control = server
        } catch {
            NSLog("Runbar: could not open the control socket: \(error)")
        }
    }

    private func handle(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case "ping":
            return ControlResponse(ok: true, message: "pong")
        case "status":
            return ControlResponse(ok: true, services: statusList(), configError: configError?.description)
        case "reload":
            reloadConfig(force: true)
            return ControlResponse(ok: configError == nil, message: "config reloaded: \(config.services.count) services", configError: configError?.description)
        case "start", "stop", "restart":
            guard let id = request.id, let rt = runtimes[id] else {
                return ControlResponse(ok: false, error: "no service \"\(request.id ?? "")\" in config.json")
            }
            switch request.cmd {
            case "start":
                if rt.isAlive { return ControlResponse(ok: true, message: "\(id) is already running") }
                rt.start()
                if case .failed(let msg) = rt.phase { return ControlResponse(ok: false, error: msg) }
                return ControlResponse(ok: true, message: "starting \(id)")
            case "stop":
                if !rt.isAlive {
                    if rt.external != nil {
                        rt.stopExternal()
                        return ControlResponse(ok: true, message: "stopping \(id) (started outside Runbar)")
                    }
                    rt.stop()
                    return ControlResponse(ok: true, message: "\(id) is already stopped")
                }
                rt.stop()
                return ControlResponse(ok: true, message: "stopping \(id)")
            default:
                rt.restart()
                return ControlResponse(ok: true, message: "restarting \(id)")
            }
        default:
            return ControlResponse(ok: false, error: "unknown command: \(request.cmd)")
        }
    }

    private func statusList() -> [ServiceStatus] {
        let ordered = groups.flatMap(\.runtimes)
        return ordered.map { rt in
            let d = display(rt)
            let status: String
            switch rt.phase {
            case .stopped: status = rt.external == nil ? "stopped" : "external"
            case .starting: status = "starting"
            case .running: status = "running"
            case .stopping: status = "stopping"
            case .crashed: status = "crashed"
            case .failed: status = "failed"
            }
            return ServiceStatus(
                id: rt.id, project: rt.config.projectID, type: rt.config.type.rawValue, status: status,
                port: rt.config.port, realPort: d.realPort, listening: rt.external?.ports ?? rt.listening,
                pid: rt.pid ?? rt.external?.rootPID,
                memoryMB: d.memory.map { Double($0) / 1_048_576 },
                cpuPercent: d.cpu, processes: rt.isAlive ? rt.processCount : rt.external?.pids.count,
                startedAt: rt.isAlive ? rt.startedAt : rt.external?.startedAt, lastLogAt: rt.lastLogAt, exitCode: rt.lastExitCode,
                url: d.url?.absoluteString, command: rt.config.command(port: rt.expectedPort),
                cwd: rt.config.cwd, logFile: rt.logURL.path, alert: d.alert ? d.subtitle : nil,
                activePort: rt.activePort
            )
        }
    }

    // MARK: - Summary for the UI

    var runningCount: Int { runtimes.values.filter(\.isRunningAnywhere).count }
    var isBusy: Bool { runtimes.values.contains { $0.phase == .starting || $0.phase == .stopping } }
    var alertCount: Int { runtimes.values.filter { display($0).alert }.count + (configError == nil ? 0 : 1) }

    /// Total memory of everything running, including services started outside Runbar.
    var totalMemory: UInt64 {
        runtimes.values.filter(\.isRunningAnywhere).reduce(0) { $0 + ($1.external?.memory ?? $1.memory) }
    }

    var totalCPU: Double {
        runtimes.values.filter(\.isRunningAnywhere).reduce(0) { $0 + ($1.external?.cpu ?? $1.cpu) }
    }

    /// Services with an alert, in list order.
    var alertingServices: [ServiceRuntime] {
        groups.flatMap(\.runtimes).filter { display($0).alert }
    }

    /// Summed history of live services. They are all sampled at the same instant, so the sum is per date.
    func totalHistory(_ history: KeyPath<ServiceRuntime, [MetricPoint]>) -> [MetricPoint] {
        var sums: [Date: Double] = [:]
        for rt in runtimes.values where rt.isAlive {
            for point in rt[keyPath: history] { sums[point.date, default: 0] += point.value }
        }
        return sums.keys.sorted().enumerated().map { MetricPoint(id: $0.offset, date: $0.element, value: sums[$0.element] ?? 0) }
    }

    // MARK: - Utilities

    func openConfigFile() {
        NSWorkspace.shared.open(Paths.configFile)
    }

    func revealConfigDir() {
        NSWorkspace.shared.activateFileViewerSelecting([Paths.configFile])
    }

    func openLogsDir() {
        NSWorkspace.shared.open(Paths.logsDir)
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Runbar: login item: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    static let cliDirectories = ["/opt/homebrew/bin", "/usr/local/bin", Paths.home + "/.local/bin"]

    var cliHelperPath: String? {
        let p = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/runbar").path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    var cliInstalledPath: String? {
        Self.cliDirectories.map { $0 + "/runbar" }.first { FileManager.default.fileExists(atPath: $0) }
    }

    func installCLI() -> String {
        guard let helper = cliHelperPath else { return "The command ships inside Runbar.app; open the installed app." }
        let fm = FileManager.default
        for dir in Self.cliDirectories where fm.isWritableFile(atPath: dir) {
            let link = dir + "/runbar"
            if let attrs = try? fm.attributesOfItem(atPath: link) {
                guard attrs[.type] as? FileAttributeType == .typeSymbolicLink else { continue }
                try? fm.removeItem(atPath: link)
            }
            if (try? fm.createSymbolicLink(atPath: link, withDestinationPath: helper)) != nil {
                return "Installed at \(Paths.abbreviate(link))"
            }
        }
        return "Couldn't find a writable folder on your PATH."
    }

    /// Common parent folder of the projects, for the agent request.
    var suggestedRoot: String {
        let roots = config.projects.compactMap(\.root)
        if roots.count > 1 {
            var common = roots[0].split(separator: "/")
            for r in roots.dropFirst() {
                let parts = r.split(separator: "/")
                common = Array(zip(common, parts).prefix { $0 == $1 }.map(\.0))
            }
            if common.count > 2 { return Paths.abbreviate("/" + common.joined(separator: "/")) }
        } else if let only = roots.first {
            return Paths.abbreviate((only as NSString).deletingLastPathComponent)
        }
        let guess = Paths.home + "/Documents/repos"
        return FileManager.default.fileExists(atPath: guess) ? "~/Documents/repos" : "~"
    }
}

#if DEBUG
extension AppModel {
    /// README screenshots: a made-up config and machine state, with nothing read from this Mac.
    func loadDemo(config: RunbarConfig, now: Date, portOwners: [Int: PortOwner], otherListeners: [Listener]) {
        snapshotMode = true
        self.config = config
        configError = nil
        configWarnings = []
        configLoadedAt = now
        syncRuntimes()
        self.now = now
        self.portOwners = portOwners
        self.otherListeners = otherListeners
    }
}
#endif

