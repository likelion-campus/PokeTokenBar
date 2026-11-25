#if os(Windows)
import CPlazaD2D
import Foundation
import WinSDK

/// Test-only switches that break one rule of the chat field each, so the tests prove they notice
/// (`WindowsPlazaChatInputTests.testEachInjectedFaultIsCaught`). Debug builds only; in a release build `has` is always false.
@MainActor enum WinChatFaults {
    enum Fault: CaseIterable, Sendable {
        /// Enter sends while a syllable is still being composed.
        case sendWhileComposing
        /// A held Enter (repeat bit) sends.
        case sendOnRepeat
        /// The line is cut to the limit while a syllable is being composed.
        case cutWhileComposing
        /// A paste keeps its line breaks and tabs.
        case pasteKeepsLineBreaks
        /// Closing leaves the composition in the IME (it comes back as a ghost on the next open).
        case keepCompositionOnClose
        /// A click on the bar's emoji grid does not finish the syllable first.
        case insertOverComposition
        /// An edit over a syllable shown in the field goes in as soon as the finish request returns, before the IME has put the syllable back.
        case editBeforeResult
        /// A field attached to a new window keeps the old window's "hidden" (its bar never draws after a close while hidden).
        case keepHiddenAcrossWindows
        /// The cut runs while a character is still missing its second UTF-16 half.
        case cutSplitsSurrogates
    }
    static var active: Set<Fault> = []

    @inline(__always) static func has(_ f: Fault) -> Bool {
        #if DEBUG
        return !active.isEmpty && active.contains(f)
        #else
        return false
        #endif
    }
}

/// The plaza's chat line on Windows (D13), the `PlazaChatInputHost` the shared controller talks to, as AppKit's `PlazaChatInput`
/// is on the Mac. The text area is the system's own one-line `EDIT` control (in a small host window, a child of the plaza
/// window, over the composition), so the IME, Hangul composition in place, the candidate and Hanja windows, the emoji panel
/// (Win + .), the clipboard, selection, undo, the caret and Narrator are Windows' own; this type adds only the Mac field's
/// rules on top: Enter sends (a composition still open is finished, not sent), a held Enter does nothing, Tab and Shift+Tab
/// toggle the megaphone, Esc closes, Ctrl+A selects all, Ctrl+W closes the plaza, paste puts one line in, the line is cut to
/// `TeamChat.maxCharacters` only when no syllable is being composed, leaving the field for the scene closes it, the app going
/// to the background does not. The chrome around the field (fill, border, 😀 button, emoji grid) is the shared
/// `PlazaChatBarPanel` in its own HUD, drawn into the window's frame above every other panel (`drawList`).
///
/// It owns no timer and no thread: it runs only inside the field's and the window's messages. Main thread only.
@MainActor final class WinPlazaChatInput: PlazaChatInputHost, PlazaPanelHost {
    /// Where the field lives. A plain child of the plaza window is NOT composed over its `WS_EX_NOREDIRECTIONBITMAP` parent (the
    /// screen shows the plate drawn under it and no text: `plaza.chatChildVisible` on the runner, captures in the task 11 report);
    /// a `WS_EX_LAYERED` child host (opaque, Windows 8+) gets its own redirection surface and is composed above the visual tree. The
    /// layered host ships; the plain child stays only for the selftest's comparison.
    enum FieldHost: Int, Sendable { case child = 0, layered = 1 }
    static var fieldHost: FieldHost = .layered

    /// What the IME holds, read from the field's input context; the tests put in what a real IME would report.
    struct IME {
        var composition: @MainActor (HWND) -> String
        var result: @MainActor (HWND) -> String
        var finish: @MainActor (HWND, _ cancel: Bool) -> Void
        static var system: IME { IME(composition: { WinPlazaChatInput.imeString($0, kind: 0x8) },
                                result: { WinPlazaChatInput.imeString($0, kind: 0x800) },
                                finish: { _ = ptb_ime_finish(UnsafeMutableRawPointer($0), $1 ? 1 : 0) }) }
    }

    struct Counts: Equatable {
        var submits = 0, refused = 0, repeatsIgnored = 0, completesAsked = 0, cancelsAsked = 0, cuts = 0, pastes = 0, picks = 0
        var compositionStarts = 0, compositionUpdates = 0, compositionEnds = 0, imeChars = 0, chars = 0, charsSwallowed = 0
        var closesByFocus = 0, keptOnFocusLoss = 0, focusRestores = 0, loudToggles = 0, imePlacements = 0, menuPumps = 0, selectAlls = 0
        var candidateOpens = 0, wordDeletes = 0, cutsDeferred = 0, editsDeferred = 0
    }

