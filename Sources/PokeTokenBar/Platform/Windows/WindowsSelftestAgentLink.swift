#if os(Windows)
import Foundation
import WinSDK

// Stage 7 Task 23, part b: the `poketokenbar:` link (`link.receive`, `link.forward`, `link.registration`, `link.shell`). Links
// are FIXTURE `poketokenbar://agent` URLs. Sandboxed: `link.receive` sends to this app's own sink; `link.forward` starts copies
// of this exe with this process's environment, which find only this app (its state folder's mutex name). The registry is only
// READ, and only when this copy is the one the installer registered (`link.registration`, `link.shell`, the runner's installed
// selftest); a selftest never writes the link's key. Leaves the app's pet and settings as it found them.

extension WindowsSelftest {
    @MainActor static func agentLinkChecks(_ r: Recorder, _ app: WindowsAppDelegate) async {
        await WindowsSelftestAgentLink.run(r, app)
    }
}

@MainActor enum WindowsSelftestAgentLink {
    static let names = ["link.receive", "link.forward", "link.coldStart", "link.registration", "link.shell"]

    static func run(_ r: WindowsSelftest.Recorder, _ app: WindowsAppDelegate) async {
        receiveCheck(r, app)
        await forwardCheck(r, app)
        await coldStartCheck(r)
        let registered = registrationCheck(r)
        await shellCheck(r, app, registered: registered)
    }

    /// One `WM_COPYDATA` to the app's sink, as another program would send it: the handler's answer.
    static func send(_ sink: HWND, tag: UInt, bytes: [UInt8]?, count: Int? = nil) -> LRESULT {
        var payload = bytes ?? []
        return payload.withUnsafeMutableBytes { raw in
            var data = COPYDATASTRUCT(dwData: ULONG_PTR(tag), cbData: DWORD(count ?? raw.count), lpData: bytes == nil ? nil : raw.baseAddress)
            return withUnsafeMutablePointer(to: &data) { SendMessageW(sink, WinAgentLink.copyData, 0, LPARAM(Int(bitPattern: $0))) }
        }
    }

    static func utf16(_ s: String) -> [UInt8] { Array(s.utf16).withUnsafeBytes { Array($0) } }

    // MARK: - link.receive: what the sink takes over WM_COPYDATA, and what it refuses

