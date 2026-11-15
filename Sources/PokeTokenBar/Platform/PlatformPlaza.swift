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
    /// Canvases, text, bundled assets and image codecs: CoreGraphics/CoreText/ImageIO on the Mac, WIC and the app's own
    /// resource folders on Windows (canvas and text still the stub), the stub in the shared-only check.
    static let graphics: any PlazaGraphics = {
        #if os(Windows)
        WinPlazaGraphics.shared  // real assets and codecs; canvas and text stay the stub's until stage 6 draws them
        #elseif PTB_SHARED_ONLY
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
    /// is held). Windows reads `GetKeyState` (Ctrl as ⌘, Alt as ⌥).
    @MainActor static func currentModifiers() -> PlazaModifiers {
        #if os(Windows)
        WinPlazaInput.currentModifiers()
        #elseif PTB_SHARED_ONLY
        []
        #else
        MacPlazaInput.currentModifiers()
        #endif
    }

    /// Where the scene draws: SpriteKit on the Mac (`SpriteKitStage`, whose `SKScene` the window's `SKView` presents),
    /// Direct2D in the Windows app (`WinPlazaStage`, once the app installed `WinPlazaLive`), the headless stage in tests and
    /// the shared-only check (no drawing, no frame clock: the scene gets no `update`).
    @MainActor static func makeStage(size: CGSize) -> any PlazaStage {
        #if os(Windows)
        WinPlazaLive.isInstalled ? WinPlazaStage(size: size) : PlazaHeadlessStage(size: size)
        #elseif PTB_SHARED_ONLY
        PlazaHeadlessStage(size: size)
        #else
        SpriteKitStage(size: size)
        #endif
    }

    /// The plaza window: AppKit + `SKView` + SwiftUI HUD on the Mac (`PlazaMacWindow`), the Direct2D window in the Windows
    /// app (`WinPlazaWindow`), nothing in tests and the shared-only check.
    @MainActor static func makeShell() -> any PlazaWindowShell {
        #if os(Windows)
        WinPlazaLive.isInstalled ? WinPlazaLive.makeShell() : PlazaHeadlessShell(log: { AppLog.write($0) })
        #elseif PTB_SHARED_ONLY
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

    #if os(Windows) || PTB_SHARED_ONLY
    /// Logged once, the first time a bundled art file cannot be read (the stub graphics: Windows until stage 6).
    private static let missingArtNote: Void = AppLog.write(
        "PlatformPlaza: no bundled plaza art on this platform yet; the plaza is plain grass without pond visuals, tall grass or ice art")

    private static func bundledImage(_ name: String, ext: String) -> PlazaImage? {
        let image = graphics.assetURL(name, ext: ext).flatMap { graphics.decodeImage(at: $0) }
        if image == nil { _ = missingArtNote }
        return image
    }
    #endif

    /// The bundled tile sheet. The Mac reads it as it always has (`MacPlazaAssets.swift`); elsewhere through `graphics`.
    static func tileSheet() -> PlazaImage? {
        #if os(Windows) || PTB_SHARED_ONLY
        bundledImage(PlazaResources.tileSheetName, ext: "png")
        #else
        PlazaResources.tileSheet().map(PlazaImage.init(cgImage:))
        #endif
    }

    /// The bundled tall-grass sheet, read like `tileSheet()`.
    static func tallGrassSheet() -> PlazaImage? {
        #if os(Windows) || PTB_SHARED_ONLY
        bundledImage(PlazaResources.tallGrassSheetName, ext: "png")
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
        return PlazaIceArt(gloss: bundledImage(PlazaResources.iceGlossSheetName, ext: "png").map { PlazaIceArt.gloss(fromSheet: $0) },
                           cracks: bundledImage(PlazaResources.iceCrackSheetName, ext: "png").map { PlazaIceArt.cracks(fromSheet: $0) } ?? [],
                           shards: PlazaIceArt.shards(fromFrames: graphics.assetURL(PlazaResources.iceShatterName, ext: "gif")
                               .map { graphics.decodeImageFrames(at: $0) } ?? []))
        #else
        return PlazaIceArt.load()
        #endif
    }

    /// An SF Symbol as an image (`size` in points) for the overlay panels' icons, set as the SwiftUI views set it. The Mac
    /// draws the real symbol; Windows draws a glyph of Segoe Fluent Icons / Segoe MDL2 Assets for the names it knows (the eyes); any
    /// other name, or no such font, gives nil and the panel falls back to its own drawing of the glyph.
    static func symbolImage(named name: String, pointSize: CGFloat, weight: PlazaFontWeight, scale: CGFloat,
                            color: PlazaColor) -> (image: PlazaImage, size: CGSize)? {
        #if os(Windows)
        WinPlazaSymbols.image(named: name, pointSize: pointSize, weight: weight, scale: scale, color: color)
        #elseif PTB_SHARED_ONLY
        nil
        #else
        MacPlazaSymbols.image(named: name, pointSize: pointSize, weight: weight, scale: scale, color: color)
        #endif
    }

    #if os(Windows)
    /// Windows keeps its sprites in the app's state folder (`PTB_STATE_DIR` honoured), never outside it.
    private static let spriteStore = SpriteStore(directory: AppStatePaths.directory().appendingPathComponent("sprites", isDirectory: true))
    #endif

    /// Where character sprites come from: `SpriteLoader`/`SpriteStore` on the Mac, `SpriteStore` through the shared
    /// loader on Windows, nothing (the placeholder) in the shared-only check.
    @MainActor static func spriteFetcher() -> any PlazaSpriteFetching {
        #if os(Windows)
        PlazaStoreSpriteFetcher(store: spriteStore, graphics: graphics)
        #elseif PTB_SHARED_ONLY
        PlazaStubSpriteFetcher(log: { AppLog.write($0) })
        #else
        LivePlazaSpriteFetcher()
        #endif
    }

    /// Where the roster and card panels get their Pokémon pictures: `PlazaIconLoader`/`SpriteLoader` on the Mac
    /// (`MacPlazaIcons`), the same store through the shared loader on Windows, nothing in the shared-only check.
    @MainActor static func iconSource() -> any PlazaIconSource {
        #if os(Windows)
        PlazaStoreIconSource(store: spriteStore, graphics: graphics)
        #elseif PTB_SHARED_ONLY
        PlazaStubIconSource()
        #else
        MacPlazaIcons()
        #endif
    }
}
