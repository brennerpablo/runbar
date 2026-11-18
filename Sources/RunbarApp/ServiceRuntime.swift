import Darwin
import Foundation
import Observation
import RunbarCore

struct LogLine: Identifiable, Equatable {
    enum Kind { case normal, error, warning, success, meta }
    let id: Int
    let text: String
    let kind: Kind

    init(id: Int, text: String) {
        self.id = id
        self.text = text
        self.kind = LogLine.classify(text)
    }

    static func classify(_ t: String) -> Kind {
        if t.hasPrefix("── Runbar") { return .meta }
        let l = t.lowercased()
        if l.contains("error") || l.contains("traceback") || l.contains("exception") || l.contains("failed") || l.contains("erro:") { return .error }
        if l.contains("warn") || t.contains("⚠") { return .warning }
        if t.contains("✓") || l.contains("ready in") || l.contains("startup complete") || l.contains("started server") || l.contains("compiled") { return .success }
        return .normal
    }
}

/// A service that is running but was started outside Runbar (e.g. in Terminal).
struct ExternalRun: Equatable {
    var rootPID: Int32
    var pids: Set<Int32>
    var ports: [Int]
    var memory: UInt64
    var cpu: Double
    var startedAt: Date
}

struct MetricPoint: Identifiable, Equatable {
    let id: Int
    let date: Date
    let value: Double
}

/// Something connected to a proxy: a Runbar service (all its processes together) or another process.
struct ProxyClient: Identifiable, Equatable {
    var id: String
    var name: String
    var serviceID: String?
    var pid: Int32
    var connections: Int
}

/// Live state of a service: process, log, ports, memory and CPU.
@MainActor @Observable
final class ServiceRuntime: Identifiable {
    enum Phase: Equatable {
        case stopped, starting, running, stopping
        /// Opening what it needs (`needs`) before starting.
        case waiting
        case crashed(Int32?)
        case failed(String)
    }

    let id: String
    var config: ServiceConfig
    var orphaned = false

    private(set) var phase: Phase = .stopped
    private(set) var pid: Int32?
    private(set) var startedAt: Date?
    private(set) var lastLogAt: Date?
    private(set) var lastExitCode: Int32?
    private(set) var exitedAt: Date?
    private(set) var logs: [LogLine] = []
    private(set) var listening: [Int] = []
    private(set) var memory: UInt64 = 0
    private(set) var cpu: Double = 0
    private(set) var processCount = 0
    private(set) var memHistory: [MetricPoint] = []
    private(set) var cpuHistory: [MetricPoint] = []
    private(set) var appliedSignature: String?
    private(set) var gaveUpRestarting = false
    /// Port the process was started with; `fallbackFrom` is the configured one when autoPort switched.
    private(set) var activePort: Int?
    private(set) var fallbackFrom: Int?
    var healthy: Bool?
    private(set) var external: ExternalRun?
    /// While waiting: the services from `needs` that aren't open yet.
    private(set) var waitingFor: [String] = []

    // Proxies, kept up to date by the model on every scan.
    /// Who is connected now.
    var clients: [ProxyClient] = []
    /// Running services that need this proxy: it stays open while any of them runs.
    var heldBy: [String] = []
    /// Since when nothing uses it (no connections, no service holding it).
    var idleSince: Date?
    /// When Runbar last closed it for being idle (cleared on the next start).
    private(set) var closedIdleAt: Date?
    /// The log since the last start says the tool's sign-in expired, and when Runbar first saw it.
    private(set) var signInExpiredAt: Date?

