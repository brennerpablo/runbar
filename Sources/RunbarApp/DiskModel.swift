import AppKit
import Darwin
import Foundation
import Observation
import RunbarCore

enum DiskAction: Equatable {
    /// Delete build output or tool caches; they come back on their own.
    case clear
    /// Delete dependencies and install them again.
    case reinstall
    /// Delete dependencies Runbar can't reinstall (outside a service, or no lockfile).
    case delete
}

struct DiskJob: Equatable {
    enum Step: Int, Comparable {
        case waiting, stopping, deleting, installing, starting
        static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }
    }

    var item: DiskItem
    var action: DiskAction
    /// Services stopped for the job and started again at the end.
    var services: [String]
    var step: Step
    var stepStartedAt: Date
    var startedAt: Date
    var lastLine: String?
    var installPID: Int32?
    var cancelled = false

    var steps: [Step] {
        (services.isEmpty ? [] : [.stopping]) + [.deleting] + (action == .reinstall ? [.installing] : []) + (services.isEmpty ? [] : [.starting])
    }
}

struct DiskResult: Identifiable, Equatable {
    let id = UUID()
    var ok: Bool
    var title: String
    var detail: String
    var lastLine: String?
    var logURL: URL?
    var retry: DiskItem?
    var retryAction: DiskAction?
    /// Service whose folder it was, to show the result in its detail too.
    var serviceID: String?
}

/// Measures what dependencies and build output take in each project, and clears or reinstalls them.
@MainActor @Observable
final class DiskModel {
    static let shared = DiskModel()

    private(set) var projects: [ProjectDisk] = []
    /// Projects being measured right now.
    private(set) var scanning: Set<String> = []
    private(set) var scannedAt: Date?
    private(set) var freeBytes: UInt64?
    private(set) var capacityBytes: UInt64?
    private(set) var jobs: [String: DiskJob] = [:]
    private(set) var results: [DiskResult] = []
    /// The item (or `DiskModel.allBuildID`) whose confirmation is open.
    var confirming: String?

    static let allBuildID = "#all-build"

    @ObservationIgnored private let scanQueue = DispatchQueue(label: "runbar.disk.scan", qos: .utility)
    @ObservationIgnored private var watchers: [Int32: DispatchSourceProcess] = [:]

    var isScanning: Bool { !scanning.isEmpty }
    var total: UInt64 { projects.reduce(0) { $0 + $1.total } }
    var hasMeasured: Bool { scannedAt != nil || !projects.isEmpty }

    func bytes(_ category: DiskCategory) -> UInt64 {
        projects.reduce(0) { $0 + $1.bytes(category) }
    }

    func items(forService id: String) -> [DiskItem] {
        projects.flatMap(\.items).filter { $0.serviceID == id }
    }

    var buildItems: [DiskItem] {
        projects.flatMap(\.items).filter { $0.category == .build }.sorted { $0.bytes > $1.bytes }
    }

    /// Under 15% of the disk free.
    var lowOnSpace: Bool {
        guard let free = freeBytes, let capacity = capacityBytes, capacity > 0 else { return false }
        return Double(free) / Double(capacity) < 0.15
    }

    // MARK: - Measuring

