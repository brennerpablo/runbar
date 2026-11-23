import Foundation

public enum ServiceType: String, Sendable, CaseIterable, Codable {
    case nextjs, node, python, docker, java, proxy, other

    public var label: String {
        switch self {
        case .nextjs: return "Next.js"
        case .node: return "Node"
        case .python: return "Python"
        case .docker: return "Docker"
        case .java: return "Java"
        case .proxy: return "Proxy"
        case .other: return "Other"
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
    /// Absolute folder the command runs in.
    public var cwd: String
    public var port: Int?
    public var type: ServiceType
    public var open: String?
    public var env: [String: String]
    /// Absolute path of the env file.
    public var envFile: String?
    public var health: String?
    public var autostart: Bool
    public var restart: RestartPolicy
    public var stop: String?
    /// If the port is taken, start on the next free one.
    public var autoPort: Bool
    /// Command that reinstalls dependencies. Without it, Runbar picks one from the lockfile.
    public var install: String?
    /// Services (usually proxies) opened before this one starts.
    public var needs: [String]
    /// Proxies only: seconds with no connections before Runbar closes it; nil never closes it.
    public var idle: TimeInterval?
    /// The local name the browser reaches it by (`fundsys-app.localhost`), routed by Runbar to wherever
    /// the service listens; nil when it has none.
    public var host: String?
    /// The port those names answer on (`settings.hostPort`): 80 leaves it out of the URL.
    public var hostPort: Int

    public init(
        id: String, projectID: String, projectName: String, command: String, cwd: String,
        port: Int? = nil, type: ServiceType = .other, open: String? = nil, env: [String: String] = [:],
        envFile: String? = nil, health: String? = nil, autostart: Bool = false,
        restart: RestartPolicy = .never, stop: String? = nil, autoPort: Bool = false, install: String? = nil,
        needs: [String] = [], idle: TimeInterval? = nil, host: String? = nil, hostPort: Int = 80
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
        self.install = install
        self.needs = needs
        self.idle = idle
        self.host = host
        self.hostPort = hostPort
    }

    /// A local port forwarded to something remote (Cloud SQL, a cluster, a host over SSH): opened on
    /// demand and closed when nothing uses it.
    public var isProxy: Bool { type == .proxy }

    public var proxyTool: ProxyTool { ProxyTool.detect(command) }

    /// `http://fundsys-app.localhost`, or with `:port` when names answer on a port other than 80.
    public var hostURL: String? {
        host.map { "http://\($0)" + (hostPort == 80 ? "" : ":\(hostPort)") }
    }

    /// `{port}`, `{host}` and `{url}` in a command, an env value or `open`. Without a local name, `{host}`
    /// is `localhost` and `{url}` is `http://localhost:<port>`.
    public func expand(_ text: String, port launchPort: Int?) -> String {
        guard text.contains("{") else { return text }
        let p = launchPort ?? port
        var s = text
        if let p { s = s.replacingOccurrences(of: "{port}", with: String(p)) }
        s = s.replacingOccurrences(of: "{host}", with: host ?? "localhost")
        if let url = hostURL ?? p.map({ "http://localhost:\($0)" }) { s = s.replacingOccurrences(of: "{url}", with: url) }
        return s
    }

    /// Command with `{port}`, `{host}` and `{url}` replaced, for the port the service will start on.
    public func command(port launchPort: Int?) -> String {
        expand(command, port: launchPort)
    }

    /// Changes when anything that requires restarting the process changes. The local name only counts
    /// when the command or its env use it.
    public var launchSignature: String {
        let envPart = env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\u{1}")
        var parts = [command, cwd, String(port ?? 0), envPart, envFile ?? ""]
        let usesHost = ([command, stop ?? ""] + Array(env.values)).contains { $0.contains("{host}") || $0.contains("{url}") }
        if usesHost { parts.append(hostURL ?? "") }
        return parts.joined(separator: "\u{0}")
    }

    /// URL for the "Open" button: `open` with its placeholders replaced, else the service's local name
    /// when `viaHost` (Runbar is answering on it), else `http://localhost:<port>`. A proxy has none unless
    /// `open` says.
    public func url(port realPort: Int?, viaHost: Bool = false) -> URL? {
        let p = realPort ?? port
        if let open { return URL(string: expand(open, port: p)) }
        guard let p, !isProxy else { return nil }
        if viaHost, let hostURL { return URL(string: hostURL) }
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
    /// Default autoPort for services that don't set their own.
    public var autoPort: Bool = false
    /// The panel lists projects with something running before the others.
    public var activeProjectsFirst: Bool = true
    /// Each service with a port gets a local name, `<id>.localhost`, that Runbar routes to it.
    public var hosts: Bool = true
    /// The port those names answer on. 80 keeps it out of the URL.
    public var hostPort: Int = 80
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

    /// Project and service ids: letters, digits, `.`, `_` and `-`.
    public static func isValidID(_ s: String) -> Bool { ConfigValidator.validID(s) }

    /// Services that open `id` before they start, in file order.
    public func dependents(of id: String) -> [ServiceConfig] {
        services.filter { $0.needs.contains(id) }
    }
}

public struct ConfigIssue: Sendable, Equatable, CustomStringConvertible {
    public enum Severity: String, Sendable { case error, warning }
    public var severity: Severity
    public var message: String
    public var path: String
    public var line: Int
    public var column: Int

    public var location: String { line > 0 ? "line \(line), column \(column)" : "" }

    public var description: String {
        let loc = line > 0 ? "\(line):\(column): " : ""
        let kind = severity == .error ? "error" : "warning"
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
            let issue = ConfigIssue(severity: .error, message: "couldn't read \(Paths.abbreviate(url.path)): \(error.localizedDescription)", path: "", line: 0, column: 0)
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

/// Targeted edits made from the UI: they keep key order and fields the app doesn't know about.
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

// MARK: - Validation

struct ConfigValidator {
    var issues: [ConfigIssue] = []
    var defaultAutoPort = false
    var settingsHosts = true
    var hostPort = 80

    static let rootKeys = ["$schema", "version", "settings", "projects"]
    static let settingsKeys = ["look", "shell", "notifyOnCrash", "autoPort", "activeProjectsFirst", "hosts", "hostPort"]
    static let projectKeys = ["name", "root", "services"]
    static let serviceKeys = ["command", "cwd", "port", "type", "open", "env", "envFile", "health", "autostart", "restart", "stop", "autoPort", "install", "needs", "idle", "host"]

    /// Where each service's `needs` sits in the file, to point at it once every id is known.
    private var needsRefs: [(id: String, path: String, position: JSONPosition?)] = []

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
            var msg = "unknown field \"\(e.key)\""
            if let s = Self.suggest(e.key, allowed) { msg += "; did you mean \"\(s)\"?" }
            add(.warning, msg, Self.join(path, e.key), e.position)
        }
    }

    mutating func string(_ o: JSONObject, _ key: String, _ path: String) -> String? {
        guard let v = o[key], !v.isNull else { return nil }
        if case .string(let s) = v { return s }
        add(.error, "\(key) must be a quoted string, not \(v.typeName)", Self.join(path, key), o.position(of: key))
        return nil
    }

    mutating func bool(_ o: JSONObject, _ key: String, _ path: String) -> Bool? {
        guard let v = o[key], !v.isNull else { return nil }
        if case .bool(let b) = v { return b }
        add(.error, "\(key) must be true or false, not \(v.typeName)", Self.join(path, key), o.position(of: key))
        return nil
    }

    mutating func validate(_ json: JSON) -> RunbarConfig {
        var config = RunbarConfig()
        guard case .object(let root) = json else {
            add(.error, "the file must be a JSON object { … }", "", JSONPosition(line: 1, column: 1))
            return config
        }
        checkKeys(root, Self.rootKeys, "")
        if let v = root["version"], v.numberValue != 1 {
            add(.error, "version must be 1", "version", root.position(of: "version"))
        }
        if let s = root["settings"] {
            if case .object(let so) = s {
                config.settings = settings(so)
                defaultAutoPort = config.settings.autoPort
                settingsHosts = config.settings.hosts
                hostPort = config.settings.hostPort
            } else {
                add(.error, "settings must be an object", "settings", root.position(of: "settings"))
            }
        }
        guard let p = root["projects"] else {
            add(.warning, "no \"projects\" yet; add your services", "projects", nil)
            return config
        }
        guard case .object(let projects) = p else {
            add(.error, "projects must be an object: { \"project-id\": { … } }", "projects", root.position(of: "projects"))
            return config
        }

        var seen: [String: String] = [:]
        var ports: [Int: String] = [:]
        var hosts: [String: String] = [:]
        for entry in projects.entries {
            let path = "projects.\(entry.key)"
            guard Self.validID(entry.key) else {
                add(.error, "invalid project id \"\(entry.key)\": use letters, digits, . _ or -", path, entry.position)
                continue
            }
            guard case .object(let po) = entry.value else {
                add(.error, "the project must be an object { … }", path, entry.position)
                continue
            }
            checkKeys(po, Self.projectKeys, path)
            let name = string(po, "name", path) ?? entry.key
            var rootDir: String?
            if let r = string(po, "root", path) {
                let expanded = URL(fileURLWithPath: Paths.expand(r)).standardizedFileURL.path
                rootDir = expanded
                if !Self.dirExists(expanded) { add(.warning, "the folder \(r) doesn't exist", path + ".root", po.position(of: "root")) }
            }
            var project = ProjectConfig(id: entry.key, name: name, root: rootDir, services: [])

            guard let s = po["services"] else {
                add(.warning, "project has no \"services\"", path, entry.position)
                config.projects.append(project)
                continue
            }
            guard case .object(let services) = s else {
                add(.error, "services must be an object: { \"service-id\": { … } }", path + ".services", po.position(of: "services"))
                continue
            }
            for se in services.entries {
                let spath = "\(path).services.\(se.key)"
                guard Self.validID(se.key) else {
                    add(.error, "invalid service id \"\(se.key)\": use letters, digits, . _ or -", spath, se.position)
                    continue
                }
                if let other = seen[se.key] {
                    add(.error, "the id \"\(se.key)\" already exists in project \(other); service ids must be unique across the whole file", spath, se.position)
                    continue
                }
                guard case .object(let so) = se.value else {
                    add(.error, "the service must be an object { … }", spath, se.position)
                    continue
                }
                guard var svc = service(id: se.key, project: project, obj: so, path: spath, position: se.position) else { continue }
                seen[se.key] = entry.key
                if let host = svc.host {
                    if let other = hosts[host] {
                        add(.warning, "\(host) is already \(other)'s address; give this one its own with \"host\"", spath, so.position(of: "host") ?? se.position)
                        svc.host = nil
                    } else {
                        hosts[host] = se.key
                    }
                }
                if let port = svc.port, port == hostPort, svc.host != nil || settingsHosts, !svc.isProxy {
                    add(.warning, "port \(port) is where the .localhost addresses answer (settings.hostPort); pick another", spath + ".port", so.position(of: "port"))
                }
                if !svc.needs.isEmpty { needsRefs.append((se.key, spath + ".needs", so.position(of: "needs"))) }
                if let port = svc.port {
                    if let other = ports[port] {
                        add(.warning, "port \(port) is also used by \(other); the two can't run at the same time", spath + ".port", so.position(of: "port"))
                    } else {
                        ports[port] = se.key
                    }
                }
                project.services.append(svc)
            }
            config.projects.append(project)
        }
        checkNeeds(config)
        return config
    }

    /// Every id in `needs` exists, and no service ends up waiting for itself.
    mutating func checkNeeds(_ config: RunbarConfig) {
        let all = config.services
        let ids = all.map(\.id)
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for ref in needsRefs {
            for need in byID[ref.id]?.needs ?? [] where byID[need] == nil {
                var msg = "needs \"\(need)\" isn't a service in config.json"
                if let s = Self.suggest(need, ids) { msg += "; did you mean \"\(s)\"?" }
                add(.error, msg, ref.path, ref.position)
            }
        }
        // A loop would leave every service in it waiting for the next one.
        var state: [String: Int] = [:]  // 1 visiting, 2 done
        var reported = Set<String>()
        func visit(_ id: String, _ trail: [String]) -> [String]? {
            if state[id] == 2 { return nil }
            if state[id] == 1 { return Array(trail.drop { $0 != id }) + [id] }
            state[id] = 1
            for next in byID[id]?.needs ?? [] where byID[next] != nil {
                if let loop = visit(next, trail + [id]) { return loop }
            }
            state[id] = 2
            return nil
        }
        for ref in needsRefs where state[ref.id] == nil {
            guard let loop = visit(ref.id, []), !loop.contains(where: reported.contains) else { continue }
            reported.formUnion(loop)
            add(.error, "needs makes a loop: \(loop.joined(separator: " → ")); remove one of them", ref.path, ref.position)
        }
    }

    mutating func settings(_ o: JSONObject) -> SettingsConfig {
        var s = SettingsConfig()
        checkKeys(o, Self.settingsKeys, "settings")
        if let look = string(o, "look", "settings") {
            if let l = LookSetting(rawValue: look) {
                s.look = l
            } else {
                add(.error, "look must be \"auto\", \"solid\" or \"glass\"", "settings.look", o.position(of: "look"))
            }
        }
        if let shell = string(o, "shell", "settings") {
            if FileManager.default.isExecutableFile(atPath: shell) {
                s.shell = shell
            } else {
                add(.warning, "the shell \(shell) doesn't exist; using /bin/zsh", "settings.shell", o.position(of: "shell"))
            }
        }
        if let n = bool(o, "notifyOnCrash", "settings") { s.notifyOnCrash = n }
        if let a = bool(o, "autoPort", "settings") { s.autoPort = a }
        if let f = bool(o, "activeProjectsFirst", "settings") { s.activeProjectsFirst = f }
        if let h = bool(o, "hosts", "settings") { s.hosts = h }
        if let v = o["hostPort"], !v.isNull {
            if let n = v.numberValue, n.rounded() == n, n >= 1, n <= 65535 {
                s.hostPort = Int(n)
            } else {
                add(.error, "hostPort must be a whole number from 1 to 65535", "settings.hostPort", o.position(of: "hostPort"))
            }
        }
        return s
    }

    mutating func service(id: String, project: ProjectConfig, obj o: JSONObject, path: String, position: JSONPosition) -> ServiceConfig? {
        checkKeys(o, Self.serviceKeys, path)
        let errorsBefore = issues.filter { $0.severity == .error }.count

        let command = string(o, "command", path)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if o["command"] == nil {
            add(.error, "missing \"command\": the command that starts the service", path, position)
        } else if command?.isEmpty == true {
            add(.error, "command is empty", path + ".command", o.position(of: "command"))
        }

        var cwd: String?
        if let raw = string(o, "cwd", path) {
            let expanded = Paths.expand(raw)
            if expanded.hasPrefix("/") {
                cwd = expanded
            } else if let root = project.root {
                cwd = (root as NSString).appendingPathComponent(expanded)
            } else {
                add(.error, "relative cwd (\(raw)) needs a \"root\" in the project", path + ".cwd", o.position(of: "cwd"))
            }
        } else if let root = project.root {
            cwd = root
        } else {
            add(.error, "no \"cwd\" and the project has no \"root\"", path, position)
        }
        if let c = cwd {
            cwd = URL(fileURLWithPath: c).standardizedFileURL.path
            if !Self.dirExists(cwd!) { add(.warning, "the folder \(Paths.abbreviate(cwd!)) doesn't exist", path + ".cwd", o.position(of: "cwd") ?? position) }
        }

        var port: Int?
        if let v = o["port"], !v.isNull {
            if let n = v.numberValue, n.rounded() == n, n >= 1, n <= 65535 {
                port = Int(n)
            } else {
                add(.error, "port must be a whole number from 1 to 65535", path + ".port", o.position(of: "port"))
            }
        }

        var type: ServiceType = .other
        if let t = string(o, "type", path) {
            if let st = ServiceType(rawValue: t) {
                type = st
            } else {
                let options = ServiceType.allCases.map(\.rawValue).joined(separator: ", ")
                add(.error, "type \"\(t)\" doesn't exist; use \(options)", path + ".type", o.position(of: "type"))
            }
        } else if let command, let cwd {
            type = Self.guessType(command: command, cwd: cwd)
        }

        let open = string(o, "open", path)
        if let open, !open.contains("://") {
            add(.warning, "open should be a full URL, like http://localhost:{port}", path + ".open", o.position(of: "open"))
        }

        var env: [String: String] = [:]
        if let v = o["env"], !v.isNull {
            if case .object(let eo) = v {
                for e in eo.entries {
                    switch e.value {
                    case .string(let s): env[e.key] = s
                    case .number(let n): env[e.key] = n.rounded() == n ? String(Int64(n)) : String(n)
                    case .bool(let b): env[e.key] = b ? "true" : "false"
                    default: add(.error, "the value of \(e.key) must be a string", path + ".env." + e.key, e.position)
                    }
                }
            } else {
                add(.error, "env must be an object { \"NAME\": \"value\" }", path + ".env", o.position(of: "env"))
            }
        }

        var envFile: String?
        if let f = string(o, "envFile", path) {
            let expanded = Paths.expand(f)
            let full = expanded.hasPrefix("/") ? expanded : ((cwd ?? project.root ?? "") as NSString).appendingPathComponent(expanded)
            envFile = full
            if !FileManager.default.fileExists(atPath: full) {
                add(.warning, "the file \(f) doesn't exist", path + ".envFile", o.position(of: "envFile"))
            }
        }

        let health = string(o, "health", path)
        if let health, !(health.hasPrefix("/") || health.hasPrefix("http")) {
            add(.warning, "health should start with / (e.g. /health) or be a URL", path + ".health", o.position(of: "health"))
        }

        let autostart = bool(o, "autostart", path) ?? false
        var restart: RestartPolicy = .never
        if let r = string(o, "restart", path) {
            if let rp = RestartPolicy(rawValue: r) {
                restart = rp
            } else {
                add(.error, "restart must be \"never\" or \"on-crash\"", path + ".restart", o.position(of: "restart"))
            }
        }
        let stop = string(o, "stop", path)
        let install = string(o, "install", path)
        // A proxy's clients connect to a fixed port: it never moves unless the proxy itself asks to.
        let autoPort = bool(o, "autoPort", path) ?? (type == .proxy ? false : defaultAutoPort)

        var needs: [String] = []
        if let v = o["needs"], !v.isNull {
            if case .array(let items) = v {
                for item in items {
                    guard case .string(let need) = item, Self.validID(need) else {
                        add(.error, "needs must list service ids, like [\"acme-db\"]", path + ".needs", o.position(of: "needs"))
                        break
                    }
                    if need == id {
                        add(.error, "a service can't need itself", path + ".needs", o.position(of: "needs"))
                    } else if !needs.contains(need) {
                        needs.append(need)
                    }
                }
            } else {
                add(.error, "needs must be a list of service ids, like [\"acme-db\"]", path + ".needs", o.position(of: "needs"))
            }
        }

        var idle: TimeInterval? = type == .proxy ? IdleSetting.defaultSeconds : nil
        if let raw = string(o, "idle", path) {
            switch IdleSetting.parse(raw) {
            case .never: idle = nil
            case .after(let seconds): idle = seconds
            case .invalid: add(.error, "idle must be a duration like \"5m\", \"15m\" or \"1h\", or \"never\"", path + ".idle", o.position(of: "idle"))
            }
            if type != .proxy {
                add(.warning, "idle only applies to proxies (\"type\": \"proxy\")", path + ".idle", o.position(of: "idle"))
                idle = nil
            }
        }
        if let command {
            if command.contains("{port}"), port == nil {
                add(.warning, "the command uses {port}, but the service has no \"port\"", path + ".command", o.position(of: "command"))
            }
            if autoPort, let port, !command.contains("{port}"),
               command.range(of: "(?<![0-9])\(port)(?![0-9])", options: .regularExpression) != nil {
                add(.warning, "the command hardcodes port \(port); use {port} instead so autoPort can start it on another port", path + ".command", o.position(of: "command"))
            }
        }

        let host = self.host(o, id: id, port: port, type: type, path: path)
        if let host {
            // An app told its URL is localhost:<port> rejects (or redirects away from) its local address.
            let pinned = ["localhost:{port}", "127.0.0.1:{port}"]
            if let command, pinned.contains(where: command.contains) {
                add(.warning, "the command gives the app http://localhost:{port} as its URL, but the browser opens it at http://\(host); use {url} there so sign-in and redirects stay on that address", path + ".command", o.position(of: "command"))
            }
            for (key, value) in env where pinned.contains(where: value.contains) {
                add(.warning, "\(key) points at localhost:{port}, but the browser opens this service at http://\(host); use {url} there", path + ".env." + key, o.position(of: "env"))
            }
        }

        let errorsAfter = issues.filter { $0.severity == .error }.count
        guard errorsAfter == errorsBefore, let command, let cwd else { return nil }
        return ServiceConfig(
            id: id, projectID: project.id, projectName: project.name, command: command, cwd: cwd,
            port: port, type: type, open: open, env: env, envFile: envFile, health: health,
            autostart: autostart, restart: restart, stop: stop, autoPort: autoPort, install: install,
            needs: needs, idle: idle, host: host, hostPort: hostPort
        )
    }

    /// The service's local name, always under `.localhost` (the one domain browsers and macOS send to
    /// this Mac on their own): `"host": "fundsys"` is `fundsys.localhost`, `"app.fundsys"` is
    /// `app.fundsys.localhost`. `false` turns it off; without the field, a service with a port (not a
    /// proxy) gets `<id>.localhost` unless `settings.hosts` is false.
    mutating func host(_ o: JSONObject, id: String, port: Int?, type: ServiceType, path: String) -> String? {
        let hpath = path + ".host"
        var name: String?
        switch o["host"] {
        case nil, .null?:
            guard settingsHosts, port != nil, type != .proxy else { return nil }
            return Self.defaultHost(for: id)
        case .bool(false)?:
            return nil
        case .bool(true)?:
            name = Self.defaultHost(for: id)
        case .string(let raw)?:
            var h = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if h.hasSuffix(".") { h.removeLast() }
            if h.contains("://") || h.contains("/") || h.contains(":") {
                add(.error, "host is a name, like \"\(id)\" (for \(id).localhost), not a URL", hpath, o.position(of: "host"))
                return nil
            }
            if h == "localhost" {
                add(.error, "host can't be localhost itself; use a name under it, like \"\(id)\"", hpath, o.position(of: "host"))
                return nil
            }
            if !h.hasSuffix(".localhost") { h += ".localhost" }
            guard Self.validHostname(h) else {
                add(.error, "host \"\(raw)\" isn't a valid name: use letters, digits and -, with dots between parts, like \"app.fundsys\"", hpath, o.position(of: "host"))
                return nil
            }
            name = h
        case let v?:
            add(.error, "host must be a name like \"\(id)\" (for \(id).localhost), or false, not \(v.typeName)", hpath, o.position(of: "host"))
            return nil
        }
        if port == nil {
            add(.warning, "host needs a \"port\" to send the browser to", hpath, o.position(of: "host"))
            return nil
        }
        return name
    }

    /// `fundsys-app.localhost` from the id `fundsys-app`: lowercase, with `_` as `-` (not valid in names).
    static func defaultHost(for id: String) -> String? {
        let name = id.lowercased().replacingOccurrences(of: "_", with: "-") + ".localhost"
        return validHostname(name) ? name : nil
    }

    static func validHostname(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 253 else { return false }
        return s.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            $0.range(of: #"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$"#, options: .regularExpression) != nil
        }
    }

    static func guessType(command: String, cwd: String) -> ServiceType {
        let c = command.lowercased()
        if ProxyTool.detect(command) != .other { return .proxy }
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
