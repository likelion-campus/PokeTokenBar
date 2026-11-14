#if os(Windows)
import CWinShim
import Foundation
import WinSDK

/// `--selftest-crash <mode> [<logs folder> [dumps]]` (`dumps` = run as if `PTB_CRASH_DUMPS=1`): installs the crash log like the app does, then dies on purpose.
/// Modes: `av` (write through a bad pointer), `fatalError`, `precondition`, `overflow`, `abort`, `clean` (a normal
/// exit through `WindowsApp.exit`). With a folder the helper works there and logs to `<folder>\child.log`; without
/// one it uses the real log folder (the workflow's crash-then-relaunch step). `SetErrorMode` is for this child only,
/// so Windows Error Reporting shows no dialog and the runner never hangs; the app itself never sets it.
enum WindowsSelftestCrash {
    @MainActor static func run(_ args: [String]) -> Never {
        let mode = args.first ?? "clean"
        let scratch = args.count > 1 ? URL(fileURLWithPath: args[1], isDirectory: true) : nil
        // Dumps are opt-in through the environment: a child asks for them with a third argument, else the variable is cleared (with no folder the real environment decides).
        if scratch != nil { _ = SetEnvironmentVariableW(WinStr.w("PTB_CRASH_DUMPS"), args.count > 2 && args[2] == "dumps" ? WinStr.w("1") : nil) }
        _ = SetErrorMode(0x0001 | 0x0002)  // SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX
        WindowsCrashLog.install(version: "selftest-crash", logsDirectory: scratch ?? PlatformCompat.logsDirectory(), log: { line in
            guard let scratch else { AppLog.write(line); return }
            let url = scratch.appendingPathComponent("child.log")
            let data = Data((line + "\n").utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        })
        switch mode {
        case "av": ptb_crash_selftest_trigger(0)
        case "fatalError": fatalError("selftest crash")
        case "precondition": precondition(args.count > 99, "selftest precondition")
        case "overflow": _ = overflowing(args.count)
        case "abort": ptb_crash_selftest_trigger(2)
        default: WindowsApp.exit(0, .helper)
        }
        WindowsApp.exit(7, .helper)  // a crash mode that did not crash
    }

    @inline(never) private static func overflowing(_ n: Int) -> Int { Int.max + n }
}

extension WindowsSelftest {
    /// Crashes child processes of this exe in a scratch folder and reads what each left behind. Every wait is bounded.
    @MainActor static func crashChecks(_ r: Recorder) async {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-crash-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let fresh = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-crash-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let optIn = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-crash-\(UUID().uuidString.prefix(8))", isDirectory: true)
        for dir in [scratch, fresh, optIn] { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        defer { for dir in [scratch, fresh, optIn] { try? FileManager.default.removeItem(at: dir) } }

        func child(_ mode: String, in dir: URL, dumps: Bool = false) async -> DWORD? {
            do {
                let process = try Helper.start(["--selftest-crash", mode, dir.path] + (dumps ? ["dumps"] : []), ready: false)
                let code = await process.waitExit(timeout: 60)
                if code == nil { process.kill() }
                process.close()
                return code
            } catch {
                AppLog.write("selftest: cannot start the crash child: \(error)")
                return nil
            }
        }
        func text(_ name: String, in dir: URL = scratch) -> String {
            String(decoding: (try? Data(contentsOf: dir.appendingPathComponent(name))) ?? Data(), as: UTF8.self)
        }
        func dumps(in dir: URL = scratch) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { $0.hasPrefix(WindowsCrashLog.dumpPrefix) && $0.hasSuffix(".dmp") }.sorted()
        }
        func count(_ needle: String, in haystack: String) -> Int { haystack.components(separatedBy: needle).count - 1 }
        func hex(_ code: DWORD?) -> String { code.map { "0x" + String($0, radix: 16, uppercase: true) } ?? "timeout" }
        let crashLog = WindowsCrashLog.crashLogName
        let marker = scratch.appendingPathComponent(WindowsCrashLog.markerName)

        // 1. a deliberate access violation
        let c1 = await child("av", in: scratch)
        let rec1 = text(crashLog)
        let dumps1 = dumps()
        let moduleLine = rec1.split(separator: "\n").first { $0.hasPrefix("[CRASH] module=") }.map(String.init) ?? "none"
        let hasVersion = rec1.contains(" version=selftest-crash"), hasOS = rec1.contains(" os=10.")
        let markerLeft = FileManager.default.fileExists(atPath: marker.path)
        let moduleOK = moduleLine.contains("+0x") && !moduleLine.contains("unknown")
        let avLines = rec1.contains("[CRASH] exception 0xC0000005 at 0x")
            && rec1.contains("access violation: write of 0x0000000000000008")
        let identity = rec1.contains(" pid=") && rec1.contains(" utc=")
        r.add("crash.access", c1 == 0xC000_0005 && avLines && moduleOK && hasVersion && hasOS && identity && markerLeft,
              "exit=\(hex(c1)) first_line=\(rec1.split(separator: "\n").first.map(String.init) ?? "none") \(moduleLine) "
                + "has_version=\(hasVersion) has_os=\(hasOS) marker_left=\(markerLeft)")
        let dumpOff = rec1.contains("[CRASH] dump=off")
        r.add("crash.dump", dumps1.isEmpty && dumpOff && rec1.contains("[CRASH] exception") && !rec1.contains("[CRASH] dump=PokeTokenBar-"),
              "default run (PTB_CRASH_DUMPS unset): dump files=\(dumps1) text_log_says_off=\(dumpOff) text_record_present=\(rec1.contains("[CRASH] exception"))")

        // 2. the next launch notices (and a second crash does not overwrite the first)
        let c2 = await child("av", in: scratch)
        let childLog = text("child.log")
        let rec2 = text(crashLog)
        let dumps2 = dumps()
        r.add("crash.previous", count("previous session did not end cleanly", in: childLog) == 1
              && childLog.contains("previous session crash record:") && childLog.contains("[CRASH] exception 0xC0000005"),
              "next launch logged unclean=\(count("previous session did not end cleanly", in: childLog)) (expected 1) drained_record=\(childLog.contains("[CRASH] exception 0xC0000005")) exit=\(hex(c2))")
        r.add("crash.twice", rec2.contains("[CRASH] exception 0xC0000005") && childLog.contains("[CRASH] exception 0xC0000005") && dumps2.isEmpty,
              "first_record_kept_in_child_log=\(childLog.contains("[CRASH] exception")) second_record_in_crash_log=\(rec2.contains("[CRASH] exception")) dumps=\(dumps2.count)")

        // 3. the Swift runtime's own traps
        let c3 = await child("fatalError", in: scratch)
        let rec3 = text(crashLog)
        let stderrText = text(WindowsCrashLog.stderrName)
        let exceptionLine3 = rec3.split(separator: "\n").first { $0.hasPrefix("[CRASH] exception") }.map(String.init) ?? "none"
        r.add("crash.fatalError", c3 != 0 && c3 != nil && exceptionLine3 != "none" && rec3.contains(" version=selftest-crash"),
              "exit=\(hex(c3)) \(exceptionLine3)")
        r.add("crash.stderr", stderrText.contains("selftest crash"),
              "stderr.log bytes=\(stderrText.utf8.count) contains_'selftest crash'=\(stderrText.contains("selftest crash")) first_line=\(stderrText.split(separator: "\n").first.map(String.init) ?? "none")")
        let c4 = await child("precondition", in: scratch)
        let rec4 = text(crashLog)
        let exceptionLine4 = rec4.split(separator: "\n").first { $0.hasPrefix("[CRASH] exception") }.map(String.init) ?? "none"
        r.add("crash.precondition", c4 != 0 && c4 != nil && exceptionLine4 != "none", "exit=\(hex(c4)) \(exceptionLine4)")
        let c5 = await child("overflow", in: scratch)
        let rec5 = text(crashLog)
        let exceptionLine5 = rec5.split(separator: "\n").first { $0.hasPrefix("[CRASH] exception") }.map(String.init) ?? "none"
        r.add("crash.overflow", c5 != 0 && c5 != nil && exceptionLine5 != "none", "exit=\(hex(c5)) \(exceptionLine5)")
        let c6 = await child("abort", in: scratch)
        let rec6 = text(crashLog)
        r.add("crash.abort", c6 != 0 && c6 != nil && rec6.contains("[CRASH] fatal signal SIGABRT"),
              "exit=\(hex(c6)) record=\(rec6.split(separator: "\n").first.map(String.init) ?? "none")")

        // 4. opted in (PTB_CRASH_DUMPS=1): a dump per crash, two crashes keep both, the folder stays bounded
        _ = await child("av", in: optIn, dumps: true)
        let optRec1 = text(crashLog, in: optIn)
        let optDumps1 = dumps(in: optIn)
        let firstDump = optDumps1.first ?? ""
        let magic = (try? Data(contentsOf: optIn.appendingPathComponent(firstDump)).prefix(4)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let dumpSize = (try? FileManager.default.attributesOfItem(atPath: optIn.appendingPathComponent(firstDump).path)[.size] as? Int) ?? 0
        r.add("crash.dumpOptIn", optDumps1.count == 1 && magic == "MDMP" && dumpSize > 0 && optRec1.contains("[CRASH] dump=\(firstDump)"),
              "PTB_CRASH_DUMPS=1: dumps=\(optDumps1) magic=\(magic) bytes=\(dumpSize) named_in_record=\(optRec1.contains("[CRASH] dump=\(firstDump)"))")
        _ = await child("av", in: optIn, dumps: true)
        let optDumps2 = dumps(in: optIn)
        r.add("crash.twiceDumps", optDumps2.count == 2 && Set(optDumps2).count == 2 && optDumps2.contains(firstDump),
              "dumps=\(optDumps2) (two crashes, two distinct files, the first kept)")
        for _ in 0..<5 { _ = await child("av", in: optIn, dumps: true) }
        let all = dumps(in: optIn)
        r.add("crash.bounded", all.count <= WindowsCrashLog.keptDumps + 1 && all.count >= WindowsCrashLog.keptDumps && !all.contains(firstDump),
              "opted in, crashes=7 dumps_after=\(all.count) (limit \(WindowsCrashLog.keptDumps) kept + the new one) oldest_gone=\(!all.contains(firstDump))")

        // 5. a normal exit leaves nothing behind, and the next launch has nothing to report
        let e1 = await child("clean", in: fresh)
        let e2 = await child("clean", in: fresh)
        let freshLog = text("child.log", in: fresh)
        let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: fresh.path)) ?? []).filter { $0 != "child.log" }
        let crashEmpty = text(crashLog, in: fresh).isEmpty
        r.add("crash.cleanExit", e1 == 0 && e2 == 0 && !freshLog.contains("did not end cleanly") && crashEmpty
              && !leftovers.contains(WindowsCrashLog.markerName) && dumps(in: fresh).isEmpty,
              "exit=\(hex(e1)),\(hex(e2)) reported_unclean=\(freshLog.contains("did not end cleanly")) marker_left=\(leftovers.contains(WindowsCrashLog.markerName)) "
                + "crash_log_empty=\(crashEmpty) dumps=\(dumps(in: fresh).count) files=\(leftovers.sorted())")
    }
}
#endif
