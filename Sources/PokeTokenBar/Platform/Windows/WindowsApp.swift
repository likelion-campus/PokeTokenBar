#if os(Windows)
import Foundation
import CWinShim
import CTeamTLS

/// Entry point of the Windows app. Skeleton: proves the process starts, the main run loop can be touched,
/// and the bundled OpenSSL is linked (`--selftest`).
public enum WindowsApp {
    public static func main() -> Int32 {
        _ = RunLoop.main  // first, before any window: Foundation's initializer turns on CF's message mask (F4)
        let args = CommandLine.arguments
        if args.contains("--selftest") {
            guard let i = args.firstIndex(of: "--selftest-out"), i + 1 < args.count else { return 2 }
            return writeSelfTest(to: args[i + 1])
        }
        return 0
    }

    private static func writeSelfTest(to path: String) -> Int32 {
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let version = (try? String(contentsOf: exeDir.appendingPathComponent("PokeTokenBar.version"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        let payload: [String: Any] = [
            "result": ptb_shim_abi() == 1 ? "pass" : "fail",
            "version": version,
            "openssl": String(cString: ptb_tls_openssl_version()),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return 3 }
        do { try data.write(to: URL(fileURLWithPath: path)) } catch { return 4 }
        return 0
    }
}
#endif
