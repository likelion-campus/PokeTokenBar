#if os(Windows)
import CWinShim
import Foundation
import WinSDK

/// `--selftest --dump-ui <dir>`: writes PNGs of the Windows tray UI as the CI runner renders it (sample data on a
/// headless runner, not a real PC): the tray icon at 16/24/32 px (egg and a hatched sprite), the open tray menu, and
/// the screen right after a balloon was posted. Off unless the flag is given. Every wait is bounded.
@MainActor enum WinUIDump {
    struct Bitmap: Sendable {
        let width: Int
        let height: Int
        var bgra: [UInt8]
    }

    private final class Slot: @unchecked Sendable {
        private let lock = NSLock()
        private var image: Bitmap?
        private var notes: [String] = []
        private var done = false
        func set(_ b: Bitmap?) { lock.lock(); image = b; lock.unlock() }
        func note(_ s: String) { lock.lock(); notes.append(s); lock.unlock() }
        func finish() { lock.lock(); done = true; lock.unlock() }
        var isDone: Bool { lock.lock(); defer { lock.unlock() }; return done }
        var captured: Bitmap? { lock.lock(); defer { lock.unlock() }; return image }
        var text: String { lock.lock(); defer { lock.unlock() }; return notes.joined(separator: ",") }
    }

    static func directory(from arguments: [String]) -> URL? {
        guard let i = arguments.firstIndex(of: "--dump-ui"), i + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[i + 1], isDirectory: true)
    }

    static func run(_ r: WindowsSelftest.Recorder, _ app: WindowsAppDelegate, into dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let host = app.tray else {
            r.add("ui.dump.icons", false, "no tray host")
            return
        }
        await iconDump(r, dir)
        await menuDump(r, app, host, dir)
        await balloonDump(r, host, dir)
    }

    // MARK: - icons

    private static func iconDump(_ r: WindowsSelftest.Recorder, _ dir: URL) async {
        let sizes = [16, 24, 32]
        var rows: [(String, [Bitmap])] = []
        var notes: [String] = []
        var written = 0
        let sources: [(String, Data?)] = [
            ("egg", await SpriteStore.shared.eggData()),
            ("pikachu", await SpriteStore.shared.data(speciesID: 25, animated: false, shiny: false, form: nil, back: false)),
        ]
        for (name, png) in sources {
            guard let png else { notes.append("\(name): sprite unavailable (offline)"); continue }
            var bitmaps: [Bitmap] = []
            for size in sizes {
                guard let icon = WinIcon(png: png, size: size), let bitmap = bitmap(of: icon) else {
                    notes.append("\(name)@\(size): icon build failed")
                    continue
                }
                if write(bitmap, to: dir.appendingPathComponent("icon-\(name)-\(size).png")) == 0 { written += 1 }
                bitmaps.append(bitmap)
            }
            rows.append((name, bitmaps))
        }
        let sheet = contactSheet(rows.map(\.1))
        let sheetOK = sheet.map { write($0, to: dir.appendingPathComponent("icons-sheet.png")) == 0 } ?? false
        r.add("ui.dump.icons", written >= 3 && sheetOK,
              "\(written) icon PNGs + sheet=\(sheetOK) in \(dir.path); " + notes.joined(separator: "; "))
    }

    private static func bitmap(of icon: WinIcon) -> Bitmap? {
        var w: UInt32 = 0, h: UInt32 = 0
        var out: UnsafeMutablePointer<UInt8>?
        guard ptb_icon_to_bgra(UnsafeMutableRawPointer(icon.handle), &w, &h, &out) == 0, let out else { return nil }
        defer { ptb_free(out) }
        return Bitmap(width: Int(w), height: Int(h), bgra: Array(UnsafeBufferPointer(start: out, count: Int(w * h) * 4)))
    }

    /// Each row of icons magnified 8x (nearest), on a light and on a dark taskbar-like background.
    private static func contactSheet(_ all: [[Bitmap]]) -> Bitmap? {
        let scale = 8, pad = 12
        let rows = all.filter { !$0.isEmpty }
        guard !rows.isEmpty else { return nil }
        let cellH = rows.flatMap { $0 }.map { $0.height * scale }.max() ?? 0
        let width = rows.map { $0.reduce(pad) { $0 + $1.width * scale + pad } }.max() ?? 0
        let backgrounds: [(UInt8, UInt8, UInt8)] = [(243, 243, 243), (32, 32, 32)]
        let height = rows.count * backgrounds.count * (cellH + pad) + pad
        var px = [UInt8](repeating: 128, count: width * height * 4)
        var top = pad
        for row in rows {
            for bg in backgrounds {
                for y in top - pad / 2..<min(height, top + cellH + pad / 2) {
                    for x in 0..<width { let o = (y * width + x) * 4; px[o] = bg.2; px[o + 1] = bg.1; px[o + 2] = bg.0; px[o + 3] = 255 }
                }
                var left = pad
                for icon in row {
                    for y in 0..<icon.height * scale {
                        for x in 0..<icon.width * scale {
                            let s = ((y / scale) * icon.width + x / scale) * 4
                            let a = Int(icon.bgra[s + 3])
                            let o = ((top + y) * width + left + x) * 4
                            for c in 0..<3 { px[o + c] = UInt8((Int(icon.bgra[s + c]) * a + Int(px[o + c]) * (255 - a)) / 255) }
                        }
                    }
                    left += icon.width * scale + pad
                }
                top += cellH + pad
            }
        }
        return Bitmap(width: width, height: height, bgra: px)
    }

    // MARK: - the open menu

    private static func menuDump(_ r: WindowsSelftest.Recorder, _ app: WindowsAppDelegate, _ host: WinTrayHost, _ dir: URL) async {
        _ = await WindowsSelftest.waitUntil(timeout: 60) { !app.store.isRefreshing }
        let slot = Slot()
        let screenW = Int(GetSystemMetrics(SM_CXSCREEN)), screenH = Int(GetSystemMetrics(SM_CYSCREEN))
        let owner = Int(bitPattern: app.sink.hwnd)
        Thread {
            func post(_ message: Int32, _ key: Int32) { _ = PostMessageW(HWND(bitPattern: owner), UINT(message), WPARAM(key), 0) }
            var waited = 0
            while WinPopupMenu.openMenuBits == 0, waited < 200 { Thread.sleep(forTimeInterval: 0.05); waited += 1 }
            guard WinPopupMenu.openMenuBits != 0 else { slot.note("menu never opened"); slot.finish(); return }
            Thread.sleep(forTimeInterval: 0.8)  // let it paint
            var rect = RECT()
            let found = WinStr.w("#32768").withUnsafeBufferPointer { FindWindowW($0.baseAddress, nil) }
            if let found, GetWindowRect(found, &rect) {
                slot.note("class #32768 rect=(\(rect.left),\(rect.top),\(rect.right),\(rect.bottom))")
            } else {  // fallback: the area the menu was asked to open in
                rect = RECT(left: 300, top: 40, right: 700, bottom: 300)
                slot.note("menu window not found; fixed region")
            }
            let m = 24
            let x = max(0, Int(rect.left) - m), y = max(0, Int(rect.top) - m)
            let w = min(screenW - x, Int(rect.right - rect.left) + 2 * m), h = min(screenH - y, Int(rect.bottom - rect.top) + 2 * m)
            slot.set(w > 0 && h > 0 ? screenshot(x: x, y: y, w: w, h: h) : nil)
            for _ in 0..<5 where WinPopupMenu.openMenuBits != 0 {
                post(WM_KEYDOWN, Int32(VK_ESCAPE)); post(WM_KEYUP, Int32(VK_ESCAPE))
                for _ in 0..<10 where WinPopupMenu.openMenuBits != 0 { Thread.sleep(forTimeInterval: 0.1) }
            }
            slot.note(WinPopupMenu.openMenuBits == 0 ? "closed" : "STILL OPEN")
            slot.finish()
        }.start()
        let timer = Timer(fire: Date(timeIntervalSinceNow: 0.05), interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { host.openMenu(at: POINT(x: 300, y: 300)) }
        }
        RunLoop.main.add(timer, forMode: .common)
        let finished = await WindowsSelftest.waitUntil(timeout: 40) { slot.isDone }
        var wrote: Int32 = -1
        if let image = slot.captured { wrote = write(image, to: dir.appendingPathComponent("tray-menu-open.png")) }
        r.add("ui.dump.menu", finished && wrote == 0 && !host.menuOpen,
              "language=\(app.companion.language) png=\(slot.captured.map { "\($0.width)x\($0.height)" } ?? "none") write=\(wrote) \(slot.text)")
    }

    // MARK: - the balloon

    private static func balloonDump(_ r: WindowsSelftest.Recorder, _ host: WinTrayHost, _ dir: URL) async {
        guard let notifier = Platform.current.notifications as? WindowsNotifications else {
            r.add("ui.dump.balloon", false, "the live notifier is not the Windows one")
            return
        }
        let w = Int(GetSystemMetrics(SM_CXSCREEN)), h = Int(GetSystemMetrics(SM_CYSCREEN))
        let before = screenshot(x: 0, y: 0, w: w, h: h)
        notifier.post(id: "ui-dump", title: "PokeTokenBar", body: "Sample balloon from the CI runner · 샘플 알림 😀", sound: false)
        _ = await WindowsSelftest.waitUntil(timeout: 3) { false }  // let the shell show it
        let after = screenshot(x: 0, y: 0, w: w, h: h)
        notifier.presenter.handle(.hidden)
        var changed = -1
        if let before, let after, before.bgra.count == after.bgra.count {
            changed = 0
            var i = 0
            while i < before.bgra.count {
                if before.bgra[i] != after.bgra[i] || before.bgra[i + 1] != after.bgra[i + 1] || before.bgra[i + 2] != after.bgra[i + 2] { changed += 1 }
                i += 4
            }
        }
        var wrote: Int32 = -1
        if let after { wrote = write(after, to: dir.appendingPathComponent("balloon-screen.png")) }
        // The call succeeding says nothing about visibility; the pixel difference is the only evidence here.
        r.add("ui.dump.balloon", wrote == 0 && notifier.presenter.lastShown?.id == "ui-dump",
              "screen \(w)x\(h) write=\(wrote) shell accepted=\(host.tray.lastBalloonOK) pixels changed vs before the post=\(changed) (informational; visibility is a PC check)")
    }

    // MARK: - pixels and files

    nonisolated static func screenshot(x: Int, y: Int, w: Int, h: Int) -> Bitmap? {
        var out: UnsafeMutablePointer<UInt8>?
        guard ptb_capture_screen(Int32(x), Int32(y), UInt32(w), UInt32(h), &out) == 0, let out else { return nil }
        defer { ptb_free(out) }
        return Bitmap(width: w, height: h, bgra: Array(UnsafeBufferPointer(start: out, count: w * h * 4)))
    }

    nonisolated static func write(_ bitmap: Bitmap, to url: URL) -> Int32 {
        let path = WinStr.w(WinPath.native(url))
        return path.withUnsafeBufferPointer { p in
            bitmap.bgra.withUnsafeBufferPointer { px in
                ptb_png_write_bgra(p.baseAddress, px.baseAddress, UInt32(bitmap.width), UInt32(bitmap.height))
            }
        }
    }
}
#endif
