#if os(Windows)
import Foundation

/// `PokeTokenBar.exe --import-save <file>`: the Windows shell of `SaveImportTool` (see there for what it does and does
/// not change). Stopgap until the popover's Backup & Transfer page (stage 7 Task 15), which calls `SaveImportTool.run`.
/// Like `--set-team-code`: refuses while the app runs (single-instance mutex), goes through the settings guard first,
/// leaves through `WindowsApp.exit`. Exit 0 = applied, 2 = bad argument or file, 3 = the app is running, 4 = no backup / not applied.
@MainActor enum WindowsImportSaveTool {
    static func run(_ arguments: [String]) -> Never {
        let i = arguments.firstIndex(of: "--import-save")
        let path = i.flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        let stateDirectory = AppStatePaths.directory()
        let result = SaveImportTool.run(
            path: path, stateDirectory: stateDirectory,
            appIsRunning: {
                let mutex = WinSingleInstance.mutexName(stateDirectory: stateDirectory,
                                                        defaultDirectory: WindowsAppDelegate.defaultStateDirectory)
                return WinSingleInstance.acquire(name: mutex) != .acquired
            },
            makeDefaults: {
                let teamSuite = TeamSettings.suiteName(for: stateDirectory, defaultDirectory: WindowsAppDelegate.defaultStateDirectory)
                WinDefaultsSync.guardAtLaunch(suites: [nil, teamSuite])  // the app's launch step 8b
                return WinDefaultsSync.makeAppDefaults()
            })
        try? FileHandle.standardOutput.write(contentsOf: Data((result.line + "\n").utf8))
        AppLog.write("import save tool: exit \(result.exitCode)")
        WindowsApp.exit(result.exitCode, .helper)
    }
}
#endif