    /// The bar and its HUD are made on first use (the plaza window opening): the controller exists from launch, and measuring the
    /// field's font then would load DirectWrite at launch (`plaza.graphics.lazy`).
    var bar: PlazaChatBarPanel { made().bar }
    var hud: PlazaHUD { made().hud }
    private(set) var isOpen = false
    var isLoud: Bool { madeParts?.bar.isLoud ?? false }
    /// The placeholder the field shows now (the tests read it).
    private(set) var cueText = ""
    /// What the line asks for (`PlazaChatInputPurpose`): the word line has its own cue, no megaphone, no emoji grid and a 12-character cut.
    var purpose: PlazaChatInputPurpose = .chat {
        didSet { if purpose != oldValue { madeParts?.bar.hasEmojiButton = purpose == .chat; refreshCue() } }
    }
    var onSubmit: ((String) -> Bool)?
    var onClose: (() -> Void)?
    /// Ctrl+W in the field: the plaza window closes (⌘W in the Mac field, `PlazaChatTextField.commandAction`).
    var onCloseWindow: (() -> Void)?
    /// The bar's drawing or place changed: the window draws again and its tooltips follow.
    var onChange: (() -> Void)?
    var ime = IME.system
    /// The clipboard's text for a paste (CF_UNICODETEXT); tests put in their own.
    var clipboardText: @MainActor () -> String? = { WinPlazaChatInput.readClipboardText() }

    private(set) var counts = Counts()
    /// The composition as the field's messages report it: where it started (UTF-16 offset) and what it holds now; nil between
    /// WM_IME_ENDCOMPOSITION and the next WM_IME_STARTCOMPOSITION.
    private(set) var composition: (start: Int, text: String)?
    /// The panels to draw above every other, bottom first (the bar alone, or nothing while closed).
    private(set) var drawList: [WinPanelDraw] = []
    /// The bar's place in window points while shown.
    private(set) var barFrame: CGRect?
    /// The field's place in the window's client pixels while shown.
    private(set) var fieldPixels: (x: Int32, y: Int32, w: Int32, h: Int32)?
    private var editRaw: UnsafeMutableRawPointer?
    private var parent: HWND?
    private var drawing: PlazaPanelDrawing?
    private var scale: CGFloat = 1
    private var styledScale: CGFloat = 0
    private var depth = 0
    private var limitPending = false, applyingLimit = false
    /// Edits waiting for the IME to end a syllable it was asked to finish (TSF can deliver the end after `ImmNotifyIME` returns), each with
    /// where the syllable ends.
    private var afterComposition: [(at: Int?, edit: () -> Void)] = []
    /// Where the last finished syllable ended (UTF-16 offset), from the composition messages: the last fallback.
    private var lastCommitEnd: Int?
    /// What the last edit over a composition saw and did (the selftest prints it).
    private(set) var lastEditTrace = ""
    /// Edits over a syllable the field showed in place, waiting for the IME to commit it: the field's text back to `before` (the syllable now
    /// committed) after the IME reported a result or took the syllable out of the text. `end`: where the syllable ends in `before`.
    private struct PendingEdit {
        let before: [UInt16], end: Int, token: Int
        var edits: [() -> Void]
        var sawResult = false, sawRemoval = false
        var seen: [String] = []
    }
    private var pendingEdit: PendingEdit?
    private var pendingToken = 0, finishingEdit = false, checkingPending = false
    private var captured = false
    private static var fontLoaded: Bool?
    private let graphics: any PlazaGraphics
    private var madeParts: (bar: PlazaChatBarPanel, hud: PlazaHUD)?
    private var retained: Unmanaged<WinPlazaChatInput>?

    init(graphics: any PlazaGraphics = PlatformPlaza.graphics) {
        self.graphics = graphics
    }

    private func made() -> (bar: PlazaChatBarPanel, hud: PlazaHUD) {
        if let madeParts { return madeParts }
        let m = graphics.text.metrics(.plaza(.body))
        let bar = PlazaChatBarPanel(fieldHeight: (m.ascender - m.descender + m.leading).rounded(.up))
        let hud = PlazaHUD(panels: [bar], graphics: graphics)
        hud.onAction = { [weak self] _, hit in self?.clicked(hit) }
        madeParts = (bar, hud)
        return (bar, hud)
    }

    var editHWND: HWND? { editRaw.flatMap { HWND(bitPattern: Int(bitPattern: $0)) } }
    var hostHWND: HWND? { editRaw.flatMap { ptb_chat_edit_host($0) }.flatMap { HWND(bitPattern: Int(bitPattern: $0)) } }

    // MARK: attaching to a window

    /// Makes the field (hidden) in `parent` and shows the bar through this host. False when the EDIT could not be made (logged).
    @discardableResult
    func attach(parent: HWND) -> Bool {
        guard editRaw == nil else { return true }
        // The field's procedure calls back into this object until `detach`: it holds it (released there), so no message can reach a
        // freed input (a window destroyed with its parent sends its last messages after the owner let go).
        let context = Unmanaged.passRetained(self)
        guard let made = ptb_chat_edit_create(UnsafeMutableRawPointer(parent), Int32(Self.fieldHost.rawValue),
                                              { ctx, m, w, l, handled in winChatRoute(ctx, m, w, l, handled) }, context.toOpaque()) else {
            context.release()
            AppLog.write("plaza chat: the field could not be made (\(GetLastError())); the chat line is not available")
            return false
        }
        retained = context
        editRaw = made
        self.parent = parent
        styledScale = 0
        restyle()
        // A new window starts visible: the last window may have been closed while hidden (minimized, covered, on another desktop),
        // and its visibility callback set this HUD to not rendering. This object outlives windows; the controller resets its own HUD
        // the same way at close.
        if !WinChatFaults.has(.keepHiddenAcrossWindows) { hud.isRendering = true }
        hud.host = self
        return true
    }

