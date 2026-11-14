import Foundation

/// A drawing loop that can be paused (the Mac's `SKView`). Tests swap in a fake, without a window.
@MainActor protocol PlazaPausableView: AnyObject { var isPaused: Bool { get set } }

/// What the window tells the plaza controller (`PlazaWindowController`). The shell forwards its window's events here and
/// decides nothing itself.
@MainActor protocol PlazaWindowEvents: AnyObject {
    /// The content area's height after a resize (the roster's page size follows it).
    func contentHeightDidChange(_ height: CGFloat)
    /// Minimized, fully covered or shown again.
    func setRendering(visible: Bool)
    func didResignKey()
    func didBecomeKey()
    /// The window is closing (by the user, ⌘W or `requestClose`).
    func handleClose()
}

/// The controller's models and actions the overlay views read and call. The Mac shell hosts its SwiftUI views over these;
/// the closures hold the controller weakly.
struct PlazaOverlayBindings {
    let rosterModel: PlazaRosterModel
    let overlayModel: PlazaOverlayModel
    let feed: TeamFeedStore?
    let myMemberID: String
    let chatLog: PlazaChatLog
    let minimap: PlazaMinimapModel
    let backgroundModel: PlazaBackgroundModel
    let shortcutModel: PlazaShortcutGuideModel
    let nameColorModel: PlazaNameColorModel
    let mapImage: PlazaImage
    let worldSize: CGSize
    /// The native one-line field (per OS); the shell puts its view in the window and focuses it.
    let chatInput: any PlazaChatInputHost
    let walkToMember: (String) -> Void
    let turnRosterPage: (Int) -> Void
    let react: (_ eventID: String, _ kind: TeamReactionKind) -> Void
    let chooseMenu: (_ action: PlazaMemberAction, _ memberID: String) -> Void
    let closeOverlay: () -> Void
    let chooseCampfire: (_ index: Int) -> Void
    let toggleChatLog: () -> Void
    let toggleShortcuts: () -> Void
    let toggleBackground: () -> Void
    let toggleNameColorPicker: () -> Void
    let pickNameColor: (UInt32) -> Void
}

/// The plaza window on one OS: the window, the view that draws the stage, the overlay views and focus. The Mac's is
/// `PlazaMacWindow` (AppKit, `SKView`, SwiftUI); headless tests and Windows until stage 6 use `PlazaHeadlessShell`.
/// Every call is a no-op while no window is open, as `window?.…` was.
@MainActor protocol PlazaWindowShell: AnyObject {
    var events: (any PlazaWindowEvents)? { get set }
    /// Makes the window and presents `stage`. The controller keeps the stage's scene alive until `stopPresenting`.
    func open(stage: any PlazaStage, title: String, overlays: PlazaOverlayBindings)
    /// Brings the app forward and the window to the front (the only call that activates the app).
    func bringToFront()
    /// Closes the window the way the close button does; the shell then reports `handleClose`.
    func requestClose()
    /// Stops drawing the presented stage. Called before the controller lets go of the stage's scene.
    func stopPresenting()
    /// Lets go of the window and its views (after `stopPresenting`).
    func dismantle()
    func setTitle(_ title: String)
    /// See-through window (background hidden): no fill, no shadow.
    func setTransparent(_ transparent: Bool)
    /// Hides the HUD panels for photo mode (not the overlay or the chat field).
    func setHUDHidden(_ hidden: Bool)
    /// Gives the keys back to the scene.
    func focusScene()
    func focusChatInput()
    /// While the chat field is open the chat log sits above it.
    func setChatLogAboveInput(_ above: Bool)
    /// The app is active and the plaza window is its key window.
    var isFrontmost: Bool { get }
    /// The user is dragging the window's size (SpriteKit does not draw then).
    var isInLiveResize: Bool { get }
    /// The drawing loop of the open window.
    var renderLoop: (any PlazaPausableView)? { get }
    /// For the state log only: whether the window is visible on screen and key. nil without a window.
    var diagnostics: (occlusionVisible: Bool?, isKey: Bool?) { get }
}

/// The one-line chat field (per OS: AppKit's `PlazaChatInput` on the Mac). Its own keys (Enter, Tab for the megaphone,
/// Esc) and its emoji panel stay inside it.
@MainActor protocol PlazaChatInputHost: AnyObject {
    var isOpen: Bool { get }
    /// The megaphone is on for this line.
    var isLoud: Bool { get }
    func open()
    func close()
    /// The typed line. false keeps the field open with the line in it.
    var onSubmit: ((String) -> Bool)? { get set }
    /// Called whenever the field closes.
    var onClose: (() -> Void)? { get set }
}
