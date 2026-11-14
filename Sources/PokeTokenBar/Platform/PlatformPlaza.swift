import Foundation

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

    /// The modifier keys held right now. The scene polls it every frame (key-up events do not arrive while Command
    /// is held). Windows reads its keyboard in stage 6; until then nothing is held there.
    @MainActor static func currentModifiers() -> PlazaModifiers {
        #if os(Windows) || PTB_SHARED_ONLY
        []
        #else
        MacPlazaInput.currentModifiers()
        #endif
    }

    /// Where the scene draws. The headless stage on both OSes until Task 10 adds the Mac's SpriteKit stage; nothing
    /// calls it before then.
    @MainActor static func makeStage(size: CGSize) -> any PlazaStage { PlazaHeadlessStage(size: size) }

    /// Where character sprites come from: `SpriteLoader`/`SpriteStore` on the Mac, nothing (the placeholder) elsewhere.
    @MainActor static func spriteFetcher() -> any PlazaSpriteFetching {
        #if os(Windows) || PTB_SHARED_ONLY
        PlazaStubSpriteFetcher(log: { AppLog.write($0) })
        #else
        LivePlazaSpriteFetcher()
        #endif
    }
}
