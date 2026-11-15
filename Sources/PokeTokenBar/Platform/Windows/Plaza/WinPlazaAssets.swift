#if os(Windows)
import Foundation

/// Where the bundled plaza files (art, fonts) are on Windows. SwiftPM resources do not exist there (`Bundle.module` is
/// not available and the Windows build excludes `Resources`), so the app finds its own files:
///
/// 1. the `;`-separated folders in `PTB_PLAZA_RESOURCES` (what `swift test` and the CI jobs set to the checkout's
///    `Sources/PokeTokenBar/Resources/Plaza` and `windows/resources/Plaza`). A packaged app (a `PokeTokenBar.version`
///    next to the exe) ignores the variable, so an installed app reads nothing from outside its own folder;
/// 2. `<exe folder>\Resources\Plaza`, where `scripts/windows/package.ps1` puts every file and the installer copies them.
///
/// Nothing else is searched: not the working directory, not the toolchain, not PATH.
enum WinPlazaAssets {
    static let environmentKey = "PTB_PLAZA_RESOURCES"

    /// The folders to look in, in order. Pure: tests pass their own environment and exe folder.
    static func resourceDirectories(environment: [String: String], executableDirectory: URL) -> [URL] {
        var out: [URL] = []
        for part in (environment[environmentKey] ?? "").split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { out.append(URL(fileURLWithPath: trimmed, isDirectory: true)) }
        }
        out.append(executableDirectory.appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("Plaza", isDirectory: true))
        return out
    }

    /// The first `name.ext` that exists in `directories`; nil for a name that is not a plain file name.
    static func resolve(_ name: String, ext: String, in directories: [URL]) -> URL? {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), !name.contains(".."), !ext.contains("/"),
              !ext.contains("\\") else { return nil }
        for directory in directories {
            let url = directory.appendingPathComponent("\(name).\(ext)")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue { return url }
        }
        return nil
    }

    /// The folders for a process: the environment counts only for an unpackaged run (tests, the CI build tree).
    static func liveDirectories(processEnvironment: [String: String], executableDirectory: URL) -> [URL] {
        let environment = WindowsInstall.isPackagedLayout(executableDirectory: executableDirectory) ? [:] : processEnvironment
        return resourceDirectories(environment: environment, executableDirectory: executableDirectory)
    }

    /// This process's folders.
    static let directories: [URL] = liveDirectories(
        processEnvironment: ProcessInfo.processInfo.environment,
        executableDirectory: URL(fileURLWithPath: Bundle.main.bundlePath, isDirectory: true))
}
#endif