    func detach() {
        if isOpen {   // the window goes away with the line open (the controller closes it first in the app)
            isOpen = false
            bar.isEmojiOpen = false
            bar.isOpen = false
        }
        if madeParts?.hud.host === self { madeParts?.hud.host = nil }
        pendingEdit = nil
        if let e = editRaw { ptb_chat_edit_destroy(e) }
        editRaw = nil
        retained?.release()
        retained = nil
        parent = nil
        drawing = nil
        barFrame = nil
        fieldPixels = nil
        drawList = []
        composition = nil
        captured = false
    }

    /// The window's content size (points) and backing scale: the bar's place, the field's font.
    func report(size: CGSize, scale: CGFloat) {
        self.scale = scale
        if scale != styledScale { restyle() }
        hud.setViewport(size, scale: scale)
        if let barFrame { placeField(barFrame) }
    }

    // MARK: PlazaChatInputHost

    func open() {
        guard !isOpen else { return }
        isOpen = true
        bar.isLoud = false
        bar.isEmojiOpen = false
        bar.hasEmojiButton = purpose == .chat
        resetField()
        refreshCue()
        bar.isOpen = true
        // The field shows now, so the keyboard lands on a visible field; its plate follows on the HUD's next turn (one frame).
        if let frame = hud.layout(viewport: hud.viewport, scale: hud.scale)[.chatBar] { placeField(frame) }
    }

    func close() {
        purpose = .chat
        guard isOpen else { return }
        isOpen = false
        bar.isEmojiOpen = false
        bar.isOpen = false
        resetField()
        let hadKeyboard = editHWND.map { GetFocus() == $0 } ?? false
        hideField()
        if hadKeyboard, let parent { _ = SetFocus(parent) }   // a hidden field never keeps the keyboard
        onClose?()
    }

    /// The field takes the keyboard (the controller's `focusChatInput`, and the window getting active again with the line open).
    @discardableResult
    func focus() -> Bool {
        guard isOpen, let e = editHWND else { return false }
        if GetFocus() != e { _ = SetFocus(e) }
        return true
    }

    /// The window became active with the line open: the keyboard goes back to the field (DefWindowProc would give it to the scene).
    /// Counted only when it moved the keyboard.
    func restoreFocus() -> Bool {
        guard isOpen, let e = editHWND else { return false }
        if GetFocus() != e {
            _ = SetFocus(e)
            counts.focusRestores += 1
        }
        return true
    }


    // MARK: the bar's mouse (window points), before the other panels

    /// A point on the shown bar: a press there keeps the keyboard in the field.
    func takes(_ point: CGPoint) -> Bool { barFrame?.contains(point) == true }

    /// The field's own pixels (client of the window): a press there goes to the EDIT itself.
    func fieldContains(pixel p: POINT) -> Bool {
        guard let f = fieldPixels else { return false }
        return p.x >= f.x && p.x < f.x + f.w && p.y >= f.y && p.y < f.y + f.h
    }

    func mouse(_ e: PlazaMouseEvent) -> Bool {
        switch e.kind {
        case .down:
            guard takes(e.location) else { captured = false; return false }
            captured = true
            _ = hud.handleMouse(e, in: .chatBar)
            return true
        case .up:
            guard captured else { return false }
            captured = false
            return hud.handleMouse(e, in: .chatBar)
        case .moved:
            return captured ? hud.handleMouse(e, in: .chatBar) : false
        case .exited:
            return false
        case .scroll:
            return takes(e.location)   // over the bar: nothing under it scrolls (the Mac's bar view passes it to nobody)
        }
    }

    /// The bar's hover texts in window points.
    var tips: [WinPlazaPanels.PointTip] {
        guard let drawing, let barFrame else { return [] }
        return drawing.tooltips.map { WinPlazaPanels.PointTip(frame: $0.frame.offsetBy(dx: barFrame.minX, dy: barFrame.minY), text: $0.text) }
    }

    // MARK: PlazaPanelHost (the bar's HUD)

    func show(_ id: PlazaPanelID, drawing: PlazaPanelDrawing, frame: CGRect, scale: CGFloat) {
        guard id == .chatBar else { return }
        self.drawing = drawing
        barFrame = frame
        drawList = [WinPanelDraw(layers: drawing.layers, frame: frame)]
        if isOpen { placeField(frame) }
        onChange?()
    }

    func hide(_ id: PlazaPanelID) {
        guard id == .chatBar else { return }
        drawing = nil
        barFrame = nil
        drawList = []
        hideField()
        onChange?()
    }

    // MARK: the field

    /// The emoji grid's cells and the 😀 button (through the bar's HUD).
    private func clicked(_ hit: PlazaPanelHit) {
        switch hit.action {
        case "emoji": if purpose == .chat { bar.isEmojiOpen.toggle() }
        case "pick":
            if purpose == .chat, let i = hit.index, PlazaChatEmojis.all.indices.contains(i) { insert(PlazaChatEmojis.all[i]) }
        default: break
        }
        _ = focus()   // the bar is not a window: the keyboard never left the field
    }

