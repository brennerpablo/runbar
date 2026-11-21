import Foundation
import RunbarCore

enum FixAction: Equatable {
    case stopService(String)
    case killProcess(Int32)
    /// The port's owner is a launchd job: killing it would only make launchd start it again.
    case turnOffLaunchd(String, Int32)
    case takeOverExternal
    /// Run the proxy tool's sign-in in Terminal.
    case signIn
    /// Open what a running service needs, closed meanwhile.
    case openNeeds
}

/// What the UI shows for a service, derived from its state.
struct ServiceDisplay {
    enum Dot { case running, busy, stopped, warning, error }
    enum Action { case start, stop, retry }

    var dot: Dot = .stopped
    var action: Action = .start
    var statusLabel = "Stopped"
    var subtitle = ""
    var subtitleMono = false
    var warn = false
    var alert = false
    var isAlive = false
    var isExternal = false
    var isProxy = false
    /// Between states (starting, stopping, waiting): what it's doing, in a few words ("stopping…").
    var busyText: String?
    /// The stop was sent and it hasn't exited yet: stopping again does nothing.
    var stopping = false
    var memory: UInt64?
    var cpu: Double?
    /// Proxies: connections open now (nil when closed).
    var connections: Int?
    var realPort: Int?
    var portLabel: String?
    var url: URL?
    var banner: String?
    /// Neutral notice (not a problem), such as the port autoPort switched to.
    var info: String?
    var fix: FixAction?
    var fixLabel: String?
    /// One line for "Needs you" when it says more than `subtitle` ("node (PID 4821) holds :3100").
    var reason: String?
    var note: String?
    /// The alert is still true but the user dismissed it: no strip, no menu bar badge, no count.
    var dismissed = false

    /// Identifies one alert: the same text means the same situation.
    var alertKey: String { "\(statusLabel)|\(subtitle)" }

    /// The one-line reason "Needs you" shows.
    var alertLine: String { reason ?? subtitle }

    var actionSymbol: String {
        switch action {
        case .start: return "play.fill"
        case .stop: return "stop.fill"
        case .retry: return "arrow.clockwise"
        }
    }
}

