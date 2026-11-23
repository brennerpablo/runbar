import Foundation
import Network

/// Where one local name leads: the service behind it and the port it answers on now.
public struct HostRoute: Sendable, Equatable {
    public var host: String
    public var serviceID: String
    /// Port to forward to; nil while the service isn't running.
    public var port: Int?
    /// "running", "starting", "stopped", "crashed"…, for the page shown while it can't answer.
    public var status: String

    public init(host: String, serviceID: String, port: Int?, status: String) {
        self.host = host
        self.serviceID = serviceID
        self.port = port
        self.status = status
    }
}

/// The routes the app keeps up to date (every scan) and the proxy reads on each new connection.
public final class HostRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [String: HostRoute] = [:]
    private var order: [String] = []

    public init() {}

    public func update(_ list: [HostRoute]) {
        lock.lock()
        defer { lock.unlock() }
        routes = Dictionary(list.map { ($0.host, $0) }, uniquingKeysWith: { a, _ in a })
        order = list.map(\.host)
    }

    public func route(for host: String) -> HostRoute? {
        lock.lock()
        defer { lock.unlock() }
        return routes[host]
    }

    public var all: [HostRoute] {
        lock.lock()
        defer { lock.unlock() }
        return order.compactMap { routes[$0] }
    }
}

/// A reverse proxy on one port of the loopback interface: `http://fundsys-app.localhost` reaches whatever
/// port fundsys-app listens on now, so the browser's origin (saved passwords, cookies) stays the same
/// when the port changes.
///
/// It reads the first request's head to learn the host, then passes bytes both ways untouched, WebSocket
/// upgrades included. A browser keeps one connection per origin, so later requests on it are for the same
/// host. On port 80 it needs no root: macOS lets anyone listen on a low port on the wildcard address, and
/// the listener is held to the loopback interface, so nothing outside this Mac reaches it.
public final class HostProxy: @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case off
        case starting(Int)
        case listening(Int)
        /// The port, and why it couldn't listen there.
        case failed(Int, String)

        public var port: Int? {
            switch self {
            case .off: return nil
            case .starting(let p), .listening(let p), .failed(let p, _): return p
            }
        }
    }

    public let router: HostRouter
    private let queue = DispatchQueue(label: "runbar.hosts")
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: ProxySession] = [:]
    private let onState: @Sendable (State) -> Void

    public init(router: HostRouter, onState: @escaping @Sendable (State) -> Void) {
        self.router = router
        self.onState = onState
    }

    public func start(port: Int) {
        queue.async { self.listen(on: port) }
    }

    /// Stops listening and drops the open connections.
    public func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            let open = self.sessions.values
            self.sessions = [:]
            open.forEach { $0.close() }
        }
    }

    private func listen(on port: Int) {
        listener?.cancel()
        listener = nil
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0 else {
            onState(.failed(port, "\(port) isn't a valid port"))
            return
        }
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        let l: NWListener
        do {
            l = try NWListener(using: params, on: nwPort)
        } catch {
            onState(.failed(port, Self.describe(error)))
            return
        }
        onState(.starting(port))
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self, let l, self.listener === l else { return }
            switch state {
            case .ready:
                self.onState(.listening(port))
            case .failed(let error), .waiting(let error):
                l.cancel()
                self.listener = nil
                self.onState(.failed(port, Self.describe(error)))
            default:
                break
            }
        }
        l.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            let session = ProxySession(client: connection, router: self.router, queue: self.queue, port: port)
            let key = ObjectIdentifier(session)
            self.sessions[key] = session
            session.onClose = { [weak self] in self?.sessions[key] = nil }
            session.start()
        }
        listener = l
        l.start(queue: queue)
    }

    static func describe(_ error: Error) -> String {
        if case .posix(let code) = error as? NWError {
            switch code {
            case .EADDRINUSE: return "the port is in use"
            case .EACCES: return "macOS didn't allow listening on it"
            default: return String(cString: strerror(code.rawValue))
            }
        }
        return "\(error)"
    }
}

/// One browser connection: reads the first request's head, then pipes it to the service, or answers with
/// a page when there's nothing to pipe to.
private final class ProxySession {
    let client: NWConnection
    let router: HostRouter
    let queue: DispatchQueue
    /// The port the proxy listens on, for links in its pages.
    let port: Int
    var upstream: NWConnection?
    var head = Data()
    var closed = false
    /// Directions that reached their end (client → service, service → client).
    var finished = 0
    var onClose: (() -> Void)?

