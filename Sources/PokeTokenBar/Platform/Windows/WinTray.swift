#if os(Windows)
import Foundation
import WinSDK

/// The notification-area icon (one per app, id 1) on the sink window, in `NOTIFYICON_VERSION_4` behaviour.
@MainActor final class WinTray {
    enum BalloonEvent { case shown, clicked, hidden, timedOut }

    /// Must not collide with `WM_APP + 1` (`WinSingleInstance.showMessage`) or the selftest's `+0x20/+0x21`.
    static let callbackMessage = UINT(WM_APP) + 0x30
    private static let iconID: UINT = 1
    // Tray notification codes (v4): the low word of lParam.
    private static let ninSelect: UInt32 = 0x400, ninKeySelect: UInt32 = 0x401
    private static let ninBalloonShow: UInt32 = 0x402, ninBalloonHide: UInt32 = 0x403, ninBalloonTimeout: UInt32 = 0x404, ninBalloonUserClick: UInt32 = 0x405

    private let window: WinSinkWindow
    private var icon: WinIcon?
    private var tip = ""

    private(set) var isPresent = false
    /// Stage 7 Task 4: the icon was chosen. `NOTIFYICON_VERSION_4` reports a left click as `NIN_SELECT` and Space / Enter on
    /// the focused icon as `NIN_KEYSELECT`, each with a screen point in `wParam` (the click, or the icon for a key). The
    /// mouse messages that come with a click are not selects (a click would toggle twice), except on the legacy version-0
    /// behaviour when `NIM_SETVERSION` failed, where `WM_LBUTTONUP` is the only signal.
    enum Select {
        case click(POINT), key(POINT)
        var point: POINT { switch self { case .click(let p), .key(let p): return p } }
    }
    var onSelect: ((Select) -> Void)?
    var onContextMenu: ((POINT) -> Void)?
    var onBalloonEvent: ((BalloonEvent) -> Void)?

    // What the selftest reads.
    private(set) var addCount = 0
    private(set) var lastAddOK = false
    private(set) var lastVersionOK = false
    private(set) var lastModifyOK = false
    private(set) var lastDeleteOK = false
    private(set) var lastAnchorResult: Int32 = -1
    private(set) var lastTipUnits = 0
    private(set) var lastBalloonOK = false
    private(set) var lastBalloonFlags: DWORD = 0
    /// NIN_BALLOONSHOW notifications received, whatever balloon they were for (the selftest's control experiment).
    private(set) var shownEventCount = 0
    /// Selects and context-menu requests the shell sent, and the last one's point (the popover selftest reads them).
    private(set) var selectCount = 0
    /// Every callback the shell sent the icon (the selftest's idle windows report it).
    private(set) var callbackCount = 0
    private(set) var keySelectCount = 0
    private(set) var contextMenuCount = 0
    private(set) var lastSetFocusOK = false
    /// The point of the last select (the click, or the icon for a key; v4).
    private(set) var lastEventPoint: POINT?
    /// The first selects of a run go to the log (which events one Enter or one click gives on a PC; bounded).
    private var loggedSelects = 0

    init(window: WinSinkWindow) {
        self.window = window
        window.on(Self.callbackMessage) { [weak self] wParam, lParam in
            self?.handle(wParam: wParam, lParam: lParam)
            return 0
        }
        // Explorer restarted: its icons are gone, ours must be added again.
        window.onRegistered("TaskbarCreated") { [weak self] in self?.readd() }
    }

    @discardableResult
    func add() -> Bool {
        var nid = base(NIF_MESSAGE | NIF_ICON | NIF_TIP | 0x80 /* NIF_SHOWTIP */)
        nid.uCallbackMessage = Self.callbackMessage
        nid.hIcon = icon?.handle ?? Self.defaultIcon
        fill(&nid.szTip, tip, capacity: 128)
        lastTipUnits = min(tip.utf16.count, TrayMenuModel.tipLimit)
        let ok = Shell_NotifyIconW(DWORD(NIM_ADD), &nid)
        addCount += 1
        lastAddOK = ok
        if !ok { AppLog.write("tray: NIM_ADD failed: \(GetLastError())") }
        isPresent = ok
        if ok {
            nid.uVersion = UINT(NOTIFYICON_VERSION_4)
            lastVersionOK = Shell_NotifyIconW(DWORD(NIM_SETVERSION), &nid)
            if !lastVersionOK { AppLog.write("tray: NIM_SETVERSION failed: \(GetLastError())") }
        }
        return ok
    }

    func remove() {
        guard isPresent else { return }
        var nid = base(0)
        lastDeleteOK = Shell_NotifyIconW(DWORD(NIM_DELETE), &nid)
        isPresent = false
    }

    /// After `TaskbarCreated`: delete first (a no-op when the shell lost the icon), then add.
    func readd() {
        var nid = base(0)
        _ = Shell_NotifyIconW(DWORD(NIM_DELETE), &nid)
        isPresent = false
        add()
    }

