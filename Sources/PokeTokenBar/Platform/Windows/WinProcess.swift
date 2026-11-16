#if os(Windows)
import Foundation
import WinSDK

/// Starting another program without a shell (stage 8, D8 step 6): `CreateProcessW` with the exact executable path as the
/// application name (no search of the working folder or PATH), a command line whose program part is that path quoted, an
/// explicit working folder, no inherited handles (the app's single-instance mutex must die with the app, or Setup would wait
/// for an app that has left), not elevated and not waited for. The update's Setup is the one caller.
enum WinProcess {
    /// `"<exe>" <args>`: the program quoted, each argument as given and separated by one space (the caller writes it in the
    /// form its program parses, e.g. Inno's `/LOG="C:\a b\x.log"`). nil when the path holds a quote, or anything holds a NUL
    /// or a line break: no part can then end the program name early or start another argument.
    static func commandLine(_ exe: String, _ args: [String]) -> String? {
        let bad: (Character) -> Bool = { $0 == "\0" || $0 == "\n" || $0 == "\r" }
        guard !exe.isEmpty, !exe.contains("\""), !exe.contains(where: bad), !args.contains(where: { $0.contains(where: bad) })
        else { return nil }
        return (["\"" + exe + "\""] + args).joined(separator: " ")
    }

    /// true when the program started. Its process and thread handles are closed at once: nobody waits for it, and it outlives
    /// the app. The reason for a false is logged (the Win32 error only).
    static func launchDetached(_ exe: URL, _ args: [String], workingDirectory: URL) -> Bool {
        let path = WinPath.native(exe)
        guard let line = commandLine(path, args) else {
            AppLog.write("process: not starting \(exe.lastPathComponent): its command line would hold a quote, NUL or line break")
            return false
        }
        var startup = STARTUPINFOW()
        startup.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
        var info = PROCESS_INFORMATION()
        var command = WinStr.w(line)  // CreateProcessW may write into the command line buffer
        let started = command.withUnsafeMutableBufferPointer { buffer in
            CreateProcessW(WinStr.w(path), buffer.baseAddress, nil, nil, false, DWORD(0x0400_0000) /* CREATE_DEFAULT_ERROR_MODE */,
                           nil, WinStr.w(WinPath.native(workingDirectory)), &startup, &info)
        }
        let error = started ? 0 : GetLastError()
        guard started else {
            AppLog.write("process: CreateProcessW(\(exe.lastPathComponent)) failed: \(error)")
            return false
        }
        AppLog.write("process: started \(exe.lastPathComponent) pid=\(info.dwProcessId) in \(WinPath.native(workingDirectory))")
        _ = CloseHandle(info.hThread)
        _ = CloseHandle(info.hProcess)
        return true
    }

    /// Whether a named mutex exists now (`Local\PokeTokenBar-Setup` while a PokeTokenBar Setup runs). A mutex we may not open
    /// still exists.
    static func mutexExists(_ name: String) -> Bool {
        if let handle = OpenMutexW(DWORD(0x0010_0000) /* SYNCHRONIZE */, false, WinStr.w(name)) {
            _ = CloseHandle(handle)
            return true
        }
        return GetLastError() == DWORD(ERROR_ACCESS_DENIED)
    }
}
#endif