    static func receiveCheck(_ r: WindowsSelftest.Recorder, _ app: WindowsAppDelegate) {
        guard let sink = app.sink?.hwnd else { r.add("link.receive", false, "no sink"); return }
        let before = WinAgentLink.stats, shows = app.showRequests, fg = GetForegroundWindow()
        let good = "poketokenbar://agent?state=waiting&label=selftest-receive&message=FIXTURE%20question"
        let accepted = send(sink, tag: AgentLinkRules.copyDataTag, bytes: utf16(good))
        let refusals: [(String, LRESULT)] = [
            ("another tag", send(sink, tag: AgentLinkRules.copyDataTag ^ 1, bytes: utf16(good))),
            ("no tag", send(sink, tag: 0, bytes: utf16(good))),
            ("half a unit", send(sink, tag: AgentLinkRules.copyDataTag, bytes: Array(utf16(good).dropLast()))),
            ("empty", send(sink, tag: AgentLinkRules.copyDataTag, bytes: [])),
            ("a size and no data", send(sink, tag: AgentLinkRules.copyDataTag, bytes: nil, count: 64)),
            ("a NUL inside", send(sink, tag: AgentLinkRules.copyDataTag, bytes: utf16("poketokenbar://agent?state=done\u{0}x"))),
            ("over the cap", send(sink, tag: AgentLinkRules.copyDataTag,
                                  bytes: utf16("poketokenbar://agent?state=done&message=" + String(repeating: "a", count: AgentLinkRules.maxLength)))),
            ("another host", send(sink, tag: AgentLinkRules.copyDataTag, bytes: utf16("poketokenbar://open?state=done"))),
            ("a file path", send(sink, tag: AgentLinkRules.copyDataTag, bytes: utf16(#"C:\Windows\System32\cmd.exe"#))),
        ]
        let after = WinAgentLink.stats
        let refusedAll = refusals.allSatisfy { $0.1 == 0 }
        let counted = after.received - before.received == 1 + refusals.count && after.accepted - before.accepted == 1
            && after.refused - before.refused == refusals.count
        let parsed = WinAgentLink.lastAccepted == AgentLinkRules.event(fromLink: good)
        let quiet = app.showRequests == shows && GetForegroundWindow() == fg
        r.add("link.receive", accepted == 1 && refusedAll && counted && parsed && quiet,
              "a tagged FIXTURE link -> taken=\(accepted == 1), parsed as the Mac parses it=\(parsed); refused (answer 0): "
              + refusals.map { "\($0.0)=\($0.1 == 0)" }.joined(separator: ", ")
              + "; counted received/accepted/refused \(after.received - before.received)/\(after.accepted - before.accepted)/\(after.refused - before.refused)=\(counted); "
              + "no popover, foreground kept=\(quiet)")
    }

    // MARK: - link.forward: a start with a link hands it over and ends; nothing else of its command line is read

    static func forwardCheck(_ r: WindowsSelftest.Recorder, _ app: WindowsAppDelegate) async {
        var notes: [String] = []
        var ok = true
        let shows = app.showRequests
        // CI: the app's own pet on, so the event is seen to arrive where the Mac sends it (`handleAgentEvent`).
        let petWas = app.store.floatingPetEnabled, agentsWere = app.store.floatingPetAgentActivity
        if WindowsSelftest.onCI {
            app.store.floatingPetEnabled = true
            app.store.floatingPetAgentActivity = true
            _ = await WindowsSelftest.waitUntil(timeout: 3) { WinFloatingPet.current?.window != nil }
        }
        defer {
            WinFloatingPet.current?.acknowledgeAgents()
            if let pet = WinFloatingPet.current {
                for label in ["selftest-forward", "selftest-inject"] {
                    if let e = AgentLinkRules.event(fromLink: "poketokenbar://agent?state=idle&label=\(label)") { pet.handleAgentEvent(e) }
                }
            }
            app.store.floatingPetEnabled = petWas
            app.store.floatingPetAgentActivity = agentsWere
        }
        let link = "poketokenbar://agent?state=waiting&label=selftest-forward&message=FIXTURE%20from%20a%20second%20start"
        let a0 = WinAgentLink.stats.accepted
        let plain = await start([AgentLinkRules.flag, link])
        let took = await WindowsSelftest.waitUntil(timeout: 3) { WinAgentLink.stats.accepted == a0 + 1 }
        let arrived = !WindowsSelftest.onCI
            || WinFloatingPet.current?.extras.flow.summary.waiting == AgentActivitySummary.Note(label: "selftest-forward", message: "FIXTURE from a second start")
        let plainOK = plain.code == 0 && took && arrived && WinAgentLink.lastAccepted == AgentLinkRules.event(fromLink: link)
        ok = ok && plainOK
        notes.append("start with a FIXTURE link -> exit \(plain.code.map(String.init) ?? "none") in \(plain.ms) ms, taken by this app=\(took), "
                     + (WindowsSelftest.onCI ? "on the pet's waiting bubble=\(arrived)" : "the pet: skipped (CI not set)"))
        // A link that closes its quotes and adds flags: the whole start is dropped, nothing of it is read (a second start would
        // open the popover; the selftest flag would switch the settings suite).
        let injected = #"poketokenbar://agent?state=waiting&label=selftest-inject""#
        let r1 = WinAgentLink.stats.received
        let inj = await start([AgentLinkRules.flag, injected, "--selftest-second", "--set-team-code", "FIXTURE"])
        await WindowsSelftestPopoverPet.wait(0.3)
        let injOK = inj.code == 0 && WinAgentLink.stats.received == r1
        ok = ok && injOK
        notes.append("link + '--selftest-second --set-team-code' -> exit \(inj.code.map(String.init) ?? "none") (a second start would be 3), nothing sent=\(injOK)")
        // A bare link as the first argument (another program's registration, the old form): dropped, never the app's flags.
        let r3 = WinAgentLink.stats.received
        let bare = await start([link, "--selftest-second"])
        await WindowsSelftestPopoverPet.wait(0.3)
        let bareOK = bare.code == 0 && WinAgentLink.stats.received == r3
        ok = ok && bareOK
        notes.append("a bare link without --agent-link -> exit \(bare.code.map(String.init) ?? "none"), nothing sent=\(bareOK)")
        // A link the Mac's parser refuses: the start ends without sending anything.
        let r2 = WinAgentLink.stats.received
        let bad = await start([AgentLinkRules.flag, "poketokenbar://agent?state=format-c"])
        await WindowsSelftestPopoverPet.wait(0.3)
        let badOK = bad.code == 0 && WinAgentLink.stats.received == r2
        ok = ok && badOK
        notes.append("an unknown state -> exit \(bad.code.map(String.init) ?? "none"), nothing sent=\(badOK)")
        let popoverOK = app.showRequests == shows
        ok = ok && popoverOK
        notes.append("the popover was never asked for=\(popoverOK)")
        r.add("link.forward", ok, notes.joined(separator: "; "))
    }

    /// A copy of this exe with `arguments` (and `environment` over this process's), waited for: its exit code and how long.
    static func start(_ arguments: [String], environment: [String: String] = [:]) async -> (code: DWORD?, ms: Int, pid: Int32?) {
        let began = Date()
        guard let child = try? WindowsSelftest.Helper.start(arguments, ready: false, environment: environment) else { return (nil, 0, nil) }
        let code = await child.waitExit(timeout: 15)
        if code == nil { child.kill() }
        child.close()
        return (code, Int(Date().timeIntervalSince(began) * 1000), child.pid)
    }

    /// The PokeTokenBar processes whose recorded parent is `parent` (a clean start's app).
    static func children(of parent: DWORD) -> [DWORD] {
        let snapshot = CreateToolhelp32Snapshot(DWORD(TH32CS_SNAPPROCESS), 0)
        guard snapshot != INVALID_HANDLE_VALUE else { return [] }
        defer { CloseHandle(snapshot) }
        var out: [DWORD] = []
        var entry = PROCESSENTRY32W()
        entry.dwSize = DWORD(MemoryLayout<PROCESSENTRY32W>.size)
        if Process32FirstW(snapshot, &entry) {
            repeat {
                let name = withUnsafeBytes(of: entry.szExeFile) { String(decoding: $0.bindMemory(to: UInt16.self).prefix { $0 != 0 }, as: UTF16.self) }
                if entry.th32ParentProcessID == parent, name.caseInsensitiveCompare("PokeTokenBar.exe") == .orderedSame { out.append(entry.th32ProcessID) }
            } while Process32NextW(snapshot, &entry)
        }
        return out
    }

    // MARK: - link.coldStart: no app for the state folder (review I1, I2, M2)

    /// A link start finding no app: a well-formed one starts the app clean (a new PokeTokenBar process, its child, while the
    /// link start's own state folder stays untouched: the clean start has the user's fresh environment, not this one's
    /// PTB_STATE_DIR); one with a smuggled flag starts nothing and writes nothing. CI only: the clean start is the real app on
    /// the runner's default profile (stopped at once); a person's PC keeps its own app alone.
    static func coldStartCheck(_ r: WindowsSelftest.Recorder) async {
        guard WindowsSelftest.onCI else {
            r.add("link.coldStart", true, "skipped: CI not set (a clean start would start the app on this PC's own profile)")
            return
        }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-link-cold-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        func folder(_ name: String) -> URL {
            let dir = base.appendingPathComponent(name, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        func written(_ dir: URL) -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? ["unreadable"] }
        var notes: [String] = []
        // A smuggled flag with no app for its state folder: dropped whole (no clean start, no settings suite switched).
        let smuggledDir = folder("smuggled")
        let smuggled = await start([AgentLinkRules.flag, #"poketokenbar://agent?state=done""#, "--selftest-x", ""], environment: ["PTB_STATE_DIR": smuggledDir.path])
        await WindowsSelftestPopoverPet.wait(1)
        let smuggledChildren = smuggled.pid.map { children(of: DWORD($0)) } ?? []
        let smuggledOK = smuggled.code == 0 && smuggledChildren.isEmpty && written(smuggledDir).isEmpty
        notes.append("smuggled flag, no app -> exit \(smuggled.code.map(String.init) ?? "none"), started \(smuggledChildren.count) app(s), wrote \(written(smuggledDir))=\(smuggledOK)")
        // Well formed, no app for its state folder: the app started clean, the link start's folder untouched.
        let cleanDir = folder("clean")
        let clean = await start([AgentLinkRules.flag, "poketokenbar://agent?state=done&label=selftest-cold"], environment: ["PTB_STATE_DIR": cleanDir.path])
        var started: [DWORD] = []
        _ = await WindowsSelftest.waitUntil(timeout: 5) {
            started = clean.pid.map { children(of: DWORD($0)) } ?? []
            return !started.isEmpty
        }
        for pid in started {
            if let h = OpenProcess(DWORD(0x0001 | 0x0010_0000) /* TERMINATE | SYNCHRONIZE */, false, pid) {
                _ = TerminateProcess(h, 0)
                _ = WaitForSingleObject(h, 5_000)
                _ = CloseHandle(h)
            }
        }
        let cleanOK = clean.code == 0 && started.count == 1 && written(cleanDir).isEmpty
        notes.append("well formed, no app -> exit \(clean.code.map(String.init) ?? "none") in \(clean.ms) ms, started \(started.count) clean app(s) (stopped), "
                     + "the link start's folder wrote \(written(cleanDir))=\(cleanOK)")
        r.add("link.coldStart", smuggledOK && cleanOK, notes.joined(separator: "; "))
    }

    // MARK: - link.registration: the installer's key (read only, and only from the registered copy)

    /// The registered command, nil when there is none (read only: `WinRegistry.string`).
    static func registeredCommand() -> String? {
        if case .value(let command) = WinRegistry.string(#"Software\Classes\poketokenbar\shell\open\command"#, "") { return command }
        return nil
    }

    /// True when this copy is the registered one (the shell check may then run).
    @discardableResult
    static func registrationCheck(_ r: WindowsSelftest.Recorder) -> Bool {
        let exe = WindowsSelftest.executablePath()
        let expected = "\"\(exe)\" \(AgentLinkRules.flag) \"%1\""
        guard let command = registeredCommand() else {
            r.add("link.registration", true, "skipped: no poketokenbar: link registered (not an installed copy)")
            return false
        }
        guard command.lowercased() == expected.lowercased() else {
            r.add("link.registration", true, "skipped: the link starts another copy ('\(command)'), not this one ('\(exe)')")
            return false
        }
        let protocolValue: Bool = { if case .value = WinRegistry.string(#"Software\Classes\poketokenbar"#, "URL Protocol") { return true } else { return false } }()
        r.add("link.registration", protocolValue, "HKCU\\Software\\Classes\\poketokenbar: command '\(command)' starts this copy with the link as its one argument; 'URL Protocol' present=\(protocolValue)")
        return protocolValue
    }

    // MARK: - link.shell: a link opened through the shell reaches this app (the runner's installed copy)

    static func shellCheck(_ r: WindowsSelftest.Recorder, _ app: WindowsAppDelegate, registered: Bool) async {
        guard WindowsSelftest.onCI, registered else {
            r.add("link.shell", true, "skipped: \(WindowsSelftest.onCI ? "this copy is not the registered one" : "CI not set") (the shell would start the registered app)")
            return
        }
        let a0 = WinAgentLink.stats.accepted, shows = app.showRequests
        let link = "poketokenbar://agent?state=done&label=selftest-shell&message=FIXTURE%20through%20the%20shell"
        let result = ShellExecuteW(nil, WinStr.w("open"), WinStr.w(link), nil, nil, 4 /* SW_SHOWNOACTIVATE */)
        let code = Int(bitPattern: result)
        let took = await WindowsSelftest.waitUntil(timeout: 15) { WinAgentLink.stats.accepted > a0 }
        let same = WinAgentLink.lastAccepted == AgentLinkRules.event(fromLink: link)
        r.add("link.shell", code > 32 && took && same && app.showRequests == shows,
              "ShellExecuteW(open, FIXTURE link) = \(code) (> 32 is started) -> taken by this app within 15 s=\(took), the same event=\(same), no popover=\(app.showRequests == shows)")
    }
}
#endif
