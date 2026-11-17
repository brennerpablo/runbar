import AppKit
import Observation
import RunbarCore
import SwiftUI

/// The menu bar icon and the panel it opens.
///
/// The panel is ours, not MenuBarExtra's: the system window brought its own glass and, after
/// closing and reopening, came back without rounded corners and detached from the menu bar. Here the
/// view draws the shape and background, and the position is recomputed from the icon on every open.
@MainActor
final class StatusBarController: NSObject {
    static let shared = StatusBarController()

    private var item: NSStatusItem?
    let panel = PanelController()

    func install() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
        self.item = item
        panel.statusButton = item.button
        observe()
    }

    @objc private func clicked() { panel.toggle() }

    /// Redraws the icon and count whenever anything they show changes.
    private func observe() {
        withObservationTracking { render() } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.observe() } }
        }
    }

    private func render() {
        let model = AppModel.shared
        let badge: MenuBarIcon.Badge = model.alertCount > 0 ? .alert : (model.isBusy ? .busy : .none)
        let count = model.runningCount
        guard let button = item?.button else { return }
        button.image = MenuBarIcon.image(badge)
        button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        button.title = count > 0 ? "\(count)" : ""
        button.imagePosition = count > 0 ? .imageLeading : .imageOnly
        button.setAccessibilityLabel(count == 1 ? "Runbar, 1 service running" : "Runbar, \(count) services running")
    }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    /// Gap between the menu bar and the top of the panel.
    static let gap: CGFloat = 6

    weak var statusButton: NSStatusBarButton?
    private(set) var panel: RunbarPanel?
    private var outsideClick: Any?

    var isOpen: Bool { panel?.isVisible == true }

    /// App that was frontmost when the panel opened, to give focus back when closing with Esc or the icon.
    private var previousApp: NSRunningApplication?
    private var resignActive: NSObjectProtocol?

    /// Uptime when a click on the icon closed the panel before the icon's action arrived (see `dismiss`).
    private var closedByIconClick: TimeInterval?

    func toggle() {
        if isOpen { return close(restoreFocus: true) }
        // The panel already closed on this click: leave it closed.
        if let closed = closedByIconClick, ProcessInfo.processInfo.systemUptime - closed < 1 {
            closedByIconClick = nil
            return
        }
        open()
    }

    func open() {
        closedByIconClick = nil
        let panel = self.panel ?? makePanel()
        self.panel = panel
        DiskModel.shared.refreshFreeSpace()
        place(panel)
        // With the app active, no other app takes focus from the panel while it is open.
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        if resignActive == nil {
            resignActive = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            }
        }
        // The button unhighlights itself on mouse up; highlight it again once the click is done.
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isOpen else { return }
                self.statusButton?.highlight(true)
                self.panel?.invalidateShadow()
            }
        }
        if outsideClick == nil {
            outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            }
        }
    }

    /// Closes because a click or focus went elsewhere. On recent macOS the menu bar is drawn by another
    /// process, so a click on the icon counts as elsewhere too and closes the panel before the icon's
    /// action arrives; that action must then leave the panel closed instead of opening it again.
    private func dismiss() {
        if isOpen, let icon = statusButton?.window?.frame, icon.contains(NSEvent.mouseLocation) {
            closedByIconClick = ProcessInfo.processInfo.systemUptime
        }
        close()
    }

    /// `restoreFocus`: closed with Esc or the icon, so focus goes back to the previous app. On a click
    /// in another app, that click decides where focus goes.
    func close(restoreFocus: Bool = false) {
        if let outsideClick { NSEvent.removeMonitor(outsideClick) }
        outsideClick = nil
        if let resignActive { NotificationCenter.default.removeObserver(resignActive) }
        resignActive = nil
        statusButton?.highlight(false)
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        let previous = previousApp
        previousApp = nil
        // An open agent window keeps focus in Runbar.
        let ownWindowOpen = NSApp.windows.contains { $0.isVisible && $0.level == .normal && $0 !== panel }
        guard restoreFocus, NSApp.isActive, !ownWindowOpen else { return }
        if let previous, !previous.isTerminated {
            NSApp.yieldActivation(to: previous)
            previous.activate()
        } else {
            NSApp.hide(nil)
        }
    }

    /// With Runbar active, losing focus means the agent window opened or the app left the front: close.
    /// With Runbar inactive, another app took focus back without a user click; the panel stays open.
    func windowDidResignKey(_ notification: Notification) {
        if NSApp.isActive { dismiss() }
    }

    private func makePanel() -> RunbarPanel {
        let panel = RunbarPanel(
            contentRect: NSRect(x: 0, y: 0, width: Layout.width, height: 400),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.delegate = self
        let root = PopoverView()
            .environment(AppModel.shared)
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self] size in
                MainActor.assumeIsolated { self?.resize(to: size) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        let host = NSHostingView(rootView: root)
        // We apply the size ourselves (with the top pinned); the hosting view doesn't resize the window.
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }

    /// Below the icon, aligned to its left edge, kept on screen.
    private func place(_ panel: RunbarPanel) {
        guard let itemWindow = statusButton?.window else { return }
        let item = itemWindow.frame
        let visible = (itemWindow.screen ?? NSScreen.main)?.visibleFrame ?? item
        var frame = panel.frame
        frame.origin.x = min(max(item.minX, visible.minX + 8), visible.maxX - frame.width - 8)
        panel.pinnedTop = item.minY - Self.gap
        panel.maxHeight = max(200, item.minY - Self.gap - visible.minY - 8)
        panel.setFrame(frame, display: false)
    }

    /// The content changed height: the window follows and the top stays put.
    func resize(to size: CGSize) {
        guard let panel, size.width > 0, size.height > 0 else { return }
        let target = CGSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
        guard abs(panel.frame.width - target.width) > 0.5 || abs(panel.frame.height - target.height) > 0.5 else { return }
        panel.setFrame(NSRect(origin: panel.frame.origin, size: target), display: true)
        panel.invalidateShadow()
    }
}

/// Borderless panel: the background, corners and border come from the view (`rbPanel`).
final class RunbarPanel: NSPanel {
    /// Fixed top on screen; every size change grows or shrinks downward.
    var pinnedTop: CGFloat?
    var maxHeight: CGFloat = .greatestFiniteMagnitude

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var frame = frameRect
        frame.size.height = min(frame.height, maxHeight)
        if let pinnedTop { frame.origin.y = pinnedTop - frame.height }
        super.setFrame(frame, display: flag)
    }

    override func cancelOperation(_ sender: Any?) {
        (delegate as? PanelController)?.close(restoreFocus: true)
    }
}
