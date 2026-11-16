#if os(Windows)
import Foundation
import WinSDK

/// The bounded exit's app-level check (`exit.stuckSocketThread`). A child copy of this exe runs the real exit path with the
/// team transport on, a dial to a peer that never answers the handshake, and the socket thread stuck in a call that never
/// returns (`WinSocketLoop.injectStall`); it is closed the way Windows closes an app (`WM_CLOSE`). The parent measures how long
/// the child takes to end, reads the child's own step times (what was done before the waits: the tray icon) and checks that
/// the child's named mutex is gone.
extension WindowsSelftest {
    static let exitStuckFlag = "--selftest-exit-stuck"

    /// `--selftest-exit-stuck <mutex name> <marker file>`: the helper of `exit.stuckSocketThread`.
    @MainActor static func runExitStuck(_ args: [String]) -> Never {
        guard args.count >= 2 else { WindowsApp.exit(2, .helper) }
        let marker = URL(fileURLWithPath: args[1])
        let strategy = WinMainLoop.prepare()
        guard let window = try? WinSinkWindow(title: "ptb-selftest-helper-\(GetCurrentProcessId())") else { WindowsApp.exit(2, .helper) }
        WindowsAppDelegate.installExitHandlers(on: window)
        _ = CreateMutexW(nil, true, WinStr.w(args[0]))   // held until the process ends, like the single-instance mutex
        let tray = WinTray(window: window)
        tray.add()
        WindowsApp.trayToRemove = tray

        // A peer that accepts and never admits: the transport's handshake against it never completes.
        let peer = WinSocketLoop(deliver: { _ in })
        peer.start()
        let code = TeamCode(parsing: "PTB-AAAA-BBBB-CCCC")!
        let transport = WindowsTeamTransport(advertise: false)
        transport.start(code: code)
        WindowsApp.teamTransportToShutdown = transport
        let release = DispatchSemaphore(value: 0)   // never signalled: the thread stays stuck until the process ends

        var began = Date()
        WindowsApp.exitStepObserver = { step in
            let line = "\(step) \(Int(Date().timeIntervalSince(began) * 1000)) tray_delete_ok=\(tray.lastDeleteOK)\n"
            if let h = try? FileHandle(forWritingTo: marker) { _ = try? h.seekToEnd(); try? h.write(contentsOf: Data(line.utf8)); try? h.close() }
        }
        try? Data().write(to: marker)
        Task { @MainActor in
            peer.listen(code: code)
            try? await Task.sleep(nanoseconds: 500_000_000)
            transport.socketLoop?.injectStall(until: release)
            try? await Task.sleep(nanoseconds: 300_000_000)
            signalReady()
            began = Date()
            _ = PostMessageW(window.hwnd, UINT(WM_CLOSE), 0, 0)
        }
        WinMainLoop.run(strategy) { false }
        WindowsApp.exit(5, .helper)
    }

    /// Quitting with a stuck socket thread ends the process within the budget, takes the tray icon out before it waits, and
    /// leaves no mutex behind.
    @MainActor static func exitDeadlineCheck(_ r: Recorder) async {
        let mutex = "Local\\PokeTokenBar-selftest-exit-\(UUID().uuidString)"
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-exit-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: marker) }
        do {
            let child = try Helper.start([exitStuckFlag, mutex, marker.path], ready: true)
            let ready = await child.waitReady(timeout: 30)
            let began = Date()
            let code = await child.waitExit(timeout: 30)
            let took = Date().timeIntervalSince(began)
            if code == nil { child.kill() }
            child.close()
            let lines = ((try? String(contentsOf: marker, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            func ms(_ step: String) -> Int? {
                lines.first { $0.hasPrefix(step + " ") }.flatMap { $0.split(separator: " ").dropFirst().first }.flatMap { Int($0) }
            }
            let tray = ms("tray removed"), team = ms("team shutdown done")
            let mutexGone = !WinProcess.mutexExists(mutex)
            let budget = WindowsApp.exitBudget
            let ok = ready && code == 0 && took >= budget - 1 && took <= budget + 3
                && (tray ?? Int.max) < 1500 && lines.contains { $0.hasPrefix("tray removed ") && $0.hasSuffix("tray_delete_ok=true") }
                && mutexGone && (team ?? 0) >= Int((budget - 1) * 1000)
            r.add("exit.stuckSocketThread", ok,
                  "child with the team on, a silent peer and the socket thread stuck, closed by WM_CLOSE: exit=\(describe(code)) after \(Int(took * 1000)) ms "
                    + "(budget \(Int(budget * 1000)) ms; at least budget-1 s proves the stall held, at most budget+3 s proves it was cut); "
                    + "tray icon removed at \(tray.map(String.init) ?? "never") ms (before the waits, must be < 1500); team shutdown done at \(team.map(String.init) ?? "never") ms; "
                    + "mutex gone=\(mutexGone) ready=\(ready); steps: \(lines.joined(separator: " | "))")
        } catch {
            r.add("exit.stuckSocketThread", false, "\(error)")
        }
    }
}
#endif
