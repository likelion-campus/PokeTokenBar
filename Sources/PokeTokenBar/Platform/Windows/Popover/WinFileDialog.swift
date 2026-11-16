#if os(Windows)
import CWinShim
import Foundation
import WinSDK

/// The common file dialogs (`IFileOpenDialog` / `IFileSaveDialog`, in `CWinShim/filedialog.cpp`) as the popover's Backup &
/// transfer rows use them (stage 7 Task 15, D17). Owned by the popover, so it stays above it and the popover keeps its place;
/// opened from the click's window message (the caller is a control's `onClick`), and run inside `WinModalPump` because the
/// dialog's modal loop starves the main queue otherwise (team heartbeats, store refresh). The dialog opens in Documents the
/// first time (the shell resolves a OneDrive-redirected one) and then where the user last was. A path with spaces or
/// non-ASCII characters is UTF-16 from the dialog to the `URL`.
@MainActor enum WinFileDialog {
    /// Dialogs shown since launch, and the one open now (the selftest reads them).
    private(set) static var opened = 0
    private(set) static var isOpen = false
    /// The last result code (0 chosen, 1 cancelled, else an HRESULT) for the selftest and the log.
    private(set) static var lastCode: Int32 = 0
    /// The file the last dialog returned (the selftest compares it with what it asked for).
    private(set) static var lastChosen: URL?
    /// Selftest only: the open dialog's name field.
    static func setFileNameForTesting(_ name: String) -> Int32 { WinStr.w(name).withUnsafeBufferPointer { ptb_file_dialog_set_file_name($0.baseAddress) } }

    /// The chosen file, nil when cancelled or the dialog could not be shown (logged).
    static func choose(save: Bool, owner: HWND?, title: String, suggestedName: String?, filterName: String) -> URL? {
        guard !isOpen else { return nil }   // one at a time (a second click cannot arrive: the owner is disabled)
        isOpen = true
        opened += 1
        currentOwner = owner
        WinModalPump.begin("dialog")
        defer {
            WinModalPump.end("dialog")
            isOpen = false
            currentOwner = nil
        }
        let titleW = WinStr.w(title), nameW = WinStr.w(suggestedName ?? ""), filterW = WinStr.w(filterName)
        let specW = WinStr.w("*.json"), extW = WinStr.w("json")
        var out = [UInt16](repeating: 0, count: 32_768)
        let ownerPointer = owner.map { UnsafeMutableRawPointer($0) }
        let code: Int32 = titleW.withUnsafeBufferPointer { t in
            nameW.withUnsafeBufferPointer { n in
                filterW.withUnsafeBufferPointer { f in
                    specW.withUnsafeBufferPointer { s in
                        extW.withUnsafeBufferPointer { e in
                            out.withUnsafeMutableBufferPointer { o in
                                ptb_file_dialog(ownerPointer, save ? 1 : 0, t.baseAddress, save ? n.baseAddress : nil, f.baseAddress,
                                                s.baseAddress, e.baseAddress, o.baseAddress, UInt32(o.count))
                            }
                        }
                    }
                }
            }
        }
        lastCode = code
        guard code == 0 else {
            if code != 1 { AppLog.write("file dialog failed (\(save ? "save" : "open")): HRESULT 0x\(String(UInt32(bitPattern: code), radix: 16))") }
            return nil
        }
        let length = out.firstIndex(of: 0) ?? out.count
        let chosen = URL(fileURLWithPath: String(decoding: out[0..<length], as: UTF16.self))
        lastChosen = chosen
        return chosen
    }

    private static var currentOwner: HWND?

    /// Closes the open dialog as a cancel (the exit path, the selftest). `IFileDialog::Close` first; on the runner the dialog
    /// stayed open after it, so the dialogs owned by the popover also get `WM_CLOSE`, which ends them as the close box does.
    static func closeOpenDialog() {
        _ = ptb_file_dialog_close()
        guard let owner = currentOwner else { return }
        var previous: HWND?
        let cls = WinStr.w("#32770")
        while let h = FindWindowExW(nil, previous, cls, nil) {
            previous = h
            if GetWindow(h, UINT(GW_OWNER)) == owner { _ = PostMessageW(h, UINT(WM_CLOSE), 0, 0) }
        }
    }
}
#endif
