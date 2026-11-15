#if os(Windows)
import Foundation

/// The switch that makes `PlatformPlaza.makeStage` / `makeShell` build the real Windows stage and window (D17). The app
/// installs it once at launch (`WindowsAppDelegate.launch`), before it builds the plaza controller; tests never do, so
/// XCTest keeps the headless stage and shell.
@MainActor enum WinPlazaLive {
    private(set) static var isInstalled = false
    /// Where the window's placement is saved: the app's settings.
    private(set) static var defaults: UserDefaults?
    private(set) static weak var events: WindowsSystemEvents?
    /// The plaza window that is open now (one at a time): the display-state handlers and the exit line reach it here.
    static weak var current: WinPlazaWindow?

    static func install(defaults: WinSyncingDefaults, events: WindowsSystemEvents?) {
        guard !isInstalled else { return }
        isInstalled = true
        self.defaults = defaults
        self.events = events
        // Registered once for the app's life (`WindowsSystemEvents` keeps its handlers): they reach whichever window is
        // open, and do nothing while none is. Called on the main thread (the sink's WM_POWERBROADCAST).
        events?.onScreensSleep { MainActor.assumeIsolated { current?.displaysChanged(asleep: true) } }
        events?.onScreensWake { MainActor.assumeIsolated { current?.displaysChanged(asleep: false) } }
    }

    static func makeShell() -> any PlazaWindowShell {
        WinPlazaWindow(defaults: defaults ?? WinDefaultsSync.makeAppDefaults(), systemEvents: events)
    }

    /// The open plaza's counters, for the exit log line (nil when no plaza is open).
    static var openPlazaLine: String? { current.map { "plaza open at exit: \($0.statsLine)" } }
}
#endif
