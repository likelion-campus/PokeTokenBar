import Foundation

/// The plaza window where there is none: headless tests and Windows until stage 6 brings its window. Nothing is shown,
/// nothing is drawn and nothing ticks; it reports "unavailable" (not frontmost, no drawing loop, no diagnostics) and
/// logs once when a plaza is opened on it. It keeps the window's lifecycle, though: between `open` and `dismantle` it is
/// "open", and `requestClose` then reports `handleClose` at once, as the Mac's `performClose` does.
@MainActor final class PlazaHeadlessShell: PlazaWindowShell {
    weak var events: (any PlazaWindowEvents)?
    private let log: (String) -> Void
    private var logged = false
    /// Between `open` and `dismantle`.
    private(set) var isOpen = false
    /// The stage `open` was given, held until `stopPresenting` (as the Mac's `SKView` holds its `SKScene`).
    private(set) var presentedStage: (any PlazaStage)?

    init(log: @escaping (String) -> Void = { _ in }) {
        self.log = log
    }

    func open(stage: any PlazaStage, title: String, overlays: PlazaOverlayBindings) {
        isOpen = true
        presentedStage = stage
        guard !logged else { return }
        logged = true
        log("PlazaHeadlessShell: no plaza window on this platform yet")
    }

    func bringToFront() {}
    func requestClose() {
        guard isOpen else { return }
        events?.handleClose()
    }
    func stopPresenting() { presentedStage = nil }
    func dismantle() { isOpen = false }
    func setTitle(_ title: String) {}
    func setTransparent(_ transparent: Bool) {}
    func setHUDHidden(_ hidden: Bool) {}
    func focusScene() {}
    func focusChatInput() {}
    func setChatLogAboveInput(_ above: Bool) {}
    var isFrontmost: Bool { false }
    var isInLiveResize: Bool { false }
    var renderLoop: (any PlazaPausableView)? { nil }
    var diagnostics: (occlusionVisible: Bool?, isKey: Bool?) { (nil, nil) }
}

/// A chat field without a native control: it keeps the open/closed and megaphone state the controller reads, so the chat
/// flow behaves as on the Mac, and logs once when it is first opened. Nothing can be typed into it.
@MainActor final class PlazaStubChatInput: PlazaChatInputHost {
    private(set) var isOpen = false
    private(set) var isLoud = false
    var onSubmit: ((String) -> Bool)?
    var onClose: (() -> Void)?
    private let log: (String) -> Void
    private var logged = false

    init(log: @escaping (String) -> Void = { _ in }) {
        self.log = log
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        isLoud = false
        if !logged {
            logged = true
            log("PlazaStubChatInput: no chat field on this platform yet")
        }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        onClose?()
    }
}