    func setIcon(_ newIcon: WinIcon?) {
        icon = newIcon
        guard isPresent else { return }
        var nid = base(NIF_ICON)
        nid.hIcon = icon?.handle ?? Self.defaultIcon
        lastModifyOK = Shell_NotifyIconW(DWORD(NIM_MODIFY), &nid)
    }

    /// Clipped to 127 UTF-16 units.
    func setTip(_ text: String) {
        tip = TrayMenuModel.clipped(text)
        lastTipUnits = tip.utf16.count
        guard isPresent else { return }
        var nid = base(NIF_TIP | 0x80 /* NIF_SHOWTIP */)
        fill(&nid.szTip, tip, capacity: 128)
        lastModifyOK = Shell_NotifyIconW(DWORD(NIM_MODIFY), &nid)
    }

    func showBalloon(title: String, body: String, sound: Bool, kind: BalloonQueue.Kind = .app, extraInfoFlags: DWORD = 0) -> Bool {
        guard isPresent else { return false }
        var nid = base(NIF_INFO)
        fill(&nid.szInfoTitle, title, capacity: 64)
        fill(&nid.szInfo, body, capacity: 256)
        nid.dwInfoFlags = BalloonFlags.infoFlags(kind: kind, sound: sound) | extraInfoFlags  // extra: CI control experiments only
        lastBalloonFlags = nid.dwInfoFlags
        lastBalloonOK = Shell_NotifyIconW(DWORD(NIM_MODIFY), &nid)
        return lastBalloonOK
    }

    /// Gives the keyboard focus back to the notification area (`NIM_SETFOCUS`): what an icon does when its UI, opened from the
    /// keyboard, is dismissed (stage 7 Task 4: the popover closed with Escape after a key select).
    @discardableResult
    func returnFocus() -> Bool {
        guard isPresent else { return false }
        var nid = base(0)
        lastSetFocusOK = Shell_NotifyIconW(DWORD(3 /* NIM_SETFOCUS */), &nid)
        return lastSetFocusOK
    }

    /// The icon's screen rectangle (stage 7 places the popover with it); nil when the shell cannot say.
    func anchorRect() -> RECT? {
        var id = NOTIFYICONIDENTIFIER()
        id.cbSize = DWORD(MemoryLayout<NOTIFYICONIDENTIFIER>.size)
        id.hWnd = window.hwnd
        id.uID = Self.iconID
        var rect = RECT()
        lastAnchorResult = Shell_NotifyIconGetRect(&id, &rect)
        return lastAnchorResult == 0 ? rect : nil
    }

    // MARK: -

    private static let defaultIcon: HICON? = LoadIconW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))  // IDI_APPLICATION, shared

    private func base(_ flags: Int32) -> NOTIFYICONDATAW {
        var nid = NOTIFYICONDATAW()
        nid.cbSize = DWORD(MemoryLayout<NOTIFYICONDATAW>.size)
        nid.hWnd = window.hwnd
        nid.uID = Self.iconID
        nid.uFlags = UINT(flags)
        return nid
    }

    private static func cursor() -> POINT {
        var p = POINT()
        _ = GetCursorPos(&p)
        return p
    }

    private func fill<T>(_ field: inout T, _ text: String, capacity: Int) {
        let units = Array(TrayMenuModel.clipped(text, maxUnits: capacity - 1).utf16)
        withUnsafeMutableBytes(of: &field) { raw in
            let p = raw.bindMemory(to: UInt16.self)
            for i in 0..<min(capacity, p.count) { p[i] = i < units.count ? units[i] : 0 }
        }
    }

    private func handle(wParam: WPARAM, lParam: LPARAM) {
        let event = UInt32(truncatingIfNeeded: lParam) & 0xFFFF
        callbackCount += 1
        let x = Int16(truncatingIfNeeded: wParam & 0xFFFF), y = Int16(truncatingIfNeeded: (wParam >> 16) & 0xFFFF)
        let point = POINT(x: Int32(x), y: Int32(y))  // v4: the event's screen point
        if loggedSelects < 20, [Self.ninSelect, Self.ninKeySelect, UInt32(WM_CONTEXTMENU)].contains(event) {
            loggedSelects += 1
            AppLog.write("tray: \(event == Self.ninSelect ? "NIN_SELECT" : event == Self.ninKeySelect ? "NIN_KEYSELECT" : "WM_CONTEXTMENU") at \(point.x),\(point.y)")
        }
        switch event {
        case Self.ninSelect where lastVersionOK:
            selectCount += 1
            lastEventPoint = point
            onSelect?(.click(point))
        case Self.ninKeySelect where lastVersionOK:
            keySelectCount += 1
            lastEventPoint = point
            onSelect?(.key(point))
        case UInt32(WM_LBUTTONUP) where !lastVersionOK:  // version 0 sends no NIN_SELECT and no point
            selectCount += 1
            lastEventPoint = Self.cursor()
            onSelect?(.click(Self.cursor()))
        case UInt32(WM_CONTEXTMENU):
            contextMenuCount += 1
            onContextMenu?(point)
        case UInt32(WM_RBUTTONUP) where !lastVersionOK:
            contextMenuCount += 1
            onContextMenu?(Self.cursor())
        case Self.ninBalloonShow:
            shownEventCount += 1
            onBalloonEvent?(.shown)
        case Self.ninBalloonUserClick: onBalloonEvent?(.clicked)
        case Self.ninBalloonHide: onBalloonEvent?(.hidden)
        case Self.ninBalloonTimeout: onBalloonEvent?(.timedOut)
        default: break
        }
    }
}