    /// Puts `text` at the caret, replacing the selection. A syllable being composed is finished first (the Mac's `unmarkText`).
    func insert(_ text: String) {
        guard let h = editHWND else { return }
        editAfterComposition(h) { [weak self] in
            guard let self else { return }
            replaceSelection(h, text)
            counts.picks += 1
            applyLimitIfDue()
        }
    }

    /// An edit at the caret (an emoji, a paste, a word delete) over a syllable being composed: the syllable is finished first and the edit
    /// goes AFTER it, as the Mac's `unmarkText` leaves the caret. The real IME's finish is not done when `ImmNotifyIME` returns (the
    /// syllable can leave the text and come back later at the caret): an edit over a syllable the field shows waits for it to be back
    /// (plaza.chatRealIME: 하 + 🍜).
    private func editAfterComposition(_ h: HWND, _ edit: @escaping () -> Void) {
        if pendingEdit != nil { pendingEdit?.edits.append(edit); counts.editsDeferred += 1; return }   // keeps the order of quick picks
        guard isComposing, !WinChatFaults.has(.insertOverComposition) else { edit(); return }
        let shown = ime.composition(h)
        let caret = selection.start
        let before = units(h)
        guard let end = Self.syllableEnd(before, Array(shown.utf16), caret: caret) else {
            // An IME that shows the syllable in a window of its own: finishing types it at the caret; the composition messages say where.
            let byRecord = composition.map { $0.start + $0.text.utf16.count }
            lastCommitEnd = nil
            finish(h, cancel: false)
            let at = byRecord ?? lastCommitEnd
            lastEditTrace = "composing \(shown.debugDescription) not in the text; by the record \(at.map(String.init) ?? "-")"
            if isComposing {
                afterComposition.append((at, edit))
                counts.editsDeferred += 1
                return
            }
            if let at = lastCommitEnd ?? at { _ = SendMessageW(h, 0x00B1 /* EM_SETSEL */, WPARAM(at), LPARAM(at)) }
            edit()
            return
        }
        // The EDIT shows the syllable in its text (the real Korean IME). Its end can take the syllable out of the text and type it back
        // later, at the caret (plaza.chatRealIME: '🍜하' twice): the edit waits until the field shows the committed syllable again.
        pendingToken += 1
        let token = pendingToken
        pendingEdit = PendingEdit(before: before, end: end, token: token, edits: [edit])
        finishingEdit = true
        finish(h, cancel: false)
        finishingEdit = false
        let now = units(h)
        lastEditTrace = "composing \(shown.debugDescription) caret \(caret), syllable ends at \(end); after the finish request: text "
            + "\(String(decoding: now, as: UTF16.self).debugDescription) composing=\(isComposing) seen \(pendingEdit?.seen ?? [])"
        if WinChatFaults.has(.editBeforeResult) { runPendingEdit(h, why: "at once"); return }
        if runPendingEditIfDue(h) { return }
        counts.editsDeferred += 1
        Task { @MainActor [weak self] in   // an IME that never reports: the edit is not lost
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, self.pendingEdit?.token == token, let h = self.editHWND else { return }
            self.runPendingEdit(h, why: "after 0.3 s")
        }
    }

    /// A message to the field while an edit waits: what the IME delivered (the selftest prints the sequence).
    private func notePending(_ m: UInt32, _ w: UInt64, _ l: Int64) {
        guard pendingEdit != nil else { return }
        let u = String(UInt32(truncatingIfNeeded: w), radix: 16)
        switch m {
        case 0x010F:
            if UInt32(truncatingIfNeeded: l) & 0x800 != 0 { pendingEdit?.sawResult = true }
            note("comp 0x\(String(UInt32(truncatingIfNeeded: l), radix: 16))")
        case 0x010E: note("end")
        case 0x010D: note("start")
        case 0x0286: pendingEdit?.sawResult = true; note("imechar \(u)")
        case 0x0102: pendingEdit?.sawResult = true; note("char \(u)")
        default: break
        }
    }

    private func note(_ s: String) {
        if (pendingEdit?.seen.count ?? 99) < 16 { pendingEdit?.seen.append(s) }
    }

    /// Runs the waiting edits once the IME is done: no composition, the field's text back to what it showed (the syllable committed in
    /// place), after a result or after the syllable left the text.
    private func runPendingEditIfDue(_ h: HWND) -> Bool {
        guard let p = pendingEdit else { return false }
        checkingPending = true
        let now = units(h)
        checkingPending = false
        if now != p.before { pendingEdit?.sawRemoval = true }
        guard !isComposing, now == p.before, p.sawResult || pendingEdit?.sawRemoval == true else { return false }
        runPendingEdit(h, why: "when the syllable was back")
        return true
    }

    /// The field's messages after which a waiting edit may be due: a composition update, its end, a character, a text change.
    nonisolated static func deliversIMEOutput(_ m: UInt32) -> Bool {
        m == 0x010F || m == 0x010E || m == 0x0286 || m == 0x0102 || m == PTB_CHAT_CHANGED
    }

