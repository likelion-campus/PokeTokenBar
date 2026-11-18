#if os(Windows)
import Foundation
import WinSDK

// Visual polish K4: the drop-down (replacing the combo box), the stepper and the field frame, and the direct MSAA query of K3's and
// K4's controls. Fixture texts only.
//
//   popover.dropDown   keys (Up/Down/Home/End change in place, F4, Alt+Down and a click open the menu with the choice checked),
//                      the width follows the entries, the accessible name "label: value" is what MSAA reports, pixels of rest,
//                      hover, pressed, focus ring, disabled and the chevron; light, dark, high contrast
//   popover.stepper    value, keys, halves (mouse), range ends, width not sized to the maximum, MSAA name follows the value, pixels
//   popover.field      the frame is the field's non-client area (client smaller than the window, NM paint counter), pixels of the
//                      hairline and of the focus ring, no sunken client edge
//   popover.msaa       role, state, name through AccessibleObjectFromWindow for a segment, a switch, a button, the slider, a
//                      drop-down, a stepper and a field
//   popover.k4.fault   the same evaluation with custom draw off must find problems (the guard guards)

extension WindowsSelftest {
    @MainActor static func popoverK4Checks(_ r: Recorder, _ app: WindowsAppDelegate) async {
        await WindowsSelftestPopoverK4.run(r)
    }
}

/// IAccessible through `AccessibleObjectFromWindow` (oleacc), called through the interface's vtable: no COM wrapper in Swift.
enum MSAAProbe {
    struct Info { var role: Int; var state: Int; var name: String; var value: String }

    static func query(_ hwnd: HWND) -> Info? {
        typealias Obj = @convention(c) (HWND?, DWORD, UnsafePointer<GUID>?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32
        guard let fn = WinDynamic.symbol("oleacc.dll", "AccessibleObjectFromWindow", as: Obj.self) else { return nil }
        var iid = GUID(Data1: 0x618736E0, Data2: 0x3C3D, Data3: 0x11CF, Data4: (0x81, 0x0C, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71))
        var object: UnsafeMutableRawPointer?
        guard fn(hwnd, DWORD(bitPattern: -4 /* OBJID_CLIENT */), &iid, &object) == 0, let object else { return nil }
        let vtable = object.load(as: UnsafePointer<UnsafeRawPointer>.self)
        typealias Release = @convention(c) (UnsafeMutableRawPointer) -> UInt32
        typealias Text = @convention(c) (UnsafeMutableRawPointer, VARIANT, UnsafeMutablePointer<UnsafeMutablePointer<UInt16>?>) -> Int32
        typealias Number = @convention(c) (UnsafeMutableRawPointer, VARIANT, UnsafeMutablePointer<VARIANT>) -> Int32
        let release = unsafeBitCast(vtable[2], to: Release.self)
        defer { _ = release(object) }
        func selfChild() -> VARIANT {
            var v = VARIANT()
            withUnsafeMutableBytes(of: &v) { b in
                b.storeBytes(of: UInt16(3 /* VT_I4 */), as: UInt16.self)
                b.storeBytes(of: Int32(0 /* CHILDID_SELF */), toByteOffset: 8, as: Int32.self)
            }
            return v
        }
        func text(_ index: Int) -> String {
            let call = unsafeBitCast(vtable[index], to: Text.self)
            var bstr: UnsafeMutablePointer<UInt16>?
            guard call(object, selfChild(), &bstr) == 0, let bstr else { return "" }
            defer { SysFreeString(bstr) }
            return String(decodingCString: bstr, as: UTF16.self)
        }
        func number(_ index: Int) -> Int {
            let call = unsafeBitCast(vtable[index], to: Number.self)
            var out = VARIANT()
            guard call(object, selfChild(), &out) == 0 else { return -1 }
            return withUnsafeBytes(of: &out) { Int($0.load(fromByteOffset: 8, as: Int32.self)) }
        }
        // IAccessible: IUnknown 0-2, IDispatch 3-6, get_accParent 7, get_accChildCount 8, get_accChild 9, get_accName 10,
        // get_accValue 11, get_accDescription 12, get_accRole 13, get_accState 14
        return Info(role: number(13), state: number(14), name: text(10), value: text(11))
    }
}

@MainActor final class K4Page {
    var combo: WinControl?, wide: WinControl?, off: WinControl?, stepper: WinControl?, big: WinControl?, edit: WinControl?, multi: WinControl?
    var picked: [Int] = [], values: [Int] = []

