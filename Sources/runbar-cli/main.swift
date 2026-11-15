import Foundation
import RunbarCore

setvbuf(stdout, nil, _IOLBF, 0)

let usage = """
runbar \(RunbarInfo.version) — control Runbar from the Terminal

usage:
  runbar validate [file] [--json]      check config.json (line and column of each error)
  runbar status [--json]               status, real port, memory and CPU of each service
  runbar start <id> [--wait]           start a service (--wait waits for the port to open)
  runbar stop <id>                     stop the service and its child processes
  runbar restart <id> [--wait]         restart a service
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
let command = args.isEmpty ? "help" : args.removeFirst()
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
    let names: [String: String] = ["running": "running", "starting": "starting", "stopping": "stopping", "stopped": "stopped", "crashed": "crashed", "failed": "failed to start", "external": "outside Runbar"]
    print(pad("SERVICE", 24) + pad("STATUS", 16) + pad("PORT", 8) + pad("MEM", 10) + pad("CPU", 8) + "SINCE")
    for s in services {
        let port = (s.realPort ?? s.port).map { ":\($0)" } ?? "—"
        let mem = s.memoryMB.map { Format.memory(UInt64($0 * 1_048_576)) } ?? "—"
        let cpu = s.cpuPercent.map { Format.cpu($0) } ?? "—"
        let since = s.startedAt.map { Format.clock($0) } ?? ""
        var line = pad(s.id, 24) + pad(names[s.status] ?? s.status, 16) + pad(port, 8) + pad(mem, 10) + pad(cpu, 8) + since
        if let alert = s.alert { line += "  ⚠ \(alert)" }
        print(line)
    }

case "start", "stop", "restart":
    guard let id = positional.first else { fail("usage: runbar \(command) <id>") }
    ensureApp()
    let response = request(command, id)
    guard response.ok else { fail("error: \(response.error ?? "failed")") }
    if command != "stop", flags.contains("--wait") {
        let deadline = Date().addingTimeInterval(120)
        var last = ""
        while Date() < deadline {
            usleep(1_000_000)
            guard let s = request("status").services?.first(where: { $0.id == id }) else { break }
            if s.status != last {
                last = s.status
            }
            if s.status == "running" {
                let real = s.realPort ?? s.activePort ?? s.port
                var line = "\(id) running" + (real.map { " on :\($0)" } ?? "")
                if let p = s.port, let real, real != p { line += " (:\(p) was taken)" }
                if let alert = s.alert { line += " — \(alert)" }
                print(line)
                exit(0)
            }
            if s.status == "crashed" || s.status == "failed" {
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
