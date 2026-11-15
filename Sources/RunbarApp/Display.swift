import Foundation
import RunbarCore

enum FixAction: Equatable {
    case stopService(String)
    case killProcess(Int32)
    case takeOverExternal
}

/// O que a interface mostra para um serviço, calculado a partir do estado.
struct ServiceDisplay {
    enum Dot { case running, busy, stopped, warning, error }
    enum Action { case start, stop, retry }

    var dot: Dot = .stopped
    var action: Action = .start
    var statusLabel = "Parado"
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
    /// Aviso neutro (não é problema), como a porta trocada pelo autoPort.
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
            d.statusLabel = "Subindo"
            d.portLabel = (rt.realPort ?? rt.expectedPort).map { ":\($0)" }
            d.subtitle = "subindo…"
            if let active = rt.activePort, let from = rt.fallbackFrom {
                d.subtitle = "subindo na :\(active) · a :\(from) estava ocupada"
            } else if let port, let owner = blocker(of: port), cfg.type != .docker {
                d.subtitle = "subindo… a :\(port) está em uso por \(owner.label)"
                d.warn = true
            } else if rt.config.health != nil, rt.healthy == false {
                d.subtitle = "esperando \(rt.config.health!) responder"
            }

        case .running:
            d.isAlive = true
            d.action = .stop
            d.dot = .running
            d.statusLabel = "Rodando"
            let real = rt.realPort
            let expected = rt.expectedPort
            d.portLabel = (real ?? expected).map { ":\($0)" }
            d.url = cfg.url(port: real ?? expected)
            let since = rt.startedAt.map { "desde \(Format.clock($0, now: now))" } ?? "rodando"
            let log = rt.lastLogAt.map { "log \(Format.ago($0, now: now))" } ?? "sem log"
            d.subtitle = "\(since) · \(log)"
            if let expected, let real, real != expected {
                d.dot = .warning
                d.warn = true
                d.alert = true
                d.statusLabel = "Porta trocada"
                d.subtitle = "na :\(real) · esperava :\(expected)"
                if let owner = blocker(of: expected) {
                    d.banner = "A :\(expected) estava ocupada por \(owner.label), então o serviço subiu na :\(real)."
                    d.fix = fix(for: owner)
                    d.fixLabel = owner.serviceID != nil ? "Parar \(owner.label) e reiniciar este" : "Encerrar \(owner.name) e reiniciar este"
                } else {
                    d.banner = "O serviço está na :\(real), não na :\(expected). Confira se o comando fixa outra porta."
                }
            } else if cfg.health != nil, rt.healthy == false {
                d.dot = .warning
                d.warn = true
                d.alert = true
                d.statusLabel = "Sem resposta"
                d.subtitle = "\(cfg.health!) não está respondendo"
            } else if let active = rt.activePort, let from = rt.fallbackFrom {
                d.subtitle = "\(since) · :\(from) ocupada"
                var text = "A :\(from) estava ocupada, então este serviço subiu na :\(active) (autoPort)."
                if let owner = blocker(of: from) {
                    text = "A :\(from) estava ocupada por \(owner.label), então este serviço subiu na :\(active) (autoPort)."
                    d.fix = fix(for: owner)
                    d.fixLabel = owner.serviceID != nil ? "Parar \(owner.label) e voltar para a :\(from)" : "Encerrar \(owner.name) e voltar para a :\(from)"
                }
                d.info = text
            }

        case .stopping:
            d.isAlive = true
            d.dot = .busy
            d.action = .stop
            d.statusLabel = "Parando"
            d.subtitle = "parando…"
            d.portLabel = port.map { ":\($0)" }