    func build(_ s: WinStack) {
        let section = s.addSection("K4")
        combo = section.addRow("Language") { pane, ctx in WinControls.combo(["English", "한국어", "日本語"], selected: 1, in: pane, ctx: ctx) }.control
        combo?.onSelect = { [weak self] i in self?.picked.append(i) }
        wide = section.addRow("Wide") { pane, ctx in
            WinControls.combo(["Follow current companion", "A much longer entry than the others to size the button"], selected: 0, in: pane, ctx: ctx)
        }.control
        off = section.addRow("Off") { pane, ctx in WinControls.combo(["English", "한국어"], selected: 0, in: pane, ctx: ctx) }.control
        off?.isEnabled = false
        stepper = section.addRow("Quantity") { pane, ctx in WinControls.stepper(range: 1...5, step: 1, value: 3, format: { "×\($0)" }, in: pane, ctx: ctx) }.control
        stepper?.onValue = { [weak self] v in self?.values.append(v) }
        big = section.addRow("Big") { pane, ctx in WinControls.stepper(range: 1...2_000_000_000, step: 1, value: 3, format: { "×\($0)" }, in: pane, ctx: ctx) }.control
        edit = section.addRow("Nickname") { pane, ctx in WinControls.edit(.text(cue: "Nickname"), text: "Pika", width: 160, in: pane, ctx: ctx) }.control
        multi = section.addRow("Folders", style: .stacked) { pane, ctx in WinControls.edit(.multiLine(lines: 3, cue: nil), in: pane, ctx: ctx) }.control
    }
}

@MainActor enum WindowsSelftestPopoverK4 {
    /// Breadcrumbs: a hung step shows up in the timeout's list of checks so far.
    static var crumbs: WindowsSelftest.Recorder?
    static func at(_ n: String) { crumbs?.add("popover.k4.at.\(n)", true, "reached") }
    private static func wait(_ seconds: TimeInterval) async { _ = await WindowsSelftest.waitUntil(timeout: seconds) { false } }
    typealias CD = WindowsSelftestPopoverCustomDraw

    private static func lum(_ c: (r: Int, g: Int, b: Int)) -> Double {
        func ch(_ v: Int) -> Double { let s = Double(v) / 255; return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
        return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b)
    }

    private static func ratio(_ a: (r: Int, g: Int, b: Int), _ b: (r: Int, g: Int, b: Int)) -> Double {
        (max(lum(a), lum(b)) + 0.05) / (min(lum(a), lum(b)) + 0.05)
    }

