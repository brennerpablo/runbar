import Darwin
import Foundation

/// Testa se uma porta TCP está ocupada tentando um bind nela (IPv4 e IPv6), sem SO_REUSEADDR.
public enum PortProbe {
    public static func isInUse(_ port: Int) -> Bool {
        guard (1...65535).contains(port) else { return false }
        return !canBind(port, ipv6: false) || !canBind(port, ipv6: true)
    }

    private static func canBind(_ port: Int, ipv6: Bool) -> Bool {
        let fd = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        let netPort = in_port_t(UInt16(port).bigEndian)
        if ipv6 {
            var only: Int32 = 1
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &only, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = netPort
            addr.sin6_addr = in6addr_any
            return withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            } == 0 || errno != EADDRINUSE
        } else {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = netPort
            addr.sin_addr = in_addr(s_addr: INADDR_ANY)
            return withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            } == 0 || errno != EADDRINUSE
        }
    }
}