extension AppModel {
    func display(_ rt: ServiceRuntime) -> ServiceDisplay {
        let cfg = rt.config
        let port = cfg.port
        let proxy = cfg.isProxy
        var d = ServiceDisplay()
        d.isProxy = proxy

        func blocker(of p: Int) -> PortOwner? {
            guard let owner = portOwners[p], !rt.treePIDs.contains(owner.pid) else { return nil }
            return owner
        }
        func fix(for owner: PortOwner) -> FixAction {
            if let sid = owner.serviceID { return .stopService(sid) }
            if let job = launchdJobs[owner.pid], job.keepAlive { return .turnOffLaunchd(job.label, owner.pid) }
            return .killProcess(owner.pid)
        }
        /// "Stop acme-web", "Kill node", "Turn off br.com.acme.proxy": the first half of a fix's label.
        func fixLead(_ owner: PortOwner) -> String {
            if owner.serviceID != nil { return "Stop \(owner.label)" }
            if let job = launchdJobs[owner.pid], job.keepAlive { return "Turn off \(job.label)" }
            return "Kill \(owner.name)"
        }

        if rt.isAlive, rt.memory > 0 {
            d.memory = rt.memory
            d.cpu = rt.cpu
        }
        d.realPort = rt.realPort

        switch rt.phase {
        case .waiting:
            d.dot = .busy
            d.action = .stop
            d.statusLabel = "Waiting"
            d.portLabel = port.map { ":\($0)" }
            d.subtitle = "waiting for \(rt.waitingFor.joined(separator: ", "))…"

        case .starting:
            d.isAlive = true
            d.dot = .busy
            d.action = .stop
            d.statusLabel = proxy ? "Opening" : "Starting"
            d.portLabel = (rt.realPort ?? rt.expectedPort).map { ":\($0)" }
            d.subtitle = proxy ? "opening…" : "starting…"
            d.busyText = d.subtitle
            if let active = rt.activePort, let from = rt.fallbackFrom {
                d.subtitle = "starting on :\(active) · :\(from) was taken"
            } else if let port, let owner = blocker(of: port), cfg.type != .docker {
                d.subtitle = "\(d.subtitle) :\(port) is in use by \(owner.label)"
                d.warn = true
            } else if rt.config.health != nil, rt.healthy == false {
                d.subtitle = "waiting for \(rt.config.health!) to respond"
            }

        case .running:
            d.isAlive = true
            d.action = .stop
            d.dot = .running
            d.statusLabel = proxy ? "Open" : "Running"
            let real = rt.realPort
            let expected = rt.expectedPort
            d.portLabel = (real ?? expected).map { ":\($0)" }
            d.url = cfg.url(port: real ?? expected)
            let since = rt.startedAt.map { "since \(Format.clock($0, now: now))" } ?? "running"
            let log = rt.lastLogAt.map { "log \(Format.ago($0, now: now))" } ?? "no log"
            d.subtitle = proxy ? proxyUsage(rt) : "\(since) · \(log)"
            if let expected, let real, real != expected {
                d.dot = .warning
                d.warn = true
                d.alert = true
                d.statusLabel = "Port changed"
                d.subtitle = "on :\(real) · expected :\(expected)"
                if let owner = blocker(of: expected) {
                    d.reason = "\(owner.label) holds :\(expected)"
                    d.banner = "Port :\(expected) was taken by \(owner.label), so the service started on :\(real)."
                    d.fix = fix(for: owner)
                    d.fixLabel = "\(fixLead(owner)) and restart this one"
                } else {
                    d.banner = "The service is on :\(real), not :\(expected). Check whether the command sets a different port."
                }
            } else if cfg.health != nil, rt.healthy == false {
                d.dot = .warning
                d.warn = true
                d.alert = true
                d.statusLabel = "Not responding"
                d.subtitle = "\(cfg.health!) is not responding"
            } else if let active = rt.activePort, let from = rt.fallbackFrom {
                d.subtitle = "\(since) · :\(from) taken"
                var text = "Port :\(from) was taken, so this service started on :\(active) (autoPort)."
                if let owner = blocker(of: from) {
                    text = "Port :\(from) was taken by \(owner.label), so this service started on :\(active) (autoPort)."
                    d.fix = fix(for: owner)
                    d.fixLabel = "\(fixLead(owner)) and go back to :\(from)"
                }
                d.info = text
            } else if !proxy {
                let closed = cfg.needs.filter { runtimes[$0]?.isRunningAnywhere == false }
                if !closed.isEmpty {
                    let names = closed.joined(separator: ", ")
                    d.info = "\(names) \(closed.count == 1 ? "is" : "are") closed, so \(rt.id) may not reach what it needs."
                    d.fix = .openNeeds
                    d.fixLabel = "Open \(names)"
                }
            }

        case .stopping:
            d.isAlive = true
            d.dot = .busy
            d.action = .stop
            d.statusLabel = proxy ? "Closing" : "Stopping"
            d.subtitle = proxy ? "closing…" : "stopping…"
            d.busyText = d.subtitle
            d.stopping = true
            d.portLabel = port.map { ":\($0)" }

        case .stopped where rt.external != nil:
            let ext = rt.external!
            d.isExternal = true
            d.dot = .running
            d.action = .stop
            d.statusLabel = "Outside Runbar"
            d.memory = ext.memory
            d.cpu = ext.cpu
            let real = port.flatMap { ext.ports.contains($0) ? $0 : nil } ?? ext.ports.first
            d.realPort = real
            d.portLabel = (real ?? port).map { ":\($0)" }
            d.url = cfg.url(port: real)
            d.subtitle = "outside Runbar · since \(Format.clock(ext.startedAt, now: now))"
            if proxy { d.subtitle = "outside Runbar · " + proxyUsage(rt) }
            if let port, let real, real != port {
                d.warn = true
                d.alert = true
                d.subtitle = "outside Runbar · config :\(port)"
            }
            d.banner = proxy
                ? "This proxy was started outside Runbar (in Terminal, for example). Runbar shows who uses it, but won't close it when idle or show its output. Stop it and open it from Runbar."
                : "This service was started outside Runbar (in Terminal, for example). Runbar shows its port, memory and CPU, but not its output. Stop it and start it from Runbar to follow its logs."
            d.fix = .takeOverExternal
            d.fixLabel = proxy ? "Stop and open from Runbar" : "Stop and start from Runbar"
            if rt.isStoppingExternal {
                d.dot = .busy
                d.stopping = true
                d.statusLabel = "Stopping"
                d.busyText = "stopping…"
                d.subtitle = "stopping · outside Runbar"
                d.warn = false
                d.alert = false
                d.fix = nil
                d.fixLabel = nil
                d.url = nil
            }

        case .stopped:
            d.action = .start
            d.statusLabel = proxy ? "Closed" : "Stopped"
            d.portLabel = port.map { ":\($0)" }
            if let port, let owner = blocker(of: port), cfg.autoPort, cfg.type != .docker {
                d.subtitle = ":\(port) taken · will start on another port"
                d.info = "Port :\(port) is in use by \(owner.label). With autoPort, this service starts on the next free port."
                d.fix = fix(for: owner)
                d.fixLabel = "\(fixLead(owner)) and use :\(port)"
            } else if let port, let owner = blocker(of: port) {
                d.warn = true
                if let job = launchdJobs[owner.pid], job.keepAlive {
                    d.subtitle = ":\(port) held by \(owner.name) (launchd)"
                    d.banner = "Port :\(port) is in use by \(owner.label), which launchd keeps alive (\(job.label)): killing it only makes launchd start it again. Turn the job off to free the port\(proxy ? " and open this proxy from Runbar" : "")."
                } else {
                    d.subtitle = ":\(port) in use by \(owner.label)"
                    d.banner = "Port :\(port) is in use by \(owner.label). This service only starts when the port is free. To start on another port automatically, turn on \"autoPort\" in config.json."
                }
                d.fix = fix(for: owner)
                d.fixLabel = "\(fixLead(owner)) and \(proxy ? "open" : "start") this one"
            } else if proxy {
                d.subtitle = closedProxySubtitle(rt)
            } else if let code = rt.lastExitCode, let exited = rt.exitedAt {
                // A crash the user dismissed stays visible here, in grey, until the next start.
                let ago = Format.ago(exited, now: now)
                d.subtitle = code == 0 ? "exited \(ago) (code 0)" : "crashed \(ago) (exit code \(code))"
            } else {
                d.subtitle = cfg.command(port: nil)
                d.subtitleMono = true
            }

        case .crashed(let code):
            d.dot = .error
            d.action = .retry
            d.warn = true
            d.alert = true
            d.statusLabel = "Crashed"
            d.portLabel = port.map { ":\($0)" }
            var reason = code.map { "exit code \($0)" } ?? "exited on its own"
            if code == 127 { reason = "command not found (127)" }
            d.subtitle = "Crashed — \(reason)" + (rt.lastLine.map { " · \($0)" } ?? "")
            var text = code == nil ? "The process exited on its own." : "The process ended with \(reason)."
            if code == 127 { text += " Check that the program is installed and on the login shell's PATH." }
            if let port, let owner = blocker(of: port) {
                text += " Port :\(port) is in use by \(owner.label), which is the usual cause."
                d.fix = fix(for: owner)
                d.fixLabel = "\(fixLead(owner)) and try again"
            }
            if rt.gaveUpRestarting { text += " Runbar restarted it 3 times in 2 minutes and stopped trying." }
            d.banner = text

        case .failed(let message):
            d.dot = .error
            d.action = .retry
            d.warn = true
            d.alert = true
            d.statusLabel = proxy ? "Failed to open" : "Failed to start"
            d.subtitle = message
            d.banner = "\(proxy ? "Failed to open" : "Failed to start"): \(message)."
            d.portLabel = port.map { ":\($0)" }
            if let port, let owner = blocker(of: port) {
                d.fix = fix(for: owner)
                d.fixLabel = "\(fixLead(owner)) and start this one"
            }
        }

        if proxy {
            d.connections = rt.isRunningAnywhere ? rt.connectionCount : nil
            // An expired sign-in explains a proxy that won't open, or opens and can't reach the database.
            let tool = cfg.proxyTool
            if rt.signInExpiredAt != nil, rt.external == nil, let account = tool.account, tool.signInCommand != nil {
                d.dot = .warning
                d.warn = true
                d.alert = rt.phase != .stopped
                if rt.phase != .stopped { d.statusLabel = "Sign-in expired" }
                d.subtitle = "\(account) sign-in expired"
                d.banner = "Your \(account) sign-in expired, so \(tool.label) can't reach the database. Sign in again and Runbar \(rt.isAlive || rt.phase != .stopped ? "reopens" : "can open") \(rt.id) on its own."
                d.fix = .signIn
                d.fixLabel = "Sign in with \(tool == .awsSSM ? "aws" : "gcloud")"
            }
        }

        if rt.orphaned { d.subtitle = "not in config.json · " + d.subtitle }
        if rt.needsRestart { d.note = "The configuration changed since this service started. Restart to apply it." }
        if d.alert, mutedAlerts[rt.id] == d.alertKey {
            d.alert = false
            d.dismissed = true
        }
        return d
    }