    static let maxHead = 64 * 1024
    static let headEnd = Data("\r\n\r\n".utf8)

    init(client: NWConnection, router: HostRouter, queue: DispatchQueue, port: Int) {
        self.client = client
        self.router = router
        self.queue = queue
        self.port = port
    }

    func start() {
        client.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        client.start(queue: queue)
        readHead()
    }

    func close() {
        guard !closed else { return }
        closed = true
        client.stateUpdateHandler = nil
        upstream?.stateUpdateHandler = nil
        client.cancel()
        upstream?.cancel()
        onClose?()
        onClose = nil
    }

    private func readHead() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data { self.head.append(data) }
            if self.head.range(of: Self.headEnd) != nil {
                self.route()
            } else if self.head.count > Self.maxHead {
                self.respond(431, HostPages.page(title: "Request too large", body: "The request's headers are over 64 KB."))
            } else if isComplete || error != nil {
                self.close()
            } else {
                self.readHead()
            }
        }
    }

    private func route() {
        let host = Self.host(in: head)
        if let host, let route = router.route(for: host) {
            if let port = route.port {
                connect(to: port, route: route)
            } else {
                respond(503, HostPages.down(route, proxyPort: port), retry: true)
            }
            return
        }
        let list = router.all
        if let host, !["localhost", "127.0.0.1", "[::1]"].contains(host) {
            respond(404, HostPages.unknown(host, list, proxyPort: port))
        } else {
            respond(200, HostPages.index(list, proxyPort: port))
        }
    }

    /// `localhost` connects over IPv6 or IPv4, whichever the service listens on.
    private func connect(to port: Int, route: HostRoute) {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return close() }
        let up = NWConnection(host: "localhost", port: nwPort, using: .tcp)
        upstream = up
        var answered = false
        up.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready:
                answered = true
                up.send(content: self.head, completion: .contentProcessed { [weak self] error in
                    guard let self, !self.closed else { return }
                    if error != nil { return self.close() }
                    self.head = Data()
                    self.pipe(from: self.client, to: up)
                    self.pipe(from: up, to: self.client)
                })
            case .waiting, .failed:
                // Refused: the service is still starting, or listens elsewhere.
                if answered { return self.close() }
                up.stateUpdateHandler = nil
                up.cancel()
                self.upstream = nil
                self.respond(502, HostPages.notAnswering(route, proxyPort: self.port), retry: true)
            case .cancelled:
                if answered { self.close() }
            default:
                break
            }
        }
        up.start(queue: queue)
    }

    /// Copies one direction, a chunk at a time (the next read waits for the last write), and passes its
    /// end on to the other side.
    private func pipe(from source: NWConnection, to sink: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if error != nil { return self.close() }
            let next = { [weak self] in
                guard let self, !self.closed else { return }
                if isComplete {
                    sink.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
                        guard let self else { return }
                        self.finished += 1
                        if self.finished == 2 { self.close() }
                    })
                } else {
                    self.pipe(from: source, to: sink)
                }
            }
            if let data, !data.isEmpty {
                sink.send(content: data, completion: .contentProcessed { [weak self] error in
                    if error != nil { self?.close() } else { next() }
                })
            } else {
                next()
            }
        }
    }

    private func respond(_ status: Int, _ html: String, retry: Bool = false) {
        let body = Data(html.utf8)
        let reason = [200: "OK", 404: "Not Found", 431: "Request Header Fields Too Large", 502: "Bad Gateway", 503: "Service Unavailable"][status] ?? "Error"
        var headers = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\n"
        headers += "Cache-Control: no-store\r\nConnection: close\r\n"
        if retry { headers += "Retry-After: 2\r\n" }
        headers += "\r\n"
        client.send(content: Data(headers.utf8) + body, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }

    /// The Host header's name, lowercase, without the port or a trailing dot.
    static func host(in head: Data) -> String? {
        guard let end = head.range(of: headEnd),
              let text = String(data: head[..<end.lowerBound], encoding: .utf8) ?? String(data: head[..<end.lowerBound], encoding: .isoLatin1)
        else { return nil }
        for line in text.split(separator: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "host" else { continue }
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces).lowercased()
            if value.hasPrefix("[") {
                if let close = value.firstIndex(of: "]") { value = String(value[...close]) }
            } else if let c = value.lastIndex(of: ":") {
                value = String(value[..<c])
            }
            if value.hasSuffix(".") { value.removeLast() }
            return value.isEmpty ? nil : value
        }
        return nil
    }
}

