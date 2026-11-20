import AppKit

/// The two calls `UpdateChecker.applyUpdate` made directly before it went through `PlatformShell`, copied verbatim.
@MainActor struct MacShell: PlatformShellService {
    func open(_ url: URL) { NSWorkspace.shared.open(url) }
    func terminate() { NSApp.terminate(nil) }
}
