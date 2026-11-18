#if os(Windows)
import Foundation
import WinSDK

/// The `poketokenbar:` link on Windows (stage 7 Task 23, part b; the Mac's `CFBundleURLTypes` and `handleGetURL`). The
/// installer registers the scheme for the user (`HKCU\Software\Classes\poketokenbar`, its command
/// `"…\PokeTokenBar.exe" --agent-link "%1"`), so opening a link starts the app with the flag and the link; `WindowsApp.main`
/// decides first, before anything is set up (`AgentLinkRules.decide`):
/// - an app running for this state folder gets the link over `WM_COPYDATA` and this start ends at once: no window, no popover,
///   no activation, no settings or log written (a hook may open a link for every tool call);
/// - with no app running, this start starts the app clean (`startClean`) and ends; the link is dropped, as on the Mac, where
///   Launch Services starts the app and the event arrives before the pet exists;
/// - any other shape ends at once (a link that broke out of its quotes and added arguments never reaches the app's flags).
/// The link and the message are untrusted (any program or web page can open a link, any local program can send the
/// message): both go through `AgentLinkRules` and then `AgentActivityEvent(url:)`, the Mac's parser, and the only thing an
/// accepted link does is `WinFloatingPet.handleAgentEvent`, as on the Mac. A flood of links costs what it costs the Mac: one
/// parse and one tracker update each (at most 8 agents are kept, texts are cut), no queue, no timer of its own; a link opened
/// through the shell also starts a process each, which bounds the rate further. Another program of the same user can send
/// such messages, or make a window of the sink's class and title to take links meant for the app: it has the user's rights
/// already, so neither is a boundary this crosses (windows-differences).
enum WinAgentLink {
    /// `WM_COPYDATA`.
    static let copyData: UINT = 0x004A
    /// How long a start waits for the running app to take the link (the app answers at once; a hung app is not waited for).
    static let sendTimeoutMs: UINT = 2_000

    struct Stats: Equatable { var received = 0, accepted = 0, refused = 0 }
    @MainActor static var stats = Stats()
    /// The last event taken (the selftest's).
    @MainActor static var lastAccepted: AgentActivityEvent?

    // MARK: - the start that carries a link

    /// The command line's decision acted on (`WindowsApp.main`, before anything is set up): returns the arguments the app
    /// starts with, or ends the process for a link start.
    @MainActor static func handleStart(_ raw: [String]) -> [String] {
        switch AgentLinkRules.decide(raw, appRunning: { sinkForThisStateFolder() != nil }, elevated: { isElevated() }) {
        case .app(let arguments):
            return arguments
        case .forward(let link):
            if let sink = sinkForThisStateFolder() { forward(link, to: sink) }
        case .startClean:
            _ = startClean()
        case .drop:
            break
        }
        WindowsApp.exitForLink()
    }

    /// The running app's sink for this state folder (found by its class and the mutex name, as a second start finds it).
    @MainActor static func sinkForThisStateFolder() -> HWND? {
        let name = WinSingleInstance.mutexName(stateDirectory: AppStatePaths.directory(), defaultDirectory: WindowsAppDelegate.defaultStateDirectory)
        return FindWindowW(WinStr.w(WinSinkWindow.className), WinStr.w(name))
    }

    /// Sends `link` to the running app's sink when it parses (a link the parser refuses is not sent at all).
    @MainActor static func forward(_ link: String, to sink: HWND) {
        guard AgentLinkRules.event(fromLink: link) != nil, var units = AgentLinkRules.payload(link) else { return }
        units.withUnsafeMutableBytes { raw in
            var data = COPYDATASTRUCT(dwData: ULONG_PTR(AgentLinkRules.copyDataTag), cbData: DWORD(raw.count), lpData: raw.baseAddress)
            var result: DWORD_PTR = 0
            _ = withUnsafeMutablePointer(to: &data) { p in
                SendMessageTimeoutW(sink, copyData, 0, LPARAM(Int(bitPattern: p)), UINT(0x0002 | 0x0001) /* SMTO_ABORTIFHUNG | SMTO_BLOCK */, sendTimeoutMs, &result)
            }
        }
    }

    /// This process runs elevated (`TokenElevation`); unknown reads as elevated (the clean start is skipped).
    static func isElevated() -> Bool {
        var token: HANDLE?
        guard OpenProcessToken(GetCurrentProcess(), DWORD(0x0008) /* TOKEN_QUERY */, &token), let token else { return true }
        defer { _ = CloseHandle(token) }
        var elevation = TOKEN_ELEVATION()
        var size: DWORD = 0
        guard GetTokenInformation(token, TokenElevation, &elevation, DWORD(MemoryLayout<TOKEN_ELEVATION>.size), &size) else { return true }
        return elevation.TokenIsElevated != 0
    }

    /// How a clean start went (the selftest reads it; the start itself writes nothing).
    enum CleanStart: Equatable { case started(pid: DWORD, outOfJob: Bool), failed(DWORD) }

