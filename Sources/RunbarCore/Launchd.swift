import Darwin
import Foundation

/// A job launchd runs for this user (a LaunchAgent, `brew services`): what restarts a process that
/// "won't die", and what Runbar can take over.
public struct LaunchdJob: Sendable, Equatable {
    public var label: String
    public var pid: Int32
    public var plistPath: String?
    /// launchd starts it again whenever it exits (KeepAlive true, or a KeepAlive dictionary).
    public var keepAlive: Bool
    /// launchd starts it at login.
    public var runAtLoad: Bool
    public var programArguments: [String]
    public var workingDirectory: String?
    public var environment: [String: String]

    public init(label: String, pid: Int32, plistPath: String? = nil, keepAlive: Bool = false, runAtLoad: Bool = false,
                programArguments: [String] = [], workingDirectory: String? = nil, environment: [String: String] = [:]) {
        self.label = label
        self.pid = pid
        self.plistPath = plistPath
        self.keepAlive = keepAlive
        self.runAtLoad = runAtLoad
        self.programArguments = programArguments
        self.workingDirectory = workingDirectory
        self.environment = environment
    }

    /// The plist lives in ~/Library/LaunchAgents, so Runbar can move it without a password.
    public var isUserAgent: Bool {
        plistPath?.hasPrefix(Paths.home + "/Library/LaunchAgents/") == true
    }

    /// The job's command line, quoted for a shell.
    public var command: String {
        programArguments.map(Shell.quote).joined(separator: " ")
    }

    /// The command line with the port it listens on written as `{port}`, the way config.json wants it:
    /// `--port 5433`, `--port=5433`, `-p 5433`, `5433:5432` (kubectl), `5433:host:5432` (ssh -L).
    public func command(port: Int) -> String {
        let p = String(port)
        var words = programArguments
        for i in words.indices {
            let w = words[i]
            if w == p, i > 0, ["--port", "-p", "--listen-port", "-port", "-P"].contains(words[i - 1]) {
                words[i] = "{port}"
            } else if w.hasSuffix("=" + p), w.hasPrefix("-") {
                words[i] = String(w.dropLast(p.count)) + "{port}"
            } else if w.hasPrefix(p + ":") {
                words[i] = "{port}" + w.dropFirst(p.count)
            }
        }
        return words.map(Shell.quote).joined(separator: " ")
    }
}

public enum Shell {
    /// Leaves plain words alone (a `{port}` included) and single-quotes the rest.
    public static func quote(_ word: String) -> String {
        let plain = word.range(of: #"^[A-Za-z0-9_@%+=:,./{}-]+$"#, options: .regularExpression) != nil
        if plain { return word }
        return "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

public enum Launchd {
    public struct Failure: Error, CustomStringConvertible {
        public var description: String
    }

    static var domain: String { "gui/\(getuid())" }

    /// Where Runbar keeps the plists of the jobs it took over. Moving one back to ~/Library/LaunchAgents undoes it.
    public static var retiredDir: URL { Paths.configDir.appendingPathComponent("launchd", isDirectory: true) }

    /// This user's running jobs, by PID (`launchctl list`).
    public static func runningJobs() -> [Int32: String] {
        let (status, output) = run(["list"])
        guard status == 0 else { return [:] }
        var out: [Int32: String] = [:]
        for line in output.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: "\t", maxSplits: 2)
            guard parts.count == 3, let pid = Int32(parts[0]) else { continue }
            out[pid] = String(parts[2])
        }
        return out
    }

    /// The job behind `label`, with what its plist says.
    public static func job(label: String, pid: Int32) -> LaunchdJob {
        var job = LaunchdJob(label: label, pid: pid, plistPath: plistPath(for: label))
        guard let path = job.plistPath,
              let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return job }
        switch plist["KeepAlive"] {
        case let flag as Bool: job.keepAlive = flag
        case is [String: Any]: job.keepAlive = true
        default: break
        }
        job.runAtLoad = plist["RunAtLoad"] as? Bool ?? false
        if let args = plist["ProgramArguments"] as? [String], !args.isEmpty {
            job.programArguments = args
        } else if let program = plist["Program"] as? String {
            job.programArguments = [program]
        }
        job.workingDirectory = plist["WorkingDirectory"] as? String
        job.environment = plist["EnvironmentVariables"] as? [String: String] ?? [:]
        return job
    }

    static func plistPath(for label: String) -> String? {
        let agent = Paths.home + "/Library/LaunchAgents/\(label).plist"
        if FileManager.default.fileExists(atPath: agent) { return agent }
        let (status, output) = run(["print", "\(domain)/\(label)"])
        guard status == 0 else { return nil }
        for line in output.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("path = ") { return String(t.dropFirst(7)) }
        }
        return nil
    }

    /// Stops the job and keeps launchd from starting it again, at login included. Undo with
    /// `launchctl enable gui/<uid>/<label>`.
    public static func turnOff(_ label: String) throws {
        let (status, output) = run(["bootout", "\(domain)/\(label)"])
        // 3: "No such process", 113: "Could not find service": already unloaded.
        if status != 0, status != 3, status != 113 {
            throw Failure(description: "launchctl bootout \(label) failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        _ = run(["disable", "\(domain)/\(label)"])
    }

    /// Stops the job and moves its plist to `retiredDir`, so it doesn't load at the next login either.
    /// Returns where the plist went.
    @discardableResult
    public static func retire(_ job: LaunchdJob) throws -> String? {
        let (status, output) = run(["bootout", "\(domain)/\(job.label)"])
        if status != 0, status != 3, status != 113 {
            throw Failure(description: "launchctl bootout \(job.label) failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        guard let path = job.plistPath, job.isUserAgent else {
            _ = run(["disable", "\(domain)/\(job.label)"])
            return nil
        }
        let fm = FileManager.default
        try fm.createDirectory(at: retiredDir, withIntermediateDirectories: true)
        var target = retiredDir.appendingPathComponent((path as NSString).lastPathComponent)
        if fm.fileExists(atPath: target.path) {
            target = retiredDir.appendingPathComponent("\(job.label)-\(Int(Date().timeIntervalSince1970)).plist")
        }
        try fm.moveItem(atPath: path, toPath: target.path)
        return target.path
    }

    @discardableResult
    static func run(_ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
        } catch {
            return (-1, "\(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
