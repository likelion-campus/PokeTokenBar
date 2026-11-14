#if os(Windows)
import Foundation
import WinSDK

/// Selftest group for launch at login and the update check (Task 10). The login checks write the REAL Run key (the
/// throwaway runner profile's), but only under a scratch value name and only when `CI` is set; every path removes
/// the scratch value again, also on failure.
extension WindowsSelftest {
    @MainActor static func shellChecks(_ r: Recorder) async {
        loginFirstRunCheck(r)
        loginRealKeyCheck(r)
        loginFailureCheck(r)
        await updateChecks(r)
    }

    /// The app has been running for the whole selftest and nothing but the tray toggle writes the Run value.
    @MainActor private static func loginFirstRunCheck(_ r: Recorder) {
        guard runsOnCI else {
            r.add("login.firstRunOff", true, "skipped (CI not set): a person's PC may have launch at login on")
            return
        }
        let real = WindowsLoginItem()
        let names = WinRegistry.valueNames(WindowsLoginItem.defaultRunKey)
        r.add("login.firstRunOff", real.state == .off && !names.contains(WindowsLoginItem.defaultValueName),
              "state=\(real.state) run_values=\(names.count) has_PokeTokenBar=\(names.contains(WindowsLoginItem.defaultValueName)) command=\(real.command)")
    }

    @MainActor private static func loginRealKeyCheck(_ r: Recorder) {
        guard runsOnCI else {
            r.add("login.realKey", true, "skipped (CI not set)")
            return
        }
        let name = "PokeTokenBar-selftest-\(UUID().uuidString.prefix(8))"
        let runKey = WindowsLoginItem.defaultRunKey
        defer { _ = WinRegistry.deleteValue(runKey, name); _ = WinRegistry.deleteValue(WindowsLoginItem.defaultApprovedKey, name) }
        let item = WindowsLoginItem(valueName: name)
        let exe = WindowsLoginItem.currentExecutablePath()
        let exeName = exe.split(separator: "\\").last.map(String.init) ?? exe
        let packaged = WindowsInstall.isPackagedLayout
        let enabled = item.setEnabled(true)
        let afterEnable = item.state
        var stored = ""
        if case .value(let v) = WinRegistry.string(runKey, name) { stored = v }
        // The folder moved: the same value name now points at another exe. Reads as off; nothing repaired it.
        let moved = WindowsLoginItem(valueName: name, command: WindowsLoginItem.command(forExecutable: #"C:\somewhere\else\PokeTokenBar.exe"#))
        let movedState = moved.state
        var storedAfterMovedRead = ""
        if case .value(let v) = WinRegistry.string(runKey, name) { storedAfterMovedRead = v }
        let disabled = item.setEnabled(false)
        var gone = false
        if case .missing = WinRegistry.string(runKey, name) { gone = true }
        let namesAfter = WinRegistry.valueNames(runKey)
        let quoted = stored == "\"\(exe)\" --autostart"
        let ok = enabled && afterEnable == .on && quoted && movedState == .off && storedAfterMovedRead == stored
            && disabled && gone && item.state == .off && !namesAfter.contains(name) && (!packaged || exeName == WindowsInstall.shippedExecutableName)
        r.add("login.realKey", ok,
              "scratch value \(name) on the real Run key: enable=\(enabled) state=\(afterEnable) stored=\(stored) quoted=\(quoted) "
                + "moved_reads=\(movedState) repaired=\(storedAfterMovedRead != stored) disable=\(disabled) gone=\(gone) "
                + "exe=\(exeName) packaged=\(packaged)")
    }

    /// A write that cannot happen is reported as failed and never shows "on" (the key path is over the 255-character limit).
    @MainActor private static func loginFailureCheck(_ r: Recorder) {
        let item = WindowsLoginItem(runKey: "Software\\PokeTokenBarTests\\" + String(repeating: "x", count: 300),
                                    approvedKey: "Software\\PokeTokenBarTests\\unused", valueName: "PokeTokenBar-selftest-fail")
        let wrote = item.setEnabled(true)
        let state = item.state
        r.add("login.writeFailure", !wrote && state != .on, "setEnabled(true) on an unwritable key returned \(wrote), state=\(state)")
    }

    private final class RecordingShell: PlatformShellService {
        var opened: [URL] = []
        var terminations = 0
        func open(_ url: URL) { opened.append(url) }
        func terminate() { terminations += 1 }
    }

    /// The Windows wiring of the shared checker with canned data: a Mac-only release is no update, a release with
    /// the installer is, and applying it with no brew opens the release page through the shell. No network.
    @MainActor private static func updateChecks(_ r: Recorder) async {
        let page = "https://github.com/likelion-campus/PokeTokenBar/releases/tag/v99.0.0"
        func release(_ assets: [String]) -> Data {
            Data("{\"tag_name\":\"v99.0.0\",\"html_url\":\"\(page)\",\"assets\":[\(assets.map { "{\"name\":\"\($0)\"}" }.joined(separator: ","))]}".utf8)
        }
        let suite = "ptb.selftest.update.\(UUID().uuidString.prefix(8))"
        guard let defaults = UserDefaults(suiteName: suite) else {
            r.add("update.feed", false, "no scratch defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let macData = release(["PokeTokenBar-99.0.0.zip"]), winData = release(["PokeTokenBar-Setup-99.0.0-win-x64.exe"])
        let mac = UpdateChecker(currentVersion: "2.5.3", defaults: defaults) { InstallerReleaseFeed.parse(macData) }
        await mac.check()
        let shell = RecordingShell()
        let previous = PlatformShell.current
        PlatformShell.current = shell
        defer { PlatformShell.current = previous }
        let win = UpdateChecker(currentVersion: "2.5.3", defaults: defaults, fetchLatest: { InstallerReleaseFeed.parse(winData) },
                                brewLocator: { nil })
        await win.check()
        win.applyUpdate()
        _ = await waitUntil(timeout: 5) { !shell.opened.isEmpty }
        let wired = WindowsUpdates.checker != nil
        r.add("update.feed", mac.available == nil && win.available?.version == "99.0.0" && shell.opened.map(\.absoluteString) == [page]
              && shell.terminations == 0 && !win.isUpdating && wired,
              "mac_only_release_offered=\(mac.available != nil) installer_release=\(win.available?.version ?? "none") "
                + "opened=\(shell.opened.map(\.absoluteString)) terminations=\(shell.terminations) live_checker_wired=\(wired) "
                + "installed_version=\(WindowsInstall.version ?? "unknown")")
    }
}
#endif
