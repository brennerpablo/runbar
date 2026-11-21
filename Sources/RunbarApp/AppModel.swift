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
    /// The project's services; its proxies are listed apart, after them.
    @MainActor var services: [ServiceRuntime] { runtimes.filter { !$0.config.isProxy } }
    @MainActor var proxies: [ServiceRuntime] { runtimes.filter { $0.config.isProxy } }
}

/// Where a service's `needs` stand before it starts.
enum NeedsState: Equatable {
    case ready
    case pending([String])
    case failed(String)
}

/// What the user picked when moving a launchd job into Runbar.
struct LaunchdImport {
    var name: String
    var projectID: String
    /// "15m", "1h", "never": proxies only.
    var idle: String
    /// Services that will open it before they start.
    var openWith: [String]
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
    /// In the Dock and the app switcher too, not only in the menu bar. Remembered between launches.
    private(set) var showInDock = UserDefaults.standard.bool(forKey: AppModel.showInDockKey)
    /// Alerts the user dismissed while their situation still holds, by service: the alert's key.
    private(set) var mutedAlerts: [String: String] = [:]
    /// launchd jobs behind ports held outside Runbar, by the PID that listens.
    private(set) var launchdJobs: [Int32: LaunchdJob] = [:]
    /// Development servers in the projects' folders that config.json doesn't run, ignored ones included.
    private(set) var found: [FoundService] = []
    /// Found services the user doesn't want suggested, by id.
    private(set) var ignoredFound: Set<String> = FoundIgnores.load()

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
    /// The listening PIDs the last launchd lookup covered: it runs again only when they change.
    @ObservationIgnored private var launchdScannedFor: Set<Int32> = []
    @ObservationIgnored private var findingServices = false
    /// The config the last look through the project folders was for, and when it finished.
    @ObservationIgnored private var foundFor: RunbarConfig?
    @ObservationIgnored private var foundAt: Date?

    /// Used by --snapshot mode to draw both looks.
    var lookOverride: LookSetting?
    @ObservationIgnored var snapshotMode = false

    var theme: Theme { Theme.resolve(lookOverride ?? config.settings.look) }

