import Foundation

public enum ServiceType: String, Sendable, CaseIterable, Codable {
    case nextjs, node, python, docker, java, other

    public var label: String {
        switch self {
        case .nextjs: return "Next.js"
        case .node: return "Node"
        case .python: return "Python"
        case .docker: return "Docker"
        case .java: return "Java"
        case .other: return "Outro"
        }
    }
}

public enum RestartPolicy: String, Sendable, Codable {
    case never
    case onCrash = "on-crash"
}

public enum LookSetting: String, Sendable, Codable, CaseIterable {
    case auto, solid, glass
}

public struct ServiceConfig: Sendable, Equatable, Identifiable {
    public var id: String
    public var projectID: String
    public var projectName: String
    public var command: String
    /// Pasta absoluta onde o comando roda.
    public var cwd: String
    public var port: Int?
    public var type: ServiceType
    public var open: String?
    public var env: [String: String]
    /// Caminho absoluto do arquivo de variáveis.
    public var envFile: String?
    public var health: String?
    public var autostart: Bool
    public var restart: RestartPolicy
    public var stop: String?
    /// Se a porta estiver ocupada, sobe na próxima livre.
    public var autoPort: Bool

    public init(
        id: String, projectID: String, projectName: String, command: String, cwd: String,
        port: Int? = nil, type: ServiceType = .other, open: String? = nil, env: [String: String] = [:],
        envFile: String? = nil, health: String? = nil, autostart: Bool = false,
        restart: RestartPolicy = .never, stop: String? = nil, autoPort: Bool = false
    ) {
        self.id = id
        self.projectID = projectID
        self.projectName = projectName
        self.command = command
        self.cwd = cwd
        self.port = port
        self.type = type
        self.open = open
        self.env = env
        self.envFile = envFile
        self.health = health
        self.autostart = autostart
        self.restart = restart
        self.stop = stop
        self.autoPort = autoPort
    }

    /// Comando com `{port}` trocado pela porta em que o serviço vai subir.
    public func command(port launchPort: Int?) -> String {
        guard let p = launchPort ?? port else { return command }
        return command.replacingOccurrences(of: "{port}", with: String(p))
    }

    /// Muda quando algo que exige reiniciar o processo muda.
    public var launchSignature: String {
        let envPart = env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\u{1}")
        return [command, cwd, String(port ?? 0), envPart, envFile ?? ""].joined(separator: "\u{0}")
    }

    /// URL do botão "Abrir". `{port}` vira a porta real.
    public func url(port realPort: Int?) -> URL? {
        let p = realPort ?? port
        if let open {
            var s = open
            if let p { s = s.replacingOccurrences(of: "{port}", with: String(p)) }
            return URL(string: s)
        }
        guard let p else { return nil }
        return URL(string: "http://localhost:\(p)")
    }
}

public struct ProjectConfig: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var root: String?
    public var services: [ServiceConfig]
}

public struct SettingsConfig: Sendable, Equatable {
    public var look: LookSetting = .auto
    public var shell: String = "/bin/zsh"
    public var notifyOnCrash: Bool = true
    /// Padrão de autoPort para os serviços que não definem o próprio.
    public var autoPort: Bool = false
    public init() {}
}

public struct RunbarConfig: Sendable, Equatable {
    public var settings = SettingsConfig()
    public var projects: [ProjectConfig] = []
    public init() {}

    public var services: [ServiceConfig] { projects.flatMap(\.services) }

    public func service(_ id: String) -> ServiceConfig? {
        services.first { $0.id == id }
    }
}

public struct ConfigIssue: Sendable, Equatable, CustomStringConvertible {
    public enum Severity: String, Sendable { case error, warning }
    public var severity: Severity
    public var message: String
    public var path: String
    public var line: Int
    public var column: Int

    public var location: String { line > 0 ? "linha \(line), coluna \(column)" : "" }