    private func runPendingEdit(_ h: HWND, why: String) {
        guard let p = pendingEdit else { return }
        pendingEdit = nil
        let now = units(h)
        let at = now == p.before ? p.end : selection.start   // after the syllable; or where the IME left the caret (it typed something else)
        _ = SendMessageW(h, 0x00B1 /* EM_SETSEL */, WPARAM(at), LPARAM(at))
        lastEditTrace += "; \(why): seen \(p.seen), text \(String(decoding: now, as: UTF16.self).debugDescription) -> at \(at)"
        for e in p.edits { e() }
    }

    /// The end (UTF-16) of `syllable` shown in `text` at the caret: right after the caret (the EDIT's caret sits at a composition's start) or
    /// right before it. nil when the text does not hold it there (an IME that shows its composition in a window of its own).
    nonisolated static func syllableEnd(_ text: [UInt16], _ syllable: [UInt16], caret: Int) -> Int? {
        let n = syllable.count
        guard n > 0, caret >= 0, caret <= text.count else { return nil }
        if caret + n <= text.count, Array(text[caret..<caret + n]) == syllable { return caret + n }
        if caret >= n, Array(text[(caret - n)..<caret]) == syllable { return caret }
        return nil
    }

    private func placeField(_ frame: CGRect) {
        guard let e = editRaw, isOpen else { return }
        let r = bar.fieldRect.offsetBy(dx: frame.minX, dy: frame.minY)
        let x = Int32((r.minX * scale).rounded()), y = Int32((r.minY * scale).rounded())
        let w = Int32((r.maxX * scale).rounded()) - x, h = Int32((r.maxY * scale).rounded()) - y
        if let p = fieldPixels, p.x == x, p.y == y, p.w == w, p.h == h { return }
        _ = ptb_chat_edit_place(e, x, y, w, h, 1)
        fieldPixels = (x, y, w, h)
    }

    private func hideField() {
        guard let e = editRaw, fieldPixels != nil else { return }
        _ = ptb_chat_edit_place(e, 0, 0, 0, 0, 0)
        fieldPixels = nil
    }

    /// Galmuri14 at the body size in device pixels, white on the bar's colour, the placeholder as the cue banner.
    private func restyle() {
        guard let e = editRaw else { return }
        styledScale = scale
        if Self.fontLoaded == nil {
            let url = WinPlazaAssets.resolve("Galmuri14", ext: "ttf", in: WinPlazaAssets.directories)
            let added = url.map { ptb_chat_font_add(WinStr.w(WinPath.native($0))) } ?? 0
            Self.fontLoaded = added > 0
            if added <= 0 { AppLog.write("plaza chat: Galmuri14 not loaded (\(url.map { WinPath.native($0) } ?? "no file")); the field uses the system font") }
        }
        let px = (15 * scale).rounded()
        let quality: Int32 = px.truncatingRemainder(dividingBy: 15) == 0 ? 3 /* NONANTIALIASED */ : 4 /* ANTIALIASED */
        _ = ptb_chat_edit_style(e, 0x00FF_FFFF, 0x005C_4F1D /* 1D4F5C */, WinStr.w("Galmuri14"), Int32(px), quality,
                                Int32((PlazaChatBarPanel.fieldTextInset * scale).rounded()))   // the AppKit field's text inset
        refreshCue()
    }

    private func refreshCue() {
        let l = L(.ko)
        cueText = purpose == .quizWord ? l.plazaDrawWordPlaceholder : bar.isLoud ? l.plazaLoudPlaceholder : l.plazaChatPlaceholder
        guard let e = editRaw else { return }
        _ = ptb_chat_edit_cue(e, WinStr.w(cueText))
    }

    /// Empty, with no composition left behind (a cancelled syllable must not come back on the next open).
    private func resetField() {
        guard let h = editHWND else { return }
        if !ime.composition(h).isEmpty, !WinChatFaults.has(.keepCompositionOnClose) { finish(h, cancel: true) }
        afterComposition = []   // nothing waits on a line that is being emptied
        pendingEdit = nil
        applyingLimit = true
        setText(h, "")
        applyingLimit = false
        limitPending = false
        composition = nil
    }

    var isComposing: Bool { editHWND.map { !ime.composition($0).isEmpty } ?? false }

    private func finish(_ h: HWND, cancel: Bool) {
        if cancel { counts.cancelsAsked += 1 } else { counts.completesAsked += 1 }
        ime.finish(h, cancel)
    }

    // MARK: the field's messages

    fileprivate func message(_ m: UInt32, _ w: UInt64, _ l: Int64, _ handled: UnsafeMutablePointer<Int32>?) -> Int64 {
        handled?.pointee = 1
        if pendingEdit != nil { notePending(m, w, l) }
        depth += 1
        let r = handle(m, w, l)
        depth -= 1
        if depth == 0 {
            // Only after what the IME delivers or a text change, never re-entered: reading the text sends WM_GETTEXT through here.
            if pendingEdit != nil, !finishingEdit, !checkingPending, Self.deliversIMEOutput(m), let h = editHWND { _ = runPendingEditIfDue(h) }
            applyLimitIfDue()
        }
        return r
    }

    private func pass(_ m: UInt32, _ w: UInt64, _ l: Int64) -> Int64 {
        guard let e = editRaw else { return 0 }
        return ptb_chat_edit_default(e, m, w, l)
    }