    static func evaluate(dark: Bool, highContrast: Bool) async -> (problems: [String], note: String) {
        var problems: [String] = []
        var notes: [String] = []
        let page = K4Page()
        guard let w = KitWindow(heightDIP: 700, highContrast: highContrast, dark: highContrast ? nil : dark, register: true,
                                origin: POINT(x: 0, y: 0), build: { _, s in page.build(s) }) else { return (["no window"], "") }
        defer { w.destroy(); WinControl.testMenu = nil }
        w.fitToContent()
        w.show(activate: false)
        _ = RedrawWindow(w.hwnd, nil, nil, UINT(0x0001 | 0x0004 | 0x0080 | 0x0100))
        await wait(0.4)
        guard let combo = page.combo, let wide = page.wide, let off = page.off, let stepper = page.stepper, let big = page.big,
              let edit = page.edit, let multi = page.multi else { return (["the page's controls were not made"], "") }
        let scale = Double(w.ctx.scale)
        func style(_ h: HWND) -> DWORD { DWORD(bitPattern: GetWindowLongW(h, -16)) }

        // classes: buttons (role and name by MSAA), edits without a sunken edge
        for c in [combo, wide, off, stepper, big] where WinKit.className(c.hwnd) != "Button" || style(c.hwnd) & 0xF != 0 { problems.append("\(c.kind) is not a push button") }
        for c in [edit, multi] {
            if WinKit.className(c.hwnd) != "Edit" { problems.append("a field is not an Edit") }
            if DWORD(bitPattern: GetWindowLongW(c.hwnd, -20)) & 0x200 != 0 { problems.append("a field still has a sunken client edge") }
        }

        at("built")
        // names, as MSAA says them
        if let info = MSAAProbe.query(combo.hwnd) {
            if info.role != 0x2B { problems.append("drop-down MSAA role \(info.role), expected push button 43") }
            if info.name != "Language: 한국어" { problems.append("drop-down MSAA name '\(info.name)', expected 'Language: 한국어'") }
            notes.append("drop-down MSAA role=\(info.role) name='\(info.name)' state=0x\(String(info.state, radix: 16))")
        } else { problems.append("no MSAA object for the drop-down") }
        at("msaaCombo")
        if let info = MSAAProbe.query(off.hwnd), info.state & 0x1 == 0 { problems.append("a disabled drop-down is not UNAVAILABLE in MSAA (state 0x\(String(info.state, radix: 16)))") }
        if let info = MSAAProbe.query(stepper.hwnd) {
            if info.role != 0x2B || info.name != "Quantity: ×3" { problems.append("stepper MSAA role \(info.role) name '\(info.name)', expected 43 'Quantity: ×3'") }
            notes.append("stepper MSAA role=\(info.role) name='\(info.name)'")
        } else { problems.append("no MSAA object for the stepper") }
        at("msaaStepper")
        if let info = MSAAProbe.query(edit.hwnd) {
            if info.role != 0x2A || !info.name.contains("Nickname") { problems.append("field MSAA role \(info.role) name '\(info.name)', expected text 42 named 'Nickname'") }
            notes.append("field MSAA role=\(info.role) name='\(info.name)' value='\(info.value)'")
        } else { problems.append("no MSAA object for the field") }

        at("msaaEdit")
        // drop-down: keys, menu, width
        var menus: [[TrayMenuModel.Item?]] = []
        var answer: Int? = 0
        WinControl.testMenu = { entries in menus.append(entries); return answer }
        func key(_ c: WinControl, _ vk: Int, system: Bool = false) { _ = SendMessageW(c.hwnd, system ? 0x0104 : UINT(WM_KEYDOWN), WPARAM(vk), 0) }
        key(combo, 0x28)  // Down: 1 -> 2
        if combo.selection != 2 || page.picked != [2] { problems.append("Down: selection \(combo.selection) picks \(page.picked), expected 2 / [2]") }
        key(combo, 0x28)  // at the end: stays
        if combo.selection != 2 { problems.append("Down at the last entry moved to \(combo.selection)") }
        key(combo, 0x24)  // Home
        if combo.selection != 0 { problems.append("Home: selection \(combo.selection)") }
        key(combo, 0x23)  // End
        if combo.selection != 2 { problems.append("End: selection \(combo.selection)") }
        key(combo, 0x26)  // Up
        if combo.selection != 1 { problems.append("Up: selection \(combo.selection)") }
        if !menus.isEmpty { problems.append("an arrow key opened the menu") }
        answer = 0
        key(combo, 0x73)  // F4
        if menus.count != 1 || combo.selection != 0 { problems.append("F4: menus \(menus.count), selection \(combo.selection)") }
        if let m = menus.first {
            let titles = m.compactMap { $0?.title }, checked = m.compactMap { $0 }.firstIndex { $0.checked }
            if titles != ["English", "한국어", "日本語"] || checked != 1 { problems.append("the menu lists \(titles) with \(String(describing: checked)) checked, expected the three entries with the second") }
        }
        answer = 2
        key(combo, 0x28, system: true)  // Alt+Down
        if menus.count != 2 || combo.selection != 2 { problems.append("Alt+Down: menus \(menus.count), selection \(combo.selection)") }
        answer = nil
        _ = SendMessageW(combo.hwnd, 0x00F5 /* BM_CLICK */, 0, 0)  // Space / Enter / a click
        if menus.count != 3 || combo.selection != 2 { problems.append("a click: menus \(menus.count), dismissed menu changed the selection to \(combo.selection)") }
        if MSAAProbe.query(combo.hwnd)?.name != "Language: 日本語" { problems.append("the accessible name did not follow the choice") }
        combo.selection = 1
        // the width follows the entries, up to a cap
        let cw = combo.preferredSize.width / CGFloat(scale), ww = wide.preferredSize.width / CGFloat(scale)
        if !(cw < 150 && ww > cw + 40 && ww <= 240.5) { problems.append("drop-down widths \(Int(cw)) / \(Int(ww)) DIP: not sized to the entries (short < 150, long up to 240)") }
        notes.append("drop-down widths \(Int(cw)) / \(Int(ww)) DIP")

        at("dropdownKeys")
        // stepper: value, keys, ends, width
        let sw = stepper.preferredSize.width, bw = big.preferredSize.width
        if sw != bw { problems.append("stepper width follows the maximum: \(Int(sw)) px for 1...5, \(Int(bw)) px for 1...2e9") }
        key(stepper, 0x26)
        key(stepper, 0x26)
        key(stepper, 0x26)  // 3 -> 4 -> 5 -> stays
        if stepper.value != 5 || page.values != [4, 5] { problems.append("Up x3: value \(stepper.value) callbacks \(page.values), expected 5 / [4, 5]") }
        if stepper.canStepUp { problems.append("the upper end still offers a step up") }
        key(stepper, 0x24)
        if stepper.value != 1 || stepper.canStepDown { problems.append("Home: value \(stepper.value)") }
        stepper.clickHalf(1)
        stepper.clickHalf(1)
        if stepper.value != 3 { problems.append("click on the upper half twice from 1: \(stepper.value)") }
        if MSAAProbe.query(stepper.hwnd)?.name != "Quantity: ×3" { problems.append("the stepper's name did not follow the value (\(MSAAProbe.query(stepper.hwnd)?.name ?? "-"))") }
        var client = RECT()
        _ = GetClientRect(stepper.hwnd, &client)
        let x = Int(client.right) - Int(w.ctx.px(9))
        let upper = LPARAM(Int(w.ctx.px(5)) << 16 | x), lower = LPARAM((Int(client.bottom) - Int(w.ctx.px(5))) << 16 | x)
        _ = SendMessageW(stepper.hwnd, 0x0200, 0, lower)  // WM_MOUSEMOVE
        _ = SendMessageW(stepper.hwnd, 0x0201, 1, lower)  // WM_LBUTTONDOWN on the lower half
        let pressedHalf = stepper.pressedHalf, hotHalf = stepper.hotHalf
        _ = SendMessageW(stepper.hwnd, 0x0202, 0, lower)
        if stepper.value != 2 || pressedHalf != 2 || hotHalf != 2 || stepper.pressedHalf != 0 { problems.append("lower half: value \(stepper.value) pressed \(pressedHalf) hot \(hotHalf), expected 2 / 2 / 2") }
        _ = SendMessageW(stepper.hwnd, 0x0200, 0, upper)
        notes.append("stepper \(Int(sw)) px wide (same for a 2e9 maximum), halves hot=\(stepper.hotHalf)")

        at("stepper")
        // field frame: the padding is non-client, and was painted by WM_NCPAINT
        var wr = RECT(), cr = RECT()
        _ = GetWindowRect(edit.hwnd, &wr)
        _ = GetClientRect(edit.hwnd, &cr)
        let padW = (wr.right - wr.left) - (cr.right - cr.left), padH = (wr.bottom - wr.top) - (cr.bottom - cr.top)
        if padW < w.ctx.px(10) || padH < w.ctx.px(2) { problems.append("the field's frame padding is \(padW) x \(padH) px (non-client), expected at least \(w.ctx.px(10)) x \(w.ctx.px(2))") }
        let before = edit.framePaints
        _ = RedrawWindow(edit.hwnd, nil, nil, UINT(0x0400 | 0x0001 | 0x0100))  // RDW_FRAME | INVALIDATE | UPDATENOW
        if highContrast || !WinCustomDraw.testDisabled, edit.framePaints == before { problems.append("WM_NCPAINT did not paint the field's frame") }
        _ = GetWindowRect(multi.hwnd, &wr)
        _ = GetClientRect(multi.hwnd, &cr)
        if (wr.right - wr.left) - (cr.right - cr.left) < w.ctx.px(10) { problems.append("the multi-line field's text area is not inset") }

        at("fieldNC")
        guard let dcOwner = CreateCompatibleDC(nil) else { return (problems, notes.joined(separator: "; ")) }
        defer { _ = DeleteDC(dcOwner) }
        // frame pixels: drawn into a bitmap the size of the window
        func frameShot(_ c: WinControl, focused: Bool) -> CD.Shot? {
            var r = RECT()
            _ = GetWindowRect(c.hwnd, &r)
            let fw = Int(r.right - r.left), fh = Int(r.bottom - r.top)
            var info = BITMAPINFO()
            info.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
            info.bmiHeader.biWidth = Int32(fw)
            info.bmiHeader.biHeight = -Int32(fh)
            info.bmiHeader.biPlanes = 1
            info.bmiHeader.biBitCount = 32
            var bits: UnsafeMutableRawPointer?
            guard let mem = CreateCompatibleDC(nil), let dib = CreateDIBSection(mem, &info, 0, &bits, nil, 0), let bits else { return nil }
            defer { _ = DeleteDC(mem); _ = DeleteObject(UnsafeMutableRawPointer(dib)) }
            let old = SelectObject(mem, UnsafeMutableRawPointer(dib))
            defer { _ = SelectObject(mem, old) }
            var all = RECT(left: 0, top: 0, right: Int32(fw), bottom: Int32(fh))
            _ = FillRect(mem, &all, c.ctx.colors.brush(0x00FF00FF))  // magenta: what the frame leaves alone stays visible
            WinCustomDraw.drawFieldFrame(c, mem, width: Int32(fw), height: Int32(fh), focused: focused)
            _ = GdiFlush()
            return CD.Shot(width: fw, height: fh, bgra: Array(UnsafeRawBufferPointer(start: bits, count: fw * fh * 4)))
        }
        if let rest = frameShot(edit, focused: false), let ring = frameShot(edit, focused: true) {
            let look = WinLook(edit)
            let mid = rest.height / 2
            let edge = rest.rgb(0, mid), card = (r: Int(look.bg & 0xFF), g: Int((look.bg >> 8) & 0xFF), b: Int((look.bg >> 16) & 0xFF))
            let magenta = rest.rgb(rest.width / 2, rest.height / 2)
            if !(magenta.r == 255 && magenta.g == 0 && magenta.b == 255) { problems.append("the frame painted over the text area (centre \(CD.hex(magenta)))") }
            let edgeRatio = ratio(rest.rgb(1, mid), card)
            if edgeRatio < 1.3 { problems.append("the field's hairline is \(String(format: "%.2f", edgeRatio)):1 against its card, expected at least 1.3:1") }
            let top = ring.rgb(ring.width / 2, 0), inkColour: COLORREF = highContrast ? look.palette.text : (dark ? 0x00FF_FFFF : 0)
            if !CD.near(top, inkColour, tolerance: 40) { problems.append("the focus ring's top edge is \(CD.hex(top)), expected \(CD.hex(from: inkColour))") }
            notes.append("field hairline \(CD.hex(edge)) on card = \(String(format: "%.2f", edgeRatio)):1, focus ring \(CD.hex(top))")
        } else { problems.append("no picture of the field frame") }

        at("fieldPixels")
        // drop-down and stepper pixels (the system draws in high contrast)
        if !highContrast {
            let look = WinLook(combo)
            func fillAt(_ c: WinControl, hot: Bool = false, pressed: Bool = false, focus: Bool = false) -> (r: Int, g: Int, b: Int)? {
                c.forceState(hot: hot ? 0 : nil, pressed: pressed ? 0 : nil, focus: focus ? 0 : nil)
                guard let s = CD.shot(c.hwnd) else { return nil }
                return s.rgb(s.width / 2, Int(look.ipx(3)))
            }
            let rest = fillAt(combo), hot = fillAt(combo, hot: true), pressed = fillAt(combo, hot: true, pressed: true)
            let ring = fillAt(combo, focus: true)
            combo.forceState()
            func rgb(_ c: COLORREF) -> (r: Int, g: Int, b: Int) { (Int(c & 0xFF), Int((c >> 8) & 0xFF), Int((c >> 16) & 0xFF)) }
            if let rest, !CD.near(rest, look.buttonFill(hot: false, pressed: false)) { problems.append("drop-down at rest is \(CD.hex(rest)), expected its fill \(CD.hex(from: look.buttonFill(hot: false, pressed: false)))") }
            if let hot, !CD.near(hot, look.buttonFill(hot: true, pressed: false)) { problems.append("drop-down hovered is \(CD.hex(hot)), expected \(CD.hex(from: look.buttonFill(hot: true, pressed: false)))") }
            if let pressed, !CD.near(pressed, look.buttonFill(hot: true, pressed: true)) { problems.append("drop-down pressed is \(CD.hex(pressed)), expected \(CD.hex(from: look.buttonFill(hot: true, pressed: true)))") }
            if let ring, !CD.near(ring, dark ? 0x00FF_FFFF : 0, tolerance: 60) { problems.append("drop-down focus ring is \(CD.hex(ring)), expected the text colour") }
            if let rest, let hot, let pressed, rest == hot || hot == pressed { problems.append("drop-down hover and pressed look like rest") }
            // the chevron: strong ink in the right part of the button, none in an empty stretch left of it
            if let s = CD.shot(combo.hwnd) {
                let ref = s.rgb(s.width / 2, Int(look.ipx(3)))
                var chevron = 0.0
                for yy in 0..<s.height { for xx in (s.width - Int(look.ipx(22)))..<(s.width - Int(look.ipx(8))) { chevron = max(chevron, abs(s.luma(xx, yy) - (0.2126 * Double(ref.r) + 0.7152 * Double(ref.g) + 0.0722 * Double(ref.b)))) } }
                if chevron < 60 { problems.append("no chevron in the drop-down (strongest ink \(Int(chevron)))") }
                notes.append("drop-down chevron ink \(Int(chevron)), rest \(rest.map(CD.hex) ?? "-") hover \(hot.map(CD.hex) ?? "-") pressed \(pressed.map(CD.hex) ?? "-")")
            }
            if let o = CD.shot(off.hwnd), let e = CD.shot(combo.hwnd) {
                let ref = (x: e.width / 2, y: 3)
                if !(o.contrast(against: ref) < e.contrast(against: ref) - 20) { problems.append("a disabled drop-down's text is not visibly weaker") }
            }
            // stepper halves: hover tints the upper half, the lower one stays; a half at its range end does not tint
            stepper.forceHalves(hot: 0, pressed: 0)
            let sx = Int(client.right) - Int(look.ipx(11)), syUp = Int(look.ipx(7)), syDown = Int(client.bottom) - Int(look.ipx(7))
            let restShot = CD.shot(stepper.hwnd)
            stepper.forceHalves(hot: 1, pressed: 0)
            let hotShot = CD.shot(stepper.hwnd)
            stepper.forceHalves(hot: 1, pressed: 2)
            let pressedShot = CD.shot(stepper.hwnd)
            stepper.forceHalves(hot: 0, pressed: 0)
            if let a = restShot, let b = hotShot, let c = pressedShot {
                if a.rgb(sx, syUp) == b.rgb(sx, syUp) { problems.append("the hovered upper half looks like rest") }
                if b.rgb(sx, syDown) != a.rgb(sx, syDown) { problems.append("hovering the upper half tinted the lower half") }
                if c.rgb(sx, syDown) == a.rgb(sx, syDown) { problems.append("the pressed lower half looks like rest") }
            } else { problems.append("no picture of the stepper") }
        }
        return (problems, notes.joined(separator: "; "))
    }