    public var description: String {
        let loc = line > 0 ? "\(line):\(column): " : ""
        let kind = severity == .error ? "erro" : "aviso"
        let p = path.isEmpty ? "" : " [\(path)]"
        return "\(loc)\(kind): \(message)\(p)"
    }
}

public struct ConfigLoadResult: Sendable {
    public var config: RunbarConfig?
    public var issues: [ConfigIssue]
    public var json: JSON?
    public var errors: [ConfigIssue] { issues.filter { $0.severity == .error } }
    public var warnings: [ConfigIssue] { issues.filter { $0.severity == .warning } }
}

public enum ConfigLoader {
    public static func load(from url: URL = Paths.configFile) -> ConfigLoadResult {
        do {
            return load(data: try Data(contentsOf: url))
        } catch {
            let issue = ConfigIssue(severity: .error, message: "não consegui ler \(Paths.abbreviate(url.path)): \(error.localizedDescription)", path: "", line: 0, column: 0)
            return ConfigLoadResult(config: nil, issues: [issue], json: nil)
        }
    }

    public static func load(data: Data) -> ConfigLoadResult {
        let json: JSON
        do {
            json = try JSONParser.parse(data)
        } catch let e as JSONParseError {
            let issue = ConfigIssue(severity: .error, message: e.message, path: "", line: e.line, column: e.column)
            return ConfigLoadResult(config: nil, issues: [issue], json: nil)
        } catch {
            let issue = ConfigIssue(severity: .error, message: "\(error)", path: "", line: 0, column: 0)
            return ConfigLoadResult(config: nil, issues: [issue], json: nil)
        }
        var v = ConfigValidator()
        let config = v.validate(json)
        let failed = v.issues.contains { $0.severity == .error }
        return ConfigLoadResult(config: failed ? nil : config, issues: v.issues, json: json)
    }
}

/// Edições pontuais feitas pela interface: mantêm a ordem e os campos que o app não conhece.
public enum ConfigEditor {
    public enum EditError: Error { case notAnObject }

    public static func set(_ value: JSON, at path: [String], in url: URL = Paths.configFile) throws {
        let data = try Data(contentsOf: url)
        let json = try JSONParser.parse(data)
        guard case .object(let root) = json else { throw EditError.notAnObject }
        let updated = setting(value, at: path[...], in: root)
        try JSON.object(updated).prettyPrinted().write(to: url, atomically: true, encoding: .utf8)
    }

    private static func setting(_ value: JSON, at path: ArraySlice<String>, in obj: JSONObject) -> JSONObject {
        var obj = obj
        guard let key = path.first else { return obj }
        if path.count == 1 {
            obj[key] = value
        } else {
            let child = obj[key]?.objectValue ?? JSONObject()
            obj[key] = .object(setting(value, at: path.dropFirst(), in: child))
        }
        return obj
    }
}

// MARK: - Validação

struct ConfigValidator {
    var issues: [ConfigIssue] = []
    var defaultAutoPort = false

    static let rootKeys = ["$schema", "version", "settings", "projects"]
    static let settingsKeys = ["look", "shell", "notifyOnCrash", "autoPort"]
    static let projectKeys = ["name", "root", "services"]
    static let serviceKeys = ["command", "cwd", "port", "type", "open", "env", "envFile", "health", "autostart", "restart", "stop", "autoPort"]

    mutating func add(_ severity: ConfigIssue.Severity, _ message: String, _ path: String, _ pos: JSONPosition?) {
        issues.append(ConfigIssue(severity: severity, message: message, path: path, line: pos?.line ?? 0, column: pos?.column ?? 0))
    }

    static func validID(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
    }

