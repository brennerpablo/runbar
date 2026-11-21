import Foundation

/// A development server in a project's folder that config.json doesn't run yet.
public struct FoundService: Sendable, Identifiable, Equatable {
    /// The folder and what runs in it. The same from one scan to the next, so an ignore sticks.
    public var id: String
    /// Suggested service id, not taken in config.json.
    public var name: String
    public var projectID: String
    public var projectName: String
    /// Absolute folder the command runs in.
    public var cwd: String
    /// `cwd` relative to the project's root; empty for the root itself.
    public var folder: String
    public var type: ServiceType
    /// What it is, for people: "Next.js", "Vite", "FastAPI", "Django", "Docker Compose"…
    public var framework: String
    public var command: String
    public var stop: String?
    public var port: Int?
    /// The file it was found from: "package.json", "run_local.py", "docker-compose.yml".
    public var source: String
    /// What's missing before it can run, when something is ("no .venv yet").
    public var note: String?

    /// The service as it goes into config.json, under `projects.<projectID>.services.<name>`.
    public var entry: JSONObject {
        var o = JSONObject()
        if !folder.isEmpty { o["cwd"] = .string(folder) }
        o["type"] = .string(type.rawValue)
        o["command"] = .string(command)
        if let stop { o["stop"] = .string(stop) }
        if let port { o["port"] = .number(Double(port)) }
        return o
    }

    /// As a configured service, for whatever takes one (the icon).
    public var asService: ServiceConfig {
        ServiceConfig(id: name, projectID: projectID, projectName: projectName, command: command, cwd: cwd,
                      port: port, type: type, stop: stop)
    }
}

/// Looks through each project's folder for development servers config.json doesn't run: a `dev` script in
/// `package.json`, a FastAPI, Flask or Django app, a compose file. Reads only, never follows symlinks.
public enum ServiceFinder {
    /// How far below a project's root to look: `viabiz-app/infra/api` is 3 levels down.
    public static let maxDepth = 3

    /// Folders never looked into: dependencies, build output, assets, tests. Folders whose names start with
    /// `.` or `_` (caches, backups, workbenches) and virtualenvs are left out too.
    static let skipNames: Set<String> = [
        "node_modules", "site-packages", "__pycache__", "dist", "build", "out", "target", "coverage", "vendor",
        "public", "static", "assets", "docs", "tests", "test", "__tests__", "migrations", "Pods", "DerivedData",
    ]

    /// Development servers under each project's root that config.json doesn't run yet, in file order, each
    /// with an id and a port no other service in the file uses.
    public static func find(in config: RunbarConfig) -> [FoundService] {
        var takenIDs = Set(config.services.map(\.id))
        var takenPorts = Set(config.services.compactMap(\.port))
        // A proxy runs from the project's folder without being the folder's app.
        let running = config.services.filter { !$0.isProxy }.map { (cwd: DiskScanner.standard($0.cwd), service: $0) }
        var out: [FoundService] = []
        for project in config.projects {
            guard let root = project.root.map(DiskScanner.standard), ConfigValidator.dirExists(root) else { continue }
            var detected: [Detected] = []
            walk(root, root: root, depth: 0, into: &detected)
            for d in detected {
                if running.contains(where: { $0.cwd == d.cwd && d.isRun(by: $0.service) }) { continue }
                let alone = detected.filter { $0.cwd == d.cwd }.count == 1
                let name = suggestedName(d, project: project, root: root, alone: alone, taken: takenIDs)
                takenIDs.insert(name)
                var port = d.port
                if var p = port, !d.fixedPort {
                    while takenPorts.contains(p), p < 65535 { p += 1 }
                    port = p
                }
                if let port { takenPorts.insert(port) }
                out.append(FoundService(
                    id: d.cwd + "#" + d.key, name: name, projectID: project.id, projectName: project.name,
                    cwd: d.cwd, folder: DiskScanner.relative(d.cwd, to: root), type: d.type, framework: d.framework,
                    command: d.command, stop: d.stop, port: port, source: d.source, note: d.note
                ))
            }
        }
        return out
    }

    // MARK: - What a folder runs

    struct Detected {
        enum Kind: String { case node, python, docker }
        var cwd: String
        var kind: Kind
        var type: ServiceType
        var framework: String
        var command: String
        var stop: String?
        var port: Int?
        /// Set by a file Runbar doesn't write (a compose file, a script): it isn't moved to a free port.
        var fixedPort = false
        var source: String
        var note: String?
        /// The Python app (`main:app`): two apps in one folder are two services.
        var target: String?

