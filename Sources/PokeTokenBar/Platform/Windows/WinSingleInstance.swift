#if os(Windows)
import Foundation
import WinSDK

/// One running app per state folder. A named mutex held for the process's life decides; a second start posts
/// `showMessage` to the running sink (found by class and title = the mutex name), which opens the popover there, and
/// leaves with exit code 3.
/// The installer closes the default instance through the same name (`AppMutex=Local\PokeTokenBar-Team`).
enum WinSingleInstance {
    enum Outcome: Equatable { case acquired, yielded }

    /// What holds the name when it is not a PokeTokenBar that answers.
    enum ForeignHolder: Equatable {
        /// No window of the app's class and title exists (the holder may be a program, or this app still starting up).
        case noAnswer
        /// A window with the app's class and title exists, but its process runs another executable (`image` nil: unreadable).
        case otherProgram(pid: DWORD, image: String?)
    }

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
    static func acquire(name: String, quietly: Bool = false, onForeignHolder: ((ForeignHolder) -> Void)? = nil) -> Outcome {
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
                let image = imagePath(ofProcess: pid)
                if let image, sameExecutable(image, ownImagePath()) {
                    let allowed = AllowSetForegroundWindow(pid)
                    let allowError = allowed ? 0 : GetLastError()
                    _ = PostMessageW(running, showMessage, 0, 0)
                    AppLog.write("single instance: asked pid \(pid) to open its popover; AllowSetForegroundWindow "
                        + (allowed ? "ok" : "refused (\(allowError))"))
                } else {
                    // Any program of this user can create a window with this class and title. It gets neither a message nor the foreground.
                    AppLog.write("single instance: \(name) is answered by pid \(pid), which does not run this executable (\(image ?? "image unreadable")); not asked")
                    onForeignHolder?(.otherProgram(pid: pid, image: image))
                }
            } else {
                AppLog.write("single instance: \(name) is held but no sink window answers")
                onForeignHolder?(.noAnswer)
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

    /// This process's executable, spelled as `imagePath(ofProcess:)` spells another process's (links, junctions, `subst` drives and 8.3 names
    /// resolved by the kernel), so the two compare equal when they are the same file. `GetModuleFileNameW` (as started) is the fallback.
    static func ownImagePath() -> String {
        if let image = imagePath(ofProcess: GetCurrentProcessId()) { return image }
        var buffer = [UInt16](repeating: 0, count: 32_768)
        let n = Int(GetModuleFileNameW(nil, &buffer, DWORD(buffer.count)))
        return String(decoding: buffer.prefix(n), as: UTF16.self)
    }

    /// Same file, ignoring case and separator style.
    static func sameExecutable(_ a: String, _ b: String) -> Bool {
        func key(_ path: String) -> String { path.replacingOccurrences(of: "/", with: "\\").lowercased() }
        return key(a) == key(b)
    }

    /// The message box a copy that cannot start shows (no tray exists yet). A second copy of PokeTokenBar itself (same file name, another
    /// folder, same state folder) is named as that; the unanswered name does not claim anything about who holds it.
    static func foreignHolderText(_ holder: ForeignHolder, language: AppLanguage) -> String {
        switch holder {
        case .noAnswer:
            switch language {
            case .ko: return "PokeTokenBar를 시작하지 못했어요. 한 번에 하나만 실행하는 이름(Local\\PokeTokenBar-Team)이 이미 쓰이고 있는데, 응답하는 PokeTokenBar 창이 없어요. 방금 막 시작한 PokeTokenBar일 수도 있고, 다른 프로그램일 수도 있어요. PokeTokenBar가 실행 중이 아니라면 PC를 다시 시작해 보세요."
            case .ja: return "PokeTokenBarを起動できませんでした。同時に1つだけ実行するための名前(Local\\PokeTokenBar-Team)が使用中ですが、応答するPokeTokenBarのウィンドウがありません。起動したばかりのPokeTokenBarか、別のプログラムかもしれません。PokeTokenBarが動いていなければ、PCを再起動してください。"
            default: return "PokeTokenBar could not start. The name that keeps it to one copy (Local\\PokeTokenBar-Team) is in use, but no PokeTokenBar window answers. It may be a PokeTokenBar that is still starting, or another program. If PokeTokenBar is not running, restart the PC."
            }
        case .otherProgram(let pid, let image):
            let name = image.map { ($0 as NSString).lastPathComponent } ?? ""
            let shown = image.map(shownPath)  // bounded and printable: a holder can sit in a path of 32,000 characters
            if let image = shown, name.lowercased() == "poketokenbar.exe" {
                switch language {
                case .ko: return "PokeTokenBar가 이미 다른 위치에서 실행 중이에요(\(image)). 그 복사본을 트레이 아이콘에서 종료한 뒤 다시 시작해 주세요."
                case .ja: return "PokeTokenBarはすでに別の場所から実行中です(\(image))。そのコピーをトレイアイコンから終了して、もう一度起動してください。"
                default: return "Another copy of PokeTokenBar is already running from \(image). Quit that copy from its tray icon, then start this one again."
                }
            }
            let who = shown ?? "process \(pid)"
            switch language {
            case .ko: return "PokeTokenBar를 시작하지 못했어요. 한 번에 하나만 실행하는 이름(Local\\PokeTokenBar-Team)을 다른 프로그램(\(who))이 쓰고 있어요."
            case .ja: return "PokeTokenBarを起動できませんでした。同時に1つだけ実行するための名前(Local\\PokeTokenBar-Team)を別のプログラム(\(who))が使用しています。"
            default: return "PokeTokenBar could not start. The name that keeps it to one copy (Local\\PokeTokenBar-Team) is held by another program (\(who))."
            }
        }
    }

    /// The path as shown in a message box: control characters out, and at most 200 characters (a longer one keeps its leaf name).
    static func shownPath(_ path: String) -> String {
        let clean = String(String.UnicodeScalarView(path.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }))
        guard clean.count > 200 else { return clean }
        let leaf = (clean as NSString).lastPathComponent
        return "…\\" + String(leaf.prefix(150))
    }
}
#endif