    /// MSAA role, state and name of K3's controls: the check box, the radio group, the push buttons and the slider.
    static func msaaChecks(_ r: WindowsSelftest.Recorder) async {
        var problems: [String] = []
        var notes: [String] = []
        let page = CustomDrawPage()
        guard let w = KitWindow(heightDIP: 700, register: true, origin: POINT(x: 0, y: 0), build: { _, s in page.build(s) }) else {
            r.add("popover.msaa", false, "no window"); return
        }
        defer { w.destroy() }
        w.fitToContent()
        w.show(activate: false)
        await wait(0.4)
        guard let seg = page.segments, let on = page.on, let off = page.off, let enabled = page.enabled, let disabled = page.disabled,
              let primary = page.primary, let slider = page.slider, let chips = page.chips else { r.add("popover.msaa", false, "controls missing"); return }
        func show(_ i: MSAAProbe.Info?) -> String { i.map { "role \($0.role) state 0x\(String($0.state, radix: 16)) name '\($0.name)'" } ?? "no object" }
        // a segment: the selected one reads as checked (or pressed) and differs from its neighbours
        let selected = MSAAProbe.query(seg.parts[1]), other = MSAAProbe.query(seg.parts[0])
        if let selected, let other {
            if ![0x2B, 0x2D].contains(selected.role) { problems.append("segment role \(selected.role), expected radio button 45 or push button 43") }
            if selected.state == other.state { problems.append("the selected segment's MSAA state equals an unselected one's (0x\(String(selected.state, radix: 16)))") }
            if selected.name != "Remaining" || other.name != "Used" { problems.append("segment names '\(selected.name)' / '\(other.name)'") }
        } else { problems.append("no MSAA object for a segment") }
        notes.append("selected segment: \(show(selected)); other: \(show(other))")
        let chipSel = MSAAProbe.query(chips.parts[0]), chipOther = MSAAProbe.query(chips.parts[1])
        if let chipSel, let chipOther, chipSel.state == chipOther.state { problems.append("the selected chip's MSAA state equals an unselected one's") }
        notes.append("chips: \(show(chipSel)) / \(show(chipOther))")
        let sOn = MSAAProbe.query(on.hwnd), sOff = MSAAProbe.query(off.hwnd)
        if let sOn, let sOff {
            if sOn.role != 0x2C || sOff.role != 0x2C { problems.append("switch role \(sOn.role)/\(sOff.role), expected check box 44") }
            if sOn.state & 0x10 == 0 || sOff.state & 0x10 != 0 { problems.append("switch CHECKED state: on 0x\(String(sOn.state, radix: 16)), off 0x\(String(sOff.state, radix: 16))") }
        } else { problems.append("no MSAA object for a switch") }
        notes.append("switch on: \(show(sOn)); off: \(show(sOff))")
        let button = MSAAProbe.query(enabled.hwnd), dis = MSAAProbe.query(disabled.hwnd), prim = MSAAProbe.query(primary.hwnd)
        if button?.role != 0x2B || prim?.role != 0x2B { problems.append("button roles \(button?.role ?? -1)/\(prim?.role ?? -1), expected push button 43") }
        if dis.map({ $0.state & 0x1 == 0 }) ?? true { problems.append("a disabled button is not UNAVAILABLE in MSAA") }
        if prim?.name != "Update" { problems.append("primary button name '\(prim?.name ?? "-")'") }
        notes.append("button: \(show(button)); disabled: \(show(dis)); primary: \(show(prim))")
        let bar = MSAAProbe.query(slider.parts[0])
        if bar?.role != 0x33 { problems.append("slider role \(bar?.role ?? -1), expected slider 51") }
        notes.append("slider: \(show(bar)) value '\(bar?.value ?? "")'")
        r.add("popover.msaa", problems.isEmpty, notes.joined(separator: " | ") + (problems.isEmpty ? "" : " | PROBLEMS: " + problems.joined(separator: "; ")))
    }