        case .stopped where rt.external != nil:
            let ext = rt.external!
            d.isExternal = true
            d.dot = .running
            d.action = .stop
            d.statusLabel = "Fora do Runbar"
            d.memory = ext.memory
            d.cpu = ext.cpu
            let real = port.flatMap { ext.ports.contains($0) ? $0 : nil } ?? ext.ports.first
            d.realPort = real
            d.portLabel = (real ?? port).map { ":\($0)" }
            d.url = cfg.url(port: real)
            d.subtitle = "fora do Runbar · desde \(Format.clock(ext.startedAt, now: now))"
            if let port, let real, real != port {
                d.warn = true
                d.alert = true
                d.subtitle = "fora do Runbar · config :\(port)"
            }
            d.banner = "Este serviço foi iniciado fora do Runbar (no Terminal, por exemplo). Dá para ver porta, memória e CPU, mas não a saída. Pare e inicie pelo Runbar para acompanhar os logs."
            d.fix = .takeOverExternal
            d.fixLabel = "Parar e iniciar pelo Runbar"

        case .stopped:
            d.action = .start
            d.statusLabel = "Parado"
            d.portLabel = port.map { ":\($0)" }
            if let port, let owner = blocker(of: port), cfg.autoPort, cfg.type != .docker {
                d.subtitle = ":\(port) ocupada · sobe em outra porta"
                d.info = "A :\(port) está em uso por \(owner.label). Com autoPort, este serviço sobe na próxima porta livre."
                d.fix = fix(for: owner)
                d.fixLabel = owner.serviceID != nil ? "Parar \(owner.label) e usar a :\(port)" : "Encerrar \(owner.name) e usar a :\(port)"
            } else if let port, let owner = blocker(of: port) {
                d.warn = true
                d.subtitle = ":\(port) em uso por \(owner.label)"
                d.banner = "A :\(port) está em uso por \(owner.label). Este serviço só sobe com a porta livre. Para subir em outra porta automaticamente, ligue \"autoPort\" no config.json."
                d.fix = fix(for: owner)
                d.fixLabel = owner.serviceID != nil ? "Parar \(owner.label) e iniciar este" : "Encerrar \(owner.name) e iniciar este"
            } else if rt.lastExitCode == 0, let exited = rt.exitedAt {
                d.subtitle = "terminou \(Format.ago(exited, now: now)) (código 0)"
            } else {
                d.subtitle = cfg.command(port: nil)
                d.subtitleMono = true
            }

        case .crashed(let code):
            d.dot = .error
            d.action = .retry
            d.warn = true
            d.alert = true
            d.statusLabel = "Caiu"
            d.portLabel = port.map { ":\($0)" }
            var reason = code.map { "código \($0)" } ?? "saiu sozinho"
            if code == 127 { reason = "comando não encontrado (127)" }
            d.subtitle = "Caiu — \(reason)" + (rt.lastLine.map { " · \($0)" } ?? "")
            var text = "O processo terminou com \(reason)."
            if code == 127 { text += " Confira se o programa está instalado e no PATH do shell de login." }
            if let port, let owner = blocker(of: port) {
                text += " A :\(port) está em uso por \(owner.label), o que costuma ser a causa."
                d.fix = fix(for: owner)
                d.fixLabel = owner.serviceID != nil ? "Parar \(owner.label) e tentar de novo" : "Encerrar \(owner.name) e tentar de novo"
            }
            if rt.gaveUpRestarting { text += " Reiniciei 3 vezes em 2 minutos e parei de tentar." }
            d.banner = text

        case .failed(let message):
            d.dot = .error
            d.action = .retry
            d.warn = true
            d.alert = true
            d.statusLabel = "Não subiu"
            d.subtitle = message
            d.banner = "Não subiu: \(message)."
            d.portLabel = port.map { ":\($0)" }
            if let port, let owner = blocker(of: port) {
                d.fix = fix(for: owner)
                d.fixLabel = owner.serviceID != nil ? "Parar \(owner.label) e iniciar este" : "Encerrar \(owner.name) e iniciar este"
            }
        }

        if rt.orphaned { d.subtitle = "fora do config.json · " + d.subtitle }
        if rt.needsRestart { d.note = "A configuração mudou desde que este serviço subiu. Reinicie para aplicar." }
        return d
    }
}
