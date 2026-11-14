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

    /// The plaza window: AppKit + `SKView` + SwiftUI HUD on the Mac (`PlazaMacWindow`), nothing elsewhere until stage 6.
    @MainActor static func makeShell() -> any PlazaWindowShell {
        #if os(Windows) || PTB_SHARED_ONLY
        PlazaHeadlessShell(log: { AppLog.write($0) })
        #else
        PlazaMacWindow()
        #endif
    }

    /// The one-line chat field: the AppKit field on the Mac, a state-only stub elsewhere.
    @MainActor static func makeChatInput() -> any PlazaChatInputHost {
        #if os(Windows) || PTB_SHARED_ONLY
        PlazaStubChatInput(log: { AppLog.write($0) })
        #else
        PlazaChatInput()
        #endif
    }

    /// The bundled tile sheet. The Mac reads it as it always has (`MacPlazaAssets.swift`); elsewhere through `graphics`.
    static func tileSheet() -> PlazaImage? {
        #if os(Windows) || PTB_SHARED_ONLY
        graphics.assetURL(PlazaResources.tileSheetName, ext: "png").flatMap { graphics.decodeImage(at: $0) }
        #else
        PlazaResources.tileSheet().map(PlazaImage.init(cgImage:))
        #endif
    }

    /// The bundled tall-grass sheet, read like `tileSheet()`.
    static func tallGrassSheet() -> PlazaImage? {
        #if os(Windows) || PTB_SHARED_ONLY
        graphics.assetURL(PlazaResources.tallGrassSheetName, ext: "png").flatMap { graphics.decodeImage(at: $0) }
        #else
        PlazaResources.tallGrassSheet().map(PlazaImage.init(cgImage:))
        #endif
    }

    /// The tall-grass pieces cut from the bundled sheet; nil when the sheet is missing.
    static func tallGrassArt() -> PlazaTallGrassArt? {
        #if os(Windows) || PTB_SHARED_ONLY
        tallGrassSheet().flatMap(PlazaTallGrassArt.init(sheet:))
        #else
        PlazaTallGrassArt.load()
        #endif
    }

    /// The ice gloss, cracks and shatter frames from the bundled files (empty parts when a file is missing).
    static func iceArt() -> PlazaIceArt {
        #if os(Windows) || PTB_SHARED_ONLY
        let image = { (name: String) in graphics.assetURL(name, ext: "png").flatMap { graphics.decodeImage(at: $0) } }
        return PlazaIceArt(gloss: image(PlazaResources.iceGlossSheetName).map { PlazaIceArt.gloss(fromSheet: $0) },
                           cracks: image(PlazaResources.iceCrackSheetName).map { PlazaIceArt.cracks(fromSheet: $0) } ?? [],
                           shards: PlazaIceArt.shards(fromFrames: graphics.assetURL(PlazaResources.iceShatterName, ext: "gif")
                               .map { graphics.decodeImageFrames(at: $0) } ?? []))
        #else
        return PlazaIceArt.load()
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
