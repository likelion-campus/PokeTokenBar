#if os(Windows)
import Foundation
import WinSDK

/// Task 12: what only a packaged or installed copy can prove. Skipped (and said so) when the exe is not next to a
/// `PokeTokenBar.version` (a build-tree run).
extension WindowsSelftest {
    /// The full paths of the DLLs and the exe loaded in this process (Toolhelp module snapshot).
    private static func loadedModules() -> [String]? {
        let snapshot = CreateToolhelp32Snapshot(DWORD(0x8 | 0x10) /* TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32 */, GetCurrentProcessId())
        guard snapshot != INVALID_HANDLE_VALUE else { return nil }
        defer { _ = CloseHandle(snapshot) }
        var entry = MODULEENTRY32W()
        entry.dwSize = DWORD(MemoryLayout<MODULEENTRY32W>.size)
        var paths: [String] = []
        var more = Module32FirstW(snapshot, &entry)
        while more {
            paths.append(withUnsafePointer(to: &entry.szExePath) {
                $0.withMemoryRebound(to: UInt16.self, capacity: 260) { String(decodingCString: $0, as: UTF16.self) }
            })
            more = Module32NextW(snapshot, &entry)
        }
        return paths
    }

    private static func windowsFolder(_ get: (UnsafeMutablePointer<UInt16>?, UINT) -> UINT) -> String {
        var buffer = [UInt16](repeating: 0, count: 520)
        let n = Int(get(&buffer, UINT(buffer.count)))
        return String(decoding: buffer.prefix(n), as: UTF16.self).lowercased()
    }

    @MainActor static func packagedChecks(_ r: Recorder) {
        guard WindowsInstall.isPackagedLayout else {
            r.add("packaged.processName", true, "skipped: not packaged (no \(WindowsInstall.versionFileName) next to the exe)")
            return
        }
        // The settings plist is named after the process name: the frozen exe name must be what the OS reports.
        let processName = ProcessInfo.processInfo.processName
        let exePath = executablePath()
        let leaf = exePath.split(separator: "\\").last.map(String.init) ?? exePath
        r.add("packaged.processName", processName == WindowsInstall.shippedExecutableName && leaf == WindowsInstall.shippedExecutableName,
              "processName=\(processName) exe=\(exePath) expected=\(WindowsInstall.shippedExecutableName)")

        let version = WindowsInstall.version ?? ""
        let shape = version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil
        r.add("packaged.version", shape, "PokeTokenBar.version=\(version.isEmpty ? "absent" : version) (x.y.z from scripts/build-app.sh)")

        // Every loaded DLL comes from the app folder or from Windows; none from the Swift toolchain, a PATH folder or
        // a vcpkg folder. A bundled DLL that was loaded from elsewhere would mean the app folder is not first.
        guard let modules = loadedModules() else {
            r.add("packaged.modules", false, "CreateToolhelp32Snapshot failed")
            return
        }
        let home = WinPath.native(URL(fileURLWithPath: Bundle.main.bundlePath)).lowercased() + "\\"
        let system = windowsFolder { GetSystemDirectoryW($0, $1) } + "\\"
        let windows = windowsFolder { GetWindowsDirectoryW($0, $1) } + "\\"
        var fromHome: [String] = [], fromOS = 0, strangers: [String] = []
        for path in modules {
            let lower = path.lowercased()
            if lower.hasPrefix(home) { fromHome.append(String(path.dropFirst(home.count))) }
            else if lower.hasPrefix(system) || lower.hasPrefix(windows) { fromOS += 1 }
            else { strangers.append(path) }
        }
        let bundled = ((try? FileManager.default.contentsOfDirectory(atPath: Bundle.main.bundlePath)) ?? [])
            .filter { $0.lowercased().hasSuffix(".dll") }
        let loadedNames = Set(modules.map { ($0.split(separator: "\\").last.map(String.init) ?? $0).lowercased() })
        let misplaced = bundled.filter { name in
            loadedNames.contains(name.lowercased()) && !fromHome.contains { $0.lowercased() == name.lowercased() }
        }
        let ssl = modules.filter { let n = ($0.split(separator: "\\").last.map(String.init) ?? $0).lowercased()
            return n.hasPrefix("libssl") || n.hasPrefix("libcrypto") }
        r.add("packaged.modules", strangers.isEmpty && misplaced.isEmpty && ssl.isEmpty,
              "loaded=\(modules.count) from_app_folder=\(fromHome.count) from_windows=\(fromOS) outside=\(strangers) "
                + "bundled_but_loaded_elsewhere=\(misplaced) openssl_dlls=\(ssl) bundled_dlls=\(bundled.count)")
    }
}
#endif
