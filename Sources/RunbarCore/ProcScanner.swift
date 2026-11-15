import Darwin
import Foundation

public struct ProcSample: Sendable {
    public var pid: Int32
    public var ppid: Int32
    public var pgid: Int32
    public var uid: UInt32
    public var name: String
    public var startTime: Date
    /// Memory as Activity Monitor shows it (phys_footprint), in bytes.
    public var footprint: UInt64
    /// Accumulated CPU time (user + system), in nanoseconds.
    public var cpuNanos: UInt64
}

public struct Listener: Sendable, Identifiable, Hashable {
    public var port: Int
    public var pid: Int32
    public var name: String
    public var path: String
    public var id: String { "\(port)-\(pid)" }

    public init(port: Int, pid: Int32, name: String, path: String) {
        self.port = port
        self.pid = pid
        self.name = name
        self.path = path
    }
}

public enum ProcScanner {
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }()

    public static func allPIDs() -> [Int32] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(estimate) + 128)
        let count = pids.withUnsafeMutableBufferPointer { buf in
            proc_listallpids(buf.baseAddress, Int32(buf.count * MemoryLayout<Int32>.size))
        }
        guard count > 0 else { return [] }
        return pids.prefix(Int(count)).filter { $0 > 0 }
    }

    private static func cString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    public static func sample(pid: Int32) -> ProcSample? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        var name = cString(info.pbi_name)
        if name.isEmpty { name = cString(info.pbi_comm) }

        var usage = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &usage) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        var footprint: UInt64 = 0
        var cpu: UInt64 = 0
        if ok == 0 {
            footprint = usage.ri_phys_footprint
            cpu = (usage.ri_user_time + usage.ri_system_time) * timebase.numer / timebase.denom
        }
        let start = Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
        return ProcSample(
            pid: pid, ppid: Int32(info.pbi_ppid), pgid: Int32(info.pbi_pgid), uid: info.pbi_uid,
            name: name, startTime: start, footprint: footprint, cpuNanos: cpu
        )
    }

    public static func path(pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return "" }
        return String(cString: buf)
    }

    /// The process's current working directory.
    public static func cwd(pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = cString(info.pvi_cdir.vip_path)
        return path.isEmpty ? nil : path
    }

    /// TCP ports in LISTEN opened by the process.
    public static func listeningTCPPorts(pid: Int32) -> [Int] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 32)
        let got = fds.withUnsafeMutableBytes { raw in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(raw.count))
        }
        guard got > 0 else { return [] }
        var ports = Set<Int>()
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var si = socket_fdinfo()
            let sz = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, sz) == sz else { continue }
            guard si.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = si.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == Int32(TSI_S_LISTEN) else { continue }
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
            if port > 0 { ports.insert(port) }
        }
        return ports.sorted()
    }
}

/// Snapshot of all processes at one instant: tree, memory, CPU and ports.
public struct ProcSnapshot: Sendable {
    public var time: Date
    public var procs: [Int32: ProcSample]
    public var children: [Int32: [Int32]]
    public var groups: [Int32: [Int32]]
    /// Only the current user's processes.
    public var listening: [Int32: [Int]]
    public var paths: [Int32: String]
    public var cwds: [Int32: String]

    public static func take() -> ProcSnapshot {
        let uid = getuid()
        var procs: [Int32: ProcSample] = [:]
        var children: [Int32: [Int32]] = [:]
        var groups: [Int32: [Int32]] = [:]
        var listening: [Int32: [Int]] = [:]
        var paths: [Int32: String] = [:]
        var cwds: [Int32: String] = [:]
        for pid in ProcScanner.allPIDs() {
            guard let s = ProcScanner.sample(pid: pid) else { continue }
            procs[pid] = s
            children[s.ppid, default: []].append(pid)
            groups[s.pgid, default: []].append(pid)
            if s.uid == uid {
                let ports = ProcScanner.listeningTCPPorts(pid: pid)
                if !ports.isEmpty {
                    listening[pid] = ports
                    paths[pid] = ProcScanner.path(pid: pid)
                    cwds[pid] = ProcScanner.cwd(pid: pid)
                }
            }
        }
        return ProcSnapshot(time: Date(), procs: procs, children: children, groups: groups, listening: listening, paths: paths, cwds: cwds)
    }

    /// The process, its descendants and anything in the same process group.
    public func tree(of root: Int32) -> [Int32] {
        var out = Set<Int32>()
        var stack: [Int32] = [root]
        stack.append(contentsOf: groups[root] ?? [])
        while let p = stack.popLast() {
            guard !out.contains(p) else { continue }
            out.insert(p)
            stack.append(contentsOf: children[p] ?? [])
        }
        return out.filter { procs[$0] != nil }
    }

    public var allListeningPorts: Set<Int> {
        Set(listening.values.flatMap { $0 })
    }

    /// Only the descendants (ignoring the process group).
    public func descendants(of root: Int32) -> [Int32] {
        var out = Set<Int32>()
        var stack: [Int32] = [root]
        while let p = stack.popLast() {
            guard !out.contains(p) else { continue }
            out.insert(p)
            stack.append(contentsOf: children[p] ?? [])
        }
        return out.filter { procs[$0] != nil }
    }

    private static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "login", "tmux", "screen", "launchd", "-zsh", "-bash"]

    /// Walks up the tree while the parent runs in the same folder and isn't a shell
    /// (e.g. next-server → node → npm), to measure the whole service.
    public func serviceRoot(from pid: Int32, cwd: String) -> Int32 {
        var current = pid
        let me = getuid()
        while let s = procs[current], let parent = procs[s.ppid], parent.pid > 1, parent.uid == me,
              !Self.shells.contains(parent.name), ProcScanner.cwd(pid: parent.pid) == cwd {
            current = parent.pid
        }
        return current
    }
}