    private func handle(_ m: UInt32, _ w: UInt64, _ l: Int64) -> Int64 {
        switch m {
        case PTB_CHAT_CHANGED:
            if !applyingLimit { limitPending = true }
            return 0
        case 0x0100:   // WM_KEYDOWN
            if let r = keyDown(w, l) { return r }
        case 0x0102:   // WM_CHAR
            if Self.swallows(character: UInt32(truncatingIfNeeded: w)) { counts.charsSwallowed += 1; return 0 }
            counts.chars += 1
        case 0x0286:   // WM_IME_CHAR (re-dispatched in Unicode by WinMessageHook)
            counts.imeChars += 1
        case 0x0302:   // WM_PASTE (Ctrl+V, Shift+Insert, the context menu)
            paste()
            return 0
        case 0x007B:   // WM_CONTEXTMENU: the EDIT's own menu is a modal loop; the pump keeps the main queue served meanwhile
            counts.menuPumps += 1
            WinModalPump.begin("chatmenu")
            defer { WinModalPump.end("chatmenu") }
            return pass(m, w, l)
        case 0x010D:   // WM_IME_STARTCOMPOSITION
            let r = pass(m, w, l)
            counts.compositionStarts += 1
            composition = (selectionStart, "")
            placeIME()
            return r
        case 0x010F:   // WM_IME_COMPOSITION
            let r = pass(m, w, l)
            compositionChanged(UInt32(truncatingIfNeeded: l))
            return r
        case 0x010E:   // WM_IME_ENDCOMPOSITION
            let endAt = composition?.start   // past the finished text (GCS_RESULTSTR moved it there)
            let r = pass(m, w, l)
            counts.compositionEnds += 1
            lastCommitEnd = endAt
            composition = nil
            limitPending = true
            if !afterComposition.isEmpty, let h = editHWND {
                let edits = afterComposition
                afterComposition = []
                for e in edits {
                    if let at = e.at ?? endAt { _ = SendMessageW(h, 0x00B1 /* EM_SETSEL */, WPARAM(at), LPARAM(at)) }
                    e.edit()
                }
            }
            return r
        case 0x0007:   // WM_SETFOCUS
            let r = pass(m, w, l)
            placeIME()
            return r
        case 0x0008:   // WM_KILLFOCUS
            return killFocus(w, l)
        case 0x0282:   // WM_IME_NOTIFY: count the candidate list opening (Hanja), then the EDIT's own handling
            if w == 0x0005 /* IMN_OPENCANDIDATE */ { counts.candidateOpens += 1 }
        case 0x0201:   // WM_LBUTTONDOWN in the field: a syllable being composed is finished where it is, then the caret moves
            if let h = editHWND, !ime.composition(h).isEmpty { finish(h, cancel: false) }
        default:
            break
        }
        return pass(m, w, l)
    }

    private func compositionChanged(_ flags: UInt32) {
        counts.compositionUpdates += 1
        guard let h = editHWND else { return }
        var start = composition?.start ?? selectionStart
        if flags & 0x800 != 0 {   // GCS_RESULTSTR: committed text went in where the composition was; a new one follows it
            start += ime.result(h).utf16.count
            limitPending = true
        }
        composition = (start, ime.composition(h))
        placeIME()
    }

    /// The composition window at the caret and the candidate list (Hanja) next to the line, in the field's pixels.
    private func placeIME() {
        guard let e = editRaw, let h = editHWND, ptb_chat_caret_window().map({ HWND(bitPattern: Int(bitPattern: $0)) == h }) == true else { return }
        var caret: [Int32] = [0, 0]
        guard ptb_chat_caret(&caret) == 1 else { return }
        if ptb_ime_place(e, caret[0], caret[1], fieldPixels?.h ?? Int32((bar.fieldHeight * scale).rounded())) == 1 { counts.imePlacements += 1 }
    }

    private func keyDown(_ w: UInt64, _ l: Int64) -> Int64? {
        let vk = UInt32(truncatingIfNeeded: w)
        let bits = WinPlazaInput.KeyBits(lParam: LPARAM(l))
        switch vk {
        case 0x0D:   // Enter and the keypad's Enter
            if bits.isRepeat, !WinChatFaults.has(.sendOnRepeat) { counts.repeatsIgnored += 1; return 0 }   // the Enter that opened the field, still held
            guard let h = editHWND else { return 0 }
            if !ime.composition(h).isEmpty, !WinChatFaults.has(.sendWhileComposing) {   // the Mac: only the syllable is finished, nothing is sent
                finish(h, cancel: false)
                return 0
            }
            submit(h)
            return 0
        case 0x09:   // Tab, Shift+Tab: the megaphone (leaving the field would close it)
            if purpose == .chat {
                bar.isLoud.toggle()
                counts.loudToggles += 1
                refreshCue()
            }
            return 0
        case 0x1B:   // Esc
            close()
            return 0
        default:
            break
        }
        // ⌘ chords by key position, as the Mac field's `commandAction`: Ctrl alone (AltGr is a character key, not Ctrl).
        guard WinPlazaInput.currentModifiers() == [.command, .control] else { return nil }
        if vk == 0x08 {   // Ctrl+Backspace: the word before the caret (the Mac's Option+Backspace)
            deleteWordBackward()
            return 0
        }
        guard let key = WinPlazaInput.macKeyCode(scanCode: bits.scanCode, extended: bits.extended) else { return nil }
        switch key {
        case PlazaKeyCode.a:
            if let h = editHWND { _ = SendMessageW(h, 0x00B1 /* EM_SETSEL */, 0, -1) }
            counts.selectAlls += 1
            return 0
        case PlazaKeyCode.w:
            DispatchQueue.main.async { [weak self] in self?.onCloseWindow?() }   // not from inside the field's own message
            return 0
        default:
            return nil   // Ctrl+C / X / V / Z: the EDIT's own
        }
    }