    static func run(_ r: WindowsSelftest.Recorder) async {
        crumbs = r
        var problems: [String] = []
        var notes: [String] = []
        for (name, dark, high) in [("light", false, false), ("dark", true, false), ("high contrast", false, true)] {
            let result = await evaluate(dark: dark, highContrast: high)
            problems.append(contentsOf: result.problems.map { "\(name): \($0)" })
            notes.append("\(name): \(result.note)")
        }
        let detail = notes.joined(separator: " | ") + (problems.isEmpty ? "" : " | PROBLEMS: " + problems.joined(separator: "; "))
        // The checks read as three names over one evaluation (each fails on its own kind of problem).
        func pick(_ key: String) -> [String] { problems.filter { $0.localizedCaseInsensitiveContains(key) } }
        let dropProblems = problems.filter { p in ["drop-down", "menu", "F4", "Alt+Down", "Down", "Up:", "Home", "End"].contains { p.contains($0) } }
        let stepperProblems = problems.filter { p in ["stepper", "half"].contains { p.localizedCaseInsensitiveContains($0) } }
        let fieldProblems = problems.filter { p in ["field", "frame", "WM_NCPAINT", "focus ring's"].contains { p.localizedCaseInsensitiveContains($0) } }
        let rest = problems.filter { p in !dropProblems.contains(p) && !stepperProblems.contains(p) && !fieldProblems.contains(p) }
        _ = pick
        r.add("popover.dropDown", dropProblems.isEmpty && rest.isEmpty, detail)
        r.add("popover.stepper", stepperProblems.isEmpty, "stepper problems: \(stepperProblems.count)" + (stepperProblems.isEmpty ? "" : " " + stepperProblems.joined(separator: "; ")))
        r.add("popover.field", fieldProblems.isEmpty, "field problems: \(fieldProblems.count)" + (fieldProblems.isEmpty ? "" : " " + fieldProblems.joined(separator: "; ")))
        await msaaChecks(r)
        WinCustomDraw.testDisabled = true
        let broken = await evaluate(dark: false, highContrast: false)
        WinCustomDraw.testDisabled = false
        r.add("popover.k4.fault", !broken.problems.isEmpty, "custom draw off: \(broken.problems.count) problems found as expected (first: \(broken.problems.first ?? "none"))")
    }
}
#endif
