import Foundation
import RunbarCore

setvbuf(stdout, nil, _IOLBF, 0)

let usage = """
runbar \(RunbarInfo.version) — control Runbar from the Terminal

usage:
  runbar validate [file] [--json]      check config.json (line and column of each error)
  runbar scan [--all] [--json]         dev servers in the projects' folders that config.json doesn't run
  runbar status [--json]               status, real port, memory and CPU of each service
  runbar start <id> [--wait]           start a service (--wait waits for the port to open)
  runbar stop <id>                     stop the service and its child processes
  runbar restart <id> [--wait]         restart a service
  runbar open <id> [--wait]            open a proxy (same as start)
  runbar close <id>                    close a proxy (same as stop)
  runbar logs <id> [-n 100] [-f]       show the service's output (-f follows it)
  runbar reload                        make the app reread config.json now
  runbar path                          show the config folder

config: \(Paths.abbreviate(Paths.configFile.path))
"""

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func printJSON<T: Encodable>(_ value: T) {
    let data = (try? ControlCoding.encoder(pretty: true).encode(value)) ?? Data("{}".utf8)
    print(String(decoding: data, as: UTF8.self))
}

func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s + " " : s + String(repeating: " ", count: width - s.count)
}

/// Connects to the app; if it is closed, opens it and waits for the socket.
func ensureApp() {
    if ControlClient.ping() { return }
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-g", "-b", RunbarInfo.bundleID]
    open.standardError = FileHandle.nullDevice
    try? open.run()
    open.waitUntilExit()
    for _ in 0..<40 {
        if ControlClient.ping() { return }
        usleep(250_000)
    }
    fail("Runbar is not open and couldn't be launched (\(RunbarInfo.bundleID)).", code: 3)
}

func request(_ cmd: String, _ id: String? = nil, timeout: TimeInterval = 10) -> ControlResponse {
    do {
        return try ControlClient.send(ControlRequest(cmd: cmd, id: id), timeout: timeout)
    } catch {
        fail("error: \(error)", code: 3)
    }
}

var args = Array(CommandLine.arguments.dropFirst())
let typed = args.isEmpty ? "help" : args.removeFirst()
/// `open` and `close` read better for proxies; they are start and stop.
let command = ["open": "start", "close": "stop"][typed] ?? typed
let flags = Set(args.filter { $0.hasPrefix("-") })
let positional = args.filter { !$0.hasPrefix("-") }

