#if os(Windows)
import Foundation

/// Stage 6 Task 12: `plaza.photo`. A controller on the headless shell (no window), P then Space through the scene's key path,
/// the photo rendered offscreen by the shared renderer through the Windows canvas and WIC, written to the REAL clipboard; the
/// check then reads both formats back. CI only: on a person's PC `--selftest` must not replace their clipboard.
extension WindowsSelftest {
    @MainActor static func plazaPhotoChecks(_ r: Recorder) async {
        guard onCI else {
            r.add("plaza.photo", true, "skipped: not on CI (the check writes the clipboard)")
            return
        }
        let defaults = WinDefaultsSync.makeAppDefaults()
        let prefs = PlazaPreferences(defaults: defaults)
        prefs.zoom = 2
        let c = PlazaWindowController(preferences: prefs, loader: PlazaCharacterLoader(fetcher: PlazaStubSpriteFetcher(log: { _ in })),
                                      nickname: { "selftest" }, memberID: { "selftest-me" },
                                      subject: { .init(speciesID: 25, isShiny: false) }, teamName: { "selftest" },
                                      shell: PlazaHeadlessShell(log: { _ in }), chatInput: PlazaStubChatInput(log: { _ in }))
        c.prepareScene()
        guard let scene = c.scene else {
            r.add("plaza.photo", false, "no scene")
            return
        }
        scene.backingOverride = 2
        scene.size = CGSize(width: 960, height: 640)
        scene.update(0)
        var block = PlazaBitmap(width: 9, height: 8)
        for y in 0..<8 { for x in 0..<9 { block[x, y] = PlazaRGBA(r: 255, g: 0, b: 0, a: 255) } }
        let frame = [PlazaFrame(image: PlazaImage(bitmap: block), delay: 0.1)]
        scene.setCharacter(PlazaCharacterFrames(front: frame, back: frame))
        scene.handleKeyDown(keyCode: 35, characters: "p", isRepeat: false)   // P: photo mode
        guard let input = scene.photoInput() else {
            r.add("plaza.photo", false, "no photo input")
            return
        }
        let wantW = Int((input.visibleRect.width * CGFloat(input.pixelsPerWorld)).rounded())
        let wantH = Int((input.visibleRect.height * CGFloat(input.pixelsPerWorld)).rounded())
        let inPhotoMode = c.isPhotoMode
        let started = DispatchTime.now().uptimeNanoseconds
        scene.handleKeyDown(keyCode: 49, characters: " ", isRepeat: false)   // Space: shutter
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        let flashing = scene.isShutterFlashing
        let png = WinImageClipboard.read(format: WinImageClipboard.pngFormat).flatMap { PlatformPlaza.graphics.decodeImage($0) }
        let dib = WinImageClipboard.readDIBV5()
        c.handleClose()
        let ok = inPhotoMode && flashing && png?.width == wantW && png?.height == wantH && dib?.width == wantW && dib?.height == wantH
        r.add("plaza.photo", ok, "P -> photoMode=\(inPhotoMode), Space -> flash=\(flashing) in \(String(format: "%.0f", ms)) ms; photo frame \(wantW)x\(wantH); "
              + "clipboard PNG \(png.map { "\($0.width)x\($0.height)" } ?? "missing"), DIBV5 \(dib.map { "\($0.width)x\($0.height)" } ?? "missing")")
    }
}
#endif
