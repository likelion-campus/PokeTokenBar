import Foundation

/// The OS clipboard for the plaza photo. The Mac writes the PNG to the general pasteboard; Windows implements it in
/// `Platform/Windows/` later, and until then the stub reports "unavailable".
protocol ImageClipboarding: Sendable {
    /// Puts the PNG on the clipboard (replacing what was there). False when it could not be written.
    func writePNG(_ data: Data) -> Bool
}

/// The plaza's OS edge: the one place that picks the Mac backend or the headless stub. The Mac types live in
/// `Platform/Mac/Plaza/`; selection follows `PlatformLimits` (`PTB_SHARED_ONLY` is the Mac checking the Windows set).
enum PlatformPlaza {
    /// Canvases, text, bundled assets and image codecs: CoreGraphics/CoreText/ImageIO on the Mac, the stub elsewhere.
    static let graphics: any PlazaGraphics = {
        #if os(Windows) || PTB_SHARED_ONLY
        PlazaStubGraphics(log: { AppLog.write($0) })
        #else
        MacPlazaGraphics()
        #endif
    }()

    /// The photo clipboard: the general pasteboard on the Mac, the logging stub elsewhere.
    static let clipboard: any ImageClipboarding = {
        #if os(Windows) || PTB_SHARED_ONLY
        StubImageClipboard(log: { AppLog.write($0) })
        #else
        MacImageClipboard()
        #endif
    }()

    /// The modifier keys held right now. The scene polls it every frame (key-up events do not arrive while Command
    /// is held). Windows reads its keyboard in stage 6; until then nothing is held there.
    @MainActor static func currentModifiers() -> PlazaModifiers {
        #if os(Windows) || PTB_SHARED_ONLY
        []
        #else
        MacPlazaInput.currentModifiers()
        #endif
    }

    /// Where the scene draws: SpriteKit on the Mac (`SpriteKitStage`, whose `SKScene` the window's `SKView` presents),
    /// the headless stage elsewhere (no drawing, no frame clock: the scene gets no `update` until stage 6 adds one).
    @MainActor static func makeStage(size: CGSize) -> any PlazaStage {
        #if os(Windows) || PTB_SHARED_ONLY
        PlazaHeadlessStage(size: size)
        #else
        SpriteKitStage(size: size)
        #endif
    }

    /// Where character sprites come from: `SpriteLoader`/`SpriteStore` on the Mac, nothing (the placeholder) elsewhere.
    @MainActor static func spriteFetcher() -> any PlazaSpriteFetching {
        #if os(Windows) || PTB_SHARED_ONLY
        PlazaStubSpriteFetcher(log: { AppLog.write($0) })
        #else
        LivePlazaSpriteFetcher()
        #endif
    }
}
