import Darwin
import Foundation

public struct SpawnError: Error, CustomStringConvertible {
    public var code: Int32
    public var description: String { String(cString: strerror(code)) }
}

public enum Spawner {
    /// Starts `command` in a login shell, as leader of a new process group,
    /// with stdout and stderr appended to the log file. The process outlives Runbar.
    public static func spawn(shell: String, command: String, cwd: String, environment: [String: String], logPath: String) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, 1, logPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&fileActions, 1, 2)
        posix_spawn_file_actions_addchdir_np(&fileActions, cwd)

        return try spawnInNewGroup([shell, "-l", "-c", command], environment: environment, fileActions: &fileActions)
    }

    /// Starts `argv` (an absolute path first) as leader of a new process group, with no input or
    /// output, so it outlives Runbar.
    public static func detached(_ argv: [String]) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        for fd: Int32 in [0, 1, 2] {
            posix_spawn_file_actions_addopen(&fileActions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0)
        }
        return try spawnInNewGroup(argv, environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], fileActions: &fileActions)
    }

    private static func spawnInNewGroup(_ args: [String], environment: [String: String], fileActions: inout posix_spawn_file_actions_t?) throws -> pid_t {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
        posix_spawnattr_setflags(&attr, Int16(flags))
        posix_spawnattr_setpgroup(&attr, 0)
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attr, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attr, &mask)

        let argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, args[0], &fileActions, &attr, argv, envp)
        guard rc == 0 else { throw SpawnError(code: rc) }
        return pid
    }

    /// Signals the whole group (the service and its children).
    public static func signalGroup(_ pgid: pid_t, _ sig: Int32) {
        guard pgid > 1 else { return }
        kill(-pgid, sig)
    }

    /// Decodes a waitpid status into an exit code (128+signal when killed by a signal).
    public static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        if status & 0x7F == 0 { return (status >> 8) & 0xFF }
        return 128 + (status & 0x7F)
    }

    /// Reads a KEY=value file (accepts `export`, comments and quotes).
    public static func parseEnvFile(_ path: String) -> [String: String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let f = value.first, let l = value.last, (f == "\"" && l == "\"") || (f == "'" && l == "'") {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty { out[key] = value }
        }
        return out
    }
}
