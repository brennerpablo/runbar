import AppKit
import IOKit.ps
import IOKit.pwr_mgt
import Observation

/// Keeps the Mac awake while you're away and an agent or a service is still working, lid closed
/// included. Locked is not asleep: the display still turns off and locks, and everything keeps running.
///
/// Two things put a Mac to sleep, and each needs its own switch:
/// - Inactivity. A power assertion stops it, the same kind a browser holds while it plays audio
///   (`pmset -g assertions` lists them). macOS drops it when Runbar quits.
/// - Closing a laptop's lid. Only the kernel's `SleepDisabled` switch stops that (`LidSleep`), and
///   it also stops the sleep that low battery and overheating would bring. So while Runbar holds it,
///   Keep awake turns itself off at `batteryFloor` on battery or when the Mac gets critically hot,
///   and a watchdog turns the switch off if Runbar dies first.
@MainActor @Observable
final class KeepAwake {
    static let shared = KeepAwake()

    /// Where closing the lid stands while Keep awake is on.
    enum Lid: Equatable {
        /// No lid on this Mac, or Keep awake is off.
        case none
        /// Turning lid-close sleep off; the first time, waiting for the password.
        case asking
        /// Closing the lid doesn't put the Mac to sleep.
        case covered
        /// Closing the lid still does: no password, or the switch didn't take.
        case uncovered
    }

    /// On battery, at this charge or below, Keep awake turns itself off.
    static let batteryFloor = 15

    /// When it was turned on; nil while off.
    private(set) var since: Date?
    private(set) var lid: Lid = .none
    /// Why it turned itself off, until it's turned on again.
    private(set) var stopReason: String?
    var isOn: Bool { since != nil }

    @ObservationIgnored private var assertion: IOPMAssertionID?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lidWasClosed = false
    /// This session turned `SleepDisabled` on (not someone before it) and must turn it off.
    @ObservationIgnored private var ownsSwitch = false
    @ObservationIgnored private var switching = false
    @ObservationIgnored private var watchdog: pid_t?
    /// Every change to the switch, in order: off then on again can't land as on then off.
    @ObservationIgnored private let queue = DispatchQueue(label: "runbar.keep-awake")

    func toggle() { isOn ? turnOff() : turnOn() }

    #if DEBUG
    /// Demo shots only: shows coffee mode on, as if turned on at `since` with the lid covered, without
    /// holding an assertion or touching the sleep switch.
    func showForDemo(since: Date?) {
        self.since = since
        lid = since == nil ? .none : .covered
        stopReason = nil
    }
    #endif

    func turnOn() {
        guard !isOn else { return }
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Runbar: keep the Mac awake" as CFString,
            &id
        )
        guard result == kIOReturnSuccess else {
            NSLog("Runbar: couldn't keep the Mac awake (IOReturn \(result))")
            return
        }
        assertion = id
        since = Date()
        stopReason = nil
        lidWasClosed = LidSleep.lidClosed
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        coverLid()
    }

    func turnOff(reason: String? = nil) {
        guard isOn else { return }
        if let assertion { IOPMAssertionRelease(assertion) }
        assertion = nil
        since = nil
        lid = .none
        stopReason = reason
        timer?.invalidate()
        timer = nil
        guard ownsSwitch else { return }
        ownsSwitch = false
        let dog = watchdog
        watchdog = nil
        queue.async {
            if LidSleep.disableSleep(false) { LidSleep.owned = false }
            if let dog { LidSleep.stopWatchdog(dog) }
        }
    }

    /// Quitting: the switch goes back before the process ends.
    func shutdown() {
        guard ownsSwitch else { return }
        ownsSwitch = false
        if LidSleep.disableSleep(false) { LidSleep.owned = false }
        if let watchdog { LidSleep.stopWatchdog(watchdog) }
        watchdog = nil
    }

    /// At launch: a switch left on by a Runbar that didn't get to turn it off (a crash, a reboot that
    /// kept it) goes back off. Keep awake itself always starts off.
    func recover() {
        guard LidSleep.owned else { return }
        queue.async {
            if LidSleep.disableSleep(false) { LidSleep.owned = false }
        }
    }

    // MARK: - Lid

    private func coverLid() {
        guard LidSleep.hasLid else { return }
        // Someone else turned lid-close sleep off: it's covered, and theirs to turn back on.
        if LidSleep.sleepDisabled && !LidSleep.owned {
            lid = .covered
            return
        }
        lid = .asking
        // A request still waiting for the password will apply to this session.
        guard !switching else { return }
        switching = true
        queue.async {
            // Marked before the switch moves, so a crash in between still gets cleaned up at launch.
            LidSleep.owned = true
            var ok = LidSleep.grantInstalled || LidSleep.installGrant()
            ok = ok && LidSleep.disableSleep(true)
            if !ok { LidSleep.owned = LidSleep.sleepDisabled }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.lidSwitched(ok) }
            }
        }
    }

    private func lidSwitched(_ ok: Bool) {
        switching = false
        guard isOn else {
            // Turned off while the password dialog was up.
            if ok { queue.async { if LidSleep.disableSleep(false) { LidSleep.owned = false } } }
            return
        }
        guard ok else {
            lid = .uncovered
            return
        }
        ownsSwitch = true
        watchdog = LidSleep.startWatchdog()
        lid = .covered
    }

    // MARK: - Every 5 s while on

    private func check() {
        if let charge = Self.chargeOnBattery(), charge <= Self.batteryFloor {
            stop(because: "battery at \(charge)%")
            return
        }
        if ProcessInfo.processInfo.thermalState == .critical {
            stop(because: "the Mac got too hot")
            return
        }
        guard lid == .covered else { return }
        if !LidSleep.sleepDisabled {
            // Someone turned lid-close sleep back on (`pmset -a disablesleep 0`).
            lid = .uncovered
            return
        }
        let closed = LidSleep.lidClosed
        if closed && !lidWasClosed && !Self.externalScreen {
            // A closed lid on an awake Mac can leave the panel lit underneath: turn it off. With an
            // external screen it's the usual clamshell setup, and that screen stays on.
            queue.async { LidSleep.sleepDisplay() }
        }
        lidWasClosed = closed
    }

    private static var externalScreen: Bool {
        NSScreen.screens.contains { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
            return CGDisplayIsBuiltin(id) == 0
        }
    }

    private func stop(because reason: String) {
        turnOff(reason: reason)
        AppModel.shared.notify(title: "Runbar let the Mac sleep again", body: "Coffee mode turned itself off: \(reason).")
    }

    /// Battery charge in percent while running on battery; nil on power or without a battery.
    private static func chargeOnBattery() -> Int? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? == kIOPMBatteryPowerKey,
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let current = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return current * 100 / max
        }
        return nil
    }
}