    func refreshFreeSpace() {
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        freeBytes = values?.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) }
        capacityBytes = values?.volumeTotalCapacity.map { UInt64(max(0, $0)) }
    }

    func scanIfStale(maxAge: TimeInterval = 600) {
        refreshFreeSpace()
        guard !isScanning else { return }
        if let scannedAt, Date().timeIntervalSince(scannedAt) < maxAge { return }
        scan()
    }

    /// Measures in the background, one project at a time; each result shows up as soon as it's ready.
    func scan(only ids: Set<String>? = nil) {
        let config = AppModel.shared.config
        let targets = config.projects.filter { (ids?.contains($0.id) ?? true) && !scanning.contains($0.id) }
        guard !targets.isEmpty else { return }
        scanning.formUnion(targets.map(\.id))
        let order = config.projects.map(\.id)
        scanQueue.async {
            for project in targets {
                let result = DiskScanner.scan(project: project)
                // Finish deletes that were cut short (Runbar quit in the middle).
                for leftover in result.leftovers { try? DiskCleaner.remove(leftover, within: result.root) }
                DispatchQueue.main.async { MainActor.assumeIsolated { self.store(result, order: order) } }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.scannedAt = Date()
                    self.refreshFreeSpace()
                }
            }
        }
    }

    /// Snapshot mode: measures everything before drawing.
    func scanNow() {
        let config = AppModel.shared.config
        let order = config.projects.map(\.id)
        for project in config.projects { store(DiskScanner.scan(project: project), order: order) }
        scannedAt = Date()
        refreshFreeSpace()
    }

    private func store(_ result: ProjectDisk, order: [String]) {
        scanning.remove(result.id)
        projects.removeAll { $0.id == result.id || !order.contains($0.id) }
        projects.append(result)
        projects.sort { $0.total > $1.total }
    }

    // MARK: - Actions

    func primaryAction(for item: DiskItem) -> DiskAction {
        switch item.category {
        case .build, .tools: return .clear
        case .dependencies: return item.serviceID != nil && item.install != nil ? .reinstall : .delete
        }
    }

    /// Services running from the folder that holds the item (or below it): they use it, so they stop first.
    func servicesUsing(_ item: DiskItem) -> [ServiceRuntime] {
        guard item.category != .tools else { return [] }
        return AppModel.shared.runtimes.values.filter { rt in
            let cwd = DiskScanner.standard(rt.config.cwd)
            return (cwd == item.parent || cwd.hasPrefix(item.parent + "/")) && rt.isRunningAnywhere
        }
        .sorted { $0.id < $1.id }
    }

    func perform(_ action: DiskAction, on item: DiskItem) {
        guard jobs[item.id] == nil else { return }
        confirming = nil
        jobs[item.id] = DiskJob(item: item, action: action, services: [], step: .waiting, stepStartedAt: Date(), startedAt: Date())
        Task { @MainActor in await self.run(item: item, action: action) }
    }

    /// Clears every build output folder, one after the other.
    func clearAllBuild() {
        confirming = nil
        let targets = buildItems.filter { jobs[$0.id] == nil }
        for item in targets {
            jobs[item.id] = DiskJob(item: item, action: .clear, services: [], step: .waiting, stepStartedAt: Date(), startedAt: Date())
        }
        Task { @MainActor in
            for item in targets { await self.run(item: item, action: .clear) }
        }
    }

    func cancel(_ itemID: String) {
        guard let pid = jobs[itemID]?.installPID else { return }
        jobs[itemID]?.cancelled = true
        Spawner.signalGroup(pid, SIGTERM)
    }

    func dismiss(_ id: UUID) {
        results.removeAll { $0.id == id }
    }

    private func setStep(_ step: DiskJob.Step, _ id: String) {
        jobs[id]?.step = step
        jobs[id]?.stepStartedAt = Date()
    }

    private func run(item: DiskItem, action: DiskAction) async {
        let model = AppModel.shared
        let started = Date()
        let running = servicesUsing(item)
        let ids = running.map(\.id)
        jobs[item.id]?.services = ids
        jobs[item.id]?.startedAt = started
        let project = projects.first { item.parent == $0.root || item.parent.hasPrefix($0.root + "/") }
        let root = project?.root ?? item.parent

        // 1. Stop what uses the folder.
        if !running.isEmpty {
            setStep(.stopping, item.id)
            for rt in running {
                if rt.isAlive { rt.stop() } else { rt.stopExternal() }
            }
            let deadline = Date().addingTimeInterval(30)
            while ids.contains(where: { model.runtimes[$0]?.isRunningAnywhere == true }), Date() < deadline {
                try? await Task.sleep(for: .milliseconds(250))
            }
            let still = ids.filter { model.runtimes[$0]?.isRunningAnywhere == true }
            if !still.isEmpty {
                return finish(item, action, ok: false, title: "Couldn't stop \(Self.list(still))",
                              detail: "Nothing was deleted.", projectID: project?.id)
            }
        }

        // 2. Delete.
        setStep(.deleting, item.id)
        let paths = item.paths
        let failure: String? = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var message: String?
                for path in paths {
                    do { try DiskCleaner.remove(path, within: root) } catch { message = "\(error)"; break }
                }
                cont.resume(returning: message)
            }
        }
        if let failure {
            restart(ids)
            return finish(item, action, ok: false, title: "Couldn't delete \(item.name)", detail: failure, projectID: project?.id)
        }

        // 3. Install again.
        if action == .reinstall, let command = item.install {
            setStep(.installing, item.id)
            let logURL = item.serviceID.map { Paths.logFile(for: $0) } ?? Paths.logsDir.appendingPathComponent("disk.log")
            let code = await install(command, item: item, logURL: logURL)
            let lastLine = jobs[item.id]?.lastLine ?? Self.lastLine(of: logURL)
            if jobs[item.id]?.cancelled == true || code != 0 {
                let stays = ids.isEmpty ? "" : "\(Self.list(ids)) \(ids.count == 1 ? "stays" : "stay") stopped until \(item.name) is installed."
                let title = jobs[item.id]?.cancelled == true ? "Install cancelled" : "\(Self.shortCommand(command)) failed · exit code \(code)"
                return finish(item, action, ok: false, title: title, detail: stays.isEmpty ? "\(item.name) is not installed." : stays,
                              lastLine: lastLine, logURL: logURL, projectID: project?.id)
            }
        }

        // 4. Start what was running.
        if !ids.isEmpty {
            setStep(.starting, item.id)
            restart(ids)
        }
        let size = Format.memory(item.bytes)
        let place = Self.place(of: item)
        switch action {
        case .reinstall:
            let took = Self.seconds(Date().timeIntervalSince(started))
            finish(item, action, ok: true, title: "Reinstalled \(item.name) in \(took)",
                   detail: ids.isEmpty ? "in \(place)" : "\(Self.list(ids)) \(ids.count == 1 ? "is" : "are") starting again",
                   projectID: project?.id)
        case .clear:
            let rebuild = item.category == .build && !ids.isEmpty ? " · rebuilding on start" : ""
            finish(item, action, ok: true, title: "Freed \(size)", detail: "Cleared \(item.name) in \(place)\(rebuild)", projectID: project?.id)
        case .delete:
            finish(item, action, ok: true, title: "Freed \(size)", detail: "Deleted \(item.name) in \(place)", projectID: project?.id)
        }
    }

    private func restart(_ ids: [String]) {
        for id in ids { AppModel.shared.runtimes[id]?.start() }
    }

    private func finish(_ item: DiskItem, _ action: DiskAction, ok: Bool, title: String, detail: String,
                        lastLine: String? = nil, logURL: URL? = nil, projectID: String?) {
        jobs[item.id] = nil
        results.insert(DiskResult(ok: ok, title: title, detail: detail, lastLine: lastLine, logURL: logURL,
                                  retry: ok ? nil : item, retryAction: ok ? nil : action, serviceID: item.serviceID), at: 0)
        if results.count > 3 { results.removeLast(results.count - 3) }
        refreshFreeSpace()
        if let projectID { scan(only: [projectID]) }
    }

    /// Runs the install in the item's folder, with its output appended to the service's log.
    private func install(_ command: String, item: DiskItem, logURL: URL) async -> Int32 {
        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.logsDir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
        let header = "\n── Runbar · \(Format.stamp(Date())) · install: \(command) · in \(Paths.abbreviate(item.parent))\n"
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(header.utf8))
            try? handle.close()
        }
        var env = ProcessInfo.processInfo.environment
        for key in ["__CFBundleIdentifier", "XPC_SERVICE_NAME", "XPC_FLAGS", "TERM_SESSION_ID", "OLDPWD", "PWD"] { env[key] = nil }
        env["CI"] = "1"
        let shell = AppModel.shared.config.settings.shell
        let pid: Int32
        do {
            pid = try Spawner.spawn(shell: shell, command: command, cwd: item.parent, environment: env, logPath: logURL.path)
        } catch {
            jobs[item.id]?.lastLine = "could not start: \(error)"
            return 127
        }
        jobs[item.id]?.installPID = pid
        let tail = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if let line = Self.lastLine(of: logURL) { self.jobs[item.id]?.lastLine = line }
            }
        }
        let code = await waitForExit(pid)
        tail.cancel()
        if let line = Self.lastLine(of: logURL) { jobs[item.id]?.lastLine = line }
        return code
    }

    private func waitForExit(_ pid: Int32) async -> Int32 {
        await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            var finished = false
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
            func complete() {
                guard !finished else { return }
                var status: Int32 = 0
                guard waitpid(pid, &status, WNOHANG) == pid else { return }
                finished = true
                source.cancel()
                // Both callers run on the main queue: the setup below and the source's handler.
                MainActor.assumeIsolated { self.watchers[pid] = nil }
                cont.resume(returning: Spawner.exitCode(fromWaitStatus: status))
            }
            source.setEventHandler { complete() }
            MainActor.assumeIsolated { self.watchers[pid] = source }
            source.resume()
            // It may have ended before the watcher was set up.
            complete()
        }
    }

    // MARK: - Text

    nonisolated static func lastLine(of url: URL) -> String? {
        LogTailer.lastLines(of: url, count: 4, maxBytes: 16_000)
            .map(TerminalText.clean)
            .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("── Runbar") }
    }

    /// "npm ci", "pnpm install", "pip install", "uv sync".
    nonisolated static func shortCommand(_ command: String) -> String {
        if command.contains("pip install") { return "pip install" }
        return command.split(separator: " ").prefix(2).joined(separator: " ")
    }

    /// "acme-web", "wt-checkout-redesign", or the project's own folder.
    nonisolated static func place(of item: DiskItem) -> String {
        item.serviceID ?? (item.folder.isEmpty ? Paths.abbreviate(item.parent) : item.folder)
    }

    nonisolated static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }

    nonisolated static func seconds(_ interval: TimeInterval) -> String {
        let s = Int(interval.rounded())
        return s < 60 ? "\(s) s" : "\(s / 60)m \(String(format: "%02d", s % 60))s"
    }
}

#if DEBUG
extension DiskModel {
    /// README screenshots: made-up measurements, nothing scanned.
    func loadDemo(projects: [ProjectDisk], free: UInt64, capacity: UInt64, scannedAt: Date, confirming: String? = nil) {
        self.projects = projects.sorted { $0.total > $1.total }
        freeBytes = free
        capacityBytes = capacity
        self.scannedAt = scannedAt
        scanning = []
        jobs = [:]
        results = []
        self.confirming = confirming
    }
}
#endif

