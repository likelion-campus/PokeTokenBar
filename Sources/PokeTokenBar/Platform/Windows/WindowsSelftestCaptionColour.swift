#if os(Windows)
import Foundation
import WinSDK

/// `plaza.captionColour`: on Windows 11 without high contrast `DwmGetWindowAttribute` returns the plaza's colours and dark mode;
/// on Windows 10 or under high contrast nothing was set (the attributes read back as the defaults) and the check reports so and
/// passes. On CI the window's whole rect (title bar included, from the screen: `PrintWindow` skips the DWM caption) is saved
/// as `plaza-caption-active.png` and, with the window made inactive, `plaza-caption-inactive.png`.
extension WindowsSelftest {
    @MainActor static func windowCaptionChecks(_ r: Recorder, plaza hwnd: HWND) {
        let build = WinCaptionColour.buildNumber
        let highContrast = WinUIContext.systemHighContrast()
        let expected = PlazaCaptionTheme.plaza
        let read = WinCaptionColour.read(hwnd)
        func hex(_ v: UInt32?) -> String { v.map { "0x" + String($0, radix: 16) } ?? "none" }
        let state = "build \(build) highContrast=\(highContrast) caption=\(hex(read?.caption)) text=\(hex(read?.text)) "
            + "border=\(hex(read?.border)) dark=\(hex(read?.dark)) (plaza: \(hex(expected.caption)) \(hex(expected.text)) \(hex(expected.border)))"
        if PlazaCaptionTheme.shouldApply(buildNumber: build, highContrast: highContrast) {
            let ok = read.map { $0.caption == expected.caption && $0.text == expected.text && $0.border == expected.border && $0.dark != 0 } ?? false
            r.add("plaza.captionColour", ok, "set: \(state)")
        } else if build < 22000 {
            r.add("plaza.captionColour", true, "unsupported on this build, the system title bar stays: \(state)")
        } else {
            // High contrast: not set, so DWM reports the default (0xFFFFFFFF) or something other than our teal.
            r.add("plaza.captionColour", read?.caption != expected.caption, "high contrast, not set: \(state)")
        }
        guard onCI else { return }
        let dir = selftestOutDirectory()
        func capture(_ name: String) {
            var rect = RECT()
            _ = GetWindowRect(hwnd, &rect)
            if let shot = WinUIDump.screenshot(x: Int(rect.left), y: Int(rect.top), w: Int(rect.right - rect.left), h: Int(rect.bottom - rect.top)) {
                _ = WinUIDump.write(shot, to: dir.appendingPathComponent(name))
            }
        }
        capture("plaza-caption-active.png")
        _ = SendMessageW(hwnd, 0x0086 /* WM_NCACTIVATE */, 0, 0)
        Thread.sleep(forTimeInterval: 0.3)
        capture("plaza-caption-inactive.png")
        _ = SendMessageW(hwnd, 0x0086 /* WM_NCACTIVATE */, 1, 0)
    }
}
#endif
