#if os(Windows)
import Foundation
import WinSDK

/// The clipboard's text for the popover (stage 7 Task 6): `CF_UNICODETEXT` in and out. Out is only for the team code's Copy
/// button, on an explicit click: the code is the team's shared key, so the copy asks the clipboard history (Win+V) and the
/// cloud clipboard not to keep it (`ExcludeClipboardContentFromMonitorProcessing`, `CanIncludeInClipboardHistory` and
/// `CanUploadToCloudClipboard` = 0, the formats Microsoft documents for this). Nothing here logs the text.
enum WinTextClipboard {
    private static let unicodeText: UINT = 13  // CF_UNICODETEXT
    private static let moveable: UINT = 0x0002  // GMEM_MOVEABLE

    /// The text on the clipboard, nil when there is none (an image, a file list, a busy clipboard).
    static func read() -> String? { WinClipboardText.read() }

    /// Replaces the clipboard's content with `text`. `secret`: kept out of the clipboard history and the cloud clipboard.
    /// true when the clipboard holds the text afterwards.
    @discardableResult
    static func write(_ text: String, secret: Bool, owner: HWND?) -> Bool {
        guard OpenClipboard(owner) else {
            AppLog.write("clipboard: could not open it (\(GetLastError()))")
            return false
        }
        defer { _ = CloseClipboard() }
        _ = EmptyClipboard()
        let units = Array(text.utf16) + [0]
        guard let handle = GlobalAlloc(moveable, SIZE_T(units.count * MemoryLayout<UInt16>.size)) else { return false }
        guard let memory = GlobalLock(handle) else {
            _ = GlobalFree(handle)
            return false
        }
        units.withUnsafeBufferPointer { memory.copyMemory(from: $0.baseAddress!, byteCount: units.count * MemoryLayout<UInt16>.size) }
        _ = GlobalUnlock(handle)
        guard SetClipboardData(unicodeText, handle) != nil else {
            _ = GlobalFree(handle)  // the clipboard did not take it
            AppLog.write("clipboard: could not set the text (\(GetLastError()))")
            return false
        }
        if secret {
            for name in ["ExcludeClipboardContentFromMonitorProcessing", "CanIncludeInClipboardHistory", "CanUploadToCloudClipboard"] {
                setFlag(name)
            }
        }
        return true
    }

    /// A registered format holding a DWORD 0 (the documented way to opt out of history and cloud copies).
    private static func setFlag(_ name: String) {
        let format = RegisterClipboardFormatW(WinStr.w(name))
        guard format != 0, let handle = GlobalAlloc(moveable, SIZE_T(MemoryLayout<DWORD>.size)), let memory = GlobalLock(handle) else { return }
        memory.storeBytes(of: DWORD(0), as: DWORD.self)
        _ = GlobalUnlock(handle)
        if SetClipboardData(format, handle) == nil { _ = GlobalFree(handle) }
    }

    /// Whether `name`'s format is on the clipboard now (the selftest checks the secret copy carries the opt-outs).
    static func hasFormat(_ name: String) -> Bool {
        let format = RegisterClipboardFormatW(WinStr.w(name))
        return format != 0 && IsClipboardFormatAvailable(format)
    }
}
#endif
