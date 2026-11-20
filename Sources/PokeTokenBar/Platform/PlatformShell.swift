import Foundation

/// What `UpdateChecker` (and, on Windows, the tray) needs from the desktop shell: open a page, end the app, and on Windows
/// install an update in-app.
@MainActor protocol PlatformShellService {
    func open(_ url: URL)
    func terminate()
    /// Called first when there is no Homebrew cask (`UpdateChecker.applyUpdate`). true: the installer is starting and the
    /// app is leaving. false: not handled here, so the caller opens the release page as before.
    func installUpdate(version: String) async -> Bool
}

extension PlatformShellService {
    /// The Mac (Homebrew or the release page, unchanged), the shared-only build and test shells: not handled here.
    func installUpdate(version: String) async -> Bool { false }
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
