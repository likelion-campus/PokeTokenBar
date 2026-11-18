#if os(Windows)
import Foundation
import WinSDK

/// The `poketokenbar:` link on Windows (stage 7 Task 23, part b; the Mac's `CFBundleURLTypes` and `handleGetURL`). The
/// installer registers the scheme for the user (`HKCU\Software\Classes\poketokenbar`, its command
/// `"…\PokeTokenBar.exe" "%1"`), so opening a link starts the app with the link as its first argument:
/// - a running app gets it over `WM_COPYDATA` and this start ends at once: no window, no popover, no activation, nothing
///   saved or logged (a hook may open a link for every tool call);
/// - with no app running, this start becomes a plain start of the app and the link is dropped, as on the Mac, where
///   Launch Services starts the app and the event arrives before the pet exists.
/// The link and the message are untrusted (any program or web page can open a link, any local program can send the
/// message): both go through `AgentLinkRules` and then `AgentActivityEvent(url:)`, the Mac's parser, and the only thing an
/// accepted link does is `WinFloatingPet.handleAgentEvent`, as on the Mac. A flood of links costs what it costs the Mac:
/// one parse and one tracker update each (at most 8 agents are kept, texts are cut), no queue, no timer of its own; a
/// link opened through the shell also starts a process each, which bounds the rate further.
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

    /// Hands `link` to the app already running for this state folder. True: one runs (it was sent the link if the link
    /// parses; this start must end now). False: none runs (start the app as a plain start).
    @MainActor static func forward(_ link: String, mutexName: String) -> Bool {
        guard let sink = FindWindowW(WinStr.w(WinSinkWindow.className), WinStr.w(mutexName)) else { return false }
        guard AgentLinkRules.event(fromLink: link) != nil, var units = AgentLinkRules.payload(link) else { return true }
        units.withUnsafeMutableBytes { raw in
            var data = COPYDATASTRUCT(dwData: ULONG_PTR(AgentLinkRules.copyDataTag), cbData: DWORD(raw.count), lpData: raw.baseAddress)
            var result: DWORD_PTR = 0
            _ = withUnsafeMutablePointer(to: &data) { p in
                SendMessageTimeoutW(sink, copyData, 0, LPARAM(Int(bitPattern: p)), UINT(0x0002 | 0x0001) /* SMTO_ABORTIFHUNG | SMTO_BLOCK */, sendTimeoutMs, &result)
            }
        }
        return true
    }

    // MARK: - the running app

    /// Takes links on the app's sink window. The message's data is read and copied before the handler returns (it lives only
    /// as long as the call); the event is handled after it, so the sender never waits on the pet.
    @MainActor static func install(on sink: WinSinkWindow, deliver: @escaping @MainActor @Sendable (AgentActivityEvent) -> Void) {
        _ = sink.on(copyData) { _, lParam in
            stats.received += 1
            guard let event = event(fromCopyData: lParam) else {
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
