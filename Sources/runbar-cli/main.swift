import Foundation
import RunbarCore

setvbuf(stdout, nil, _IOLBF, 0)

let usage = """
runbar \(RunbarInfo.version) — controla o Runbar pelo Terminal

uso:
  runbar validate [arquivo] [--json]   confere o config.json (linha e coluna de cada erro)
  runbar status [--json]               status, porta real, memória e CPU dos serviços
  runbar start <id> [--wait]           sobe um serviço (--wait espera a porta abrir)
  runbar stop <id>                     para o serviço e os processos filhos
  runbar restart <id> [--wait]         reinicia um serviço
  runbar logs <id> [-n 100] [-f]       mostra a saída do serviço (-f acompanha)
  runbar reload                        faz o app reler o config.json agora
  runbar path                          mostra a pasta da configuração

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

/// Conecta no app; se ele estiver fechado, abre e espera o socket.
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
    fail("o Runbar não está aberto e não consegui abrir o app (\(RunbarInfo.bundleID)).", code: 3)
}

func request(_ cmd: String, _ id: String? = nil, timeout: TimeInterval = 10) -> ControlResponse {
    do {
        return try ControlClient.send(ControlRequest(cmd: cmd, id: id), timeout: timeout)
    } catch {
        fail("erro: \(error)", code: 3)
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
            let kind = issue.severity == .error ? "erro" : "aviso"
            let path = issue.path.isEmpty ? "" : " (\(issue.path))"
            print("\(display)\(loc): \(kind): \(issue.message)\(path)")
        }
        if let config = result.config {
            let s = config.services.count, p = config.projects.count
            print("ok: \(s) \(s == 1 ? "serviço" : "serviços") em \(p) \(p == 1 ? "projeto" : "projetos")" + (result.warnings.isEmpty ? "" : " · \(result.warnings.count) aviso(s)"))
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
            print("O Runbar não está aberto. Serviços no config.json:")
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
    if let err = response.configError { print("config.json com erro: \(err)\n") }
    let names: [String: String] = ["running": "rodando", "starting": "subindo", "stopping": "parando", "stopped": "parado", "crashed": "caiu", "failed": "erro", "external": "fora"]
    print(pad("SERVIÇO", 24) + pad("STATUS", 10) + pad("PORTA", 8) + pad("MEM", 10) + pad("CPU", 8) + "DESDE")
    for s in services {
        let port = (s.realPort ?? s.port).map { ":\($0)" } ?? "—"
        let mem = s.memoryMB.map { Format.memory(UInt64($0 * 1_048_576)) } ?? "—"
        let cpu = s.cpuPercent.map { Format.cpu($0) } ?? "—"
        let since = s.startedAt.map { Format.clock($0) } ?? ""
        var line = pad(s.id, 24) + pad(names[s.status] ?? s.status, 10) + pad(port, 8) + pad(mem, 10) + pad(cpu, 8) + since
        if let alert = s.alert { line += "  ⚠ \(alert)" }
        print(line)
    }

case "start", "stop", "restart":
    guard let id = positional.first else { fail("uso: runbar \(command) <id>") }
    ensureApp()
    let response = request(command, id)
    guard response.ok else { fail("erro: \(response.error ?? "falhou")") }
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
                var line = "\(id) rodando" + (real.map { " na :\($0)" } ?? "")
                if let p = s.port, let real, real != p { line += " (a :\(p) estava ocupada)" }
                if let alert = s.alert { line += " — \(alert)" }
                print(line)
                exit(0)
            }
            if s.status == "crashed" || s.status == "failed" {
                print("\(id) caiu" + (s.exitCode.map { " (código \($0))" } ?? ""))
                for line in LogTailer.lastLines(of: Paths.logFile(for: id), count: 15) { print("  \(line)") }
                exit(1)
            }
        }
        fail("\(id) não ficou pronto em 2 minutos (status: \(last)).")
    }
    print(response.message ?? "ok")

case "logs":
    guard let id = positional.first else { fail("uso: runbar logs <id> [-n 100] [-f]") }
    var count = 100
    if let i = args.firstIndex(of: "-n"), i + 1 < args.count, let n = Int(args[i + 1]) { count = n }
    let url = Paths.logFile(for: id)
    guard FileManager.default.fileExists(atPath: url.path) else { fail("ainda não há log para \(id) (\(Paths.abbreviate(url.path)))") }
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
    if let err = response.configError { fail("config.json com erro: \(err)") }
    print(response.message ?? "ok")

case "path":
    print(Paths.configDir.path)

case "version", "--version", "-v":
    print("runbar \(RunbarInfo.version)")

case "help", "--help", "-h":
    print(usage)

default:
    fail("comando desconhecido: \(command)\n\n\(usage)")
}