    @ObservationIgnored private(set) var treePIDs: Set<Int32> = []
    @ObservationIgnored private(set) var processStart: Double?
    @ObservationIgnored private var isChild = false
    @ObservationIgnored private var exitSource: DispatchSourceProcess?
    @ObservationIgnored private var tailer: LogTailer?
    @ObservationIgnored private var killWork: DispatchWorkItem?
    @ObservationIgnored private var restartWork: DispatchWorkItem?
    @ObservationIgnored private var userStopped = false
    @ObservationIgnored private var restartAfterExit = false
    @ObservationIgnored private var lastCPU: UInt64?
    @ObservationIgnored private var lastCPUAt: Date?
    @ObservationIgnored private var crashTimes: [Date] = []
    @ObservationIgnored private var nextLineID = 0
    @ObservationIgnored private var nextPointID = 0
    @ObservationIgnored private var stopHelpers: [DispatchSourceProcess] = []
    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private var externalCPU: (root: Int32, nanos: UInt64, at: Date)?
    @ObservationIgnored private var waitTask: Task<Void, Never>?

    init(config: ServiceConfig, model: AppModel) {
        self.id = config.id
        self.config = config
        self.model = model
        let backlog = LogTailer.lastLines(of: Paths.logFile(for: config.id), count: 200, maxBytes: 64_000)
        append(backlog, markActivity: false)
        lastLogAt = LogTailer.modificationDate(Paths.logFile(for: config.id))
    }

    var isAlive: Bool { pid != nil }
    var isRunningAnywhere: Bool { isAlive || external != nil }
    var logURL: URL { Paths.logFile(for: id) }
    var needsRestart: Bool { isAlive && appliedSignature != nil && appliedSignature != config.launchSignature }

    /// Port the service is actually listening on.
    var realPort: Int? {
        if let p = expectedPort, listening.contains(p) { return p }
        return listening.first
    }

    /// Port the service should be on: the one chosen at start, or the configured one.
    var expectedPort: Int? { activePort ?? config.port }

    var lastLine: String? { logs.last(where: { $0.kind != .meta })?.text }

    /// Connections open to the proxy right now.
    var connectionCount: Int { clients.reduce(0) { $0 + $1.connections } }

    /// When an idle proxy closes, if nothing connects first.
    var closesAt: Date? {
        guard config.isProxy, isAlive, phase == .running, let idleSince, let idle = config.idle else { return nil }
        return idleSince.addingTimeInterval(idle)
    }

    func update(config newConfig: ServiceConfig) {
        orphaned = false
        if newConfig != config { config = newConfig }
    }

    // MARK: - Lifecycle

    /// Starts the service, opening what it needs first: it waits (phase `.waiting`) until each one's port
    /// answers, up to 30 seconds.
    func start() {
        guard !isAlive, phase != .waiting else { return }
        restartWork?.cancel()
        restartWork = nil
        if let model, !config.needs.isEmpty {
            switch model.openNeeds(of: config) {
            case .ready:
                break
            case .failed(let message):
                phase = .failed(message)
                return
            case .pending(let ids):
                wait(for: ids)
                return
            }
        }
        launch()
    }

