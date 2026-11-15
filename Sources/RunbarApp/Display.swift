import Foundation
import RunbarCore

enum FixAction: Equatable {
    case stopService(String)
    case killProcess(Int32)
    case takeOverExternal
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
    var memory: UInt64?
    var cpu: Double?
    var realPort: Int?
    var portLabel: String?
    var url: URL?
    var banner: String?
    /// Neutral notice (not a problem), such as the port autoPort switched to.
    var info: String?
    var fix: FixAction?
    var fixLabel: String?
    var note: String?

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
        var d = ServiceDisplay()

        func blocker(of p: Int) -> PortOwner? {
            guard let owner = portOwners[p], !rt.treePIDs.contains(owner.pid) else { return nil }
            return owner
        }
        func fix(for owner: PortOwner) -> FixAction {
            if let sid = owner.serviceID { return .stopService(sid) }
            return .killProcess(owner.pid)
        }

        if rt.isAlive, rt.memory > 0 {
            d.memory = rt.memory
            d.cpu = rt.cpu
        }
        d.realPort = rt.realPort

        switch rt.phase {
        case .starting:
            d.isAlive = true
            d.dot = .busy
            d.action = .stop
            d.statusLabel = "Starting"
            d.portLabel = (rt.realPort ?? rt.expectedPort).map { ":\($0)" }
            d.subtitle = "starting…"
            if let active = rt.activePort, let from = rt.fallbackFrom {
                d.subtitle = "starting on :\(active) · :\(from) was taken"
            } else if let port, let owner = blocker(of: port), cfg.type != .docker {
                d.subtitle = "starting… :\(port) is in use by \(owner.label)"
                d.warn = true
            } else if rt.config.health != nil, rt.healthy == false {
                d.subtitle = "waiting for \(rt.config.health!) to respond"
            }

        case .running:
            d.isAlive = true
            d.action = .stop
            d.dot = .running
            d.statusLabel = "Running"
            let real = rt.realPort
            let expected = rt.expectedPort
            d.portLabel = (real ?? expected).map { ":\($0)" }
            d.url = cfg.url(port: real ?? expected)
            let since = rt.startedAt.map { "since \(Format.clock($0, now: now))" } ?? "running"
            let log = rt.lastLogAt.map { "log \(Format.ago($0, now: now))" } ?? "no log"
            d.subtitle = "\(since) · \(log)"
            if let expected, let real, real != expected {
                d.dot = .warning
                d.warn = true
                d.alert = true
                d.statusLabel = "Port changed"
                d.subtitle = "on :\(real) · expected :\(expected)"
                if let owner = blocker(of: expected) {
                    d.banner = "Port :\(expected) was taken by \(owner.label), so the service started on :\(real)."
                    d.fix = fix(for: owner)
                    d.fixLabel = owner.serviceID != nil ? "Stop \(owner.label) and restart this one" : "Kill \(owner.name) and restart this one"
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
                    d.fixLabel = owner.serviceID != nil ? "Stop \(owner.label) and go back to :\(from)" : "Kill \(owner.name) and go back to :\(from)"
                }
                d.info = text
            }

        case .stopping:
            d.isAlive = true
            d.dot = .busy
            d.action = .stop
            d.statusLabel = "Stopping"
            d.subtitle = "stopping…"
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
            if let port, let real, real != port {
                d.warn = true
                d.alert = true
                d.subtitle = "outside Runbar · config :\(port)"
            }
            d.banner = "This service was started outside Runbar (in Terminal, for example). Runbar shows its port, memory and CPU, but not its output. Stop it and start it from Runbar to follow its logs."
            d.fix = .takeOverExternal
            d.fixLabel = "Stop and start from Runbar"

        case .stopped:
            d.action = .start
            d.statusLabel = "Stopped"
            d.portLabel = port.map { ":\($0)" }
            if let port, let owner = blocker(of: port), cfg.autoPort, cfg.type != .docker {
                d.subtitle = ":\(port) taken · will start on another port"
                d.info = "Port :\(port) is in use by \(owner.label). With autoPort, this service starts on the next free port."
                d.fix = fix(for: owner)
                d.fixLabel = owner.serviceID != nil ? "Stop \(owner.label) and use :\(port)" : "Kill \(owner.name) and use :\(port)"
            } else if let port, let owner = blocker(of: port) {
                d.warn = true
                d.subtitle = ":\(port) in use by \(owner.label)"
                d.banner = "Port :\(port) is in use by \(owner.label). This service only starts when the port is free. To start on another port automatically, turn on \"autoPort\" in config.json."
                d.fix = fix(for: owner)
                d.fixLabel = owner.serviceID != nil ? "Stop \(owner.label) and start this one" : "Kill \(owner.name) and start this one"
            } else if rt.lastExitCode == 0, let exited = rt.exitedAt {
                d.subtitle = "exited \(Format.ago(exited, now: now)) (code 0)"
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
                d.fixLabel = owner.serviceID != nil ? "Stop \(owner.label) and try again" : "Kill \(owner.name) and try again"
            }
            if rt.gaveUpRestarting { text += " Runbar restarted it 3 times in 2 minutes and stopped trying." }
            d.banner = text

        case .failed(let message):
            d.dot = .error
            d.action = .retry
            d.warn = true
            d.alert = true
            d.statusLabel = "Failed to start"
            d.subtitle = message
            d.banner = "Failed to start: \(message)."
            d.portLabel = port.map { ":\($0)" }
            if let port, let owner = blocker(of: port) {
                d.fix = fix(for: owner)
                d.fixLabel = owner.serviceID != nil ? "Stop \(owner.label) and start this one" : "Kill \(owner.name) and start this one"
            }
        }

        if rt.orphaned { d.subtitle = "not in config.json · " + d.subtitle }
        if rt.needsRestart { d.note = "The configuration changed since this service started. Restart to apply it." }
        return d
    }
}
