import Foundation

/// The plaza window where there is none: headless tests and Windows until stage 6 brings its window. Nothing is shown,
/// nothing is drawn and nothing ticks; it reports "unavailable" (not frontmost, no drawing loop, no diagnostics) and
/// logs once when a plaza is opened on it.
@MainActor final class PlazaHeadlessShell: PlazaWindowShell {
    weak var events: (any PlazaWindowEvents)?
    private let log: (String) -> Void
    private var logged = false

    init(log: @escaping (String) -> Void = { _ in }) {
        self.log = log
    }

    func open(stage: any PlazaStage, title: String, overlays: PlazaOverlayBindings) {
        guard !logged else { return }
        logged = true
        log("PlazaHeadlessShell: no plaza window on this platform yet")
    }

    func bringToFront() {}
    func requestClose() {}
    func stopPresenting() {}
    func dismantle() {}
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
