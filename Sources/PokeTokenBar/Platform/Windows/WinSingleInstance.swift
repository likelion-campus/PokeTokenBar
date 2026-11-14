#if os(Windows)
import Foundation
import WinSDK

/// One running app per state folder. A named mutex held for the process's life decides; a second start posts
/// `showMessage` to the running sink (found by class and title = the mutex name) and leaves with exit code 3.
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

    static func acquire(name: String) -> Outcome {
        let handle = CreateMutexW(nil, false, WinStr.w(name))
        let error = GetLastError()
        guard let handle else {
            AppLog.write("single instance: CreateMutexW failed (\(error)); running anyway")
            return .acquired
        }
        if error == DWORD(ERROR_ALREADY_EXISTS) {
            _ = CloseHandle(handle)
            if let running = FindWindowW(WinStr.w(WinSinkWindow.className), WinStr.w(name)) {
                _ = PostMessageW(running, showMessage, 0, 0)
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
