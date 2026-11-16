#if os(Windows)
import CPlazaD2D
import Foundation
import WinSDK

/// The plaza window's hover texts (D18): a system tooltip control (`tooltips_class32`) with one rectangle tool per tooltip the
/// shown panels carry. The tools are rebuilt only when the list changes (a panel re-render with the same tips, a scene frame,
/// a scroll that moves no tip: nothing). The window relays its mouse messages; the system times the rest and shows the text,
/// without taking the focus. Main thread only.
@MainActor final class WinPlazaTooltips {
    /// A tool: a rectangle in client pixels (`l, t, r, b`) and its text.
    struct Tip: Equatable {
        var rect: [Int32]
        var text: String
    }

    private let owner: HWND
    private var control: UnsafeMutableRawPointer?
    private(set) var tips: [Tip] = []
    /// How many times the tools were replaced (tests: "rebuilt only on change").
    private(set) var rebuilds = 0
    private var logged = false

    init(owner: HWND) {
        self.owner = owner
        control = ptb_tooltip_create(UnsafeMutableRawPointer(owner))
        if control == nil { AppLog.write("plaza tooltips: the tooltip control could not be made (\(GetLastError())); hover texts are not shown") }
    }

    var isAvailable: Bool { control != nil }
    var count: Int { Int(ptb_tooltip_count(control)) }
    var isShowing: Bool { ptb_tooltip_visible(control) == 1 }
    /// The tool whose text is showing, or nil.
    var currentIndex: Int? { let i = Int(ptb_tooltip_current(control, UnsafeMutableRawPointer(owner))); return i >= 0 ? i : nil }

    func setDelay(milliseconds: Int) { ptb_tooltip_set_delay(control, Int32(milliseconds)) }

    /// The tool list for the shown panels, topmost first. Replaces the control's tools only when it differs.
    func set(_ new: [Tip]) {
        guard new != tips else { return }
        tips = new
        rebuilds += 1
        guard control != nil else { return }
        var rects: [Int32] = []
        var texts: [[UInt16]] = []
        for tip in new {
            rects += tip.rect
            texts.append(Array(tip.text.utf16) + [0])
        }
        // The texts must stay alive for the call: pointers into the arrays, valid inside the nested closures only.
        func call(_ index: Int, _ pointers: inout [UnsafePointer<UInt16>?]) {
            if index == texts.count {
                let added = rects.withUnsafeBufferPointer { r in
                    pointers.withUnsafeBufferPointer { p in
                        ptb_tooltip_set(control, UnsafeMutableRawPointer(owner), r.baseAddress, p.baseAddress, UInt32(p.count))
                    }
                }
                if Int(added) != new.count, !logged {
                    logged = true
                    AppLog.write("plaza tooltips: the control took \(added) of \(new.count) tools (logged once)")
                }
                return
            }
            texts[index].withUnsafeBufferPointer { t in
                pointers.append(t.baseAddress)
                call(index + 1, &pointers)
            }
        }
        var pointers: [UnsafePointer<UInt16>?] = []
        call(0, &pointers)
    }

    /// A mouse message of the window (client coordinates in `lParam`), so the control times its rest delay.
    func relay(_ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) {
        guard control != nil else { return }
        ptb_tooltip_relay(control, UnsafeMutableRawPointer(owner), message, UInt64(wParam), Int64(lParam))
    }

    /// TTM_GETTEXT of tool `index`.
    func text(of index: Int) -> String? {
        guard control != nil, index >= 0, index < count else { return nil }
        var buffer = [UInt16](repeating: 0, count: 512)
        let n = buffer.withUnsafeMutableBufferPointer { ptb_tooltip_text(control, UnsafeMutableRawPointer(owner), UInt32(index), $0.baseAddress, 512) }
        return n >= 0 ? String(decoding: buffer.prefix(Int(n)), as: UTF16.self) : nil
    }

    func destroy() {
        if let control { ptb_tooltip_destroy(control) }
        control = nil
        tips = []
    }
}
#endif
