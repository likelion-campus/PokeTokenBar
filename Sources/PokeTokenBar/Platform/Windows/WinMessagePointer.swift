#if os(Windows)
import WinSDK

/// A pointer a window message carries in `lParam` (`WM_POWERBROADCAST`, `WM_DPICHANGED`, `WM_NOTIFY`). Windows fills it in for its own
/// messages, but any process of the same user can send these messages to our windows with whatever `lParam` it likes, and a message sent
/// across processes is not marshalled for them: the address is read as ours. Returns the pointer only when `bytes` bytes at it lie in one
/// committed, readable region of this process; otherwise nil, so a crafted value is dropped instead of crashing the app.
enum WinMessagePointer {
    static func readable(_ lParam: LPARAM, bytes: Int) -> UnsafeRawPointer? {
        guard let pointer = UnsafeRawPointer(bitPattern: Int(lParam)) else { return nil }
        var info = MEMORY_BASIC_INFORMATION()
        guard VirtualQuery(pointer, &info, SIZE_T(MemoryLayout<MEMORY_BASIC_INFORMATION>.size)) != 0,
              info.State == 0x1000 /* MEM_COMMIT */,
              info.Protect & 0x101 == 0 /* PAGE_NOACCESS | PAGE_GUARD */,
              info.Protect & 0xEE != 0 /* a readable protection (not execute-only) */ else { return nil }
        let end = UInt(bitPattern: info.BaseAddress) + UInt(info.RegionSize)
        let start = UInt(bitPattern: pointer)
        return start + UInt(bytes) <= end ? pointer : nil
    }
}
#endif
