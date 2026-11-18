import Darwin
import Foundation

/// Tests whether a TCP port is taken by trying to bind it.
///
/// The probe sets SO_REUSEADDR, like the servers themselves do: connections left over from a server that
/// just stopped (FIN_WAIT, TIME_WAIT, a client that hasn't hung up yet) don't count, only a socket that
/// listens. It binds the wildcard address and loopback, IPv4 and IPv6: with SO_REUSEADDR each bind only
/// collides with a listener on that same address, and dev servers and proxies listen on one of these.
public enum PortProbe {
    public static func isInUse(_ port: Int) -> Bool {
        guard (1...65535).contains(port) else { return false }
        return !canBind(port, ipv6: false, loopback: false) || !canBind(port, ipv6: false, loopback: true)
            || !canBind(port, ipv6: true, loopback: false) || !canBind(port, ipv6: true, loopback: true)
    }

    private static func canBind(_ port: Int, ipv6: Bool, loopback: Bool) -> Bool {
        let fd = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        let netPort = in_port_t(UInt16(port).bigEndian)
        if ipv6 {
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &one, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = netPort
            addr.sin6_addr = loopback ? in6addr_loopback : in6addr_any
            return withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            } == 0 || errno != EADDRINUSE
        } else {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = netPort
            addr.sin_addr = in_addr(s_addr: loopback ? UInt32(0x7F00_0001).bigEndian : INADDR_ANY)
            return withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            } == 0 || errno != EADDRINUSE
        }
    }
}