    private func submit(_ h: HWND) {
        counts.submits += 1
        if onSubmit?(text(h)) != false {
            close()
        } else {
            counts.refused += 1
        }
    }

    /// WM_KILLFOCUS: a syllable being composed is finished first (no syllable stuck in the IME, none lost). The keyboard moving to
    /// the scene (a click on the map, `focusScene`) closes the line, as the Mac's `controlTextDidEndEditing`; the app going to the
    /// background (Alt+Tab, Win+L, the tray menu) keeps it, as the Mac keeps the field editor in the key window.
    private func killFocus(_ w: UInt64, _ l: Int64) -> Int64 {
        if let h = editHWND, !ime.composition(h).isEmpty { finish(h, cancel: false) }
        let r = pass(0x0008, w, l)
        guard isOpen else { return r }
        if let to = HWND(bitPattern: Int(truncatingIfNeeded: w)), let parent, to != editHWND, to != hostHWND,
           GetAncestor(to, UINT(GA_ROOT)) == parent {
            counts.closesByFocus += 1
            DispatchQueue.main.async { [weak self] in   // never inside WM_KILLFOCUS
                guard let self, isOpen, let e = editHWND, GetFocus() != e else { return }
                close()
            }
        } else {
            counts.keptOnFocusLoss += 1
        }
        return r
    }

    /// Ctrl+Backspace: the selection, or else the word before the caret with the spaces after it (AppKit's `deleteWordBackward`, which
    /// the Mac field runs for Option+Backspace). A syllable being composed is finished first.
    func deleteWordBackward() {
        guard let h = editHWND else { return }
        editAfterComposition(h) { [weak self] in self?.deleteWordBeforeCaret(h) }
    }

    private func deleteWordBeforeCaret(_ h: HWND) {
        let sel = selection
        var from = sel.start
        if sel.start == sel.end {
            let line = String(decoding: units(h), as: UTF16.self)
            var i = String.Index(utf16Offset: min(sel.start, line.utf16.count), in: line)
            while i > line.startIndex, line[line.index(before: i)].isWhitespace { i = line.index(before: i) }
            while i > line.startIndex, !line[line.index(before: i)].isWhitespace { i = line.index(before: i) }
            from = line.utf16.distance(from: line.startIndex, to: i)
        }
        guard from < sel.end else { return }
        _ = SendMessageW(h, 0x00B1 /* EM_SETSEL */, WPARAM(from), LPARAM(sel.end))
        replaceSelection(h, "")
        counts.wordDeletes += 1
    }

    private func paste() {
        guard let h = editHWND, let raw = clipboardText() else { return }
        let text = WinChatFaults.has(.pasteKeepsLineBreaks) ? raw : Self.pastable(raw)
        editAfterComposition(h) { [weak self] in
            self?.replaceSelection(h, text)
            self?.counts.pastes += 1
        }
    }

    /// One line from pasted text: line breaks and tabs become spaces (as `TeamChat.prepared` sends them), at most the line limit
    /// (the whole line is cut to the limit afterwards anyway, as the Mac's `controlTextDidChange` does).
    nonisolated static func pastable(_ raw: String) -> String {
        String(raw.prefix(TeamChat.maxCharacters).map { $0.isNewline || $0 == "\t" ? " " : $0 })
    }

    /// A UTF-16 high half with no low half after it (a character typed one unit at a time is still arriving), and any unpaired half.
    nonisolated static func unpairedSurrogates(_ u: [UInt16]) -> (pendingHigh: Bool, any: Bool) {
        var pendingHigh = false, any = false, i = 0
        while i < u.count {
            let c = u[i]
            if (0xD800...0xDBFF).contains(c) {
                if i + 1 < u.count, (0xDC00...0xDFFF).contains(u[i + 1]) { i += 2; continue }
                pendingHigh = true
                any = true
            } else if (0xDC00...0xDFFF).contains(c) {
                any = true
            }
            i += 1
        }
        return (pendingHigh, any)
    }

    /// Characters the one-line field must not take: Enter, Tab and Esc (handled as keys), Ctrl+A / Ctrl+W (handled), Ctrl+Backspace's
    /// DEL and the other control characters. Backspace and Ctrl+C / V / X / Z go to the EDIT.
    nonisolated static func swallows(character c: UInt32) -> Bool {
        if c == 0x7F { return true }
        guard c < 0x20 else { return false }
        return ![0x08, 0x03, 0x16, 0x18, 0x1A].contains(c)
    }

