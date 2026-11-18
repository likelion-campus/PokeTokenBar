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
    static let names = ["link.receive", "link.forward", "link.registration", "link.shell"]

    static func run(_ r: WindowsSelftest.Recorder, _ app: WindowsAppDelegate) async {
        receiveCheck(r, app)
        await forwardCheck(r, app)
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
        func start(_ arguments: [String], _ name: String) async -> (code: DWORD?, ms: Int) {
            let began = Date()
            guard let child = try? WindowsSelftest.Helper.start(arguments, ready: false) else { return (nil, 0) }
            let code = await child.waitExit(timeout: 15)
            if code == nil { child.kill() }
            child.close()
            return (code, Int(Date().timeIntervalSince(began) * 1000))
        }
        let link = "poketokenbar://agent?state=waiting&label=selftest-forward&message=FIXTURE%20from%20a%20second%20start"
        let a0 = WinAgentLink.stats.accepted
        let plain = await start([link], "plain")
        let took = await WindowsSelftest.waitUntil(timeout: 3) { WinAgentLink.stats.accepted == a0 + 1 }
        let arrived = !WindowsSelftest.onCI
            || WinFloatingPet.current?.extras.flow.summary.waiting == AgentActivitySummary.Note(label: "selftest-forward", message: "FIXTURE from a second start")
        let plainOK = plain.code == 0 && took && arrived && WinAgentLink.lastAccepted == AgentLinkRules.event(fromLink: link)
        ok = ok && plainOK
        notes.append("start with a FIXTURE link -> exit \(plain.code.map(String.init) ?? "none") in \(plain.ms) ms, taken by this app=\(took), "
                     + (WindowsSelftest.onCI ? "on the pet's waiting bubble=\(arrived)" : "the pet: skipped (CI not set)"))
        // A link that closes its quotes and adds a flag: the flag is never read (it would make a second start open the popover).
        let injected = #"poketokenbar://agent?state=waiting&label=selftest-inject""#
        let a1 = WinAgentLink.stats.accepted, r1 = WinAgentLink.stats.received
        let inj = await start([injected, "--selftest-second", "--set-team-code", "FIXTURE"], "injected")
        _ = await WindowsSelftest.waitUntil(timeout: 2) { WinAgentLink.stats.received > r1 }
        let parses = AgentLinkRules.event(fromLink: injected) != nil
        let injOK = inj.code == 0 && WinAgentLink.stats.accepted == a1 + (parses ? 1 : 0)
        ok = ok && injOK
        notes.append("link + '--selftest-second --set-team-code' -> exit \(inj.code.map(String.init) ?? "none") (a second start would be 3), "
                     + "link \(parses ? "taken" : "refused") as it parses=\(injOK)")
        // A link the Mac's parser refuses: the start ends without sending anything.
        let r2 = WinAgentLink.stats.received
        let bad = await start(["poketokenbar://agent?state=format-c"], "bad")
        await WindowsSelftestPopoverPet.wait(0.3)
        let badOK = bad.code == 0 && WinAgentLink.stats.received == r2
        ok = ok && badOK
        notes.append("an unknown state -> exit \(bad.code.map(String.init) ?? "none"), nothing sent=\(badOK)")
        let popoverOK = app.showRequests == shows
        ok = ok && popoverOK
        notes.append("the popover was never asked for=\(popoverOK)")
        r.add("link.forward", ok, notes.joined(separator: "; "))
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
        let expected = "\"\(exe)\" \"%1\""
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
