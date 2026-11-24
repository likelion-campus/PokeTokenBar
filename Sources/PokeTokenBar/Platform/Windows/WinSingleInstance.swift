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
        "Local\\PokeTokenBar-Team" + stateSuffix(stateDirectory: stateDirectory, defaultDirectory: defaultDirectory)
    }

    /// Empty for the default state folder, `-<path hash>` for another: what tells instances apart in the mutex name and in the crash
    /// marker and crash log names (`WindowsCrashLog`).
    @MainActor static func stateSuffix(stateDirectory: URL, defaultDirectory: URL) -> String {
        guard let suite = TeamSettings.suiteName(for: stateDirectory, defaultDirectory: defaultDirectory) else { return "" }
        return "-" + String(suite.dropFirst("ptb.team.".count))
    }

    /// `quietly`: an `--autostart` copy (the Run key at sign-in) that finds the app already running yields without asking it
    /// for anything — the user did not ask for the popover (post-merge review M3).
    /// `onForeignHolder`: called when the name is held by something that is not this app (no sink window answers, or the window's
    /// process runs another executable); nothing is posted to it and no foreground right is given. The app tells the user there.
    static func acquire(name: String, quietly: Bool = false, onForeignHolder: ((String) -> Void)? = nil) -> Outcome {
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
            } else if let running = findSink(name) {
                // Stage 7 D4: a start from the Start menu or a shortcut may take the foreground; this process hands that
                // right to the running instance, which opens its popover for this launch (ruling 3) instead of a balloon.
                var pid: DWORD = 0
                _ = GetWindowThreadProcessId(running, &pid)
                if let image = imagePath(ofProcess: pid), sameExecutable(image, ownImagePath()) {
                    let allowed = AllowSetForegroundWindow(pid)
                    let allowError = allowed ? 0 : GetLastError()
                    _ = PostMessageW(running, showMessage, 0, 0)
                    AppLog.write("single instance: asked pid \(pid) to open its popover; AllowSetForegroundWindow "
                        + (allowed ? "ok" : "refused (\(allowError))"))
                } else {
                    // Any program of this user can create a window with this class and title. It gets neither a message nor the foreground.
                    AppLog.write("single instance: \(name) is answered by pid \(pid), which does not run this executable (\(imagePath(ofProcess: pid) ?? "image unreadable")); not asked")
                    onForeignHolder?("another program (process \(pid))")
                }
            } else {
                AppLog.write("single instance: \(name) is held but no sink window answers")
                onForeignHolder?("something that does not answer")
            }
            return .yielded
        }
        held = handle
        return .acquired
    }

    /// The running instance's sink window. Looked up for up to two seconds: the holder creates it a moment after the mutex.
    private static func findSink(_ name: String) -> HWND? {
        for attempt in 0..<8 {
            if let window = FindWindowW(WinStr.w(WinSinkWindow.className), WinStr.w(name)) { return window }
            if attempt < 7 { Sleep(250) }
        }
        return nil
    }

    /// The executable a process runs (`QueryFullProcessImageNameW`); nil when it cannot be opened (another user, higher integrity).
    static func imagePath(ofProcess pid: DWORD) -> String? {
        guard pid != 0, let process = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, pid) else { return nil }
        defer { _ = CloseHandle(process) }
        var buffer = [UInt16](repeating: 0, count: 32_768)
        var size = DWORD(buffer.count)
        guard QueryFullProcessImageNameW(process, 0, &buffer, &size) else { return nil }
        return String(decoding: buffer.prefix(Int(size)), as: UTF16.self)
    }

    /// This process's executable (`GetModuleFileNameW`); not `WindowsLoginItem.currentExecutablePath()`, which is main-actor isolated.
    private static func ownImagePath() -> String {
        var buffer = [UInt16](repeating: 0, count: 32_768)
        let n = Int(GetModuleFileNameW(nil, &buffer, DWORD(buffer.count)))
        return String(decoding: buffer.prefix(n), as: UTF16.self)
    }

    /// Same file, ignoring case and separator style.
    static func sameExecutable(_ a: String, _ b: String) -> Bool {
        func key(_ path: String) -> String { path.replacingOccurrences(of: "/", with: "\\").lowercased() }
        return key(a) == key(b)
    }
}
#endif
