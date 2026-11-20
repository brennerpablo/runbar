import Foundation
import IOKit
import RunbarCore

/// The one thing that keeps a laptop awake with its lid closed: the kernel's `SleepDisabled` switch.
///
/// No power assertion covers the lid. On lid close the kernel asks `checkSystemSleepAllowed`
/// (xnu, IOPMrootDomain.cpp), and the only user-space veto there is `SleepDisabled`, which
/// `pmset -a disablesleep 1` sets. That veto also blocks sleeping for low battery and for
/// overheating, so whoever turns it on has to watch both and turn it off again (`KeepAwake`).
///
/// Only root can set it. Runbar asks for the password once to install a sudoers rule that allows
/// exactly `pmset -a disablesleep 1` and `0` for this user, and runs them with `sudo -n` afterwards.
/// Everything here blocks, so it runs off the main thread, except the reads.
enum LidSleep {
    static let grantPath = "/etc/sudoers.d/runbar"
    private static let pmset = "/usr/bin/pmset"
    private static let ownedKey = "keepAwakeTurnedOffSleep"

    /// Laptops report their clamshell; a Mac mini or a Mac Studio doesn't.
    static let hasLid: Bool = rootDomain("AppleClamshellState") != nil

    static var lidClosed: Bool { rootDomain("AppleClamshellState") as? Bool ?? false }

    /// `SleepDisabled` is on, whoever turned it on.
    static var sleepDisabled: Bool { rootDomain("SleepDisabled") as? Bool ?? false }

    /// Runbar turned the switch on and hasn't turned it off yet. Kept on disk: the switch can outlive
    /// a crash, so the next launch turns it off.
    static var owned: Bool {
        get { UserDefaults.standard.bool(forKey: ownedKey) }
        set { UserDefaults.standard.set(newValue, forKey: ownedKey) }
    }

    static var grantInstalled: Bool { FileManager.default.fileExists(atPath: grantPath) }

    /// Turns lid-close sleep off (true) or back on, through the sudoers rule, never asking for a
    /// password. False without the rule.
    @discardableResult
    static func disableSleep(_ on: Bool) -> Bool {
        guard run("/usr/bin/sudo", ["-n", pmset, "-a", "disablesleep", on ? "1" : "0"]) == 0 else { return false }
        // pmset hands the setting to powerd; wait briefly for the kernel to show it.
        for _ in 0..<10 {
            if sleepDisabled == on { return true }
            usleep(100_000)
        }
        return sleepDisabled == on
    }

    /// Asks for an administrator's password (the system dialog) and installs the sudoers rule.
    /// False if the person cancels or anything fails.
    static func installGrant() -> Bool {
        let user = NSUserName()
        guard user.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil else { return false }
        return run("/usr/bin/osascript", ["-e", grantAppleScript(user: user)]) == 0 && grantInstalled
    }

    static func grantAppleScript(user: String) -> String {
        let prompt = "Runbar wants to keep the Mac awake with the lid closed. It asks for your password once."
        return "do shell script \"\(appleScriptEscaped(grantScript(user: user)))\" with prompt \"\(appleScriptEscaped(prompt))\" with administrator privileges"
    }

    /// The root shell script that writes the rule. It writes to a dotted temp name first (sudo skips
    /// files with a dot in `sudoers.d`), checks it with visudo, and only then moves it into place.
    static func grantScript(user: String, directory: String = "/etc/sudoers.d") -> String {
        let lines = [
            "# Runbar Keep awake: turns lid-close sleep off and on again without a password.",
            "# Delete this file to take that back.",
            "\(user) ALL=(root) NOPASSWD: \(pmset) -a disablesleep 1, \(pmset) -a disablesleep 0",
        ]
        return [
            "set -e",
            "/bin/mkdir -p \(directory)",
            "t=$(/usr/bin/mktemp \(directory)/.runbar.XXXXXX)",
            "trap '/bin/rm -f \"$t\"' EXIT",
            "/usr/bin/printf '%s\\n' \(lines.map { "'\($0)'" }.joined(separator: " ")) > \"$t\"",
            "/bin/chmod 0440 \"$t\"",
            "/usr/sbin/visudo -cf \"$t\" >/dev/null",
            "/bin/mv -f \"$t\" \(directory)/runbar",
        ].joined(separator: "; ")
    }

    /// A process that outlives Runbar and turns the switch off once Runbar's process is gone, for a
    /// crash, a force quit or a `kill`. Stopped with `stopWatchdog` when Runbar turns it off itself.
    static func startWatchdog() -> pid_t? {
        let script = "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 2; done; exec /usr/bin/sudo -n \(pmset) -a disablesleep 0"
        return try? Spawner.detached(["/bin/sh", "-c", script, "runbar-keep-awake", "\(getpid())"])
    }

    static func stopWatchdog(_ pid: pid_t) {
        Spawner.signalGroup(pid, SIGTERM)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
    }

    /// The display goes dark (and locks, with the usual setting) as if the lid had put it to sleep.
    static func sleepDisplay() {
        run(pmset, ["displaysleepnow"])
    }

    // MARK: - Helpers

    private static func rootDomain(_ key: String) -> Any? {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        return IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func appleScriptEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