switch command {
case "validate":
    let url = positional.first.map { URL(fileURLWithPath: Paths.expand($0)) } ?? Paths.configFile
    let result = ConfigLoader.load(from: url)
    let display = Paths.abbreviate(url.path)
    if flags.contains("--json") {
        struct Issue: Encodable { var severity, message, path: String; var line, column: Int }
        struct Report: Encodable { var valid: Bool; var file: String; var projects: Int; var services: Int; var issues: [Issue] }
        let issues = result.issues.map { Issue(severity: $0.severity.rawValue, message: $0.message, path: $0.path, line: $0.line, column: $0.column) }
        printJSON(Report(valid: result.config != nil, file: url.path, projects: result.config?.projects.count ?? 0,
                         services: result.config?.services.count ?? 0, issues: issues))
    } else {
        for issue in result.issues {
            let loc = issue.line > 0 ? ":\(issue.line):\(issue.column)" : ""
            let kind = issue.severity == .error ? "error" : "warning"
            let path = issue.path.isEmpty ? "" : " (\(issue.path))"
            print("\(display)\(loc): \(kind): \(issue.message)\(path)")
        }
        if let config = result.config {
            let s = config.services.count, p = config.projects.count
            let w = result.warnings.count
            print("ok: \(s) \(s == 1 ? "service" : "services") in \(p) \(p == 1 ? "project" : "projects")" + (w == 0 ? "" : " · \(w) \(w == 1 ? "warning" : "warnings")"))
        }
    }
    exit(result.config == nil ? 1 : 0)

case "scan":
    let result = ConfigLoader.load()
    guard let config = result.config else {
        fail("config.json has an error: \(result.errors.first?.description ?? "unknown"). Run runbar validate.")
    }
    let ignored = FoundIgnores.load()
    let all = ServiceFinder.find(in: config)
    let shown = flags.contains("--all") ? all : all.filter { !ignored.contains($0.id) }
    let hidden = all.count - shown.count
    if flags.contains("--json") {
        struct Entry: Encodable { var cwd: String?; var type: String; var command: String; var stop: String?; var port: Int? }
        struct Found: Encodable {
            var id, project, folder, framework, source: String
            var note: String?
            var ignored: Bool
            /// What goes under projects.<project>.services.<id> in config.json.
            var config: Entry
        }
        printJSON(shown.map { f in
            Found(id: f.name, project: f.projectID, folder: f.cwd, framework: f.framework, source: f.source, note: f.note,
                  ignored: ignored.contains(f.id),
                  config: Entry(cwd: f.folder.isEmpty ? nil : f.folder, type: f.type.rawValue, command: f.command, stop: f.stop, port: f.port))
        })
        exit(0)
    }
    let ignoredNote = hidden == 0 ? "" : " (\(hidden) ignored in the app; --all shows them)"
    if shown.isEmpty {
        print("Nothing new: config.json runs every development server Runbar found in the projects' folders\(ignoredNote).")
        exit(0)
    }
    for f in shown {
        let where_ = f.folder.isEmpty ? f.projectName : "\(f.projectName) / \(f.folder)"
        print("\(f.projectID) › \(f.name)  \(f.framework), in \(where_), from \(f.source)\(ignored.contains(f.id) ? " (ignored)" : "")")
        if let note = f.note { print("  ! \(note)") }
        // `"id": { … }`, ready to paste under the project's services.
        var wrapper = JSONObject()
        wrapper[f.name] = .object(f.entry)
        for line in JSON.object(wrapper).prettyPrinted().split(separator: "\n").dropFirst().dropLast() { print(line) }
        print()
    }
    print("Add one from Runbar's panel, or under projects.<project>.services in config.json\(ignoredNote).")

case "status":
    guard ControlClient.ping() else {
        let result = ConfigLoader.load()
        if flags.contains("--json") {
            struct Offline: Encodable { var app: Bool; var services: [String] }
            printJSON(Offline(app: false, services: result.config?.services.map(\.id) ?? []))
        } else {
            print("Runbar is not open. Services in config.json:")
            for s in result.config?.services ?? [] { print("  \(s.id)") }
        }
        exit(3)
    }
    let response = request("status")
    let services = response.services ?? []
    if flags.contains("--json") {
        printJSON(response)
        exit(0)
    }
    if let err = response.configError { print("config.json has an error: \(err)\n") }
    let names: [String: String] = ["running": "running", "starting": "starting", "stopping": "stopping", "stopped": "stopped", "waiting": "waiting", "crashed": "crashed", "failed": "failed to start", "external": "outside Runbar"]
    let proxyNames: [String: String] = ["running": "open", "starting": "opening", "stopping": "closing", "stopped": "closed", "failed": "failed to open"]
    print(pad("SERVICE", 24) + pad("STATUS", 16) + pad("PORT", 8) + pad("MEM", 10) + pad("CPU", 8) + "SINCE")
    for s in services {
        let port = (s.realPort ?? s.port).map { ":\($0)" } ?? "—"
        var mem = s.memoryMB.map { Format.memory(UInt64($0 * 1_048_576)) } ?? "—"
        var cpu = s.cpuPercent.map { Format.cpu($0) } ?? "—"
        // A proxy's number is who uses it.
        if s.isProxy, let n = s.connections {
            mem = "\(n) conn"
            cpu = "—"
        }
        let since = s.startedAt.map { Format.clock($0) } ?? ""
        let status = (s.isProxy ? proxyNames[s.status] : nil) ?? names[s.status] ?? s.status
        var line = pad(s.id, 24) + pad(status, 16) + pad(port, 8) + pad(mem, 10) + pad(cpu, 8) + since
        if let waiting = s.waitingFor, !waiting.isEmpty { line += "  waiting for \(waiting.joined(separator: ", "))" }
        if let closes = s.closesAt { line += "  closes \(Format.clock(closes)) if idle" }
        if let alert = s.alert { line += "  ⚠ \(alert)" }
        print(line)
    }

case "start", "stop", "restart":
    guard let id = positional.first else { fail("usage: runbar \(typed) <id>") }
    ensureApp()
    let response = request(command, id)
    guard response.ok else { fail("error: \(response.error ?? "failed")") }
    if command != "stop", flags.contains("--wait") {
        let deadline = Date().addingTimeInterval(120)
        var last = ""
        var announced = Set<String>()
        while Date() < deadline {
            usleep(500_000)
            let all = request("status").services ?? []
            guard let s = all.first(where: { $0.id == id }) else { break }
            if s.status != last {
                last = s.status
            }
            // What it needs, as each one opens.
            for need in s.needs ?? [] where !announced.contains(need) {
                guard let n = all.first(where: { $0.id == need }) else { continue }
                if n.status == "running" || n.status == "external" {
                    announced.insert(need)
                    print("\(need) open" + ((n.realPort ?? n.port).map { " on :\($0)" } ?? ""))
                } else if n.status == "crashed" || n.status == "failed" {
                    announced.insert(need)
                    print("\(need) didn't open" + (n.alert.map { ": \($0)" } ?? ""))
                }
            }
            if s.status == "running" {
                let real = s.realPort ?? s.activePort ?? s.port
                var line = "\(id) \(s.isProxy ? "open" : "running")" + (real.map { " on :\($0)" } ?? "")
                if let p = s.port, let real, real != p { line += " (:\(p) was taken)" }
                if s.isProxy, let closes = s.closesAt { line += " · closes \(Format.clock(closes)) if nothing connects" }
                if let alert = s.alert { line += " — \(alert)" }
                print(line)
                exit(0)
            }
            if s.status == "failed" {
                print("\(id) didn't start" + (s.alert.map { ": \($0)" } ?? ""))
                exit(1)
            }
            if s.status == "crashed" {
                print("\(id) crashed" + (s.exitCode.map { " (exit code \($0))" } ?? ""))
                for line in LogTailer.lastLines(of: Paths.logFile(for: id), count: 15) { print("  \(line)") }
                exit(1)
            }
        }
        fail("\(id) wasn't ready after 2 minutes (status: \(last)).")
    }
    print(response.message ?? "ok")

case "logs":
    guard let id = positional.first else { fail("usage: runbar logs <id> [-n 100] [-f]") }
    var count = 100
    if let i = args.firstIndex(of: "-n"), i + 1 < args.count, let n = Int(args[i + 1]) { count = n }
    let url = Paths.logFile(for: id)
    guard FileManager.default.fileExists(atPath: url.path) else { fail("no log for \(id) yet (\(Paths.abbreviate(url.path)))") }
    for line in LogTailer.lastLines(of: url, count: count) { print(line) }
    if flags.contains("-f") || flags.contains("--follow") {
        let tailer = LogTailer(url: url, startOffset: LogTailer.fileSize(url)) { lines in lines.forEach { print($0) } }
        tailer.start()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { tailer.poll() }
        timer.resume()
        dispatchMain()
    }

case "reload":
    ensureApp()
    let response = request("reload")
    if let err = response.configError { fail("config.json has an error: \(err)") }
    print(response.message ?? "ok")

case "path":
    print(Paths.configDir.path)

case "version", "--version", "-v":
    print("runbar \(RunbarInfo.version)")

case "help", "--help", "-h":
    print(usage)

default:
    fail("unknown command: \(command)\n\n\(usage)")
}