    /// The Mac's `controlTextDidChange`: never while a syllable is being composed; else the line is cut to the limit, the caret kept.
    private func applyLimitIfDue() {
        guard limitPending, !applyingLimit, let h = editHWND else { return }
        limitPending = false
        guard ime.composition(h).isEmpty || WinChatFaults.has(.cutWhileComposing) else { return }
        let raw = units(h)
        // One character can arrive one UTF-16 half at a time (VK_PACKET: the touch keyboard, emoji tools): cutting then would decode the
        // lone half as U+FFFD and write that back. Wait for the other half; and never write a repaired decode back at all.
        let halves = Self.unpairedSurrogates(raw)
        if halves.any, !WinChatFaults.has(.cutSplitsSurrogates) {
            if halves.pendingHigh { limitPending = true }
            counts.cutsDeferred += 1
            return
        }
        let line = String(decoding: raw, as: UTF16.self)
        guard line.count > purpose.maxCharacters else { return }
        let caret = selectionStart
        let cut = String(line.prefix(purpose.maxCharacters))
        applyingLimit = true
        setText(h, cut)
        applyingLimit = false
        limitPending = false
        let at = min(caret, cut.utf16.count)
        _ = SendMessageW(h, 0x00B1 /* EM_SETSEL */, WPARAM(at), LPARAM(at))
        counts.cuts += 1
    }

    // MARK: Win32 text plumbing

    var text: String { editHWND.map { text($0) } ?? "" }

    private func text(_ h: HWND) -> String { String(decoding: units(h), as: UTF16.self) }

    /// The field's raw UTF-16 (what the EDIT holds, unpaired halves included).
    private func units(_ h: HWND) -> [UInt16] {
        let n = Int(SendMessageW(h, 0x000E /* WM_GETTEXTLENGTH */, 0, 0))
        guard n > 0 else { return [] }
        var buf = [UInt16](repeating: 0, count: n + 1)
        let got = buf.withUnsafeMutableBufferPointer { p in
            Int(SendMessageW(h, 0x000D /* WM_GETTEXT */, WPARAM(n + 1), LPARAM(Int(bitPattern: p.baseAddress))))
        }
        return Array(buf.prefix(max(0, min(got, n))))
    }

    /// The raw UTF-16 (tests and the selftest).
    var rawText: [UInt16] { editHWND.map { units($0) } ?? [] }

    private func setText(_ h: HWND, _ s: String) {
        _ = WinStr.w(s).withUnsafeBufferPointer { SendMessageW(h, 0x000C /* WM_SETTEXT */, 0, LPARAM(Int(bitPattern: $0.baseAddress))) }
    }

    private func replaceSelection(_ h: HWND, _ s: String) {
        _ = WinStr.w(s).withUnsafeBufferPointer { SendMessageW(h, 0x00C2 /* EM_REPLACESEL */, 1, LPARAM(Int(bitPattern: $0.baseAddress))) }
    }

    /// The selection in UTF-16 units (EM_GETSEL; the line is short).
    var selection: (start: Int, end: Int) {
        guard let h = editHWND else { return (0, 0) }
        let r = UInt32(truncatingIfNeeded: SendMessageW(h, 0x00B0 /* EM_GETSEL */, 0, 0))
        return (Int(r & 0xFFFF), Int(r >> 16))
    }

    private var selectionStart: Int { selection.start }

    nonisolated static func imeString(_ h: HWND, kind: UInt32) -> String {
        var buf = [UInt16](repeating: 0, count: 256)
        let n = Int(ptb_ime_string(UnsafeMutableRawPointer(h), kind, &buf, Int32(buf.count)))
        return n > 0 ? String(decoding: buf.prefix(min(n, buf.count)), as: UTF16.self) : ""
    }

    /// The most a paste reads: the line holds 60 characters; 16 UTF-16 units each covers joined emoji and combining marks.
    nonisolated static let pasteReadUnits = TeamChat.maxCharacters * 16

    /// The clipboard's text, at most `pasteReadUnits` of it (a clipboard holding megabytes costs no more), a half character at the cut
    /// dropped.
    nonisolated static func readClipboardText() -> String? {
        var buf = [UInt16](repeating: 0, count: pasteReadUnits)
        let n = Int(ptb_clipboard_read_text(&buf, UInt32(buf.count), 300))
        guard n >= 0 else { return nil }
        var units = Array(buf.prefix(n))
        if let last = units.last, (0xD800...0xDBFF).contains(last) { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }
}

/// The field's subclass procedure calls this first for every message (C, `PTBChatProc`). Windows calls it on the thread that made
/// the field, the main thread, so entering the main actor is sound (F16).
private func winChatRoute(_ context: UnsafeMutableRawPointer?, _ message: UInt32, _ wParam: UInt64, _ lParam: Int64,
                          _ handled: UnsafeMutablePointer<Int32>?) -> Int64 {
    guard let context else { return 0 }
    let bits = Int(bitPattern: context)
    let handledBits = handled.map { Int(bitPattern: $0) } ?? 0
    return MainActor.assumeIsolated {
        guard let raw = UnsafeMutableRawPointer(bitPattern: bits) else { return 0 }
        let input = Unmanaged<WinPlazaChatInput>.fromOpaque(raw).takeUnretainedValue()
        return input.message(message, wParam, lParam, UnsafeMutablePointer<Int32>(bitPattern: handledBits))
    }
}
#endif
