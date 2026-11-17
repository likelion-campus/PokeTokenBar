#if os(Windows)
import Foundation
import WinSDK

/// `plaza.windowIcon` / `update.windowIcon`: a captioned top-level window of ours carries the app's icon, big (taskbar, Alt+Tab)
/// and small (title bar), at the pixel sizes the system metrics give for the window's DPI, and the process has the AppUserModelID
/// the installer's shortcut carries (so the taskbar groups the windows with the app). Without the icon a window shows the
/// generic application icon: `WM_GETICON` returns nothing and the class has none.
extension WindowsSelftest {
    struct IconReading {
        let ok: Bool
        let text: String
    }

    @MainActor static func readIcon(_ hwnd: HWND) -> IconReading {
        let dpi = WinAppIcon.currentDpi(of: hwnd)
        let wantBig = WinAppIcon.size(big: true, dpi: dpi), wantSmall = WinAppIcon.size(big: false, dpi: dpi)
        let big = WinAppIcon.current(of: hwnd, big: true), small = WinAppIcon.current(of: hwnd, big: false)
        let gotBig = big.map(WinAppIcon.width(of:)) ?? 0, gotSmall = small.map(WinAppIcon.width(of:)) ?? 0
        let aumid = WinAppUserModelID.current()
        return IconReading(ok: gotBig == wantBig && gotSmall == wantSmall && aumid == WinAppUserModelID.id,
                           text: "dpi=\(dpi) big \(gotBig)px (expected \(wantBig)) small \(gotSmall)px (expected \(wantSmall)) "
                               + "appId=\(aumid ?? "none") (expected \(WinAppUserModelID.id))")
    }

    @MainActor static func windowIconChecks(_ r: Recorder, plaza hwnd: HWND) {
        let p = readIcon(hwnd)
        r.add("plaza.windowIcon", p.ok, "plaza window: \(p.text)")
        // The update progress window shows itself (it activates), so it is made only on the CI runner.
        guard onCI else {
            r.add("update.windowIcon", true, "skipped off CI: the progress window would take the foreground of a person's PC")
            return
        }
        let progress = WinUpdateProgressWindow(l: L(.ko))
        progress.began(version: "0.0.0", total: 1_000_000) {}
        guard let window = progress.hwndForTesting else {
            r.add("update.windowIcon", false, "the progress window was not made")
            return
        }
        let u = readIcon(window)
        progress.close()
        r.add("update.windowIcon", u.ok, "update progress window: \(u.text)")
    }
}
#endif