    static func dirExists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    static func join(_ path: String, _ key: String) -> String { path.isEmpty ? key : path + "." + key }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        for i in 1...x.count {
            var row = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                row[j] = min(prev[j] + 1, row[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            prev = row
        }
        return prev[y.count]
    }

    static func suggest(_ key: String, _ options: [String]) -> String? {
        var best: (String, Int)?
        for o in options {
            let d = levenshtein(key.lowercased(), o.lowercased())
            if d <= 2, d < (best?.1 ?? 99) { best = (o, d) }
        }
        return best?.0
    }

    mutating func checkKeys(_ obj: JSONObject, _ allowed: [String], _ path: String) {
        for e in obj.entries where !allowed.contains(e.key) {
            var msg = "campo desconhecido \"\(e.key)\""
            if let s = Self.suggest(e.key, allowed) { msg += "; quis dizer \"\(s)\"?" }
            add(.warning, msg, Self.join(path, e.key), e.position)
        }
    }

    mutating func string(_ o: JSONObject, _ key: String, _ path: String) -> String? {
        guard let v = o[key], !v.isNull else { return nil }
        if case .string(let s) = v { return s }
        add(.error, "\(key) precisa ser texto entre aspas, não \(v.typeName)", Self.join(path, key), o.position(of: key))
        return nil
    }

    mutating func bool(_ o: JSONObject, _ key: String, _ path: String) -> Bool? {
        guard let v = o[key], !v.isNull else { return nil }
        if case .bool(let b) = v { return b }
        add(.error, "\(key) precisa ser true ou false, não \(v.typeName)", Self.join(path, key), o.position(of: key))
        return nil
    }

    mutating func validate(_ json: JSON) -> RunbarConfig {
        var config = RunbarConfig()
        guard case .object(let root) = json else {
            add(.error, "o arquivo precisa ser um objeto JSON { … }", "", JSONPosition(line: 1, column: 1))
            return config
        }
        checkKeys(root, Self.rootKeys, "")
        if let v = root["version"], v.numberValue != 1 {
            add(.error, "version precisa ser 1", "version", root.position(of: "version"))
        }
        if let s = root["settings"] {
            if case .object(let so) = s {
                config.settings = settings(so)
                defaultAutoPort = config.settings.autoPort
            } else {
                add(.error, "settings precisa ser um objeto", "settings", root.position(of: "settings"))
            }
        }
        guard let p = root["projects"] else {
            add(.warning, "ainda não há \"projects\"; adicione seus serviços", "projects", nil)
            return config
        }
        guard case .object(let projects) = p else {
            add(.error, "projects precisa ser um objeto: { \"id-do-projeto\": { … } }", "projects", root.position(of: "projects"))
            return config
        }

        var seen: [String: String] = [:]
        var ports: [Int: String] = [:]
        for entry in projects.entries {
            let path = "projects.\(entry.key)"
            guard Self.validID(entry.key) else {
                add(.error, "id de projeto inválido \"\(entry.key)\": use letras, números, . _ ou -", path, entry.position)
                continue
            }
            guard case .object(let po) = entry.value else {
                add(.error, "o projeto precisa ser um objeto { … }", path, entry.position)
                continue
            }
            checkKeys(po, Self.projectKeys, path)
            let name = string(po, "name", path) ?? entry.key
            var rootDir: String?
            if let r = string(po, "root", path) {
                let expanded = URL(fileURLWithPath: Paths.expand(r)).standardizedFileURL.path
                rootDir = expanded
                if !Self.dirExists(expanded) { add(.warning, "a pasta \(r) não existe", path + ".root", po.position(of: "root")) }
            }
            var project = ProjectConfig(id: entry.key, name: name, root: rootDir, services: [])

            guard let s = po["services"] else {
                add(.warning, "projeto sem \"services\"", path, entry.position)
                config.projects.append(project)
                continue
            }
            guard case .object(let services) = s else {
                add(.error, "services precisa ser um objeto: { \"id-do-servico\": { … } }", path + ".services", po.position(of: "services"))
                continue
            }
            for se in services.entries {
                let spath = "\(path).services.\(se.key)"
                guard Self.validID(se.key) else {
                    add(.error, "id de serviço inválido \"\(se.key)\": use letras, números, . _ ou -", spath, se.position)
                    continue
                }
                if let other = seen[se.key] {
                    add(.error, "o id \"\(se.key)\" já existe no projeto \(other); ids de serviço são únicos no arquivo todo", spath, se.position)
                    continue
                }
                guard case .object(let so) = se.value else {
                    add(.error, "o serviço precisa ser um objeto { … }", spath, se.position)
                    continue
                }
                guard let svc = service(id: se.key, project: project, obj: so, path: spath, position: se.position) else { continue }
                seen[se.key] = entry.key
                if let port = svc.port {
                    if let other = ports[port] {
                        add(.warning, "a porta \(port) também é de \(other); os dois não conseguem rodar ao mesmo tempo", spath + ".port", so.position(of: "port"))
                    } else {
                        ports[port] = se.key
                    }
                }
                project.services.append(svc)
            }
            config.projects.append(project)
        }
        return config
    }

    mutating func settings(_ o: JSONObject) -> SettingsConfig {
        var s = SettingsConfig()
        checkKeys(o, Self.settingsKeys, "settings")
        if let look = string(o, "look", "settings") {
            if let l = LookSetting(rawValue: look) {
                s.look = l
            } else {
                add(.error, "look precisa ser \"auto\", \"solid\" ou \"glass\"", "settings.look", o.position(of: "look"))
            }
        }
        if let shell = string(o, "shell", "settings") {
            if FileManager.default.isExecutableFile(atPath: shell) {
                s.shell = shell
            } else {
                add(.warning, "o shell \(shell) não existe; usando /bin/zsh", "settings.shell", o.position(of: "shell"))
            }
        }
        if let n = bool(o, "notifyOnCrash", "settings") { s.notifyOnCrash = n }
        if let a = bool(o, "autoPort", "settings") { s.autoPort = a }
        return s
    }

    mutating func service(id: String, project: ProjectConfig, obj o: JSONObject, path: String, position: JSONPosition) -> ServiceConfig? {
        checkKeys(o, Self.serviceKeys, path)
        let errorsBefore = issues.filter { $0.severity == .error }.count

        let command = string(o, "command", path)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if o["command"] == nil {
            add(.error, "falta \"command\": o comando que sobe o serviço", path, position)
        } else if command?.isEmpty == true {
            add(.error, "command está vazio", path + ".command", o.position(of: "command"))
        }

        var cwd: String?
        if let raw = string(o, "cwd", path) {
            let expanded = Paths.expand(raw)
            if expanded.hasPrefix("/") {
                cwd = expanded
            } else if let root = project.root {
                cwd = (root as NSString).appendingPathComponent(expanded)
            } else {
                add(.error, "cwd relativo (\(raw)) precisa de \"root\" no projeto", path + ".cwd", o.position(of: "cwd"))
            }
        } else if let root = project.root {
            cwd = root
        } else {
            add(.error, "sem \"cwd\" e o projeto não tem \"root\"", path, position)
        }
        if let c = cwd {
            cwd = URL(fileURLWithPath: c).standardizedFileURL.path
            if !Self.dirExists(cwd!) { add(.warning, "a pasta \(Paths.abbreviate(cwd!)) não existe", path + ".cwd", o.position(of: "cwd") ?? position) }
        }

        var port: Int?
        if let v = o["port"], !v.isNull {
            if let n = v.numberValue, n.rounded() == n, n >= 1, n <= 65535 {
                port = Int(n)
            } else {
                add(.error, "port precisa ser um número inteiro entre 1 e 65535", path + ".port", o.position(of: "port"))
            }
        }

        var type: ServiceType = .other
        if let t = string(o, "type", path) {
            if let st = ServiceType(rawValue: t) {
                type = st
            } else {
                let options = ServiceType.allCases.map(\.rawValue).joined(separator: ", ")
                add(.error, "type \"\(t)\" não existe; use \(options)", path + ".type", o.position(of: "type"))
            }
        } else if let command, let cwd {
            type = Self.guessType(command: command, cwd: cwd)
        }

        let open = string(o, "open", path)
        if let open, !open.contains("://") {
            add(.warning, "open deveria ser uma URL completa, como http://localhost:{port}", path + ".open", o.position(of: "open"))
        }

        var env: [String: String] = [:]
        if let v = o["env"], !v.isNull {
            if case .object(let eo) = v {
                for e in eo.entries {
                    switch e.value {
                    case .string(let s): env[e.key] = s
                    case .number(let n): env[e.key] = n.rounded() == n ? String(Int64(n)) : String(n)
                    case .bool(let b): env[e.key] = b ? "true" : "false"
                    default: add(.error, "o valor de \(e.key) precisa ser texto", path + ".env." + e.key, e.position)
                    }
                }
            } else {
                add(.error, "env precisa ser um objeto { \"NOME\": \"valor\" }", path + ".env", o.position(of: "env"))
            }
        }

        var envFile: String?
        if let f = string(o, "envFile", path) {
            let expanded = Paths.expand(f)
            let full = expanded.hasPrefix("/") ? expanded : ((cwd ?? project.root ?? "") as NSString).appendingPathComponent(expanded)
            envFile = full
            if !FileManager.default.fileExists(atPath: full) {
                add(.warning, "o arquivo \(f) não existe", path + ".envFile", o.position(of: "envFile"))
            }
        }

        let health = string(o, "health", path)
        if let health, !(health.hasPrefix("/") || health.hasPrefix("http")) {
            add(.warning, "health deveria começar com / (ex.: /health) ou ser uma URL", path + ".health", o.position(of: "health"))
        }

        let autostart = bool(o, "autostart", path) ?? false
        var restart: RestartPolicy = .never
        if let r = string(o, "restart", path) {
            if let rp = RestartPolicy(rawValue: r) {
                restart = rp
            } else {
                add(.error, "restart precisa ser \"never\" ou \"on-crash\"", path + ".restart", o.position(of: "restart"))
            }
        }
        let stop = string(o, "stop", path)
        let autoPort = bool(o, "autoPort", path) ?? defaultAutoPort
        if let command {
            if command.contains("{port}"), port == nil {
                add(.warning, "o comando usa {port}, mas o serviço não tem \"port\"", path + ".command", o.position(of: "command"))
            }
            if autoPort, let port, !command.contains("{port}"),
               command.range(of: "(?<![0-9])\(port)(?![0-9])", options: .regularExpression) != nil {
                add(.warning, "o comando fixa a porta \(port); troque por {port} para o autoPort conseguir subir em outra porta", path + ".command", o.position(of: "command"))
            }
        }

        let errorsAfter = issues.filter { $0.severity == .error }.count
        guard errorsAfter == errorsBefore, let command, let cwd else { return nil }
        return ServiceConfig(
            id: id, projectID: project.id, projectName: project.name, command: command, cwd: cwd,
            port: port, type: type, open: open, env: env, envFile: envFile, health: health,
            autostart: autostart, restart: restart, stop: stop, autoPort: autoPort
        )
    }

    static func guessType(command: String, cwd: String) -> ServiceType {
        let c = command.lowercased()
        if c.contains("docker") { return .docker }
        if c.contains("next ") || c.hasSuffix("next") { return .nextjs }
        if ["uvicorn", "gunicorn", "python", "manage.py", "flask", "poetry", "uv run"].contains(where: { c.contains($0) }) { return .python }
        if ["java ", "gradle", "mvn", "./start.sh"].contains(where: { c.contains($0) }) { return .java }
        if ["npm", "pnpm", "yarn", "bun", "node"].contains(where: { c.contains($0) }) {
            let pkg = (cwd as NSString).appendingPathComponent("package.json")
            if let text = try? String(contentsOfFile: pkg, encoding: .utf8), text.contains("\"next\"") { return .nextjs }
            return .node
        }
        return .other
    }
}