/// A native popup menu. The foreground dance is required for it to dismiss on an outside click: `owner` takes the foreground
/// for the menu, in answer to a click on the tray icon (the taskbar had the foreground already) or inside the popover (it has
/// it). The floating pet never takes the foreground, so the user's window had it: its menu opts into `giveBack` and the
/// foreground goes back there afterwards (stage 7 Task 22). Both activations live here, in `run`, the one allowed site
/// (`WindowsSeamScanTests.activationSites`).
@MainActor enum WinPopupMenu {
    /// The open menu's handle while `run` is inside `TrackPopupMenu` (the selftest's key driver reads it).
    nonisolated(unsafe) static var openMenuBits = 0

    /// Whether the last `run` gave the foreground back (the floating pet's stats read it).
    private(set) static var gaveBack = false

    /// Index into `items` of the chosen entry, nil when dismissed. `giveBack` (stage 7 Task 22): asked after the menu with the
    /// choice and the window that had the foreground before it, when the owner still has it and that window is still there
    /// and visible; true gives the foreground back to that window, and only to it.
    static func run(_ items: [TrayMenuModel.Item?], at point: POINT, owner: HWND, below: Bool = false,  // below: stage 7 Task 12 (a menu that opens under its label)
                    giveBack: ((_ chosen: Int?, _ previous: HWND) -> Bool)? = nil) -> Int? {
        gaveBack = false
        guard openMenuBits == 0 else { return nil }  // a menu is already open: ignore the request
        guard let menu = CreatePopupMenu() else { return nil }
        defer { openMenuBits = 0; DestroyMenu(menu) }
        for (index, item) in items.enumerated() {
            guard let item else {
                _ = AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil)
                continue
            }
            let flags = UINT(MF_STRING) | UINT(item.enabled ? MF_ENABLED : MF_GRAYED) | UINT(item.checked ? MF_CHECKED : MF_UNCHECKED)
            let title = item.title.replacingOccurrences(of: "&", with: "&&")  // no mnemonics from user-visible text
            _ = WinStr.w(title).withUnsafeBufferPointer { AppendMenuW(menu, flags, UINT_PTR(index + 1), $0.baseAddress) }
        }
        let previous = giveBack == nil ? nil : GetForegroundWindow()  // stage 7 Task 22
        _ = SetForegroundWindow(owner)
        openMenuBits = Int(bitPattern: menu)
        // The SDK import turns BOOL into Bool, which would lose the command id TPM_RETURNCMD returns: call it as Int32.
        typealias TrackFn = @convention(c) (HMENU?, UINT, Int32, Int32, Int32, HWND?, UnsafePointer<RECT>?) -> Int32
        guard let track = WinDynamic.symbol("user32.dll", "TrackPopupMenu", as: TrackFn.self) else { return nil }
        WinModalPump.begin("menu")  // the menu's modal loop starves the main queue; the pump serves it meanwhile
        defer { WinModalPump.end("menu") }
        let command = track(menu, UINT(TPM_RIGHTBUTTON | TPM_RETURNCMD | TPM_NONOTIFY | (below ? TPM_TOPALIGN : TPM_BOTTOMALIGN)),
                            point.x, point.y, 0, owner, nil)
        _ = PostMessageW(owner, UINT(WM_NULL), 0, 0)
        let chosen = command > 0 ? Int(command) - 1 : nil
        // --- stage 7 Task 22: the foreground back to the window that had it (begin) ---
        if let giveBack, let previous, previous != owner, GetForegroundWindow() == owner, IsWindow(previous), IsWindowVisible(previous),
           giveBack(chosen, previous) {
            gaveBack = SetForegroundWindow(previous)
        }
        // --- stage 7 Task 22 (end) ---
        return chosen
    }

    /// Position of the highlighted entry of an open menu, nil when none. Safe from any thread.
    nonisolated static func highlightedIndex(menuBits: Int, count: Int) -> Int? {
        guard let menu = HMENU(bitPattern: menuBits) else { return nil }
        for i in 0..<count where GetMenuState(menu, UINT(i), UINT(MF_BYPOSITION)) & UINT(MF_HILITE) != 0 { return i }
        return nil
    }
}
#endif