/// The pages the proxy answers with when it can't pass a request on.
enum HostPages {
    static func url(_ host: String, _ port: Int) -> String {
        "http://\(host)" + (port == 80 ? "" : ":\(port)")
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func down(_ route: HostRoute, proxyPort: Int) -> String {
        let id = escape(route.serviceID)
        let text: String
        switch route.status {
        case "waiting": text = "<b>\(id)</b> is waiting for what it needs to open. This page loads it as soon as it answers."
        case "crashed", "failed": text = "<b>\(id)</b> \(route.status == "crashed" ? "crashed" : "didn't start"). Runbar has its log; start it again there and this page loads it."
        default: text = "<b>\(id)</b> isn't running. Start it from Runbar (or <code>runbar start \(id)</code>) and this page loads it."
        }
        return page(title: "\(route.serviceID) · \(route.status)", body: text, refresh: true)
    }

    static func notAnswering(_ route: HostRoute, proxyPort: Int) -> String {
        let id = escape(route.serviceID)
        let p = route.port.map { " on :\($0)" } ?? ""
        let text = route.status == "starting"
            ? "<b>\(id)</b> is starting. This page loads it as soon as it answers\(p)."
            : "<b>\(id)</b> isn't answering\(p). This page tries again every few seconds."
        return page(title: "\(route.serviceID) · not answering", body: text, refresh: true)
    }

    static func index(_ routes: [HostRoute], proxyPort: Int) -> String {
        page(title: "Runbar", body: routes.isEmpty ? "No service has a local address yet." : "Local addresses Runbar answers on:", list: routes, proxyPort: proxyPort)
    }

    static func unknown(_ host: String, _ routes: [HostRoute], proxyPort: Int) -> String {
        page(title: "No service at \(host)", body: "No service in Runbar's config.json has <b>\(escape(host))</b> as its address.", list: routes, proxyPort: proxyPort)
    }

    static func page(title: String, body: String, refresh: Bool = false, list: [HostRoute] = [], proxyPort: Int = 80) -> String {
        var items = ""
        for r in list {
            let running = r.port != nil && r.status != "stopped"
            items += "<li><a href=\"\(escape(url(r.host, proxyPort)))\">\(escape(r.host))</a><span class=\"\(running ? "on" : "off")\">\(escape(r.status))</span></li>"
        }
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        \(refresh ? "<meta http-equiv=\"refresh\" content=\"2\">" : "")<title>\(escape(title))</title>
        <style>
        :root { color-scheme: light dark; --bg: #f6f7f9; --card: #fff; --text: #151a22; --dim: #6b7280; --line: #e5e7eb; --live: #16a34a; }
        @media (prefers-color-scheme: dark) { :root { --bg: #0f1218; --card: #151a22; --text: #e8eaee; --dim: #9aa1ad; --line: #262c37; --live: #4ade9a; } }
        body { margin: 0; background: var(--bg); color: var(--text); font: 15px/1.5 -apple-system, BlinkMacSystemFont, sans-serif; }
        main { max-width: 560px; margin: 12vh auto; padding: 28px; background: var(--card); border: 1px solid var(--line); border-radius: 14px; }
        .mark { font: 600 13px ui-monospace, Menlo, monospace; color: var(--live); }
        h1 { font-size: 19px; margin: 6px 0 10px; } p { margin: 0; color: var(--dim); } b { color: var(--text); }
        ul { list-style: none; padding: 0; margin: 18px 0 0; } li { display: flex; justify-content: space-between; padding: 8px 0; border-top: 1px solid var(--line); }
        a { color: var(--text); font-family: ui-monospace, Menlo, monospace; font-size: 13px; } .on { color: var(--live); } .off { color: var(--dim); } span { font-size: 13px; }
        </style></head><body><main><div class="mark">&gt;_ Runbar</div><h1>\(escape(title))</h1><p>\(body)</p>\(items.isEmpty ? "" : "<ul>\(items)</ul>")</main></body></html>
        """
    }
}
