import AppKit
import Foundation

/// The observers `UsageStore.init` used to register inline, moved here unchanged: queue `.main`, tokens not retained
/// (the observers live for the process, as before). The day change comes from the default center, the rest from
/// the workspace center.
@MainActor struct MacSystemEvents: SystemEvents {
    var center: NotificationCenter = .default
    var workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter

    func onDayChange(_ f: @escaping @Sendable () -> Void) {
        center.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { _ in f() }
    }

    func onWake(_ f: @escaping @Sendable () -> Void) {
        workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in f() }
    }

    func onScreensSleep(_ f: @escaping @Sendable () -> Void) {
        workspaceCenter.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in f() }
    }

    func onScreensWake(_ f: @escaping @Sendable () -> Void) {
        workspaceCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in f() }
    }

    var displaysAreAsleep: Bool { CGDisplayIsAsleep(CGMainDisplayID()) != 0 }
}