    private typealias CreateEnvironmentBlockFn = @convention(c) (UnsafeMutablePointer<UnsafeMutableRawPointer?>?, HANDLE?, Int32) -> Int32
    private typealias DestroyEnvironmentBlockFn = @convention(c) (UnsafeMutableRawPointer?) -> Int32

    /// The app started as a plain, quiet start that owes nothing to the opener: `"…exe" --autostart`
    /// (`AgentLinkRules.cleanStartArguments`; nothing of the link's command line), the user's own fresh environment
    /// (`CreateEnvironmentBlock` without inheriting: none of the opener's variables), out of the opener's job where the job
    /// allows it (`CREATE_BREAKAWAY_FROM_JOB`; a job that refuses keeps the app in it, and it ends with that job), from the
    /// install folder, no handles inherited. An elevated opener never gets here (`decide`: the app would run elevated, and
    /// UIPI would then refuse the normal links to it).
    @MainActor static func startClean() -> CleanStart {
        let exe = WindowsLoginItem.currentExecutablePath()
        guard let line = WinProcess.commandLine(exe, AgentLinkRules.cleanStartArguments) else { return .failed(87) }
        var environment: UnsafeMutableRawPointer?
        var token: HANDLE?
        if OpenProcessToken(GetCurrentProcess(), DWORD(0x0008 | 0x0002) /* TOKEN_QUERY | TOKEN_DUPLICATE */, &token), let token,
           let create = WinDynamic.symbol("userenv.dll", "CreateEnvironmentBlock", as: CreateEnvironmentBlockFn.self) {
            if create(&environment, token, 0) == 0 { environment = nil }
        }
        if let token { _ = CloseHandle(token) }
        defer {
            if let environment, let destroy = WinDynamic.symbol("userenv.dll", "DestroyEnvironmentBlock", as: DestroyEnvironmentBlockFn.self) {
                _ = destroy(environment)
            }
        }
        let folder = (exe as NSString).deletingLastPathComponent
        func start(breakaway: Bool) -> (Bool, PROCESS_INFORMATION, DWORD) {
            var startup = STARTUPINFOW()
            startup.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
            var info = PROCESS_INFORMATION()
            var command = WinStr.w(line)   // CreateProcessW may write into it
            var flags = DWORD(0x0400_0000)   // CREATE_DEFAULT_ERROR_MODE
            if environment != nil { flags |= 0x0000_0400 }   // CREATE_UNICODE_ENVIRONMENT
            if breakaway { flags |= 0x0100_0000 }   // CREATE_BREAKAWAY_FROM_JOB
            let ok = command.withUnsafeMutableBufferPointer { buffer in
                CreateProcessW(WinStr.w(exe), buffer.baseAddress, nil, nil, false, flags, environment, WinStr.w(folder), &startup, &info)
            }
            return (ok, info, ok ? 0 : GetLastError())
        }
        var inJob: WindowsBool = false
        let jobbed = IsProcessInJob(GetCurrentProcess(), nil, &inJob) && inJob.boolValue
        var (ok, info, error) = start(breakaway: jobbed)
        var outOfJob = !jobbed
        if ok { outOfJob = true } else if jobbed {
            (ok, info, error) = start(breakaway: false)   // the job allows no breakaway: the app stays in it
        }
        guard ok else { return .failed(error) }
        _ = CloseHandle(info.hThread)
        _ = CloseHandle(info.hProcess)
        return .started(pid: info.dwProcessId, outOfJob: outOfJob)
    }

    // MARK: - the running app

    /// Takes links on the app's sink window. The message's data is read and copied before the handler returns (it lives only
    /// as long as the call); the event is handled after it, so the sender never waits on the pet.
    @MainActor static func install(on sink: WinSinkWindow, deliver: @escaping @MainActor @Sendable (AgentActivityEvent) -> Void) {
        _ = sink.on(copyData) { _, lParam in
            stats.received += 1
            guard let event = WinAgentLink.event(fromCopyData: lParam) else {
                stats.refused += 1
                return 0
            }
            stats.accepted += 1
            lastAccepted = event
            DispatchQueue.main.async { MainActor.assumeIsolated { deliver(event) } }
            return 1
        }
    }

    /// The event a `WM_COPYDATA` carries, or nil: a tagged, whole, capped UTF-16 link the Mac's parser takes; nothing else.
    @MainActor static func event(fromCopyData lParam: LPARAM) -> AgentActivityEvent? {
        guard let cds = UnsafePointer<COPYDATASTRUCT>(bitPattern: Int(lParam)) else { return nil }
        let count = Int(cds.pointee.cbData)
        guard count > 0, count <= AgentLinkRules.maxLength * 2, let data = cds.pointee.lpData else { return nil }
        let link = AgentLinkRules.link(tag: UInt(cds.pointee.dwData), bytes: UnsafeRawBufferPointer(start: data, count: count))
        return link.flatMap(AgentLinkRules.event(fromLink:))
    }
}
#endif