    /// --snapshot mode: reads config and processes without opening the socket, watching files or touching services.
    func prepareForSnapshot() {
        snapshotMode = true
        reloadConfig(force: true)
        found = ServiceFinder.find(in: config)
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
        KeepAwake.shared.recover()
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
            findServices()
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

    func setActiveProjectsFirst(_ on: Bool) {
        try? ConfigEditor.set(.bool(on), at: ["settings", "activeProjectsFirst"])
        reloadConfig(force: true)
    }

    // MARK: - Actions

    func toggle(_ id: String) {
        guard let rt = runtimes[id] else { return }
        if rt.isAlive || rt.phase == .waiting {
            rt.stop()
        } else if rt.external != nil {
            rt.stopExternal()
        } else {
            rt.start()
        }
    }

    /// Starts the project's services. Its proxies open through `needs`, so they only open here when the
    /// project is nothing but proxies.
    func startAll(_ group: ServiceGroup) {
        let services = group.services.isEmpty ? group.runtimes : group.services
        services.filter { !$0.isRunningAnywhere }.forEach { $0.start() }
    }

    // MARK: - Needs

    /// Opens whatever `cfg` needs that isn't open, then says where they stand. `retryFailed` starts again
    /// the ones that failed or crashed (on the first try; not while waiting).
    func openNeeds(of cfg: ServiceConfig, retryFailed: Bool = true) -> NeedsState {
        for id in cfg.needs {
            guard let rt = runtimes[id], !rt.isRunningAnywhere else { continue }
            switch rt.phase {
            case .stopped: rt.start()
            case .crashed, .failed: if retryFailed { rt.start() }
            default: break
            }
        }
        return needsState(of: cfg)
    }

    func needsState(of cfg: ServiceConfig) -> NeedsState {
        var pending: [String] = []
        for id in cfg.needs {
            guard let rt = runtimes[id] else { return .failed("\(id) isn't in config.json") }
            if isReady(rt) { continue }
            switch rt.phase {
            case .failed(let message): return .failed("\(id) didn't open: \(message)")
            case .crashed(let code): return .failed("\(id) didn't open (exit code \(code.map(String.init) ?? "unknown"))")
            default: pending.append(id)
            }
        }
        return pending.isEmpty ? .ready : .pending(pending)
    }

    /// Open and answering: its port takes connections (or, without a port, it's running).
    private func isReady(_ rt: ServiceRuntime) -> Bool {
        if let ext = rt.external { return rt.config.port.map { ext.ports.contains($0) } ?? true }
        guard rt.isAlive, rt.phase == .starting || rt.phase == .running else { return false }
        guard let port = rt.expectedPort else { return rt.phase == .running }
        return rt.listening.contains(port) || PortProbe.isInUse(port)
    }

    func stopAll(_ group: ServiceGroup) {
        group.runtimes.forEach(stopIfRunning)
    }

    /// The header's Stop all: everything the Running tile counts, in config.json or not, started here or outside.
    func stopAllServices() {
        runtimes.values.forEach(stopIfRunning)
    }

    private func stopIfRunning(_ rt: ServiceRuntime) {
        if rt.isAlive || rt.phase == .waiting { rt.stop() } else if rt.external != nil { rt.stopExternal() }
    }

    /// Stops whoever holds the port and (re)starts the service. Signing in and opening what a service
    /// needs only do that.
    func perform(_ fix: FixAction, for rt: ServiceRuntime) {
        switch fix {
        case .signIn:
            signIn(for: rt)
            return
        case .openNeeds:
            _ = openNeeds(of: rt.config)
            return
        case .stopService(let blockerID):
            if let blocker = runtimes[blockerID] {
                if blocker.isAlive { blocker.stop() } else { blocker.stopExternal() }
            }
        case .killProcess(let pid):
            kill(pid, SIGTERM)
        case .turnOffLaunchd(let label, _):
            DispatchQueue.global(qos: .userInitiated).async { try? Launchd.turnOff(label) }
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
                case .killProcess(let p), .turnOffLaunchd(_, let p): blocked = kill(p, 0) == 0
                case .takeOverExternal: blocked = self.runtimes[target]?.external.map { kill($0.rootPID, 0) == 0 } ?? false
                case .signIn, .openNeeds: blocked = false
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

    // MARK: - launchd

    /// Stops a launchd job and keeps it from starting again, at login included.
    func turnOff(_ job: LaunchdJob) {
        DispatchQueue.global(qos: .userInitiated).async {
            try? Launchd.turnOff(job.label)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.tick() } }
        }
    }

    /// Takes a launchd job over: adds it to config.json (a proxy that opens on demand, when it is one),
    /// has the chosen services open it, then unloads the job and moves its plist next to config.json.
    func importLaunchd(_ job: LaunchdJob, port: Int, _ choice: LaunchdImport, done: @escaping (String?) -> Void) {
        guard RunbarConfig.isValidID(choice.name) else { return done("Use letters, digits, . _ or - in the name.") }
        guard config.service(choice.name) == nil else { return done("There's already a service called \(choice.name).") }
        guard config.projects.contains(where: { $0.id == choice.projectID }) else { return done("Pick a project.") }
        let command = job.command(port: port)
        let isProxy = ProxyTool.detect(command) != .other
        var entry = JSONObject()
        if isProxy { entry["type"] = .string(ServiceType.proxy.rawValue) }
        entry["command"] = .string(command)
        if let wd = job.workingDirectory { entry["cwd"] = .string(Paths.abbreviate(wd)) }
        entry["port"] = .number(Double(port))
        if isProxy { entry["idle"] = .string(choice.idle) }
        if !job.environment.isEmpty {
            var env = JSONObject()
            for key in job.environment.keys.sorted() { env[key] = .string(job.environment[key] ?? "") }
            entry["env"] = .object(env)
        }
        do {
            try ConfigEditor.set(.object(entry), at: ["projects", choice.projectID, "services", choice.name])
            for sid in choice.openWith {
                guard let svc = config.service(sid), !svc.needs.contains(choice.name) else { continue }
                let needs = (svc.needs + [choice.name]).map { JSON.string($0) }
                try ConfigEditor.set(.array(needs), at: ["projects", svc.projectID, "services", sid, "needs"])
            }
        } catch {
            return done("Couldn't write config.json: \(error.localizedDescription)")
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            do { try Launchd.retire(job) } catch { failure = "\(choice.name) is in config.json, but \(error)" }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.reloadConfig(force: true)
                    self.tick()
                    done(failure)
                }
            }
        }
    }

    // MARK: - Services found in the project folders

    /// What the panel suggests adding: found and not ignored.
    var suggestions: [FoundService] { found.filter { !ignoredFound.contains($0.id) } }

    /// Found services the user ignored that are still there.
    var ignoredSuggestionCount: Int { found.filter { ignoredFound.contains($0.id) }.count }

    /// Looks through the project folders again, in the background, when the config changed since the last
    /// look or it is older than `maxAge` (a folder cloned since then shows up).
    func findServices(maxAge: TimeInterval = 300) {
        guard !snapshotMode, !findingServices else { return }
        if foundFor == config, let foundAt, Date().timeIntervalSince(foundAt) < maxAge { return }
        findingServices = true
        let cfg = config
        DispatchQueue.global(qos: .utility).async {
            let result = ServiceFinder.find(in: cfg)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.findingServices = false
                    self.foundFor = cfg
                    self.foundAt = Date()
                    if result != self.found { self.found = result }
                    // The config changed while looking: what it runs now may cover some of these.
                    if cfg != self.config { self.findServices() }
                }
            }
        }
    }

    /// Adds a found service to config.json as suggested. Returns what went wrong, or nil.
    func add(_ item: FoundService) -> String? {
        guard configError == nil else { return "config.json has an error; fix it first." }
        guard config.projects.contains(where: { $0.id == item.projectID }) else { return "\(item.projectName) isn't in config.json anymore." }
        guard config.service(item.name) == nil else { return "There's already a service called \(item.name)." }
        do {
            try ConfigEditor.set(.object(item.entry), at: ["projects", item.projectID, "services", item.name])
        } catch {
            return "Couldn't write config.json: \(error.localizedDescription)"
        }
        found.removeAll { $0.id == item.id }
        reloadConfig(force: true)
        return nil
    }

    /// Stops suggesting it. Remembered between launches; `unignoreFound` brings them all back.
    func ignore(_ item: FoundService) {
        ignoredFound.insert(item.id)
        FoundIgnores.save(ignoredFound)
    }

    func unignoreFound() {
        ignoredFound = []
        FoundIgnores.save([])
    }

    /// Runs the tool's sign-in command in Terminal. When its credentials file changes, the proxy tries again.
    func signIn(for rt: ServiceRuntime) {
        guard let command = rt.config.proxyTool.signInCommand else { return }
        let url = Paths.supportDir.appendingPathComponent("sign-in.command")
        let script = """
        #!/bin/zsh -l
        echo "Runbar: signing in for \(rt.id)"
        \(command)
        echo
        echo "Runbar reopens \(rt.id) on its own. You can close this window."

        """
        do {
            try FileManager.default.createDirectory(at: Paths.supportDir, withIntermediateDirectories: true)
            try script.write(to: url, atomically: true, encoding: .utf8)
            chmod(url.path, 0o755)
            NSWorkspace.shared.open(url)
        } catch {
            NSLog("Runbar: sign-in script: \(error)")
        }
    }

    private func checkSignIns() {
        for rt in runtimes.values {
            guard let seen = rt.signInExpiredAt, let path = rt.config.proxyTool.credentialsPath,
                  let changed = LogTailer.modificationDate(URL(fileURLWithPath: path)), changed > seen else { continue }
            rt.signedInAgain()
        }
    }

    // MARK: - Proxy settings written from the UI

    /// Sets a proxy's `idle` ("5m", "15m", "1h", "never") in config.json.
    func setIdle(_ text: String, for id: String) {
        guard let svc = config.service(id) else { return }
        try? ConfigEditor.set(.string(text), at: ["projects", svc.projectID, "services", id, "idle"])
        reloadConfig(force: true)
    }

    /// Adds or removes `proxy` from a service's `needs` in config.json.
    func setNeeds(_ serviceID: String, opens proxy: String, _ on: Bool) {
        guard let svc = config.service(serviceID) else { return }
        var needs = svc.needs.filter { $0 != proxy }
        if on { needs.append(proxy) }
        try? ConfigEditor.set(.array(needs.map { JSON.string($0) }), at: ["projects", svc.projectID, "services", serviceID, "needs"])
        reloadConfig(force: true)
    }

    func refresh() {
        reloadConfig(force: true)
        findServices(maxAge: 0)
        tick()
    }

    // MARK: - Monitoring

    private func tick() {
        now = Date()
        tickCount += 1
        pruneMutedAlerts()
        if LogTailer.modificationDate(Paths.configFile) != lastConfigStamp { reloadConfig() }
        runtimes.values.forEach { $0.pollLog() }
        if tickCount % 3 == 0 {
            runHealthChecks()
            checkSignIns()
        }
        if tickCount % 30 == 0 { findServices() }
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
            guard let cwd = snap.cwds[pid], !snap.isTool(pid) else { continue }
            byCwd[cwd, default: []].append(pid)
        }
        var cwdUse: [String: Int] = [:]
        for rt in runtimes.values { cwdUse[rt.config.cwd, default: 0] += 1 }
        var claimed = Set<Int32>()
        for rt in runtimes.values.sorted(by: { $0.id < $1.id }) where !rt.isAlive {
            let candidates = (byCwd[rt.config.cwd] ?? []).filter { !claimed.contains($0) }
            let byPort = candidates.first { pid in rt.config.port.map { snap.listening[pid]?.contains($0) == true } ?? false }
            // On another port (started in Terminal with a different one): only a port a dev server would pick.
            let onOtherPort = candidates.first { pid in snap.listening[pid]?.contains { !ProcSnapshot.isEphemeral($0) } == true }
            let pick = byPort ?? (cwdUse[rt.config.cwd] == 1 ? onOtherPort : nil)
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
                if managed[pid] == nil, !system, !ProcSnapshot.isEphemeral(port), others[port] == nil {
                    others[port] = Listener(port: port, pid: pid, name: name, path: path)
                }
            }
        }
        if owners != portOwners { portOwners = owners }
        let sortedOthers = others.values.sorted { $0.port < $1.port }
        if sortedOthers != otherListeners { otherListeners = sortedOthers }

        applyProxyUsage(snap, managed: managed)
        // The ports listed outside Runbar, plus whatever holds a port from config.json (even an app's helper).
        let blockers = config.services.compactMap(\.port).compactMap { owners[$0] }.filter { $0.serviceID == nil }.map(\.pid)
        lookUpLaunchd(for: Set(sortedOthers.map(\.pid) + blockers), snap: snap)
    }

    /// Who is connected to each proxy and which services hold it open; closes the ones nothing used for
    /// their whole `idle` time.
    private func applyProxyUsage(_ snap: ProcSnapshot, managed: [Int32: String]) {
        for rt in runtimes.values where rt.config.isProxy {
            let own: Set<Int32> = rt.isAlive ? rt.treePIDs : (rt.external?.pids ?? [])
            var ports = Set(rt.isAlive ? rt.listening : (rt.external?.ports ?? []))
            if rt.isRunningAnywhere, let p = rt.expectedPort { ports.insert(p) }
            var byClient: [String: ProxyClient] = [:]
            if !ports.isEmpty {
                for (pid, n) in snap.clients(of: ports, excluding: own) {
                    let sid = managed[pid]
                    let key = sid ?? "pid-\(pid)"
                    if byClient[key] != nil {
                        byClient[key]?.connections += n
                    } else {
                        byClient[key] = ProxyClient(id: key, name: sid ?? Self.clientName(pid, snap), serviceID: sid, pid: pid, connections: n)
                    }
                }
            }
            let clients = byClient.values.sorted { ($0.serviceID == nil ? 1 : 0, $0.name) < ($1.serviceID == nil ? 1 : 0, $1.name) }
            let holders = config.dependents(of: rt.id).compactMap { runtimes[$0.id] }
                .filter { $0.isRunningAnywhere || $0.phase == .waiting }.map(\.id)
            rt.applyUsage(clients: clients, heldBy: holders, at: snap.time)
            if !snapshotMode, let closes = rt.closesAt, snap.time >= closes { rt.closeForIdle() }
        }
    }

    /// psql, TablePlus, Python: the app's name for an app, the binary's for the rest.
    private static func clientName(_ pid: Int32, _ snap: ProcSnapshot) -> String {
        let path = snap.paths[pid] ?? ProcScanner.path(pid: pid)
        if let r = path.range(of: ".app/Contents/") { return (String(path[..<r.lowerBound]) as NSString).lastPathComponent }
        if !path.isEmpty { return (path as NSString).lastPathComponent }
        return snap.procs[pid]?.name ?? "PID \(pid)"
    }

    /// Finds which ports held outside Runbar come from a launchd job (what makes Kill "not work"). Runs
    /// `launchctl list` only when those processes change.
    private func lookUpLaunchd(for pids: Set<Int32>, snap: ProcSnapshot) {
        guard pids != launchdScannedFor else { return }
        launchdScannedFor = pids
        let chains = Dictionary(uniqueKeysWithValues: pids.map { ($0, Array(snap.ancestry(of: $0).prefix(3))) })
        let lookUp = { () -> [Int32: LaunchdJob] in
            let running = Launchd.runningJobs()
            var byLabel: [String: LaunchdJob] = [:]
            var out: [Int32: LaunchdJob] = [:]
            for (pid, chain) in chains {
                // Apps (Terminal, VS Code) are launchd jobs too: what runs inside them isn't kept alive by launchd.
                guard let jobPID = chain.first(where: { running[$0] != nil }), let label = running[jobPID],
                      !label.hasPrefix("application."), !label.hasPrefix("com.apple.") else { continue }
                let job = byLabel[label] ?? Launchd.job(label: label, pid: jobPID)
                byLabel[label] = job
                out[pid] = job
            }
            return out
        }
        if snapshotMode {
            launchdJobs = lookUp()
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let jobs = lookUp()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if jobs != self.launchdJobs { self.launchdJobs = jobs }
                }
            }
        }
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
        guard config.settings.notifyOnCrash else { return }
        let code = rt.lastExitCode.map { "exit code \($0)" } ?? "no exit code"
        notify(title: "\(rt.id) crashed", body: [code, rt.lastLine].compactMap { $0 }.joined(separator: " · "))
    }

    func notify(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
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
            let proxy = rt.config.isProxy
            switch request.cmd {
            case "start":
                if rt.isAlive { return ControlResponse(ok: true, message: "\(id) is already \(proxy ? "open" : "running")") }
                if rt.phase == .waiting { return ControlResponse(ok: true, message: "\(id) is waiting for \(rt.waitingFor.joined(separator: ", "))") }
                rt.start()
                if case .failed(let msg) = rt.phase { return ControlResponse(ok: false, error: msg) }
                if rt.phase == .waiting {
                    return ControlResponse(ok: true, message: "opening \(rt.waitingFor.joined(separator: ", ")) first, then starting \(id)")
                }
                return ControlResponse(ok: true, message: "\(proxy ? "opening" : "starting") \(id)")
            case "stop":
                if rt.phase == .waiting {
                    rt.stop()
                    return ControlResponse(ok: true, message: "\(id) won't start")
                }
                if !rt.isAlive {
                    if rt.external != nil {
                        rt.stopExternal()
                        return ControlResponse(ok: true, message: "stopping \(id) (started outside Runbar)")
                    }
                    rt.stop()
                    return ControlResponse(ok: true, message: "\(id) is already \(proxy ? "closed" : "stopped")")
                }
                rt.stop()
                return ControlResponse(ok: true, message: "\(proxy ? "closing" : "stopping") \(id)")
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
            case .waiting: status = "waiting"
            case .crashed: status = "crashed"
            case .failed: status = "failed"
            }
            let proxy = rt.config.isProxy
            return ServiceStatus(
                id: rt.id, project: rt.config.projectID, type: rt.config.type.rawValue, status: status,
                port: rt.config.port, realPort: d.realPort, listening: rt.external?.ports ?? rt.listening,
                pid: rt.pid ?? rt.external?.rootPID,
                memoryMB: d.memory.map { Double($0) / 1_048_576 },
                cpuPercent: d.cpu, processes: rt.isAlive ? rt.processCount : rt.external?.pids.count,
                startedAt: rt.isAlive ? rt.startedAt : rt.external?.startedAt, lastLogAt: rt.lastLogAt, exitCode: rt.lastExitCode,
                url: d.url?.absoluteString, command: rt.config.command(port: rt.expectedPort),
                cwd: rt.config.cwd, logFile: rt.logURL.path, alert: d.alert ? d.subtitle : nil,
                activePort: rt.activePort,
                needs: rt.config.needs.isEmpty ? nil : rt.config.needs,
                waitingFor: rt.phase == .waiting ? rt.waitingFor : nil,
                connections: proxy && rt.isRunningAnywhere ? rt.connectionCount : nil,
                clients: proxy && rt.isRunningAnywhere ? rt.clients.map(\.name) : nil,
                closesAt: rt.closesAt
            )
        }
    }

    // MARK: - Summary for the UI

    /// Services running, proxies left out (they have their own count).
    var runningCount: Int { runtimes.values.filter { !$0.config.isProxy && $0.isRunningAnywhere }.count }
    var openProxyCount: Int { runtimes.values.filter { $0.config.isProxy && $0.isRunningAnywhere }.count }
    var serviceCount: Int { config.services.filter { !$0.isProxy }.count }
    var isBusy: Bool { runtimes.values.contains { $0.phase == .starting || $0.phase == .stopping || $0.phase == .waiting } }
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

    /// Dismiss the service's alert. A crash or a failed start is over: the service becomes stopped (the log
    /// keeps what happened). A situation that still holds (port changed, started outside Runbar on another
    /// port, not responding) goes quiet until it changes or ends.
    func dismissAlert(_ id: String) {
        guard let rt = runtimes[id] else { return }
        switch rt.phase {
        case .crashed, .failed:
            rt.stop()
        default:
            let d = display(rt)
            if d.alert { mutedAlerts[id] = d.alertKey }
        }
    }

    /// A dismissed alert whose situation changed or ended stops being dismissed, so the next one shows.
    func pruneMutedAlerts() {
        for id in mutedAlerts.keys {
            guard let rt = runtimes[id], display(rt).dismissed else {
                mutedAlerts[id] = nil
                continue
            }
        }
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

    private static let showInDockKey = "showInDock"

    func setShowInDock(_ on: Bool) {
        showInDock = on
        UserDefaults.standard.set(on, forKey: Self.showInDockKey)
        applyDockPolicy()
    }

    /// `.accessory` keeps the app to the menu bar, as Info.plist's `LSUIElement` does at launch.
    func applyDockPolicy() {
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
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
    func loadDemo(config: RunbarConfig, now: Date, portOwners: [Int: PortOwner], otherListeners: [Listener], launchdJobs: [Int32: LaunchdJob] = [:]) {
        snapshotMode = true
        self.config = config
        configError = nil
        configWarnings = []
        configLoadedAt = now
        syncRuntimes()
        self.now = now
        self.portOwners = portOwners
        self.otherListeners = otherListeners
        self.launchdJobs = launchdJobs
    }
}
#endif

