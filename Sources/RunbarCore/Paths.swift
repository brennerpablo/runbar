import Foundation

public enum RunbarInfo {
    public static let bundleID = "dev.runbar.Runbar"
    public static let version = "0.1.0"
}

public enum Paths {
    public static var home: String { NSHomeDirectory() }

    public static func expand(_ path: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst()) }
        return path
    }

    public static func abbreviate(_ path: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + String(path.dropFirst(home.count)) }
        return path
    }

    /// `~/.config/runbar` (or `RUNBAR_CONFIG_DIR`, useful for tests).
    public static var configDir: URL {
        if let custom = ProcessInfo.processInfo.environment["RUNBAR_CONFIG_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: expand(custom), isDirectory: true)
        }
        return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".config/runbar", isDirectory: true)
    }

    public static var configFile: URL { configDir.appendingPathComponent("config.json") }
    public static var schemaFile: URL { configDir.appendingPathComponent("schema.json") }
    public static var readmeFile: URL { configDir.appendingPathComponent("README.md") }

    /// `RUNBAR_STATE_DIR` moves the socket, state and logs elsewhere, so a second copy (a test build) can
    /// run next to the installed app without seeing it.
    private static var stateDir: URL? {
        guard let custom = ProcessInfo.processInfo.environment["RUNBAR_STATE_DIR"], !custom.isEmpty else { return nil }
        return URL(fileURLWithPath: expand(custom), isDirectory: true)
    }

    public static var supportDir: URL {
        if let stateDir { return stateDir.appendingPathComponent("support", isDirectory: true) }
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Runbar", isDirectory: true)
    }

    public static var socketPath: String { supportDir.appendingPathComponent("control.sock").path }
    public static var stateFile: URL { supportDir.appendingPathComponent("state.json") }

    public static var logsDir: URL {
        if let stateDir { return stateDir.appendingPathComponent("logs", isDirectory: true) }
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Logs/Runbar", isDirectory: true)
    }

    public static func logFile(for id: String) -> URL {
        logsDir.appendingPathComponent("\(id).log")
    }
}

public enum ConfigBootstrap {
    public static let starterConfig = """
    {
      "$schema": "./schema.json",
      "version": 1,
      "projects": {}
    }

    """

    /// Creates the folders, keeps schema.json and README.md up to date, and creates an empty config.json if missing.
    public static func ensureFiles() {
        let fm = FileManager.default
        for dir in [Paths.configDir, Paths.supportDir, Paths.logsDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        writeIfChanged(BundledDocs.schema, to: Paths.schemaFile)
        writeIfChanged(BundledDocs.readme, to: Paths.readmeFile)
        if !fm.fileExists(atPath: Paths.configFile.path) {
            try? starterConfig.write(to: Paths.configFile, atomically: true, encoding: .utf8)
        }
    }

    static func writeIfChanged(_ text: String, to url: URL) {
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == text { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
