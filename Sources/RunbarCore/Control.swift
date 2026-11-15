import Darwin
import Foundation

// Protocol between the CLI and the app: one JSON request line, one JSON response, Unix socket.

public struct ControlRequest: Codable, Sendable {
    public var cmd: String
    public var id: String?
    public init(cmd: String, id: String? = nil) {
        self.cmd = cmd
        self.id = id
    }
}

public struct ServiceStatus: Codable, Sendable {
    public var id: String
    public var project: String
    public var type: String
    /// stopped, starting, running, stopping, crashed, failed
    public var status: String
    public var port: Int?
    public var realPort: Int?
    public var listening: [Int]
    public var pid: Int32?
    public var memoryMB: Double?
    public var cpuPercent: Double?
    public var processes: Int?
    public var startedAt: Date?
    public var lastLogAt: Date?
    public var exitCode: Int32?
    public var url: String?
    public var command: String
    public var cwd: String
    public var logFile: String
    public var alert: String?
    /// Port the service started on (differs from `port` when autoPort picked another).
    public var activePort: Int?

    public init(id: String, project: String, type: String, status: String, port: Int?, realPort: Int?, listening: [Int],
                pid: Int32?, memoryMB: Double?, cpuPercent: Double?, processes: Int?, startedAt: Date?, lastLogAt: Date?,
                exitCode: Int32?, url: String?, command: String, cwd: String, logFile: String, alert: String?, activePort: Int? = nil) {
        self.id = id
        self.project = project
        self.type = type
        self.status = status
        self.port = port
        self.realPort = realPort
        self.listening = listening
        self.pid = pid
        self.memoryMB = memoryMB
        self.cpuPercent = cpuPercent
        self.processes = processes
        self.startedAt = startedAt
        self.lastLogAt = lastLogAt
        self.exitCode = exitCode
        self.url = url
        self.command = command
        self.cwd = cwd
        self.logFile = logFile
        self.alert = alert
        self.activePort = activePort
    }
}

public struct ControlResponse: Codable, Sendable {
    public var ok: Bool
    public var message: String?
    public var error: String?
    public var services: [ServiceStatus]?
    public var configError: String?

    public init(ok: Bool, message: String? = nil, error: String? = nil, services: [ServiceStatus]? = nil, configError: String? = nil) {
        self.ok = ok
        self.message = message
        self.error = error
        self.services = services
        self.configError = configError
    }
}

public enum ControlCoding {
    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

public enum ControlError: Error, CustomStringConvertible {
    case notRunning
    case io(String)
    public var description: String {
        switch self {
        case .notRunning: return "Runbar is not open"
        case .io(let m): return m
        }
    }
}

enum UnixSocket {
    static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw ControlError.io("socket path is too long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    static func withSockaddr<T>(_ addr: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    static func configure(_ fd: Int32, timeout: TimeInterval) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = write(fd, raw.baseAddress! + sent, raw.count - sent)
                if n <= 0 { throw ControlError.io("failed to write to the socket") }
                sent += n
            }
        }
    }

    static func readAll(_ fd: Int32, until delimiter: UInt8? = nil, limit: Int = 8_000_000) -> Data {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while out.count < limit {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            out.append(buf, count: n)
            if let delimiter, buf[..<n].contains(delimiter) { break }
        }
        return out
    }
}

public enum ControlClient {
    public static func send(_ request: ControlRequest, path: String = Paths.socketPath, timeout: TimeInterval = 5) throws -> ControlResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError.io("couldn't open a socket") }
        defer { close(fd) }
        UnixSocket.configure(fd, timeout: timeout)
        var addr = try UnixSocket.address(path)
        guard UnixSocket.withSockaddr(&addr, { connect(fd, $0, $1) }) == 0 else { throw ControlError.notRunning }
        var data = try ControlCoding.encoder().encode(request)
        data.append(0x0A)
        try UnixSocket.writeAll(fd, data)
        shutdown(fd, SHUT_WR)
        let reply = UnixSocket.readAll(fd)
        guard !reply.isEmpty else { throw ControlError.io("Runbar didn't respond") }
        return try ControlCoding.decoder().decode(ControlResponse.self, from: reply)
    }

    public static func ping(timeout: TimeInterval = 1) -> Bool {
        (try? send(ControlRequest(cmd: "ping"), timeout: timeout))?.ok == true
    }
}

public final class ControlServer {
    public typealias Handler = (ControlRequest, @escaping (ControlResponse) -> Void) -> Void

    private let path: String
    private let handler: Handler
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "runbar.control")

    public init(path: String = Paths.socketPath, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError.io("socket() failed") }
        var addr = try UnixSocket.address(path)
        guard UnixSocket.withSockaddr(&addr, { bind(fd, $0, $1) }) == 0 else { throw ControlError.io("bind() failed: \(String(cString: strerror(errno)))") }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { throw ControlError.io("listen() failed") }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptPending() }
        let listenFD = fd
        src.setCancelHandler { close(listenFD) }
        src.resume()
        source = src
    }

    public func stop() {
        source?.cancel()
        source = nil
        unlink(path)
    }

    private func acceptPending() {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { return }
            serve(client)
        }
    }

    private func serve(_ client: Int32) {
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        UnixSocket.configure(client, timeout: 3)
        let data = UnixSocket.readAll(client, until: 0x0A, limit: 1_000_000)
        guard let request = try? ControlCoding.decoder().decode(ControlRequest.self, from: data) else {
            respond(client, ControlResponse(ok: false, error: "invalid request"))
            return
        }
        handler(request) { [weak self] response in
            self?.queue.async { self?.respond(client, response) }
        }
    }

    private func respond(_ client: Int32, _ response: ControlResponse) {
        if let data = try? ControlCoding.encoder().encode(response) {
            try? UnixSocket.writeAll(client, data)
        }
        close(client)
    }
}
