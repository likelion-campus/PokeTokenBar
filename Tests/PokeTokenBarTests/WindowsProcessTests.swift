import XCTest
@testable import PokeTokenBar
#if os(Windows)
import WinSDK

/// Windows-only launch behaviour of npm-style `.cmd` shims (F19). Fixture shims are created by the test.
final class WindowsProcessTests: XCTestCase {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-proc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func isAlive(_ pid: DWORD) -> Bool {
        guard let h = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, pid) else { return false }
        defer { CloseHandle(h) }
        var code: DWORD = 0
        return GetExitCodeProcess(h, &code) && code == DWORD(STILL_ACTIVE)
    }

    /// Measurement (no assertion on cmd.exe's choice): what a shim receives for each metacharacter.
    func testReportWhatCmdDoesToMetacharacters() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let shim = dir.appendingPathComponent("echoarg.cmd")
        try "@echo off\r\necho GOT[%1]\r\n".write(to: shim, atomically: true, encoding: .utf8)
        for arg in ["a&echo INJECTED", "a|b", "a<b", "a>b", "a^b", "a%PATH%b", "a!b", "has space", "q\"uote"] {
            let p = Process()
            p.executableURL = shim
            p.arguments = [arg]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: " | ")
            print("F19 metachar arg=[\(arg)] safe=\(PlatformCompat.isBatchSafe(arg)) -> \(text)")
        }
    }

    /// Terminating a `.cmd`-launched process: does its child (PowerShell sleeping 30 s) survive?
    func testTerminatingACmdShimEndsItsChild() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidFile = dir.appendingPathComponent("child.pid")
        let shim = dir.appendingPathComponent("slow.cmd")
        try "@echo off\r\npowershell -NoProfile -Command \"$PID | Out-File -Encoding ascii '\(pidFile.path)'; Start-Sleep 30\"\r\n"
            .write(to: shim, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = shim
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()

        var childPid: DWORD?
        for _ in 0..<150 where childPid == nil {
            try await Task.sleep(nanoseconds: 100_000_000)
            if let s = try? String(contentsOf: pidFile, encoding: .ascii),
               let n = DWORD(s.trimmingCharacters(in: .whitespacesAndNewlines)) { childPid = n }
        }
        let child = try XCTUnwrap(childPid, "the shim's child never started")
        defer { PlatformCompat.forceKill(pid: Int32(child)) }
        XCTAssertTrue(isAlive(child))

        PlatformCompat.terminate(p)   // plain `p.terminate()` left the child running (run 43567771725)
        var gone = false
        for _ in 0..<30 where !gone {
            try await Task.sleep(nanoseconds: 100_000_000)
            gone = !isAlive(child)
        }
        print("F19 orphan: child \(child) after terminate: \(gone ? "gone" : "STILL RUNNING")")
        XCTAssertTrue(gone, "the .cmd shim's child outlived terminate (F19)")
    }
}
#endif