        var key: String { kind.rawValue + (target.map { ":" + $0 } ?? "") }

        /// Whether a configured service in the same folder already runs this.
        func isRun(by svc: ServiceConfig) -> Bool {
            // A command Runbar can't read (`make dev`, `./run.sh`) is taken to be what the folder runs.
            if svc.type == .other { return true }
            switch kind {
            case .docker:
                return svc.type == .docker || svc.command.lowercased().contains("docker")
            case .node:
                return svc.type == .nextjs || svc.type == .node
            case .python:
                guard svc.type == .python else { return false }
                guard let target else { return true }
                // `uvicorn conector.servico:app` next to a `main:app` is another app.
                let targets = ServiceFinder.appTargets(in: svc.command)
                return targets.isEmpty || targets.contains(target)
            }
        }
    }

    static func walk(_ dir: String, root: String, depth: Int, into found: inout [Detected]) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        let files = Set(names)
        if files.contains("pyvenv.cfg") { return }
        found += [node(dir, root: root, files: files), python(dir, files: files), docker(dir, files: files)].compactMap { $0 }
        guard depth < maxDepth else { return }
        for name in names.sorted() where !name.hasPrefix(".") && !name.hasPrefix("_") && !skipNames.contains(name) {
            let path = dir + "/" + name
            if DiskScanner.isPlainDirectory(path) { walk(path, root: root, depth: depth + 1, into: &found) }
        }
    }

    // MARK: - Node

    struct Framework {
        let dependency: String
        /// What the script runs when it starts this framework's dev server.
        let binaries: [String]
        let label: String
        let type: ServiceType
        /// Without one, the server reads `PORT`, which Runbar exports.
        let portFlag: String?
        let port: Int
    }

    /// In order: a Next.js or SvelteKit app also depends on Vite or React tooling.
    static let frameworks: [Framework] = [
        Framework(dependency: "next", binaries: ["next"], label: "Next.js", type: .nextjs, portFlag: "-p", port: 3000),
        Framework(dependency: "nuxt", binaries: ["nuxt", "nuxi"], label: "Nuxt", type: .node, portFlag: "--port", port: 3000),
        Framework(dependency: "astro", binaries: ["astro"], label: "Astro", type: .node, portFlag: "--port", port: 4321),
        Framework(dependency: "@sveltejs/kit", binaries: ["vite"], label: "SvelteKit", type: .node, portFlag: "--port", port: 5173),
        Framework(dependency: "@angular/cli", binaries: ["ng serve"], label: "Angular", type: .node, portFlag: "--port", port: 4200),
        Framework(dependency: "gatsby", binaries: ["gatsby"], label: "Gatsby", type: .node, portFlag: "-p", port: 8000),
        Framework(dependency: "react-scripts", binaries: ["react-scripts start"], label: "Create React App", type: .node, portFlag: nil, port: 3000),
        Framework(dependency: "vite", binaries: ["vite"], label: "Vite", type: .node, portFlag: "--port", port: 5173),
    ]

    /// Scripts that serve without one of the frameworks above. Anything else (`turbo dev` runs other
    /// packages' scripts, `tsc --watch` builds a library) isn't a server.
    static let nodeServers: Set<String> = ["node", "nodemon", "tsx", "ts-node", "ts-node-dev", "node-dev", "nest", "bun"]

    static func node(_ dir: String, root: String, files: Set<String>) -> Detected? {
        guard files.contains("package.json"), let text = read(dir + "/package.json"),
              case .object(let pkg)? = try? JSONParser.parse(text) else { return nil }
        let scripts = pkg["scripts"]?.objectValue
        let deps = Set((pkg["dependencies"]?.objectValue?.keys ?? []) + (pkg["devDependencies"]?.objectValue?.keys ?? []))
        // `dev` by convention; `start` only where it is the dev server (Angular, Create React App).
        var scriptName = "dev"
        var script = scripts?["dev"]?.stringValue
        if script == nil, let start = scripts?["start"]?.stringValue, start.contains("ng serve") || start.contains("react-scripts start") {
            scriptName = "start"
            script = start
        }
        guard let script else { return nil }
        let pm = packageManager(dir, root: root, pkg: pkg)
        let framework = frameworks.first { f in deps.contains(f.dependency) && f.binaries.contains { script.contains($0) } }

        if let framework {
            var port = framework.port
            var command = run(pm, scriptName, args: framework.portFlag.map { "\($0) {port}" })
            // A port written in the script: call the binary instead, with {port} in its place, so it can move.
            if let flag = match(#"(?:^|\s)(?:-p|--port)(?:\s+|=)(\d{2,5})(?=\s|$)"#, script), let n = Int(flag[0]) {
                port = n
                let simple = !["&&", "||", ";", "|", "&"].contains { script.contains($0) }
                    && framework.binaries.contains { script.hasPrefix($0) }
                if simple, let r = script.range(of: #"(?<=[\s=])\#(n)(?=\s|$)"#, options: .regularExpression) {
                    command = "\(exec(pm)) \(script.replacingCharacters(in: r, with: "{port}"))"
                }
            }
            return Detected(cwd: dir, kind: .node, type: framework.type, framework: framework.label, command: command,
                            port: port, source: "package.json")
        }

        guard let tool = firstTool(script), nodeServers.contains(tool) else { return nil }
        // `PORT=4000 nodemon server.js`: the script picks the port.
        let fixed = match(#"(?:^|\s)PORT=(\d{2,5})\b"#, script).flatMap { Int($0[0]) }
        return Detected(cwd: dir, kind: .node, type: .node, framework: "Node.js", command: run(pm, scriptName, args: nil),
                        port: fixed ?? 3000, fixedPort: fixed != nil, source: "package.json")
    }

    /// `npm run dev -- -p {port}`, `pnpm dev -p {port}`, `yarn dev`, `bun run dev`.
    static func run(_ pm: String, _ script: String, args: String?) -> String {
        let base: String
        switch pm {
        case "pnpm": base = "pnpm \(script)"
        case "yarn": base = "yarn \(script)"
        case "bun": base = "bun run \(script)"
        default: base = "npm run \(script)"
        }
        guard let args else { return base }
        return pm == "npm" ? "\(base) -- \(args)" : "\(base) \(args)"
    }

    /// Runs a binary from the project's dependencies.
    static func exec(_ pm: String) -> String {
        switch pm {
        case "pnpm": return "pnpm exec"
        case "yarn": return "yarn"
        case "bun": return "bunx"
        default: return "npx"
        }
    }

    /// From `packageManager` in package.json, else the lockfile here or in a folder above, up to the project's
    /// root (a monorepo keeps one at the top). With more than one, the one written last is the one in use.
    static func packageManager(_ dir: String, root: String, pkg: JSONObject) -> String {
        if let declared = pkg["packageManager"]?.stringValue?.split(separator: "@").first.map(String.init),
           ["npm", "pnpm", "yarn", "bun"].contains(declared) { return declared }
        let locks = [("pnpm-lock.yaml", "pnpm"), ("yarn.lock", "yarn"), ("bun.lock", "bun"), ("bun.lockb", "bun"), ("package-lock.json", "npm")]
        var folder = dir
        while true {
            let here = locks.compactMap { lock -> (String, Date)? in
                LogTailer.modificationDate(URL(fileURLWithPath: folder + "/" + lock.0)).map { (lock.1, $0) }
            }
            if let newest = here.max(by: { $0.1 < $1.1 }) { return newest.0 }
            if folder == root || !folder.hasPrefix(root) || folder == "/" { return "npm" }
            folder = (folder as NSString).deletingLastPathComponent
        }
    }

    /// The program a script starts, past `NAME=value` and `cross-env`.
    static func firstTool(_ script: String) -> String? {
        script.split(whereSeparator: \.isWhitespace).map(String.init)
            .first { !$0.contains("=") && $0 != "cross-env" && $0 != "env" }
    }

    // MARK: - Python

    static func python(_ dir: String, files: Set<String>) -> Detected? {
        let deps = ["requirements.txt", "requirements-dev.txt", "pyproject.toml", "Pipfile"].filter(files.contains)
            .compactMap { read(dir + "/" + $0) }.joined(separator: "\n").lowercased()
        guard !deps.isEmpty else { return nil }
        // The login shell doesn't activate venvs (README rule 2): the command names the venv's binary.
        let venv = [".venv", "venv"].first { FileManager.default.fileExists(atPath: "\(dir)/\($0)/pyvenv.cfg") }
        let bin = (venv ?? ".venv") + "/bin/"
        let note = venv == nil ? "no .venv yet" : nil

        if files.contains("manage.py"), deps.contains("django") {
            return Detected(cwd: dir, kind: .python, type: .python, framework: "Django",
                            command: "\(bin)python manage.py runserver {port}", port: 8000, source: "manage.py", note: note)
        }
        if ["fastapi", "uvicorn", "starlette"].contains(where: deps.contains), let app = asgiApp(dir, files: files) {
            return Detected(cwd: dir, kind: .python, type: .python, framework: deps.contains("fastapi") ? "FastAPI" : "Uvicorn",
                            command: "\(bin)uvicorn \(app.target) --reload --port {port}", port: app.port ?? 8000,
                            source: app.source, note: note, target: app.target)
        }
        if deps.contains("flask"), let app = flaskApp(dir, files: files) {
            // 5000 is macOS's AirPlay Receiver.
            return Detected(cwd: dir, kind: .python, type: .python, framework: "Flask",
                            command: "\(bin)flask --app \(app.module) run --port {port}", port: app.port ?? 5001,
                            source: app.source, note: note)
        }
        return nil
    }

    static let pyPort = #"port\s*=\s*(\d{2,5})"#

    /// The ASGI app to serve and the port it's meant for: from a script that calls `uvicorn.run(…)`
    /// (`run_local.py`), the Procfile, or the module that creates it.
    static func asgiApp(_ dir: String, files: Set<String>) -> (target: String, port: Int?, source: String)? {
        let preferred = ["run_local.py", "run.py", "dev.py", "server.py", "main.py", "app.py", "asgi.py"]
        let scripts = preferred.filter(files.contains) + files.filter { $0.hasSuffix(".py") && !preferred.contains($0) }.sorted()
        for name in scripts {
            guard let text = read(dir + "/" + name, limit: 200_000), text.contains("uvicorn.run(") else { continue }
            if let call = match(#"uvicorn\.run\(\s*["']([A-Za-z_][\w.]*:[A-Za-z_]\w*)["']([^)]*)\)"#, text) {
                return (call[0], match(pyPort, call[1]).flatMap { Int($0[0]) }, name)
            }
            if let call = match(#"uvicorn\.run\(\s*([A-Za-z_]\w*)\s*([,)][^)]*)"#, text) {
                return ("\(name.dropLast(3)):\(call[0])", match(pyPort, call[1]).flatMap { Int($0[0]) }, name)
            }
        }
        if files.contains("Procfile"), let text = read(dir + "/Procfile"),
           let web = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("web:") }),
           let target = match(#"(?:uvicorn|gunicorn|hypercorn)\b.*?\s([A-Za-z_][\w.]*:[A-Za-z_]\w*)"#, String(web)) {
            return (target[0], nil, "Procfile")
        }
        for path in ["main.py", "app.py", "server.py", "asgi.py", "app/main.py", "src/main.py", "api/main.py", "src/app/main.py"] {
            guard let text = read(dir + "/" + path, limit: 200_000) else { continue }
            let module = path.dropLast(3).replacingOccurrences(of: "/", with: ".")
            if let v = match(#"(?m)^([A-Za-z_]\w*)\s*(?::\s*\w+\s*)?=\s*FastAPI\("#, text) { return ("\(module):\(v[0])", nil, path) }
            // `main.py` that hands on an app made elsewhere (`from app.api.routes import app`).
            if match(#"(?m)^from\s+[\w.]+\s+import\s+(?:[\w\s,]*,\s*)?(app)\b"#, text) != nil { return ("\(module):app", nil, path) }
        }
        return nil
    }

    /// The module `flask --app` takes (with `:name` when the app isn't called `app`) and the port `app.run` uses.
    static func flaskApp(_ dir: String, files: Set<String>) -> (module: String, port: Int?, source: String)? {
        for path in ["app.py", "main.py", "server.py", "wsgi.py", "app/__init__.py", "src/app.py"] {
            guard let text = read(dir + "/" + path, limit: 200_000), text.contains("Flask(") else { continue }
            let module = path == "app/__init__.py" ? "app" : path.dropLast(3).replacingOccurrences(of: "/", with: ".")
            let variable = match(#"(?m)^([A-Za-z_]\w*)\s*=\s*Flask\("#, text)?[0]
            let port = match(#"\.run\([^)]*port\s*=\s*(\d{2,5})"#, text).flatMap { Int($0[0]) }
            return (variable.map { $0 == "app" ? module : "\(module):\($0)" } ?? module, port, path)
        }
        return nil
    }

    /// `module:app` targets in a command (`uvicorn conector.servico:app`), leaving out URLs and addresses.
    static func appTargets(in command: String) -> Set<String> {
        guard let re = try? NSRegularExpression(pattern: #"(?<![\w./:-])([A-Za-z_][\w.]*:[A-Za-z_]\w*)(?![\w:/])"#) else { return [] }
        let range = NSRange(command.startIndex..., in: command)
        return Set(re.matches(in: command, range: range).compactMap { Range($0.range(at: 1), in: command).map { String(command[$0]) } })
    }

    // MARK: - Docker

    static let composeFiles = ["compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml"]

    static func docker(_ dir: String, files: Set<String>) -> Detected? {
        guard let file = composeFiles.first(where: files.contains) else { return nil }
        return Detected(cwd: dir, kind: .docker, type: .docker, framework: "Docker Compose", command: "docker compose up",
                        stop: "docker compose down", port: publishedPort(read(dir + "/" + file) ?? ""), fixedPort: true, source: file)
    }

    /// The first port a compose file publishes on the Mac: `- "8080:8080"`, `- 127.0.0.1:5432:5432`,
    /// `- ${WEB_PORT:-3000}:3000`, `published: 8080`.
    static func publishedPort(_ yaml: String) -> Int? {
        for line in yaml.split(whereSeparator: \.isNewline).map(String.init) {
            let m = match(#"^\s*-\s*["']?(?:\d{1,3}(?:\.\d{1,3}){3}:)?(?:\$\{\w+:-)?(\d{2,5})\}?:\d+"#, line)
                ?? match(#"^\s*published:\s*["']?(\d{2,5})"#, line)
            if let m, let port = Int(m[0]) { return port }
        }
        return nil
    }

    // MARK: - Names and helpers

    /// Folder names that don't say whose they are: they get the project's id in front (`viabiz-api`).
    static let genericNames: Set<String> = [
        "app", "web", "api", "server", "backend", "frontend", "client", "site", "www", "admin", "dashboard", "worker",
        "service", "ui", "src", "docker", "infra", "db", "database",
    ]

    static func suggestedName(_ d: Detected, project: ProjectConfig, root: String, alone: Bool, taken: Set<String>) -> String {
        var base = d.cwd == root ? project.id : (sanitizedID((d.cwd as NSString).lastPathComponent) ?? project.id)
        if base != project.id, genericNames.contains(base.lowercased()) { base = "\(project.id)-\(base)" }
        // A compose file next to an app usually runs what the app uses (its database).
        if !alone, d.kind == .docker { base += "-docker" }
        var name = base
        var n = 2
        while taken.contains(name) {
            name = "\(base)-\(n)"
            n += 1
        }
        return name
    }

    /// Letters, digits, `.`, `_` and `-`, starting with a letter or digit; anything else becomes `-`.
    static func sanitizedID(_ s: String) -> String? {
        let mapped = String(s.map { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) ? $0 : "-" })
        let trimmed = mapped.drop { !($0.isLetter || $0.isNumber) }
        return trimmed.isEmpty ? nil : String(trimmed)
    }

    /// A regular file's text, if it isn't larger than `limit`.
    static func read(_ path: String, limit: Int = 1_000_000) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.size] as? Int ?? 0) <= limit else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    /// The capture groups of the first match, or nil.
    static func match(_ pattern: String, _ text: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<m.numberOfRanges).map { i in Range(m.range(at: i), in: text).map { String(text[$0]) } ?? "" }
    }
}

/// Found services the user doesn't want suggested, by `FoundService.id`. Kept in Runbar's support folder so
/// the app and `runbar scan` agree.
public enum FoundIgnores {
    public static var file: URL { Paths.supportDir.appendingPathComponent("ignored-services.json") }

    public static func load() -> Set<String> {
        guard let data = try? Data(contentsOf: file), let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(ids)
    }

    public static func save(_ ids: Set<String>) {
        try? FileManager.default.createDirectory(at: Paths.supportDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if let data = try? encoder.encode(ids.sorted()) { try? data.write(to: file, options: .atomic) }
    }
}
