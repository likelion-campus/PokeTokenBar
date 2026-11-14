import Foundation

/// What `UpdateChecker` (and, on Windows, the tray) needs from the desktop shell: open a page, end the app.
@MainActor protocol PlatformShellService {
    func open(_ url: URL)
    func terminate()
}

/// The shared-only build (the Mac checking the shared set as Windows sees it): nothing to open with, nothing to end.
@MainActor struct LoggingShell: PlatformShellService {
    func open(_ url: URL) { AppLog.write("shell: open \(url.absoluteString) (no shell in this build)") }
    func terminate() { AppLog.write("shell: terminate (no shell in this build)") }
}

enum PlatformShell {
    /// Lazily built on first use; a test may assign its own.
    @MainActor static var current: any PlatformShellService = {
        #if os(Windows)
        WindowsShell()
        #elseif PTB_SHARED_ONLY
        LoggingShell()
        #else
        MacShell()
        #endif
    }()
}