    private func wait(for ids: [String]) {
        waitingFor = ids
        phase = .waiting
        let deadline = Date().addingTimeInterval(30)
        waitTask?.cancel()
        waitTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.phase == .waiting, let model = self.model else { return }
                // Something it needs closed meanwhile (idle, or by hand) opens again: this one still wants it.
                switch model.openNeeds(of: self.config, retryFailed: false) {
                case .ready:
                    self.waitTask = nil
                    self.waitingFor = []
                    self.phase = .stopped
                    self.launch()
                    return
                case .failed(let message):
                    self.waitTask = nil
                    self.waitingFor = []
                    self.phase = .failed(message)
                    return
                case .pending(let ids):
                    if ids != self.waitingFor { self.waitingFor = ids }
                    if Date() > deadline {
                        self.waitTask = nil
                        self.waitingFor = []
                        self.phase = .failed("\(ids.joined(separator: ", ")) didn't open in 30 seconds")
                        return
                    }
                }
            }
        }
    }

    private func launch() {
        guard !isAlive else { return }
        let cfg = config
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cfg.cwd, isDirectory: &isDir), isDir.boolValue else {
            phase = .failed("folder \(Paths.abbreviate(cfg.cwd)) does not exist")
            return
        }
        // Runbar exports PORT: with the port taken the server would just crash.
        // With autoPort, start on the next free one; without it, warn before trying.
        var launchPort = cfg.port
        var fallback: Int?
        if let port = cfg.port, cfg.type != .docker, PortProbe.isInUse(port) {
            if cfg.autoPort, let free = model?.nextFreePort(after: port, for: cfg.id) {
                launchPort = free
                fallback = port
            } else {
                let owner = model?.portOwners[port]?.label ?? "another process"
                phase = .failed("port :\(port) is in use by \(owner)")
                return
            }
        }
        let offset = prepareLog(port: launchPort, fallbackFrom: fallback)
        let shell = model?.config.settings.shell ?? "/bin/zsh"
        do {
            let newPID = try Spawner.spawn(shell: shell, command: cfg.command(port: launchPort), cwd: cfg.cwd,
                                           environment: environment(port: launchPort), logPath: logURL.path)
            activePort = launchPort
            fallbackFrom = fallback
            userStopped = false
            gaveUpRestarting = false
            closedIdleAt = nil
            idleSince = nil
            clients = []
            appliedSignature = cfg.launchSignature
            memHistory = []
            cpuHistory = []
            processStart = ProcScanner.sample(pid: newPID)?.startTime.timeIntervalSince1970
            phase = .starting
            attach(pid: newPID, startedAt: Date(), isChild: true, logOffset: offset)
            model?.persistState()
        } catch {
            phase = .failed("could not start: \(error)")
        }
    }

    /// Re-adopts a process that was already running (Runbar was restarted).
    func adopt(pid: Int32, startedAt: Date, processStart: Double, signature: String, activePort: Int?) {
        guard !isAlive else { return }
        self.processStart = processStart
        self.activePort = activePort ?? config.port
        fallbackFrom = (activePort != nil && activePort != config.port) ? config.port : nil
        appliedSignature = signature
        phase = .starting
        attach(pid: pid, startedAt: startedAt, isChild: false, logOffset: LogTailer.fileSize(logURL))
        lastLogAt = LogTailer.modificationDate(logURL)
    }

    func stop() {
        restartWork?.cancel()
        restartWork = nil
        restartAfterExit = false
        if phase == .waiting {
            waitTask?.cancel()
            waitTask = nil
            waitingFor = []
            phase = .stopped
            return
        }
        guard let pid else {
            switch phase {
            case .crashed, .failed: phase = .stopped
            default: break
            }
            return
        }
        userStopped = true
        phase = .stopping
        if let extra = config.stop { runStopCommand(extra) }
        Spawner.signalGroup(pid, SIGTERM)
        for p in treePIDs where p != pid { kill(p, SIGTERM) }
        let tree = treePIDs
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pid == pid else { return }
                Spawner.signalGroup(pid, SIGKILL)
                for p in tree.union(self.treePIDs) { kill(p, SIGKILL) }
            }
        }
        killWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (config.stop == nil ? 6 : 25), execute: work)
    }

    func restart() {
        if isAlive {
            stop()
            restartAfterExit = true
        } else {
            start()
        }
    }

    /// A proxy nothing used for its whole `idle` time: closed, with a line in its log saying why.
    func closeForIdle() {
        guard isAlive, let idle = config.idle else { return }
        writeMeta("closed after \(IdleSetting.human(idle)) with no connections")
        stop()
        closedIdleAt = Date()
    }

    /// A "── Runbar" line in the service's log, for things Runbar did to it.
    private func writeMeta(_ text: String) {
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        handle.write(Data("── Runbar · \(Format.stamp(Date())) · \(text)\n".utf8))
    }

    /// Terminates immediately (Runbar quitting).
    func terminateNow() {
        guard let pid else { return }
        userStopped = true
        Spawner.signalGroup(pid, SIGTERM)
        for p in treePIDs where p != pid { kill(p, SIGTERM) }
    }

    func forceKillIfAlive() {
        guard let pid else { return }
        Spawner.signalGroup(pid, SIGKILL)
        for p in treePIDs { kill(p, SIGKILL) }
    }

    private func attach(pid: Int32, startedAt: Date, isChild: Bool, logOffset: UInt64) {
        self.pid = pid
        self.startedAt = startedAt
        self.isChild = isChild
        lastCPU = nil
        lastCPUAt = nil
        cpu = 0
        memory = 0
        listening = []
        healthy = nil
        treePIDs = [pid]

        let src = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.handleExit() }
        }
        src.resume()
        exitSource = src

        tailer?.stop()
        let t = LogTailer(url: logURL, startOffset: logOffset) { [weak self] lines in
            MainActor.assumeIsolated { self?.append(lines, markActivity: true) }
        }
        tailer = t
        t.start()

        if kill(pid, 0) != 0 && errno == ESRCH { handleExit() }
    }

    private func handleExit() {
        guard let pid else { return }
        var code: Int32?
        if isChild {
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == pid { code = Spawner.exitCode(fromWaitStatus: status) }
        }
        exitSource?.cancel()
        exitSource = nil
        killWork?.cancel()
        killWork = nil
        // Clean up what's left in the group (child servers still holding the port).
        Spawner.signalGroup(pid, SIGTERM)
        for p in treePIDs where p != pid { kill(p, SIGTERM) }
        tailer?.poll()

        self.pid = nil
        treePIDs = []
        processStart = nil
        activePort = nil
        fallbackFrom = nil
        listening = []
        memory = 0
        cpu = 0
        processCount = 0
        healthy = nil
        exitedAt = Date()
        lastExitCode = code
        let requested = userStopped
        userStopped = false

        if restartAfterExit {
            restartAfterExit = false
            phase = .stopped
            model?.persistState()
            start()
            return
        }
        if requested || code == 0 {
            phase = .stopped
        } else {
            phase = .crashed(code)
            model?.serviceCrashed(self)
            scheduleAutoRestart()
        }
        model?.persistState()
        if orphaned { model?.dropOrphan(id) }
    }

    private func scheduleAutoRestart() {
        guard config.restart == .onCrash, !orphaned else { return }
        let now = Date()
        crashTimes = crashTimes.filter { now.timeIntervalSince($0) < 120 } + [now]
        guard crashTimes.count <= 3 else {
            gaveUpRestarting = true
            return
        }
        let delay = pow(2.0, Double(crashTimes.count - 1))
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isAlive, case .crashed = self.phase else { return }
                self.start()
            }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func runStopCommand(_ command: String) {
        let shell = model?.config.settings.shell ?? "/bin/zsh"
        let resolved = command.replacingOccurrences(of: "{port}", with: expectedPort.map(String.init) ?? "")
        guard let helper = try? Spawner.spawn(shell: shell, command: resolved, cwd: config.cwd, environment: environment(port: expectedPort), logPath: logURL.path) else { return }
        let src = DispatchSource.makeProcessSource(identifier: helper, eventMask: .exit, queue: .main)
        src.setEventHandler { [weak self, weak src] in
            var status: Int32 = 0
            waitpid(helper, &status, WNOHANG)
            src?.cancel()
            MainActor.assumeIsolated { self?.stopHelpers.removeAll { $0 === src } }
        }
        src.resume()
        stopHelpers.append(src)
    }

    // MARK: - Log

    private func prepareLog(port: Int?, fallbackFrom: Int?) -> UInt64 {
        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.logsDir, withIntermediateDirectories: true)
        let path = logURL.path
        if LogTailer.fileSize(logURL) > 10_000_000 {
            let old = path + ".1"
            try? fm.removeItem(atPath: old)
            try? fm.moveItem(atPath: path, toPath: old)
        }
        if !fm.fileExists(atPath: path) { fm.createFile(atPath: path, contents: nil) }
        let stamp = Format.stamp(Date())
        var header = "\n── Runbar · \(stamp) · \(config.command(port: port)) · in \(Paths.abbreviate(config.cwd))"
        if let fallbackFrom, let port { header += " · on :\(port) because :\(fallbackFrom) was taken" }
        header += "\n"
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return 0 }
        defer { try? handle.close() }
        let offset = (try? handle.seekToEnd()) ?? 0
        handle.write(Data(header.utf8))
        return offset
    }

    private func append(_ lines: [String], markActivity: Bool) {
        guard !lines.isEmpty else { return }
        var batch = logs
        // A proxy's sign-in counts as expired from the line that says so until the next start.
        let tool = config.isProxy ? config.proxyTool : .other
        var expired = signInExpiredAt != nil
        for l in lines {
            nextLineID += 1
            let line = LogLine(id: nextLineID, text: l)
            batch.append(line)
            if line.kind == .meta { expired = false } else if tool.isSignInProblem(l) { expired = true }
        }
        if batch.count > 600 { batch.removeFirst(batch.count - 500) }
        logs = batch
        if markActivity, lines.contains(where: { !$0.hasPrefix("── Runbar") }) { lastLogAt = Date() }
        if expired != (signInExpiredAt != nil) { signInExpiredAt = expired ? Date() : nil }
    }

    /// The user signed in again: a proxy that was open or failing tries again; a closed one just forgets.
    func signedInAgain() {
        guard signInExpiredAt != nil else { return }
        signInExpiredAt = nil
        if isAlive {
            restart()
        } else {
            switch phase {
            case .crashed, .failed: start()
            default: break
            }
        }
    }

    func pollLog() { tailer?.poll() }

    private func environment(port: Int?) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in ["__CFBundleIdentifier", "XPC_SERVICE_NAME", "XPC_FLAGS", "TERM_SESSION_ID", "OLDPWD", "PWD"] { env[key] = nil }
        if let p = port ?? config.port { env["PORT"] = String(p) }
        if let f = config.envFile { env.merge(Spawner.parseEnvFile(f)) { _, new in new } }
        env.merge(config.env) { _, new in new }
        env["RUNBAR_SERVICE"] = config.id
        return env
    }

    // MARK: - Metrics

    func apply(_ snap: ProcSnapshot, sampleHistory: Bool, portOpenAnywhere: Bool) {
        guard let pid else { return }
        let tree = snap.tree(of: pid)
        treePIDs = Set(tree)
        guard !tree.isEmpty else { return }
        var mem: UInt64 = 0
        var nanos: UInt64 = 0
        var ports = Set<Int>()
        for p in tree {
            if let s = snap.procs[p] {
                mem += s.footprint
                nanos += s.cpuNanos
            }
            if let l = snap.listening[p] { ports.formUnion(l) }
        }
        if let last = lastCPU, let at = lastCPUAt {
            let dt = snap.time.timeIntervalSince(at)
            if dt > 0.2 { cpu = max(0, (Double(nanos) - Double(last)) / (dt * 1e9) * 100) }
        }
        lastCPU = nanos
        lastCPUAt = snap.time
        memory = mem
        processCount = tree.count
        let sorted = ports.sorted()
        if sorted != listening { listening = sorted }

        if phase == .starting { evaluateStarting(portOpenAnywhere: portOpenAnywhere) }

        if sampleHistory, phase != .stopping {
            nextPointID += 1
            memHistory.append(MetricPoint(id: nextPointID, date: snap.time, value: Double(mem)))
            cpuHistory.append(MetricPoint(id: nextPointID, date: snap.time, value: cpu))
            if memHistory.count > 120 { memHistory.removeFirst(memHistory.count - 120) }
            if cpuHistory.count > 120 { cpuHistory.removeFirst(cpuHistory.count - 120) }
        }
    }

    func applyExternal(root: Int32?, snap: ProcSnapshot) {
        guard let root, !isAlive else {
            if external != nil { external = nil }
            externalCPU = nil
            return
        }
        let pids = snap.descendants(of: root)
        var mem: UInt64 = 0
        var nanos: UInt64 = 0
        var ports = Set<Int>()
        for p in pids {
            if let s = snap.procs[p] {
                mem += s.footprint
                nanos += s.cpuNanos
            }
            if let l = snap.listening[p] { ports.formUnion(l) }
        }
        var usage = external?.rootPID == root ? (external?.cpu ?? 0) : 0
        if let prev = externalCPU, prev.root == root {
            let dt = snap.time.timeIntervalSince(prev.at)
            if dt > 0.2 { usage = max(0, (Double(nanos) - Double(prev.nanos)) / (dt * 1e9) * 100) }
        }
        externalCPU = (root, nanos, snap.time)
        let run = ExternalRun(rootPID: root, pids: Set(pids), ports: ports.sorted(), memory: mem, cpu: usage,
                              startedAt: snap.procs[root]?.startTime ?? Date())
        if run != external { external = run }
    }

    /// Stops a service that was started outside Runbar.
    func stopExternal() {
        guard let e = external else { return }
        for p in e.pids { kill(p, SIGTERM) }
    }

    /// A proxy's connections and holders from the latest scan, and the idle clock that follows from them.
    func applyUsage(clients newClients: [ProxyClient], heldBy holders: [String], at time: Date) {
        if newClients != clients { clients = newClients }
        if holders != heldBy { heldBy = holders }
        let inUse = !newClients.isEmpty || !holders.isEmpty
        if inUse || !isAlive || phase != .running {
            if idleSince != nil { idleSince = nil }
        } else if idleSince == nil {
            idleSince = time
        }
    }

    func evaluateStarting(portOpenAnywhere: Bool = false) {
        guard phase == .starting, let startedAt else { return }
        let age = Date().timeIntervalSince(startedAt)
        if config.port == nil {
            if age > 1.5 { phase = .running }
            return
        }
        let listeningOK = !listening.isEmpty || (config.type == .docker && portOpenAnywhere && age > 3)
        if listeningOK && (config.health == nil || healthy == true) { phase = .running }
    }
}

