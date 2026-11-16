#if os(Windows)
import Foundation
import WinSDK

/// One running app per state folder. A named mutex held for the process's life decides; a second start posts
/// `showMessage` to the running sink (found by class and title = the mutex name), which opens the popover there, and
/// leaves with exit code 3.
/// The installer closes the default instance through the same name (`AppMutex=Local\PokeTokenBar-Team`).
enum WinSingleInstance {
    enum Outcome: Equatable { case acquired, yielded }

    /// `WM_APP + 1`, posted to the running instance's sink by a second start.
    static let showMessage = UINT(WM_APP) + 1
    nonisolated(unsafe) private static var held: HANDLE?

    /// `Local\PokeTokenBar-Team` for the default state folder; otherwise with the same path hash as the team
    /// settings suite of that folder (`TeamSettings.suiteName`), so two QA instances with their own
    /// `PTB_STATE_DIR` can run side by side, as on the Mac.
    @MainActor static func mutexName(stateDirectory: URL, defaultDirectory: URL) -> String {
        let base = "Local\\PokeTokenBar-Team"
        guard let suite = TeamSettings.suiteName(for: stateDirectory, defaultDirectory: defaultDirectory) else { return base }
        return base + "-" + String(suite.dropFirst("ptb.team.".count))
    }

    /// `quietly`: an `--autostart` copy (the Run key at sign-in) that finds the app already running yields without asking it
    /// for anything — the user did not ask for the popover (post-merge review M3).
    static func acquire(name: String, quietly: Bool = false) -> Outcome {
        let handle = CreateMutexW(nil, false, WinStr.w(name))
        let error = GetLastError()
        guard let handle else {
            AppLog.write("single instance: CreateMutexW failed (\(error)); running anyway")
            return .acquired
        }
        if error == DWORD(ERROR_ALREADY_EXISTS) {
            _ = CloseHandle(handle)
            if quietly {
                AppLog.write("single instance: an --autostart start yields quietly to the instance already running (\(name))")
            } else if let running = FindWindowW(WinStr.w(WinSinkWindow.className), WinStr.w(name)) {
                // Stage 7 D4: a start from the Start menu or a shortcut may take the foreground; this process hands that
                // right to the running instance, which opens its popover for this launch (ruling 3) instead of a balloon.
                var pid: DWORD = 0
                _ = GetWindowThreadProcessId(running, &pid)
                let allowed = pid != 0 && AllowSetForegroundWindow(pid)
                let allowError = allowed ? 0 : GetLastError()
                _ = PostMessageW(running, showMessage, 0, 0)
                AppLog.write("single instance: asked pid \(pid) to open its popover; AllowSetForegroundWindow "
                    + (allowed ? "ok" : "refused (\(allowError))"))
            } else {
                AppLog.write("single instance: \(name) is held but no sink window answers")
            }
            return .yielded
        }
        held = handle
        return .acquired
    }
}
#endif
