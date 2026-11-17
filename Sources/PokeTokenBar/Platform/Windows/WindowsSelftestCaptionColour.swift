#if os(Windows)
import Foundation
import WinSDK

/// `plaza.captionColour`: on Windows 11 without high contrast DWM accepted the plaza's colours and, on CI, the title bar's own
/// pixels (a screen copy of the window's whole rect: `PrintWindow` skips the DWM caption, and `DwmGetWindowAttribute` cannot read
/// these attributes) are the caption colour; on Windows 10 or under high contrast nothing was set, and the check says so and
/// passes. On CI the whole-window captures are saved as `plaza-caption-active.png` and, after `WM_NCACTIVATE(FALSE)`,
/// `plaza-caption-inactive.png`.
extension WindowsSelftest {
    @MainActor static func windowCaptionChecks(_ r: Recorder, plaza hwnd: HWND) {
        let build = WinCaptionColour.buildNumber
        let highContrast = WinUIContext.systemHighContrast()
        let expected = PlazaCaptionTheme.plaza
        let isSet = WinCaptionColour.isSet(hwnd)
        func hex(_ v: UInt32) -> String { "0x" + String(v, radix: 16) }
        var rect = RECT()
        _ = GetWindowRect(hwnd, &rect)
        func capture() -> WinUIDump.Bitmap? {
            WinUIDump.screenshot(x: Int(rect.left), y: Int(rect.top), w: Int(rect.right - rect.left), h: Int(rect.bottom - rect.top))
        }
        let dir = selftestOutDirectory()
        let active = onCI ? capture() : nil
        // The caption's pixel in the middle of the bar (the title is at the left, the buttons at the right), as COLORREF.
        var pixel: UInt32?
        if let b = active, b.width > 200, b.height > 12 {
            let i = (10 * b.width + b.width / 2) * 4
            pixel = UInt32(b.bgra[i]) << 16 | UInt32(b.bgra[i + 1]) << 8 | UInt32(b.bgra[i + 2])
        }
        func near(_ a: UInt32, _ b: UInt32) -> Bool {
            (0..<3).allSatisfy { abs(Int((a >> UInt32(8 * $0)) & 0xFF) - Int((b >> UInt32(8 * $0)) & 0xFF)) <= 3 }
        }
        let state = "build \(build) highContrast=\(highContrast) set=\(isSet) title bar pixel=\(pixel.map(hex) ?? "not captured") "
            + "(plaza caption \(hex(expected.caption)), text \(hex(expected.text)), border \(hex(expected.border)))"
        if PlazaCaptionTheme.shouldApply(buildNumber: build, highContrast: highContrast) {
            r.add("plaza.captionColour", isSet && (pixel.map { near($0, expected.caption) } ?? !onCI), "set: \(state)")
        } else if build < 22000 {
            r.add("plaza.captionColour", !isSet, "unsupported on this build, the system title bar stays: \(state)")
        } else {
            r.add("plaza.captionColour", !isSet, "high contrast, not set: \(state)")
        }
        guard let active else { return }
        _ = WinUIDump.write(active, to: dir.appendingPathComponent("plaza-caption-active.png"))
        _ = SendMessageW(hwnd, 0x0086 /* WM_NCACTIVATE */, 0, 0)
        Thread.sleep(forTimeInterval: 0.3)
        if let inactive = capture() { _ = WinUIDump.write(inactive, to: dir.appendingPathComponent("plaza-caption-inactive.png")) }
        _ = SendMessageW(hwnd, 0x0086 /* WM_NCACTIVATE */, 1, 0)
    }
}
#endif
