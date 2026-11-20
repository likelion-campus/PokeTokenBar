#if os(Windows)
import Foundation
import WinSDK

/// What the popover's pages work with (stage 7 D2, D10): the stores, the team, the update checker, the tray and the
/// actions the app owns. The app builds one at launch; the window (`WinPopover`) and every page read it. Nothing here
/// runs on its own: no timer, no observation (the pages observe while they are on screen).
@MainActor final class WinPopoverHost {
    let store: UsageStore
    let companion: CompanionStore
    let updater: UpdateChecker?
    let team: TeamSettings
    let session: TeamSession?
    let feed: TeamFeedStore?
    let tray: WinTrayHost?
    let loginItem: WindowsLoginItem
    /// The plaza (Task 5's plaza button; the Mac's `nav.onOpenPlaza`): the app closes the popover first (D3) and opens it.
    let openPlaza: @MainActor () -> Void
    /// The window that owns the popover (the app's hidden sink): no taskbar button, and it goes with the app.
    var owner: HWND?

    init(store: UsageStore, companion: CompanionStore, updater: UpdateChecker?, team: TeamSettings, session: TeamSession?,
         feed: TeamFeedStore?, tray: WinTrayHost?, loginItem: WindowsLoginItem, openPlaza: @escaping @MainActor () -> Void) {
        self.store = store
        self.companion = companion
        self.updater = updater
        self.team = team
        self.session = session
        self.feed = feed
        self.tray = tray
        self.loginItem = loginItem
        self.openPlaza = openPlaza
    }

    /// The popover opened: the Mac's `showPopover` side effects (the notification permission; the update check behind
    /// its cooldown) through the tray host, which also reads the login and update state again.
    func opened() {
        if let tray { tray.popoverOpened() } else { store.requestNotificationAuthorizationIfNeeded() }
    }

    /// The icon's rectangle now (`Shell_NotifyIconGetRect`), nil when the shell cannot say.
    var anchorRect: RECT? { tray?.tray.anchorRect() }

    /// Where the last tray menu opened ("Settings…" places the popover there when there is no icon rectangle).
    var lastMenuPoint: POINT? { tray?.lastMenuPoint }

    /// `NIM_SETFOCUS`: the keyboard back to the notification area.
    func returnFocusToTray() -> Bool { tray?.tray.returnFocus() ?? false }

    /// Windows refused the popover the foreground (D4, R2: the overflow flyout on some builds, RDP, a full-screen app). A
    /// popover that is not active would never light-dismiss, so it was never shown; instead a tray click or key gets the
    /// tray menu at the icon, a second launch the "already running" balloon it had before stage 7, and the tray menu's own
    /// "Settings…" (which had the foreground a moment ago) only the log line. Runs inside the window message that asked
    /// for the popover, so the menu's modal loop starts from a window message (WinPopupMenu wraps it in WinModalPump).
    func foregroundRefused(_ opener: WinPopover.Opener, at point: POINT?) {
        AppLog.write("popover: the foreground was refused (\(opener)); \(fallbackName(opener)) instead")
        switch opener {
        case .trayClick, .trayKey:
            var p = point ?? POINT()
            if point == nil { _ = GetCursorPos(&p) }
            tray?.openMenu(at: p)
        case .secondLaunch:
            tray?.showAlreadyRunning()
        case .trayMenu, .pet:  // .pet: stage 7 Task 22 (the pet's click had the foreground; the log line only)
            break
        }
    }

    func fallbackName(_ opener: WinPopover.Opener) -> String {
        switch opener {
        case .trayClick, .trayKey: return "the tray menu"
        case .secondLaunch: return "the already-running balloon"
        case .trayMenu, .pet: return "nothing"  // .pet: stage 7 Task 22
        }
    }
}

/// A page of the popover (Task 5's Home, Task 6's Settings, later the recap): built into the window when it opens and
/// again after a DPI or appearance change (a new `WinUIContext`), destroyed when it closes. The page owns everything it
/// makes; after `destroy()` nothing of it may remain (no control, timer, observation, tooltip or registration). The page
/// observes its stores only while it exists, and any async work it starts captures `WinPopover.generation` and lands
/// through `WinPopover.whenCurrent` (a stale completion is dropped).
@MainActor protocol WinPopoverPage: AnyObject {
    /// The content's height in DIP (Home 600, Settings 460: D2). The window is clamped to the work area; the page scrolls.
    var heightDIP: CGFloat { get }
    /// Makes the controls as children of `window` at `ctx`'s DPI, filling `client` (client pixels).
    func build(in window: WinSinkWindow, ctx: WinUIContext, client: RECT)
    /// The client area changed size (a clamp, a re-placement).
    func layout(client: RECT)
    /// The control the keyboard starts in; nil: the window itself.
    var initialFocus: HWND? { get }
    /// Escape: true when the page went back itself (Settings, the recap, a sub-page: D3); false closes the popover.
    func escape() -> Bool
    /// Before the window goes, or before a rebuild: commit changed fields (D5), stop clocks, free what it made.
    func destroy()
}

/// Task 4's page: an empty scroll area with an empty stack (the kit's page frame, nothing on it yet; Task 5 builds Home).
@MainActor final class WinPopoverEmptyPage: WinPopoverPage {
    let heightDIP: CGFloat
    private var area: WinScrollArea?
    private var stack: WinStack?

    init(heightDIP: CGFloat = 600) { self.heightDIP = heightDIP }

    func build(in window: WinSinkWindow, ctx: WinUIContext, client: RECT) {
        guard let made = try? WinScrollArea(parent: window.hwnd, ctx: ctx, rect: client) else {
            AppLog.write("popover: no scroll area (\(GetLastError()))")
            return
        }
        let page = WinStack(pane: made.content, width: made.contentWidth)
        page.onHeight = { [weak made] h in made?.setContentHeight(h) }
        page.layout()
        area = made
        stack = page
    }

    func layout(client: RECT) {
        guard let area, let stack else { return }
        area.move(client)
        stack.width = area.contentWidth
        stack.layout()
    }

    var initialFocus: HWND? { nil }

    func escape() -> Bool { false }

    func destroy() {
        stack?.destroy()
        area?.destroy()
        stack = nil
        area = nil
    }
}
#endif