#if DEBUG
extension ServiceRuntime {
    /// README screenshots: puts the service in a made-up state (no process behind it).
    func loadDemo(phase: Phase, pid: Int32? = nil, startedAt: Date? = nil, lastLogAt: Date? = nil, exitedAt: Date? = nil,
                  exitCode: Int32? = nil, memoryMB: Double = 0, cpu: Double = 0, processCount: Int = 0, listening: [Int] = [],
                  memHistoryMB: [Double] = [], cpuSeries: [Double] = [], at now: Date, logs: [String] = [], external: ExternalRun? = nil) {
        self.phase = phase
        self.pid = pid
        self.startedAt = startedAt
        self.lastLogAt = lastLogAt
        self.exitedAt = exitedAt
        self.lastExitCode = exitCode
        self.memory = UInt64(memoryMB * 1_048_576)
        self.cpu = cpu
        self.processCount = processCount
        self.listening = listening
        self.external = external
        func points(_ values: [Double], _ scale: Double) -> [MetricPoint] {
            values.enumerated().map { MetricPoint(id: $0.offset, date: now.addingTimeInterval(Double($0.offset - values.count + 1) * 15), value: $0.element * scale) }
        }
        self.memHistory = points(memHistoryMB, 1_048_576)
        self.cpuHistory = points(cpuSeries, 1)
        self.logs = logs.enumerated().map { LogLine(id: $0.offset, text: $0.element) }
    }

    /// README screenshots: who uses a made-up proxy.
    func loadDemoUsage(clients: [ProxyClient] = [], heldBy: [String] = [], idleSince: Date? = nil, closedIdleAt: Date? = nil) {
        self.clients = clients
        self.heldBy = heldBy
        self.idleSince = idleSince
        self.closedIdleAt = closedIdleAt
    }
}
#endif

