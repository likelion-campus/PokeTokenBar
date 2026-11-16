#if os(Windows)
import CWinShim
import Foundation
import WinSDK

/// The task dialog (`TaskDialogIndirect`, comctl32 v6, in `CWinShim/filedialog.cpp`: the config struct is packed, which Swift
/// cannot import, and the entry point is looked up when called so a process without the v6 manifest still loads) for the
/// Backup & transfer confirmations and results (stage 7 Task 15, D17). Owned by the popover; run inside `WinModalPump`. Custom
/// buttons in the order given, `defaultIndex` is what Enter presses, Esc and the close box answer nil (the cancel).
@MainActor enum WinTaskDialog {
    enum Icon: Int32 { case none = 0, warning, error, information }

    private(set) static var shown = 0
    /// What the last dialog said and offered (the selftest reads them: the default button is the safe one).
    private(set) static var last: (heading: String, content: String, buttons: [String], defaultIndex: Int, icon: Icon)?
    private static var loggedUnavailable = false

    static var window: HWND? { ptb_task_dialog_window().map { $0.assumingMemoryBound(to: HWND__.self) } }

    /// The index of the pressed button; nil for Esc, the close box, or when the dialog could not be shown (a plain message
    /// box answers instead, with Cancel as its default).
    static func show(owner: HWND?, windowTitle: String = "PokeTokenBar", heading: String, content: String, icon: Icon, buttons: [String],
                     defaultIndex: Int) -> Int? {
        shown += 1
        last = (heading, content, buttons, defaultIndex, icon)
        WinModalPump.begin("dialog")
        defer { WinModalPump.end("dialog") }
        let titleW = WinStr.w(windowTitle), headingW = WinStr.w(heading), contentW = WinStr.w(content)
        let buttonsW = buttons.map { WinStr.w($0) }
        var chosen: Int32 = -1
        let ownerPointer = owner.map { UnsafeMutableRawPointer($0) }
        // The button strings must stay alive for the call: copy them into one buffer and point into it.
        var storage: [UInt16] = []
        var offsets: [Int] = []
        for b in buttonsW { offsets.append(storage.count); storage.append(contentsOf: b) }
        let code: Int32 = storage.withUnsafeBufferPointer { base in
            let pointers: [UnsafePointer<UInt16>?] = offsets.map { offset in base.baseAddress.map { $0 + offset } }
            return pointers.withUnsafeBufferPointer { list in
                titleW.withUnsafeBufferPointer { t in
                    headingW.withUnsafeBufferPointer { h in
                        contentW.withUnsafeBufferPointer { c in
                            ptb_task_dialog(ownerPointer, t.baseAddress, h.baseAddress, c.baseAddress, icon.rawValue, list.baseAddress,
                                            Int32(buttons.count), Int32(defaultIndex), &chosen)
                        }
                    }
                }
            }
        }
        if code != 0 {
            if !loggedUnavailable { AppLog.write("task dialog unavailable (HRESULT 0x\(String(UInt32(bitPattern: code), radix: 16))): a message box is used") }
            loggedUnavailable = true
            return fallback(owner: owner, title: windowTitle, heading: heading, content: content, icon: icon, buttons: buttons)
        }
        return chosen >= 0 ? Int(chosen) : nil
    }

    /// Closes the open task dialog as Esc does (the exit path, the selftest).
    static func closeOpenDialog() {
        if let w = window { _ = PostMessageW(w, 0x0466 /* TDM_CLICK_BUTTON */, 2 /* IDCANCEL */, 0) }
    }

    /// With one button: just shows it. With two: the first is OK, the second Cancel (the default, as with the task dialog).
    private static func fallback(owner: HWND?, title: String, heading: String, content: String, icon: Icon, buttons: [String]) -> Int? {
        let text = heading + "\n\n" + content
        let kind: UINT = icon == .error ? UINT(MB_ICONERROR) : icon == .warning ? UINT(MB_ICONWARNING) : UINT(MB_ICONINFORMATION)
        if buttons.count < 2 {
            _ = MessageBoxW(owner, WinStr.w(text), WinStr.w(title), UINT(MB_OK) | kind)
            return 0
        }
        let result = MessageBoxW(owner, WinStr.w(text), WinStr.w(title), UINT(MB_OKCANCEL) | UINT(MB_DEFBUTTON2) | kind)
        return result == IDOK ? 0 : nil
    }
}

/// Every dialog the Backup & transfer flows open, for the paths that must end them (the exit path).
@MainActor enum WinDialogs {
    static func closeAll() {
        WinFileDialog.closeOpenDialog()
        WinTaskDialog.closeOpenDialog()
    }
}
#endif