    /// "used by takt-analytics, psql" (the row shows the count beside it), "no connections · held open by
    /// takt-analytics", "no connections · closes in 12 min".
    func proxyUsage(_ rt: ServiceRuntime) -> String {
        if !rt.clients.isEmpty {
            return "used by " + rt.clients.map(\.name).joined(separator: ", ")
        }
        if !rt.heldBy.isEmpty { return "no connections · held open by \(rt.heldBy.joined(separator: ", "))" }
        guard rt.isAlive else { return "no connections" }
        guard let closes = rt.closesAt else { return rt.config.idle == nil ? "no connections · stays open" : "no connections" }
        let left = closes.timeIntervalSince(now)
        return "no connections · closes in \(left < 60 ? "under a minute" : IdleSetting.human((left / 60).rounded(.up) * 60))"
    }

    /// "Cloud SQL · opens with fundsys-data", "Cloud SQL · closed after 15 min idle".
    private func closedProxySubtitle(_ rt: ServiceRuntime) -> String {
        let tool = rt.config.proxyTool.shortLabel
        if let at = rt.closedIdleAt, let idle = rt.config.idle {
            return "\(tool) · closed at \(Format.clock(at, now: now)) after \(IdleSetting.human(idle)) idle"
        }
        if let code = rt.lastExitCode, code != 0, code != 143, let exited = rt.exitedAt {
            return "\(tool) · exited \(Format.ago(exited, now: now)) (exit code \(code))"
        }
        let deps = config.dependents(of: rt.id).map(\.id)
        if !deps.isEmpty { return "\(tool) · opens with \(deps.joined(separator: ", "))" }
        return "\(tool) · closed"
    }

    /// One line for the detail's "Closes" fact.
    func closesText(_ rt: ServiceRuntime) -> String {
        guard let idle = rt.config.idle else { return "never" }
        guard let closes = rt.closesAt else { return "\(IdleSetting.human(idle)) idle" }
        let left = closes.timeIntervalSince(now)
        return left < 60 ? "in < 1 min" : "in \(IdleSetting.human((left / 60).rounded(.up) * 60))"
    }
}
