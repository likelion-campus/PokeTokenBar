#if os(Windows)
import Foundation

/// The tray menu's launch-at-login entry and update entry (Task 10). The state is read when the menu opens, so a
/// change made in Task Manager's Startup tab shows the next time; nothing here runs on a timer.
extension WinTrayHost {
    func refreshShellState() {
        loginState = loginItem.state
        availableUpdate = WindowsUpdates.available
        WindowsUpdates.menuOpened()
    }

    /// Checked -> off, anything else -> on. The registry is read back: a write that failed leaves the menu
    /// showing what is really there (and `WindowsLoginItem` has logged why), never a plausible "on".
    func toggleLaunchAtLogin() {
        let turnOn = loginItem.state != .on
        let done = loginItem.setEnabled(turnOn)
        loginState = loginItem.state
        AppLog.write("launch at login: \(turnOn ? "enable" : "disable") \(done ? "done" : "failed"), now \(loginState)")
    }
}
#endif
