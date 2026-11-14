# Windows Port, Track A (Plaza Behind a Drawing Interface) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On the Mac, the plaza scene, its layers, its art, its overlays and its feature logic stop using SpriteKit, SwiftUI, AppKit and CoreGraphics drawing directly. They talk to a small drawing interface with a SpriteKit/CoreGraphics implementation behind it on the Mac, and the Mac user sees nothing change: byte-identical offscreen renders of the scene, no measurable frame-cost increase, the same input behaviour, the same idle CPU (the plaza still stops drawing when hidden). At the end, plaza code is in the shared set, builds on Windows against a headless implementation, its tests run there, and a new plaza feature is written once. The Windows renderer (Direct2D) is stage 6 and not part of this track, but every interface here is checked against what Experiment 3 showed Direct2D can do.

**Architecture:** Concrete shared node classes (`PlazaNode`, `PlazaSprite`, `PlazaCropNode`, `PlazaCameraNode`) hold all drawing state as stored Swift properties; this tree is the source of truth that shared code and tests read. A node attached under a stage root gets a backend *mirror*; every changed property is written through to it once. On the Mac the mirror is a SpriteKit node (same tree shape, same insertion order, same values as today); on Windows and in headless tests there is no mirror. Images are a dual representation (`PlazaImage`: a shared RGBA `PlazaBitmap`, or an opaque native image that the Mac keeps as the very `CGImage` it uses today). Pixel-only art becomes pure Swift over `PlazaBitmap`; art that needs text, antialiased shapes, shadows or blend modes draws through `PlazaCanvas` / `PlazaTextEngine`, whose Mac implementation is a one-call-per-call wrapper over `CGContext` / CoreText, so the Mac output is byte-identical by construction. `PlazaWindowController` keeps its name and file but becomes shared; window creation, event capture, SwiftUI hosting and the native chat field move into a thin Mac shell behind `PlazaWindowShell`. Overlays are drawn as canvas-rendered panel images that the shell stacks in today's z-order.

**Tech Stack:** Swift 6, SwiftPM, XCTest. Mac: SpriteKit, CoreGraphics, CoreText, ImageIO only inside `Platform/Mac/Plaza/` and `Team/UI/`; `SKRenderer` + Metal for the offscreen harness. Windows CI: `windows-latest` + Swift `6.3.2-RELEASE` (unchanged from stage 1).

**Spec:** `docs/superpowers/specs/2026-11-13-windows-port-design.md` (Korean) — §2 (failure conditions), §4, §5 (drawing interface), §6 (overlays), §9.1 (experiments 3 and 4), §10 steps 2–3, §11. Experiment code to crib from (do not merge the branch): `origin/spike/windows-port` — `Sources/PokeTokenBar/Team/Plaza/SpikeDraw*.swift`, `PlazaPondLayer.swift`, `Tests/PokeTokenBarTests/SpikePondRenderTests.swift`, `spike/RESULTS.md`.

## Global Constraints

- **Speed rules (user decision, 2026-11-14) — these override any stricter wording below.** (1) No per-task full Mac gate: a task is verified on the Mac by the filtered suites for what it touched, `./scripts/shared-check.sh`, and (Track A) the render compare; the full gate `./scripts/test-gate.sh` runs only at milestones (Track A: after Tasks 7, 10, 13 and 19; Track B: after Tasks 5, 12, 14 and 19) and before `windows-port` goes to `main`. (2) Do not wait for Windows CI before merging a task into `windows-port`: merge, let the push run CI, and fix forward if it is red. Tasks whose only proof is Windows CI (Windows-only code) still read their run, but batch several changes per push. (3) Reviews: tasks marked for the most capable model keep an independent review; other tasks are read by the session lead. The cost accepted: a break found at a milestone is harder to trace to its task; `windows-port` is not released, so nothing reaches users in between.
- **The Mac app must not change.** For Tasks 1–13: every task proves (a) byte-identical offscreen renders for every named harness scene against its base commit, (b) the existing plaza tests pass, (c) frame cost within the calibrated limit, (d) the idle rule. Overlay tasks (14–17) may change overlay pixels only as spec §6 allows: before/after images in the PR, the user looks at them; the scene underneath stays byte-identical.
- Work in `.worktrees/<task-branch>` branched from `origin/windows-port`. Never edit the main checkout. No bare `git stash`. Always `gh … --repo likelion-campus/PokeTokenBar`.
- **One PR per task into `windows-port`, merged with a merge commit.** At the start of every task, `git merge --no-ff origin/main` into the task branch first and resolve there; the PR body lists the `main` commits brought in and any fix that had to be ported into converted code. English title (Conventional Commits) and body, `.agents/skills/prepare-pr/SKILL.md`. Renders used as PR images are labelled "Sample-data render".
- **A feature freeze on the plaza drawing files is in force on `main`; bug fixes may still arrive.** To keep their merges textual: keep every existing plaza file at its path and every existing type name (`PlazaScene`, `PlazaActor`, `PlazaWindowController`, the `Plaza*Layer`s, the `*Art` enums). Convert in place, line-locally; do not reformat, reorder or rename code you are not converting.
- **One `swift build` / `swift test` / `shared-check.sh` / `plaza-render-compare.sh` at a time on this Mac.** Before each, `pgrep -lf 'swift-build|swift-test|swift-frontend|xctest'` must print nothing; if it prints, wait (Monitor until-loop), do not start. Never run the full suite while another session's release gate runs (`pgrep -lf 'team-release.sh|release.sh'` empty). Otherwise run the full Mac gate `./scripts/test-gate.sh` once per task, after the render compare, before merge.
- Scratch output (renders, base worktree, timing files) goes to the session scratchpad, never into the repo. Renders are never committed.
- No focus-stealing: verification is offscreen (`SKRenderer`, CPU canvas). Window snapshots for overlay PRs use a borderless window at x −10000, `orderFront(nil)` without activation, `cacheDisplay` (memory note "offscreen plaza render"). Do not launch dev app instances while the user works.
- Tests: `UserDefaults` suites only through `TestDefaults.make(suite:)`; every `UsageStore(` passes `providers:`; render tests pin `now` and seeds; never force-unwrap an async result; tests in a `@MainActor` class that run on Windows are `async` (mechanical: `func testX() {` → `func testX() async {`, `throws {` → `async throws {`; the scan test enforces). A test file split for the Mac is `<Name>+Mac.swift` (existing convention); each new entry in `Tests/PokeTokenBarTests/mac-only.txt` has a `# why` line above it.
- Body-level `#if os(...)` stays inside `Platform/` (scan-enforced). The only new file there with `#if` is `Platform/PlatformPlaza.swift`. Mac-only backend code goes to `Platform/Mac/Plaza/` and Mac-only views/shell to `Team/UI/`; both directories are already listed in `mac-only.txt`, so no new Mac-side file needs a list edit.
- **Track A does not edit** `Package.swift`, `Platform/Platform.swift`, `Platform/StubPlatform.swift`, `Platform/Windows/**`, `.github/workflows/**`, or upstream-owned files (`Core/**`, `UI/**`, `PokeTokenBarApp.swift`). New dependencies of the controller get default arguments from `PlatformPlaza`, so `PokeTokenBarApp.swift` needs no edit. If a task finds it must touch one of these, it stops and asks the lead.
- Interfaces grow only when a call site needs them (stage 1 rule). Nothing below is to be added "for Windows later" unless a named task needs it.
- Defects found on the way follow the defect protocol in `CLAUDE.md`. A class "converted code reads a value the backend changed behind its back" is a new `defect-log.md` entry if it occurs.
- Model per role (user rule): implementers `sonnet`; tasks marked **[opus]** below get `opus` for implementation and review.

## Design decisions (made here, later tasks rely on them)

**D1. Concrete shared node classes with a write-through mirror, not protocols plus a factory (the spike's shape).** Reasons, from the code:
- *Per-frame cost.* `PlazaScene.update` re-places every actor each frame (`layout()`: about 30 property writes per actor), every weather particle, footprint alpha and firework piece, and reads node state back (`characterNode.size`, `plateNode.position`, `node.position` in `photoParticles`). With concrete `final` stored properties, reads are plain loads; a write is a value compare plus, only when the value changed, one existential call into the mirror. The spike's protocol nodes made every read and write an existential call that also reached SpriteKit. Change detection means SpriteKit receives *fewer* calls than today.
- *Tests.* 66 Mac-only plaza test files read state through scene accessors and, in about 50 lines, through `children`, `as? SKSpriteNode`, `.name`, `.blendMode`, `.texture?.cgImage()`. With shared nodes these become the same queries on `root.children`, `as? PlazaSprite`, `.name`, `.blendMode`, `.texture?.image` — identical on both OSes. The shared tree *is* the recording; no separate recording backend with a duplicated query API is needed.
- *Windows.* The stage-6 Direct2D renderer walks the same tree each frame (`PlazaDrawOrder.flatten`); there is no second scene graph.
- *Ergonomics.* Shared code creates nodes with plain initializers (`PlazaSprite(texture:size:)`); a mirror appears only when the node is attached under a stage root (materialize-on-attach). No factory has to be threaded through every layer.
- *Cost of the choice.* Wherever shared code reads a value back, the shared node must reproduce SpriteKit's semantics exactly (e.g. `SKSpriteNode.size` includes `xScale`/`yScale`, which `PlazaActor` relies on: "`size`는 현재 배율을 곱한 값이라…"). Task 1 pins those semantics with probes; Task 7 adds a mirror-parity check.

**D2. Images.** `PlazaImage` is either a `PlazaBitmap` (premultiplied RGBA8, row 0 at the top, sRGB or device RGB, `premultipliedLast` or `noneSkipLast`) or a native image (`any PlazaNativeImage`; on the Mac a `CGImage`). Native images flow to SpriteKit unchanged — character GIF frames from `SpriteLoader`, `cropping(to:)` results, bundled PNGs, canvas output — so colour space and alpha handling are exactly today's. Bitmap images become a `CGImage` on the Mac through the same `CGDataProvider` construction the art files use today. Shared code reads pixels through `image.pixels` (Mac: drawn into a premultiplied sRGB context, as `SheetPixels` / `recolored` do today).

**D3. What becomes pure Swift and what goes through the canvas.**
- Pure Swift over `PlazaBitmap` (already pixel loops today; only their CG edges change): `PlazaTileArt` composition, `PlazaSnowSheet` / `PlazaSeasonSheet` recolouring, `PlazaGroundShadow`, `PlazaNestArt`, `PlazaPondArt` grids, `PlazaWeatherArt` dot grids, `PlazaTallGrassArt`, `PlazaIceArt`, `PlazaCampfireArt`, firework glyphs, the campfire/firework light texture (`PlazaScene.lightTexture`), `PlazaSpriteCrop`. Where today's code fills 1×1 rects through `CGContext` (weather, campfire), the pure version writes bytes; the legacy oracle (D5) proves equality, and if any site is not byte-equal it keeps a canvas `fill` instead.
- Through `PlazaCanvas` (CG semantics: origin bottom-left, CTM, state stack): name plates (stroke+fill text, round join, shadow blur), chat bubbles (paragraph layout, `CTFramesetter`), emote art (fills + text with image bounds), `PlazaPondArt.wetImage` (emoji text), the character placeholder (device-RGB `fillEllipse`), `PlazaPhotoRenderer` (clip, alpha, mirrored and rotated draws, multiply fill, `sourceAtop`, direct byte pass for light), and all overlay panels. The canvas uses CG's coordinate conventions so the converted code is the current code with `context.` replaced by `canvas.`; Windows implements the same conventions on Direct2D (flip once).
- Text: `PlazaTextEngine` makes lines and paragraphs and measures them; the canvas draws them. Mac: CoreText with the same `NSAttributedString` attributes as today (including `kCTForegroundColorFromContextAttributeName`). Fonts: `.plaza(PlazaTextSize)` (Galmuri), `.system(size:weight:)` (Mac system font; Pretendard on Windows), `.emoji(size:)` (Apple Color Emoji; Segoe UI Emoji on Windows) — the user's decisions.

**D4. SKActions are replaced by a shared frame-driven `PlazaTweens`.** The spec says SKAction is unused; it is used in five places: Ditto poof and jump dust (`group[moveBy, fadeOut]` then remove), tackle impact (`scale(to:)` ∥ `wait`+`fadeOut`, remove), shutter (`fadeOut`, remove), and the scene-level delayed landing puff (`wait` then `run`). `PlazaTweens` copies SKAction semantics (first evaluation at progress 0, linear timing, incremental `moveBy`, fade/scale from the value at the action's start, sequence carries over to the next step in the same frame) and steps at the end of `PlazaScene.update` with the scene's clamped `dt` (SpriteKit evaluates actions after `update`; clamping matches SpriteKit's resume-after-pause behaviour, and only differs after a frame hitch, invisibly). Task 7 proves trajectories equal against live SKActions under `SKRenderer` before Task 10 swaps them in. Behaviour change in tests only: without a view SKActions never ran, so tests saw dust/impact/shutter nodes forever; with tweens they expire as in the app (`PlazaPondSceneTests` line 272 already documents the old gap).

**D5. Legacy oracles.** Every art conversion copies the pre-change implementation verbatim into `Tests/PokeTokenBarTests/Legacy/Legacy<Name>.swift` (Mac-only directory) and asserts byte equality (`width`, `height`, `bitmapInfo`, colour-space name, data-provider bytes) between legacy and new output over an input matrix. A bug fix on `main` that touches converted art makes its oracle fail at the next merge, which is the signal to port the fix. `Legacy/` is deleted in Task 19.

**D6. Input.** Shared key identity is the macOS virtual key number (`UInt16`, today's `keyCode`), named in `PlazaKeyCode`; the Windows shell maps its scan codes to it in stage 6. This keeps `PlazaScene.handleKeyDown(keyCode:characters:isRepeat:modifiers:)` and its ~170 test call sites intact. `NSEvent.ModifierFlags` becomes `PlazaModifiers` with exactly the four flags the scene reads (`.shift`, `.control`, `.option`, `.command`); arrows' `.numericPad`/`.function` are dropped, which matches today's checks. The scene uses no mouse, no `nodes(at:)`, no `convert(_:from:)`; none of those enters the interface. Mouse events exist only for overlay panels (`PlazaMouseEvent`).

**D7. Controller split.** The shared `PlazaWindowController` owns everything it owns today except the window: scene, models, session wiring, every feature, timers, the render watchdog's logic. The Mac shell `PlazaMacWindow` (`Team/UI/`) owns `NSWindow`, `SKView`, hosting views, constraints, first responder, transparency, frame autosave, `NSWindowDelegate`, and forwards window events to the controller (`PlazaWindowEvents`). The native chat field stays per OS behind `PlazaChatInputHost` (user decision); its emoji panel and Tab-for-megaphone stay inside the Mac control.

**D8. Overlays are canvas-rendered panels, stacked by the shell in today's order.** A shared `PlazaPanel` lays out, renders itself to a `PlazaImage` through the canvas and hit-tests; the Mac shell shows each panel in a layer-backed `NSView` inserted at the subview index where today's hosting view sits, so z-order against the SwiftUI panels that remain is unchanged and no display link is added. Panels never re-render while the plaza is hidden.

**D9 (proposed deviation from spec §6, for the user to decide at Task 17).** The four scrolling panels — roster, chat log, board, card — stay SwiftUI on the Mac over shared view models in this track. They need a scroll container with wheel input, multi-colour wrapped text runs, hover-expand animation, bouncing sprite icons, tooltips and sprite images in the HUD: in effect a small UI toolkit (guess: 2,500 shared lines and new interface features: attributed text runs, scroll clipping, panel animation), and the Mac look would change. They changed 3–9 times in the last six weeks against 56–68 for the scene and controller, and a typical new feature reaches them only through data that is already shared (`PlazaActivity.rows`, `PlazaRosterEntry`). Everything else in spec §6 goes through the interface in Tasks 14–16. Cost of the deviation: stage 6 must build these four for Windows (drawn through the same panels, or Win32), and changes to them need a Windows edit until they move. Task 17 is the decision point with measured numbers from Tasks 14–16.

## Interfaces (the contract later tasks rely on)

All shared types live in `Sources/PokeTokenBar/Team/Plaza/Draw/` unless noted. Signatures, not bodies.

```swift
// PlazaColor.swift (Task 2)
struct PlazaColor: Hashable, Sendable {
    var red: Double, green: Double, blue: Double, alpha: Double   // sRGB, straight alpha
    init(srgbRed: Double, green: Double, blue: Double, alpha: Double = 1)
    init(hex: UInt32, alpha: Double = 1)
    static let clear: PlazaColor, white: PlazaColor, black: PlazaColor
}

// PlazaInput.swift (Task 2; mouse in Task 14)
struct PlazaModifiers: OptionSet, Hashable, Sendable { static let shift, control, option, command }
struct PlazaKeyEvent: Equatable, Sendable { let keyCode: UInt16; let characters: String?; let isRepeat: Bool; let modifiers: PlazaModifiers }
enum PlazaKeyCode { static let a: UInt16 = 0, d: UInt16 = 2 /* … every code PlazaScene names today */ }
struct PlazaMouseEvent: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case down, up, moved, exited, scroll(dx: CGFloat, dy: CGFloat) }
    let kind: Kind; let location: CGPoint   // view points, origin top-left
}

// PlazaBitmap.swift, PlazaImage.swift (Task 3)
enum PlazaColorSpace: Sendable { case sRGB, deviceRGB }
enum PlazaAlphaLayout: Sendable { case premultipliedLast, noneSkipLast }
struct PlazaRGBA: Hashable, Sendable { var r: UInt8, g: UInt8, b: UInt8, a: UInt8 }
struct PlazaPixelRect: Hashable, Sendable { var x: Int, y: Int, width: Int, height: Int }  // origin top-left
struct PlazaBitmap: Hashable, Sendable {
    let width: Int, height: Int
    var bytes: [UInt8]                       // RGBA8, premultiplied, row 0 = top
    var alpha: PlazaAlphaLayout = .premultipliedLast
    var colorSpace: PlazaColorSpace = .sRGB
    init(width: Int, height: Int, fill: PlazaRGBA = .init(r: 0, g: 0, b: 0, a: 0))
    subscript(x: Int, y: Int) -> PlazaRGBA { get set }
    func cropped(to rect: PlazaPixelRect) -> PlazaBitmap
}
protocol PlazaNativeImage: AnyObject, Sendable {
    var width: Int { get }; var height: Int { get }
    func pixels() -> PlazaBitmap                                   // premultiplied sRGB render
    func cropping(to rect: PlazaPixelRect) -> (any PlazaNativeImage)?
}
final class PlazaImage: @unchecked Sendable {                     // immutable; NSLock-guarded caches
    let width: Int, height: Int
    init(bitmap: PlazaBitmap)
    init(native: any PlazaNativeImage)
    var bitmap: PlazaBitmap? { get }                               // the source, when made from one
    var native: (any PlazaNativeImage)? { get }
    var pixels: PlazaBitmap { get }                                // bitmap, or native.pixels() cached
    func cropping(to rect: PlazaPixelRect) -> PlazaImage?
    var backendCache: AnyObject? { get set }                       // the Mac keeps the CGImage built from a bitmap
}

// PlazaGraphics.swift, PlazaCanvas.swift, PlazaText.swift (Task 3)
protocol PlazaGraphics: Sendable {
    var text: any PlazaTextEngine { get }
    func makeCanvas(width: Int, height: Int, colorSpace: PlazaColorSpace) -> (any PlazaCanvas)?
    func assetURL(_ name: String, ext: String) -> URL?             // bundled plaza resources (nil on Windows until stage 6)
    func decodeImage(at url: URL) -> PlazaImage?
    func decodeImage(_ data: Data) -> PlazaImage?
    func decodeImageFrames(at url: URL) -> [PlazaImage]            // every frame of a GIF
    func encodePNG(_ image: PlazaImage) -> Data?
}
enum PlazaCanvasBlend: Sendable { case normal, multiply, sourceAtop }
enum PlazaLineJoin: Sendable { case miter, round }
enum PlazaTextDrawingMode: Sendable { case fill, stroke }
struct PlazaShadow: Sendable { var offset: CGSize; var blur: CGFloat; var color: PlazaColor }
protocol PlazaCanvas: AnyObject {                                  // CG conventions: origin bottom-left, y up
    var width: Int { get }; var height: Int { get }
    func saveState(); func restoreState()
    func translate(x: CGFloat, y: CGFloat); func scale(x: CGFloat, y: CGFloat); func rotate(by radians: CGFloat)
    func setAlpha(_ a: CGFloat); func setBlend(_ b: PlazaCanvasBlend)
    func setFillColor(_ c: PlazaColor); func setStrokeColor(_ c: PlazaColor)
    func setLineWidth(_ w: CGFloat); func setLineJoin(_ j: PlazaLineJoin)
    func setShadow(_ s: PlazaShadow?)
    func setShouldAntialias(_ on: Bool); func setAllowsAntialiasing(_ on: Bool); func setShouldSmoothFonts(_ on: Bool)
    func setInterpolationNone()
    func setTextDrawingMode(_ m: PlazaTextDrawingMode)
    func clip(to rect: CGRect)
    func fill(_ rect: CGRect); func fillEllipse(in rect: CGRect)
    func draw(_ image: PlazaImage, in rect: CGRect)
    func draw(_ line: PlazaTextLine, at textPosition: CGPoint)     // textPosition then CTLineDraw
    func draw(_ paragraph: PlazaParagraph, in rect: CGRect)        // CTFramesetterCreateFrame + CTFrameDraw
    func imageBounds(of line: PlazaTextLine) -> CGRect             // CTLineGetImageBounds(line, context)
    func withPixels(_ body: (_ bytes: UnsafeMutablePointer<UInt8>, _ bytesPerRow: Int) -> Void)
    func makeImage() -> PlazaImage?
    func fillRoundedRect(_ rect: CGRect, radius: CGFloat)           // Task 14 (as built): SwiftUI's continuous corners (the Mac uses
    func strokeRoundedRect(_ rect: CGRect, radius: CGFloat, lineWidth: CGFloat)   // SwiftUI's own path); the stroke is centred
    // Task 15 adds fillPath, strokePath when the first panel needs them
}
enum PlazaFontWeight: Sendable { case regular, semibold, bold }
enum PlazaFont: Hashable, Sendable { case plaza(PlazaTextSize), system(size: CGFloat, weight: PlazaFontWeight), emoji(size: CGFloat) }
enum PlazaTextAlignment: Sendable { case natural, center }
struct PlazaFontMetrics: Equatable, Sendable { let ascender: CGFloat, descender: CGFloat, leading: CGFloat }
final class PlazaTextLine: @unchecked Sendable { let width: CGFloat, ascent: CGFloat, descent: CGFloat, leading: CGFloat; let native: AnyObject? }
final class PlazaParagraph: @unchecked Sendable {
    func suggestedSize(limit: CGSize) -> CGSize                    // CTFramesetterSuggestFrameSizeWithConstraints
    func visibleLength(in size: CGSize) -> Int                     // UTF-16, CTFrameGetVisibleStringRange
    let native: AnyObject?
}
protocol PlazaTextEngine: Sendable {
    func metrics(_ font: PlazaFont) -> PlazaFontMetrics
    func line(_ text: String, font: PlazaFont) -> PlazaTextLine
    func truncated(_ line: PlazaTextLine, width: CGFloat, ellipsis: PlazaTextLine) -> PlazaTextLine?
    func paragraph(_ text: String, font: PlazaFont, alignment: PlazaTextAlignment) -> PlazaParagraph
    func wrappedLines(_ text: String, font: PlazaFont, width: CGFloat) -> [PlazaTextLine]   // Task 14: SwiftUI Text's breaks (Korean
}                                                                  // words whole; the Mac asks TextKit, .standard strategy)

// PlazaNode.swift, PlazaTexture.swift (Task 7, as built)
enum PlazaBlendMode: Sendable { case alpha, multiply, multiplyX2 }
enum PlazaFloat {                                                   // SpriteKit's 32-bit storage, shared
    static func stored(_ v: CGFloat) -> CGFloat                     // CGFloat(Float(v)); overloads CGPoint, CGRect, PlazaColor
    static func same(_ a: CGFloat, _ b: CGFloat) -> Bool            // bit-pattern equality; overloads CGPoint, CGRect?, PlazaColor
}
@MainActor class PlazaNode {
    init()
    final var name: String?
    final var position: CGPoint; final var zPosition: CGFloat; final var alpha: CGFloat; final var isHidden: Bool
    final var xScale: CGFloat; final var yScale: CGFloat; final func setScale(_ s: CGFloat)
    final var zRotation: CGFloat
    final private(set) weak var parent: PlazaNode?
    final private(set) var children: [PlazaNode]
    final func addChild(_ node: PlazaNode)                          // precondition: no parent (SpriteKit raises too)
    final func removeFromParent()                                   // a bridge-mounted root (no shared parent) leaves SpriteKit
    final func removeAllChildren()
    final var descendantCount: Int { get }
    final private(set) var mirror: PlazaNodeMirror?                 // a class, see below
    final func installMirror(_ m: PlazaNodeMirror)                  // backends only, once
}
@MainActor final class PlazaSprite: PlazaNode {
    static let defaultColor: PlazaColor                             // (1,1,1,0), SpriteKit's default
    override init(); init(texture: PlazaTexture?, size: CGSize); init(color: PlazaColor, size: CGSize)
    var texture: PlazaTexture?
    var size: CGSize                // reads unscaled × |scale|; assigning divides by the scales only while BOTH are positive
    var unscaledSize: CGSize { get }// what a backend builds a copy with / a renderer stretches the texture to
    var anchorPoint: CGPoint        // default (0.5, 0.5)
    var color: PlazaColor           // default defaultColor; init(color:size:) the given colour
    var colorBlendFactor: CGFloat
    var blendMode: PlazaBlendMode   // default .alpha
    var frame: CGRect { get }       // SpriteKit's, rounded to 1/1000 as SpriteKit does; within 0.001 at half-thousandths; no rotation
}
@MainActor final class PlazaCropNode: PlazaNode { var maskRect: CGRect? }   // replaces SKCropNode + white mask sprite
@MainActor final class PlazaCameraNode: PlazaNode {}
@MainActor final class PlazaTexture {                               // always nearest filtering
    init(_ image: PlazaImage)
    init(rect: CGRect, in parent: PlazaTexture)                    // unit rect, origin bottom-left; a cut of a cut is a part of the WHOLE image (SpriteKit)
    let image: PlazaImage; let rect: CGRect
    let parent: PlazaTexture?                                      // the backend cuts from the parent's own native texture
    var pixelSize: CGSize { get }                                  // SKTexture.size(): image size × rect, in double
    var nativeCache: AnyObject?                                    // the backend's texture (Mac: one SKTexture per PlazaTexture)
}
@MainActor class PlazaNodeMirror {                                 // a CLASS with no-op defaults that backends override (a class call
    init()                                                         // is ~2 ns cheaper per write than a protocol-existential call)
    func insertChild(_ child: PlazaNode, at index: Int)            // materializes child's subtree if it has no mirror
    func removeFromParent()
    func setName(_ v: String?); func setPosition(_ v: CGPoint); func setZPosition(_ v: CGFloat)
    func setAlpha(_ v: CGFloat); func setHidden(_ v: Bool); func setScale(x: CGFloat, y: CGFloat); func setZRotation(_ v: CGFloat)
    func setTexture(_ v: PlazaTexture?); func setSize(_ v: CGSize) /* the assigned, scaled value */; func setAnchorPoint(_ v: CGPoint)
    func setColor(_ v: PlazaColor); func setColorBlendFactor(_ v: CGFloat); func setBlendMode(_ v: PlazaBlendMode)
    func setMaskRect(_ v: CGRect?)
}
enum PlazaDrawOrder {
    @MainActor static func flatten(root: PlazaNode, camera: PlazaCameraNode?) -> [PlazaDrawItem]
    @MainActor static func localTransform(of node: PlazaNode) -> PlazaTransform   // scale, rotate, move
}
struct PlazaDrawItem { let sprite: PlazaSprite; let globalZ: CGFloat; let treeIndex: Int; let isScreenSpace: Bool; let clip: CGRect?; let transform: PlazaTransform; let alpha: CGFloat }
// transform maps the unit square (0,0)–(1,1) of the sprite's texture/colour rect (origin bottom-left) to root space, or to
// camera space (origin at the viewport centre) when isScreenSpace; clip is in that same space
struct PlazaTransform: Equatable { var a, b, c, d, tx, ty: CGFloat; static let identity; func concatenating(_ outer: PlazaTransform) -> PlazaTransform; func apply(_ p: CGPoint) -> CGPoint }
// Mac (Platform/Mac/Plaza/SpriteKitBackend.swift): SpriteKitBackend { materialize, texture, blendMode }; SKNodeMirror (plain
// nodes AND the camera, holding an SKCameraNode; there is no SKCameraMirror), SKSpriteMirror, SKCropMirror; SpriteKitMirrorFaults
// (debug-only test switches); extension PlazaNode { var skNode: SKNode? (tests/harness only); func mountInSpriteKit(_:) (Tasks 7–9 bridge) }

// PlazaTween.swift (Task 7, as built)
@MainActor indirect enum PlazaTweenStep {
    case moveBy(dx: CGFloat, dy: CGFloat, duration: TimeInterval), fadeOut(duration: TimeInterval)
    case scaleTo(CGFloat, duration: TimeInterval), wait(TimeInterval), call(@MainActor () -> Void), removeFromParent
    case group([PlazaTweenStep]), sequence([PlazaTweenStep])
}
@MainActor final class PlazaTweens {
    init(root: PlazaNode)                                          // the stage root: a tween steps only while its node is under it
    let root: PlazaNode
    func run(_ step: PlazaTweenStep, on node: PlazaNode?)          // nil node: scene-level (the delayed puff); nodes held weakly
    func advance(by dt: TimeInterval)
    var count: Int { get }
}

// PlazaStage.swift, PlazaHeadlessStage.swift (Task 7 declares, Task 10 uses)
@MainActor protocol PlazaStageDelegate: AnyObject {
    func stageUpdate(_ currentTime: TimeInterval)
    func stageDidChangeSize(from old: CGSize)
    func stageKeyDown(_ e: PlazaKeyEvent); func stageKeyUp(keyCode: UInt16)
    func stagePausedChanged(_ paused: Bool)                        // only when the platform itself changed it
}
@MainActor protocol PlazaStage: AnyObject {
    var root: PlazaNode { get }
    var camera: PlazaCameraNode? { get set }
    var size: CGSize { get set }
    var backingScale: CGFloat? { get }                             // nil without a window
    var backgroundColor: PlazaColor { get set }
    var isPaused: Bool { get set }
    var delegate: (any PlazaStageDelegate)? { get set }
    func currentModifiers() -> PlazaModifiers
}
@MainActor final class PlazaHeadlessStage: PlazaStage { init(size: CGSize) }   // no clock: never calls stageUpdate; a size change calls stageDidChangeSize

// PlazaWindowShell.swift (Task 12, as built)
@MainActor protocol PlazaPausableView: AnyObject { var isPaused: Bool { get set } }   // moved from the controller file
@MainActor protocol PlazaWindowEvents: AnyObject {
    func contentHeightDidChange(_ height: CGFloat)
    func setRendering(visible: Bool)
    func didResignKey(); func didBecomeKey()                       // the old delegate bodies: handleResignKey/BecomeKey + the state log line
    func handleClose()
}
struct PlazaOverlayBindings {                                       // the controller's `overlayBindings`; closures hold it weakly
    let rosterModel, overlayModel, feed, myMemberID, chatLog, minimap, backgroundModel, shortcutModel, nameColorModel
    let mapImage: PlazaImage, worldSize: CGSize
    let chatInput: any PlazaChatInputHost                           // the Mac shell casts it to PlazaChatInput for .view/.field
    let walkToMember, turnRosterPage, react, chooseMenu, closeOverlay, chooseCampfire, toggleChatLog, toggleShortcuts,
        toggleBackground, toggleNameColorPicker, pickNameColor
}
@MainActor protocol PlazaWindowShell: AnyObject {
    var events: (any PlazaWindowEvents)? { get set }
    func open(stage: any PlazaStage, title: String, overlays: PlazaOverlayBindings)
    func bringToFront(); func requestClose()
    func stopPresenting()                                           // before the controller lets go of the stage's scene (`scene` willSet)
    func dismantle()                                                // after stopPresenting: window delegate/content released
    func setTitle(_ title: String); func setTransparent(_ transparent: Bool); func setHUDHidden(_ hidden: Bool)
    func focusScene(); func focusChatInput(); func setChatLogAboveInput(_ above: Bool)
    var isFrontmost: Bool { get }; var isInLiveResize: Bool { get }
    var renderLoop: (any PlazaPausableView)? { get }
    var diagnostics: (occlusionVisible: Bool?, isKey: Bool?) { get }
}
@MainActor protocol PlazaChatInputHost: AnyObject {
    var isOpen: Bool { get }; var isLoud: Bool { get }
    func open(); func close()
    var onSubmit: ((String) -> Bool)? { get set }; var onClose: (() -> Void)? { get set }
}
// Every shell call is a no-op while no window is open. Mac: Team/UI/PlazaMacWindow.swift (init(autosaveName:styleMask:front:), the
// last three for tests; also the Mac-only `PlazaWindowController.rosterView()` and `shortcutThrowLabel`). Headless:
// PlazaHeadlessShell + PlazaStubChatInput (Team/Plaza/Draw/PlazaHeadlessShell.swift). The HUD toggle models PlazaBackgroundModel,
// PlazaNameColorModel and PlazaShortcutGuideModel are shared in Team/Plaza/PlazaHUDModels.swift.
protocol ImageClipboarding: Sendable { func writePNG(_ data: Data) -> Bool }   // declared in PlatformPlaza.swift (Task 6)

// HUD/ (Task 14), in Sources/PokeTokenBar/Team/Plaza/HUD/
enum PlazaPanelID: Hashable, Sendable { case pills, clock, shortcuts, backgroundToggle, nameColorPicker, photoFrame, menu, minimap }
enum PlazaPanelAnchor: Sendable { case topLeading, topTrailing, topCenter, bottomLeading, bottomTrailing, fill }
struct PlazaPanelHit: Equatable, Sendable { let action: String; let index: Int? }
struct PlazaAccessibilityItem: Equatable, Sendable {                // (Task 14 fix round, as built)
    enum Role { case staticText, button, menuItem }
    var frame: CGRect; var role: Role; var label: String; var value: String?   // frame: panel points, top-left
    var action: PlazaPanelHit?                                       // VoiceOver's press = a click on this hit (PlazaHUD.press)
}
enum PlazaPanelLayer: Equatable { case image(PlazaImage, frame: CGRect), color(PlazaColor, frame: CGRect) }   // panel points
struct PlazaPanelDrawing { var layers: [PlazaPanelLayer]; var accessibility: [PlazaAccessibilityItem]; var tracksMouse: Bool }
struct PlazaPanelInteraction: Equatable, Sendable { var hovered: PlazaPanelHit?; var pressed: PlazaPanelHit? }
@MainActor protocol PlazaPanel: AnyObject {
    var id: PlazaPanelID { get }
    var anchor: PlazaPanelAnchor { get }; var offset: CGPoint { get }   // the frame's edges from the anchored window edges
    var isVisible: Bool { get }                                      // false: hidden, not rendered, takes no clicks
    func size(in viewport: CGSize, scale: CGFloat, text: any PlazaTextEngine) -> CGSize   // the frame; whole device pixels
    func render(scale: CGFloat, viewport: CGSize, graphics: any PlazaGraphics) -> PlazaPanelDrawing
    func hit(_ point: CGPoint) -> PlazaPanelHit?                     // panel points, top-left; nil lets the click through
    var onChange: (() -> Void)? { get set }                          // set by the HUD; the panel calls it when its content changed
    var interaction: PlazaPanelInteraction { get set }               // default ignores; set only for drawings that tracksMouse
}
@MainActor final class PlazaHUD {
    init(panels: [any PlazaPanel], graphics: any PlazaGraphics = PlatformPlaza.graphics)   // z order, bottom first
    let panels: [any PlazaPanel]; let graphics: any PlazaGraphics
    weak var host: (any PlazaPanelHost)?                             // the open window; attaching renders the visible panels once
    var isRendering: Bool                                            // false while hidden: no renders; true renders what changed
    private(set) var viewport: CGSize; private(set) var scale: CGFloat
    func setViewport(_ size: CGSize, scale: CGFloat)                 // at once: moves; re-renders only on a new size or scale
    func setNeedsRender(_ id: PlazaPanelID)                          // coalesced: one render on the main actor's next turn
    func layout(viewport: CGSize, scale: CGFloat) -> [PlazaPanelID: CGRect]   // visible panels, origin top-left, on the pixel grid
    func hit(at point: CGPoint, in id: PlazaPanelID) -> PlazaPanelHit?        // the Mac host's hitTest
    func hit(at point: CGPoint) -> (id: PlazaPanelID, hit: PlazaPanelHit)?   // top-most in the HUD's order (a window that draws all)
    func handleMouse(_ e: PlazaMouseEvent, in id: PlazaPanelID) -> Bool       // to the panel whose view got it; down+up on one hit
    func press(_ hit: PlazaPanelHit, in id: PlazaPanelID)            //   -> onAction; scroll is never taken
    var onAction: ((PlazaPanelID, PlazaPanelHit) -> Void)?
    private(set) var renderCounts: [PlazaPanelID: Int]; var renderCount: Int { get }   // tests and the idle check
}
@MainActor protocol PlazaPanelHost: AnyObject { func show(_ id: PlazaPanelID, drawing: PlazaPanelDrawing, frame: CGRect, scale: CGFloat)
                                                func hide(_ id: PlazaPanelID) }
struct PlazaPanelSpace {                                             // the by-hand conventions in one place
    init(content: CGSize, room: CGFloat = PlazaPanelStyle.strokeRoom)   // content = what is laid out; room = stroke overflow
    var size: CGSize                                                 // the panel/image size, room included
    func panel(_ r: CGRect) -> CGRect                                // content rect -> panel (top-left): hits, items, layers
    func canvas(_ r: CGRect) -> CGRect; func canvas(_ p: CGPoint) -> CGPoint   // content -> canvas (bottom-left), baselines too
    func image(scale:graphics:_ draw: (any PlazaCanvas) -> Void) -> PlazaImage?   // one image of the whole space, CTM scaled
}
// Rules for every panel (Tasks 15-16 and later):
// - Accessibility: return items for what SwiftUI exposed: each Text a staticText read as its whole string, each button a button
//   with its action, decorative parts nothing. Task 15: each name-colour swatch a button labelled as PlazaChatLogView.swift
//   (~137) labels it, `l.plazaNameColorChoice(i + 1)`, and the toggles' buttons with their visible text; Task 16: each menu row a
//   menuItem with its action, the ▶ selection marker left out as PlazaMemberMenuView.swift (~27, ~77) hides it.
// - Large areas are .color layers (the photo frame's dim: four rects around the hole; brackets: small images or thin colour
//   rects); never one window-sized image. A full-window click catcher returns an empty drawing and a hit everywhere.
// - Draw through PlazaPanelSpace (no hand flips or room offsets). Report changes with onChange; never render on a timer.
// - Hover/press looks (SwiftUI button dimming): set tracksMouse in the drawing and implement interaction (didSet -> onChange).
// Panels (Task 14): PlazaPillsPanel(model: PlazaOverlayModel) (countdown, banner, hint; follows the model; stack(in:scale:text:),
// cached per content/width/scale, also feeds the SwiftUI overlay's menu room), PlazaClockPanel(worldSize:) (update(_ text:) from the
// 1 s tick), PlazaPill (oneLine / wrapped / draw(on:in:) / accessibilityItem / drawing), PlazaPanelStyle (colours, radii, strokes,
// paddings, margins, strokeRoom = 1, pixel rounding). Controller: PlazaWindowController.hud; PlazaOverlayBindings.hud and .pills.
// Mac: Team/UI/PlazaPanelHostView (a full-window layer-backed view per panel at the old hosting view's subview index, one sublayer
// per drawing layer, NSAccessibilityElement children, a tracking area only for tracksMouse; PlazaMacWindow is the PlazaPanelHost).
// Tasks 15-16 (as built): PlazaCanvas gained PlazaPath (move/line/close only; a curve is sampled by the caller), fillPath,
// strokePath(_:lineWidth:cap:), strokeEllipse(in:lineWidth:), clip(toRoundedRect:radius:). PlazaPanel.offset(in:scale:text:) (default
// `offset`) places a panel by measured text (the picker beside the toggle, the guide under it). Panels, Team/Plaza/HUD/:
// PlazaBackgroundTogglePanel, PlazaShortcutGuidePanel (+ PlazaShortcutGuide entries), PlazaNameColorPickerPanel, PlazaPhotoFramePanel
// (four colour rectangles + four bracket images + the guide text shrunk to 0.7, then cut), PlazaMenuPanel (+ PlazaMenuText,
// PlazaMenuBackground: the menus AND the tap-outside area: hits "choose"/index, "menu" (the body: inert), "cancel" everywhere else;
// anchor .fill; its host sits below the guide/toggle/picker/chat log/minimap, above the overlay and the roster), PlazaMinimapPanel
// (two layers: plate+map made per minute/season map/hidden/scale, marks made per change) over PlazaMinimapPixels (box downscale,
// tint, Rec. 709 saturation on a PlazaBitmap). Pressed look: the control's content at PlazaPanelStyle.pressedOpacity while the mouse is
// down on it and over it (the HUD's interaction; no tracking area, so no hover); a release elsewhere cancels. PlazaChangeObserver:
// panels follow their models and report only a state that differs from the last render (observation fires on equal writes).
// Controller: HUD panels [photoFrame, menu, pills, minimap, clock, shortcuts, backgroundToggle, nameColorPicker]; hud.onAction runs
// the old button actions; PlazaOverlayBindings lost every model/closure the panels replaced. Symbols: PlatformPlaza.symbolImage
// (named:pointSize:weight:scale:color:) -> (image, size)? — the Mac draws the real SF Symbol; elsewhere nil and the panel falls back to its own
// drawing of the glyph (the toggle's eye): WINDOWS SUPPLIES ITS OWN GLYPH IN STAGE 6.

// Platform/PlatformPlaza.swift (Tasks 2, 3, 6, 7, 12) — the only #if file of this track
enum PlatformPlaza {
    static let graphics: any PlazaGraphics                          // MacPlazaGraphics | PlazaStubGraphics
    static let clipboard: any ImageClipboarding                     // MacImageClipboard | StubImageClipboard
    @MainActor static func currentModifiers() -> PlazaModifiers
    @MainActor static func makeStage(size: CGSize) -> any PlazaStage   // PlazaHeadlessStage on BOTH OSes until Task 10 adds SpriteKitStage on the Mac
    @MainActor static func makeShell() -> any PlazaWindowShell          // PlazaMacWindow | PlazaHeadlessShell
    @MainActor static func makeChatInput() -> any PlazaChatInputHost    // PlazaChatInput | PlazaStubChatInput
    static func tileSheet() -> PlazaImage?; static func tallGrassSheet() -> PlazaImage?   // Task 12: the controller's art loaders; the Mac
    static func tallGrassArt() -> PlazaTallGrassArt?; static func iceArt() -> PlazaIceArt // calls today's loaders, elsewhere `graphics`
    @MainActor static func spriteFetcher() -> any PlazaSpriteFetching   // LivePlazaSpriteFetcher | stub (empty)
}
```
Selection uses `#if os(Windows) || PTB_SHARED_ONLY` like `PlatformLimits`. Stub contract (stage 1): a stub returns "unavailable" (`nil`, `false`, empty) and logs one `AppLog` line on first use; the stub canvas records its calls and returns a transparent image of the requested size; the stub text engine is deterministic monospace (advance 0.6 × size per `Character`, ascender 0.8 × size, descender −0.2 × size, leading 0).

Direct2D check (stage 6 contract, from Experiment 3): sprites = bitmap draws with nearest interpolation, opacity and an affine transform (flip, `zRotation`, scale about the anchor); `colorBlendFactor` = ColorMatrix effect; `.multiply` = Blend effect; `.multiplyX2` = ArithmeticComposite (C1 = 2); crop = axis-aligned clip; camera = view transform; canvas text = DirectWrite (stroke via glyph-run geometry + round-join stroke style; shadow via Shadow effect); `sourceAtop` = composite mode; PNG = WIC. Nothing in the contract needs a Mac-only capability.

SpriteKit behaviours the shared tree must state (and Windows must reproduce): global z = sum of ancestors' `zPosition`; with `ignoresSiblingOrder = true` exact ties have no defined order (Windows draws ties in tree order; the Task 1 tie audit lists where it matters); camera children are screen-space but sort in the same global z space as world nodes (the daylight tint at camera z 5 lies between characters at z 1–2 and plates at z 10); a crop node's subtree draws as one unit at the crop node's z. Task 1 pins each by a probe. Task 7 added (probes, `PlazaNodeTests`, the differential test): every value is stored as a 32-bit float and read back rounded; `size` reads unscaled × |scale| and assigning divides only while both scales are positive; `frame` is rounded to 1/1000; alpha and rotation are not clamped or normalised; a cut of a cut texture is a part of the whole image; `SKAction` arithmetic as listed in `PlazaTween.swift` (32-bit durations, composites re-rounding their children's time, `fma` blends).

## Verification harness (Task 1 builds it; every later task uses it)

- `scripts/plaza-render-compare.sh [--base <ref>] [--scratch <dir>] [--release] [--runs N]`. Default base: `git merge-base HEAD origin/windows-port`. It (1) checks `pgrep` as above, (2) checks out the base detached in `<scratch>/ptb-render-base` (a reused worktree, so later builds are incremental), builds tests there and runs the base's own harness, (3) runs the head's harness in the task worktree, (4) runs `PlazaRenderCompareTests` on the two output directories, (5) runs the frame-cost harness alternately base/head `N` times each (default 9). Prints `RENDER: identical (<n> captures)` or `RENDER: <k> differ: <scene@frame>…`, and `FRAMECOST: update base <x> head <y> ratio <r> (limit <L>)`, `FRAMECOST: render …`. Exit 0 only when renders are identical and both ratios ≤ L.
- Env: `PTB_PLAZA_RENDER_OUT=<dir>` (harness on), `PTB_PLAZA_RENDER_A` / `_B` (compare on), `PTB_PLAZA_RENDER_ONLY=<names>`, `PTB_PLAZA_RENDER_SPRITES=<dir>` (real cached GIFs, read-only; the script passes `~/Library/Application Support/PokeTokenBar/sprites` when it exists), `PTB_PLAZA_FRAMECOST_OUT=<file>`, `PTB_PLAZA_FRAMECOST_FRAMES` (default 3000). Without env every harness test `XCTSkip`s.
- Output: `manifest.tsv` (`scene  frame  sha256(bgra)  sha256(tree)  nodes  textures`), `<scene>@<frame>.png`, `<scene>@<frame>.tree.txt` (one line per SpriteKit node: depth, class, name, position, z, alpha, hidden, x/yScale, zRotation; sprites add size, anchor, colour components, colorBlendFactor, blendMode, texture ordinal + pixel size + sha256 of `cgImage()` bytes; crop nodes add mask rect), `photo-<scene>.png` + `photo-<scene>.rgba.sha256`, `ties.txt` (overlapping visible sprites with equal global z and different textures). On mismatch the compare test writes `diff-<scene>@<frame>.png` (differing pixels magenta), the differing-pixel count and bounding box, and the unified diff of the two `.tree.txt`.
- Harness rules (the known quirks): `renderer.update(atTime:)` resets `scene.size`, so per frame: set size, `update(atTime:)`, set size again, render; render 15 passes per capture (first passes can be black); `backingOverride` fixed per scene; `now` pinned; seeds fixed (`pickDanceStyle`, firework style, Ditto seed); viewport 640×480 unless the scene says otherwise; frames advance at exactly 1/60 s. Synthetic character frames are built **from raw bytes through the same `CGDataProvider` construction `PlazaImage(bitmap:)` will use**, so the harness's own fixtures are byte-identical before and after Task 3. Only same-machine comparisons are valid (GPU output may differ across Macs).
- Scenes (`PlazaRenderScenes.all`, built through `PlazaScene`'s own API only):

| Scene | Covers | Captures |
|---|---|---|
| `base-noon`, `base-noon-2x`, `zoom-1`, `zoom-4` | summer map, me + 4 teammates idle and walking, plates, shadows, backing 1 and 2 | 10, 40, 90 |
| `dusk`, `night` | daylight multiply tint | 10 |
| `spring`, `autumn`, `winter-snow` | season sheets, weather particles | 10, 60 |
| `winter-footprints` | footprints stamped and fading | 30, 120, 400 |
| `campfire-ready`, `campfire-lit-night`, `campfire-smoke` | fire frames, multiplyX2 light, timer text, smoke | 10, 37, 64 |
| `pond-swim`, `pond-egg` | sink cut + ghost crop + ring, diver fade, droplets, rings, bubbles; egg sunk, egg on nest with front rim | 5, 20, 45 |
| `ice-frozen`, `ice-breaking`, `ice-refreeze` | ice alpha, cracks, shards | 5, 20, 40 |
| `tall-grass` | concealed member, lowered plate, rustle overlay and leaves | 5, 20, 50 |
| `dance`, `pray-wobble` | three styles mid-pose (zRotation, squash, lift, flip), ♪; egg wobble | 7, 23, 41 |
| `emotes`, `chat-bubbles`, `name-plates` | every emote kind; Latin, Hangul, emoji, 60-char wrap, edge push; titles, zZ, truncation, chosen colours, empty name (each at backing 1 and 2) | 10 |
| `ditto`, `ditto-decoy`, `ditto-poof` | Ditto form, copy of a member, poof dust mid-flight | 5, 15, 25 |
| `fireworks-night`, `fireworks-day` | rise, burst, firework light | 10, 30, 60 |
| `snowballs`, `water-balloon` | flight, shadow, burst, impact; summer balloon | 5, 12, 20 |
| `jump-dust`, `tackle-impact`, `shutter`, `sparkle` | SKAction-driven effects mid-flight, landing puff, sparkle | 3, 10, 22 |
| `items`, `board-marker`, `wet` | item bob, `!` marker, 💧 | 10, 40 |
| `background-hidden` | clear background, hidden layers, no tint | 10 |
| `photo-mode` | camera on the photo frame, panning | 10, 30 |
| `real-sprites` (only with `PTB_PLAZA_RENDER_SPRITES`) | native GIF frames, swim, dance | 10, 30 |
| photos | `PlazaPhotoRenderer` raw RGBA and PNG bytes for `base-noon`, `night`, `winter-snow`, `pond-swim`, `tall-grass`, `campfire-lit-night`, `fireworks-night`, `dance`, `real-sprites` | — |

- Frame cost: scene `rush-hour` (12 teammates on seeded routes, winter snow, a firework every 0.5 s, footprints at cap, campfire lit at night, 3 swimmers splashing, me walking), 3000 scripted `update` calls → ms per frame; plus 300 `SKRenderer` frames → render ms per frame. Limit `L` = max(1.05, 1 + 2 × the A/A spread measured in Task 1), stored in the script. Debug build by default (debug inflates the indirection, so it is the conservative side); `--release` (if Task 1 proves it works) is mandatory in Tasks 7, 9, 10 and 19.
- Idle rule (d): `PlazaWindowTests`' pause/watchdog tests stay green every task; Task 10 adds `testAHiddenPlazaGetsNoFrames`, Task 14 `testAHiddenPlazaRendersNoPanels`; Task 19 measures the real app.

## File Structure

```
scripts/plaza-render-compare.sh                         create (T1)
Tests/PokeTokenBarTests/PlazaRenderScenes.swift         create (T1), Mac-only until T11
Tests/PokeTokenBarTests/PlazaRender/                    create (T1), Mac-only directory
  PlazaRenderHarness.swift, PlazaRenderCompareTests.swift, PlazaFrameCostHarness.swift,
  SpriteKitSemanticsTests.swift (T1), SpriteKitMirrorParityTests.swift, PlazaTweenOracleTests.swift (T7)
Tests/PokeTokenBarTests/Legacy/                         create (T3), Mac-only directory, deleted in T19
Tests/PokeTokenBarTests/PlazaTestImages.swift           create (T3): shared byte-built fixtures (solid, patterned)
Sources/PokeTokenBar/Platform/PlatformPlaza.swift       create (T2), grows in T3/T6/T7/T12
Sources/PokeTokenBar/Platform/Mac/Plaza/                create (T2) — Mac backends, no list edit needed
  MacPlazaInput.swift (T2), MacPlazaColor.swift (T2), MacPlazaGraphics.swift, CGPlazaCanvas.swift,
  CoreTextPlazaEngine.swift, CGImagePayload.swift, MacPlazaAssets.swift (T3), MacSpriteFetcher.swift (T4),
  MacImageClipboard.swift (T6), SpriteKitBackend.swift, SpriteKitStage.swift, PlazaSKScene.swift (T7/T10)
Sources/PokeTokenBar/Team/Plaza/Draw/                   create — the shared interface and headless parts
  PlazaColor.swift, PlazaInput.swift (T2); PlazaBitmap.swift, PlazaImage.swift, PlazaGraphics.swift,
  PlazaCanvas.swift, PlazaText.swift, PlazaStubGraphics.swift (T3); PlazaNode.swift, PlazaTexture.swift,
  PlazaDrawOrder.swift, PlazaTween.swift, PlazaStage.swift, PlazaHeadlessStage.swift (T7);
  PlazaWindowShell.swift, PlazaHeadlessShell.swift (T12); PlazaGIFDecoder.swift (T18)
Sources/PokeTokenBar/Team/Plaza/HUD/                    create (T14–16): panels, shared
Sources/PokeTokenBar/Team/Plaza/*.swift                 modify in place; leave mac-only.txt as converted
Sources/PokeTokenBar/Team/UI/PlazaMacWindow.swift       create (T12): the Mac shell; PlazaPanelHostView.swift (T14)
Sources/PokeTokenBar/Team/UI/*.swift                    modify: bind to shared models; shrink as panels move
Sources/PokeTokenBar/mac-only.txt, Tests/PokeTokenBarTests/mac-only.txt, Tests/PokeTokenBarTests/shared-floor.txt   every task
```

## Review Focus

1. **The harness is green but did not exercise the changed path.** A scene list that misses a node kind or state (ghost crop only appears while swimming; dust only mid-flight; plates at backing 2) gives false confidence. → Every PR carries a coverage map: each converted node/art site → the harness scene that draws it. Each task fault-injects once (shift one converted property by 1 pt) and shows the compare naming the expected scene. A converted site with no scene gets a scene in that PR.
2. **The shared tree and SpriteKit disagree, and tests pass because they read the shared tree.** Materialize-on-attach, change detection and the size/scale model could leave SpriteKit with a different value than the node holds. → `SpriteKitMirrorParityTests` (Task 7): seeded random operation sequences applied both to shared nodes (with mirror) and directly to reference SK nodes, then the two SK trees compared property by property; and after every harness scene the shared tree is compared with its SK mirror. Fault-inject: drop the `alpha` write-through → both fail.
3. **SKAction → tween drift.** Off-by-one-frame starts, fades from the wrong start value, or removal a frame late. → `PlazaTweenOracleTests` (Task 7) runs each of the five scripts as a real SKAction and as a `PlazaTweens` twin in the same `SKRenderer` loop and compares position, alpha, scale and parent per frame; the `jump-dust`, `tackle-impact`, `shutter`, `ditto-poof` scenes capture mid-flight frames. Tests that relied on actions never running are listed in the Task 10 PR, each with its new expectation.
4. **Windows is green by exclusion.** Tests "move to Windows" while their real assertions are split into `+Mac` files or the file stays listed. → Each task's PR table: files moved off the list, tests now executed on Windows (CI count), assertions kept Mac-only with the reason; Mac-font-dependent assertions are the only accepted reason besides SwiftUI/AppKit. The Windows test-count floor is raised (through Track B, see Order).
5. **Idle and hidden-window regressions.** A new timer, a panel that re-renders every second, a tween runner or a stage that keeps a display link while hidden would raise idle CPU with every test green. → Tasks 10 and 14 add the hidden-plaza tests above (fault-injected), the controller keeps `setRendering` as the single switch for the render loop, scene pause and HUD rendering, and Task 19 measures the real app in three states.

---

### Task 1: Offscreen render harness, SpriteKit probes, A/A baseline — Size M

**Files:**
- Create: `scripts/plaza-render-compare.sh`, `Tests/PokeTokenBarTests/PlazaRenderScenes.swift`, `Tests/PokeTokenBarTests/PlazaRender/{PlazaRenderHarness,PlazaRenderCompareTests,PlazaFrameCostHarness,SpriteKitSemanticsTests}.swift`
- Modify: `Tests/PokeTokenBarTests/mac-only.txt` (`PlazaRenderScenes.swift`, `PlazaRender/`, with `# why`)

**Interfaces:**
- Consumes: today's `PlazaScene` API.
- Produces: `struct PlazaRenderScene { let name: String; let viewport: CGSize; let backing: CGFloat; let captures: [Int]; let build: @MainActor () -> PlazaRenderSetup }`; `struct PlazaRenderSetup { let scene: PlazaScene; let step: @MainActor (_ frame: Int) -> Void; let photo: Bool }`; `enum PlazaRenderScenes { static let all: [PlazaRenderScene]; static func frames(_ look: PlazaRenderLook) -> PlazaCharacterFrames }`; `enum PlazaRenderHarness { @MainActor static func skScene(of scene: PlazaScene) -> SKScene /* the single adapter Task 10 changes */ }`; the env vars, output layout and script described above.

- [ ] **Step 1: Probes** — `SpriteKitSemanticsTests` (Mac-only, plain asserts, no env): `testSpriteSizeIncludesScale` (size after `xScale`/`yScale`/`setScale`, including −1), `testSettingSizeUnderScaleStoresUnscaled` (set size with scale ≠ 1, then reset scale), `testTextureAssignmentKeepsSize`, `testSubRectTextureSize` (`SKTexture(rect:in:)`), `testFrameUnderAnchorAndScale`, `testDefaultSpriteColorAndBlend`, `testColorInitializersAgree` (`SKColor(red:…)` vs `SKColor(srgbRed:…)` components), and offscreen-render probes `testCameraChildrenSortWithWorldByGlobalZ`, `testCropSubtreeDrawsAtCropZ`, `testSceneIsPausedNotChangedByPresenting` (`SKRenderer.scene =` and `SKView().presentScene`), `testEqualZTieIsRecorded` (records, does not assert an order). Each test's message states the rule the shared model will copy.
- [ ] **Step 2: Scenes and harness** as specified in "Verification harness". `testRenderAllScenes` writes the outputs; `testRendersMatch` compares; `testFrameCost` writes timing.
- [ ] **Step 3: Script.** Base worktree reuse, serial builds, `pgrep` guard, interleaved runs, exit codes.
- [ ] **Step 4: A/A.** `./scripts/plaza-render-compare.sh --base HEAD --scratch <scratchpad>` → `RENDER: identical`; record the A/A frame-cost spread and set `L`. Run the harness twice on the same build and confirm byte-identical manifests (determinism).
- [ ] **Step 5: Release feasibility (experiment).** Try `swift build -c release --build-tests -Xswiftc -enable-testing` and the frame-cost harness under it. Record yes/no in the PR; `--release` uses it only if yes.
- [ ] **Step 6: Fault-inject** — move the name plate 1 pt in a throwaway edit → compare fails naming `name-plates@10` and `base-noon@*`; revert.
- [ ] **Step 7: Verify** — `swift test --filter SpriteKitSemanticsTests` PASS; `./scripts/test-gate.sh` green; Windows CI unchanged (all new files Mac-only).
- [ ] **Step 8: PR** `test(plaza): add an offscreen render harness for the plaza port`. Body: the scene table, the probe results (each pinned rule in one line), `L`, release feasibility, the tie audit summary.

---

### Task 2: Shared colour and input types — Size S

**Files:**
- Create: `Team/Plaza/Draw/PlazaColor.swift`, `Team/Plaza/Draw/PlazaInput.swift`, `Platform/PlatformPlaza.swift` (`currentModifiers` only), `Platform/Mac/Plaza/MacPlazaInput.swift` (`PlazaKeyEvent(_ event: NSEvent)`, `PlazaModifiers(_ flags: NSEvent.ModifierFlags)`), `Platform/Mac/Plaza/MacPlazaColor.swift` (`PlazaColor.cgColor`, `PlazaColor.skColor` built with `srgbRed`), `Team/UI` extension `Color.init(plaza:)`
- Modify: `PlazaNameColorCG.swift` (palette of `PlazaColor`; drop CoreGraphics; leaves the list), `PlazaChatLog.swift` (`Line.color: PlazaColor`; leaves the list), `PlazaMinimap.swift` (`Dot.color`), `PlazaScene.swift` (`setNameColor(_: PlazaColor)`, `handleKeyDown(... modifiers: PlazaModifiers)`, `currentModifiers: () -> PlazaModifiers = PlatformPlaza.currentModifiers`, `keyDown` maps through `PlazaKeyEvent(event)`), `PlazaActor.swift`, `PlazaDittoShown`, `PlazaWindowController.swift` (`DittoLook.color`), `PlazaNamePlate.image(color: PlazaColor)`, SwiftUI views using `Color(cgColor:)`, tests that name `CGColor` or `NSEvent.ModifierFlags`
- Test: `PlazaColorTests.swift` (shared), `PlazaInputMappingTests.swift` (Mac-only)

**Interfaces:** Produces `PlazaColor`, `PlazaModifiers`, `PlazaKeyEvent`, `PlazaKeyCode`, `PlatformPlaza.currentModifiers()`.

- [ ] **Step 1: Failing tests.** `testPaletteMatchesTheHexList`, `testHexRoundTrip`, `testColorEqualityIsComponentwise` (shared). Mac: `testArrowKeysDropNumericPadAndFunctionFlags`, `testCommandWStillCloses`, `testRepeatAndCharactersAreKept`, `testCurrentModifiersReadsTheSameFlags`.
- [ ] **Step 2: Implement and replace.** Every CG edge converts with `.cgColor`. `plateKey` and `setNameColor` equality now compare `PlazaColor` (same components as before; CGColor equality compared components and space, all sRGB).
- [ ] **Step 3: Move off the list.** `PlazaNameColorCG.swift`, `PlazaChatLog.swift`; move the chat-log model tests out of `PlazaChatTests.swift` into a new shared `PlazaChatLogTests.swift` (async). Raise `shared-floor.txt`.
- [ ] **Step 4: Verify** — `plaza-render-compare.sh` → identical, frame cost ≤ L; `shared-check.sh` exit 0; `test-gate.sh` green; Windows CI green with `PlazaColorTests`, `PlazaChatLogTests` executed.
- [ ] **Step 5: PR** `refactor(plaza): share the colour and key types`.

---

### Task 3: Graphics foundation — bitmap, image, canvas, text, codec, assets **[opus]** — Size L

**Files:**
- Create: `Team/Plaza/Draw/{PlazaBitmap,PlazaImage,PlazaGraphics,PlazaCanvas,PlazaText,PlazaStubGraphics}.swift`; `Platform/Mac/Plaza/{MacPlazaGraphics,CGPlazaCanvas,CoreTextPlazaEngine,CGImagePayload,MacPlazaAssets}.swift`; `Tests/PokeTokenBarTests/PlazaTestImages.swift`; `Tests/PokeTokenBarTests/Legacy/{LegacyPlazaGroundShadow,LegacyPlazaPondArt}.swift`, `Tests/PokeTokenBarTests/Legacy/PlazaArtParity.swift`
- Modify: `PlatformPlaza.swift` (+ `graphics`); `PlazaResources.swift` (keeps `PlazaTextSize` and asset names, shared; bundle lookup, `CTFontManagerRegisterFontsForURL` and `font(_:) -> NSFont` move to `MacPlazaAssets.swift` as an extension used by the SwiftUI views and the CoreText engine); pilots `PlazaGroundShadow.swift` (bitmap) and `PlazaPondArt.swift` (grids → bitmap; `wetImage` → canvas + `.emoji(size: 12)` text; `waterColor` → `PlazaColor`); Mac-only callers (`PlazaActor`, `PlazaPondLayer`, `PlazaPhotoRenderer`) take `image.cgImage` (Mac bridge in `CGImagePayload.swift`)
- Test: `PlazaBitmapTests.swift`, `PlazaImageTests.swift`, `PlazaStubGraphicsTests.swift` (shared); `MacPlazaGraphicsTests.swift`, `PlazaArtParityTests.swift` (Mac-only)

**Interfaces:**
- Consumes: `PlazaColor` (Task 2).
- Produces: everything under "PlazaBitmap/PlazaImage" and "PlazaGraphics/Canvas/Text" in the contract; `PlatformPlaza.graphics`; Mac-only `extension PlazaImage { var cgImage: CGImage }` (native image, or a `CGImage` built from the bitmap with today's `CGDataProvider` construction, cached in `backendCache`); `PlazaArtParity.assertIdentical(_ legacy: CGImage, _ new: PlazaImage, file:line:)`. Art builders take `graphics: any PlazaGraphics = PlatformPlaza.graphics`.

- [ ] **Step 1: Failing shared tests.** `testBitmapRowZeroIsTheTop`, `testBitmapCropCopiesRows`, `testImageFromBitmapReportsItsPixels`, `testCroppingABitmapImageKeepsPixels`, `testStubCanvasRecordsCallsAndReturnsATransparentImageOfTheSize`, `testStubTextIsMonospace`, `testStubDecodersAreUnavailableAndLogOnce`.
- [ ] **Step 2: Failing Mac tests.** `testNativeImagePixelsMatchAContextDraw` (every bundled PNG and the ice GIF), `testBundledImagesColourSpaces` (experiment: records each resource's colour space and whether drawing into sRGB changes bytes; the PR states the result), `testBitmapCGImageMatchesTheArtFilesConstruction` (`premultipliedLast` and `noneSkipLast`), `testCanvasCallsMatchCGContextCalls` (a scripted sequence through `CGPlazaCanvas` vs the same calls on a raw `CGContext` → identical bytes), `testTextLineMatchesCoreTextMetrics`, oracles `testGroundShadowIsByteIdentical` (widths 20…140), `testPondArtIsByteIdentical` (droplet, ring 2…12, bubble, swimRing, wetImage at scale 1–4).
- [ ] **Step 3: Implement.** `CGPlazaCanvas` maps each method to exactly one `CGContext` call (or `CTLineDraw` / `CTFrameDraw` / `CTLineGetImageBounds` with `textPosition`); `CoreTextPlazaEngine` builds the same `NSAttributedString`s as today (fonts: `.plaza` → `PlazaResources.font`, `.system` → `NSFont.systemFont(ofSize:weight:)`, `.emoji` → `CTFontCreateWithName("Apple Color Emoji")`); `MacPlazaGraphics.decodeImage` uses `CGImageSourceCreateWithURL`/`…WithData` + `CreateImageAtIndex` as `PlazaResources` does today; `encodePNG` is today's `PlazaPhotoRenderer.png`.
- [ ] **Step 4: Convert the two pilots**, keep their callers byte-identical through `.cgImage`. Move `PlazaGroundShadow.swift` and `PlazaPondArt.swift` off the list (the pond art's `SKColor` goes; Mac callers use `waterColor.skColor`).
- [ ] **Step 5: Fault-inject** — build bitmap `CGImage`s with `.last` instead of `.premultipliedLast` → `testGroundShadowIsByteIdentical` fails; revert.
- [ ] **Step 6: Verify** — renders identical; frame cost ≤ L; `shared-check.sh` exit 0; `test-gate.sh` green; Windows CI green and runs `PlazaBitmapTests`, `PlazaImageTests`, `PlazaStubGraphicsTests`, `PlazaGroundShadowTests`. Coverage: `llvm-cov show --show-regions` on `CGPlazaCanvas.swift` and `PlazaImage.swift` shows no `^0` region in code paths used by the pilots.
- [ ] **Step 7: PR** `refactor(plaza): draw plaza images through a shared graphics interface`.

---

### Task 4: Character frames and pixel-only art into the shared set — Size L

**Files:**
- Modify: `PlazaCharacterLoader.swift` (`PlazaFrame.image: PlazaImage`; `PlazaSpriteFetching` returns `[(image: PlazaImage, delay: TimeInterval)]` / `PlazaImage?`; placeholder through a device-RGB canvas `fillEllipse`; `PlazaSpriteCrop.trimmed(_: [PlazaImage])` reads `pixels` alpha, crops with `cropping(to:)`), `PlazaTileArt`, `PlazaSnowSheet`, `PlazaSeasonSheet`, `PlazaNestArt`, `PlazaWeatherArt`, `PlazaTallGrassArt`, `PlazaIceArt`, `PlazaCampfireArt`, `PlazaSnowball.swift` (CoreGraphics import only → Foundation), `PlazaMinimap.swift` (`seasonMapImage: PlazaImage?`; the SwiftUI view converts), `PlazaScene.swift` (`mapImage: PlazaImage`; `lightTexture` builder moves to new shared `PlazaCampfireLightArt.swift` returning a `noneSkipLast` bitmap image), `PlazaFireworkLayer.swift` (glyph images move to new shared `PlazaFireworkArt.swift`), `PlazaWindowController.swift` (cached images become `PlazaImage`), all Mac-only consumers via `.cgImage`
- Create: `Platform/Mac/Plaza/MacSpriteFetcher.swift` (`LivePlazaSpriteFetcher` moved verbatim; `NSImage` → `cgImage(forProposedRect:)` → `PlazaImage(native:)`), `PlatformPlaza.spriteFetcher()`, `Legacy/Legacy<each>.swift`
- Test: existing art tests read `image.pixels`; parts that need the bundled sheet move to `<Name>+Mac.swift`; `PlazaCharacterTests` uses `PlazaTestImages`

**Interfaces:** Consumes Task 3. Produces `PlazaFrame(image: PlazaImage, delay:)`, `PlazaSpriteFetching` (shared protocol), `PlazaCampfireLightArt.image(tint:radii:color:level:) -> PlazaImage`, `PlazaFireworkArt.image(_ glyph: PlazaFireworkGlyph) -> PlazaImage`, `PlazaTileArt.mapImage(_:sheet: PlazaImage, tallGrass:) -> PlazaImage`, `PlazaTileArt.plainGrassImage(_:) -> PlazaImage`.

- [ ] **Step 1: Oracles first** (Mac-only, fail until converted): `testTileMapIsByteIdentical` (map with and without tall grass, plain grass), `testSeasonSheetsAreByteIdentical` (four seasons, tiles and tall grass), `testNestWeatherIceCampfireFireworkLightArtAreByteIdentical` (every public builder over its inputs), `testTrimmedFramesKeepTheNativeImages` (crop of a native image is still native and equals `CGImage.cropping`), `testPlaceholderIsByteIdentical`.
- [ ] **Step 2: Convert.** Byte writes replace 1×1 `CGContext` fills only where the oracle passes; otherwise keep a canvas `fill`.
- [ ] **Step 3: Move off the list** every converted file; raise the floor.
- [ ] **Step 4: Windows tests.** Remove from the test list (async where `@MainActor`): `PlazaCharacterTests`, `PlazaSnowSheetTests`, `PlazaTallGrassArtTests`, `PlazaCampfireArtTests`, and the synthetic-sheet parts of `PlazaTileArtTests`, `PlazaIceArtTests`. Triage failures as stage 1 Task 7 did (bug / test assumption / needs Mac).
- [ ] **Step 5: Verify** — renders identical (including `real-sprites`, which exercises the native frame path); frame cost ≤ L; `shared-check.sh`; `test-gate.sh`; Windows CI green.
- [ ] **Step 6: PR** `refactor(plaza): build plaza pixel art and character frames in shared code`.

---

### Task 5: Text art through the canvas — Size M

**Files:**
- Modify: `PlazaNamePlate.swift`, `PlazaChatBubble.swift`, `PlazaEmoteArt.swift` (drop AppKit/CoreText; use `PlazaTextEngine` + `PlazaCanvas` call-for-call), Mac-only consumers via `.cgImage`
- Create: `Legacy/LegacyPlazaNamePlate.swift`, `LegacyPlazaChatBubble.swift`, `LegacyPlazaEmoteArt.swift`
- Test: `PlazaNamePlateTests` splits into a shared part (layout rules with stub metrics: plate grows upward, title above, width clamp at `maxPixelWidth`) and `PlazaNamePlateTests+Mac.swift` (pixel and Mac-font assertions)

**Interfaces:** Consumes Task 3. Produces `PlazaNamePlate.image(text:title:color: PlazaColor, scale:graphics:) -> PlazaImage?`, `PlazaChatBubble.image(text:scale:graphics:) -> PlazaImage?`, `PlazaChatBubble.drawnLength(of:graphics:) -> Int`, `PlazaEmoteArt.image(_:scale:large:graphics:) -> PlazaImage`, `impactImage`, `dustImage`, `itemImage`, `sparkImage` (same names, `PlazaImage` results).

- [ ] **Step 1: Oracles** over a matrix: texts `""`, `"나"`, Latin, Hangul, mixed with emoji (`"🔥🔥"`), a 2,000-point-wide name (truncation), a 60-character chat (wrap and `maxLines`), every `TeamEmoteKind`, item kinds; titles on and off; colours from the palette; scales 1, 2, 3 → `testNamePlateIsByteIdentical`, `testChatBubbleIsByteIdentical`, `testChatBubbleDrawnLengthMatches`, `testEmoteArtIsByteIdentical`.
- [ ] **Step 2: Convert**; move the three files off the list.
- [ ] **Step 3: Fault-inject** — omit `setShouldSmoothFonts(false)` in the bubble → its oracle fails; revert.
- [ ] **Step 4: Verify** — renders identical (`name-plates`, `chat-bubbles`, `emotes`, `campfire-lit-night` timer); frame cost ≤ L; gates; Windows CI green with the shared plate tests.
- [ ] **Step 5: PR** `refactor(plaza): draw name plates, bubbles and emotes through the canvas`.

---

### Task 6: Photo renderer, PNG and clipboard — Size M

**Files:**
- Modify: `PlazaPhotoRenderer.swift` (`PlazaPhotoInput`/`Actor`/`Band`/`Particle` images become `PlazaImage`; compositing through `PlazaCanvas`, light pass through `withPixels`, `submerged` through a `sourceAtop` fill; `png` through `graphics.encodePNG`), `PlazaScene.swift` / `PlazaActor.swift` / layers (`photoInput`, `photoActor`, `photoParticles` pass `PlazaImage`), `PlazaWindowController.swift` (`photoWriter` default `PlatformPlaza.clipboard.writePNG`; `writePhotoToClipboard` code moves), `PlatformPlaza.swift` (+ `ImageClipboarding`, `clipboard`)
- Create: `Platform/Mac/Plaza/MacImageClipboard.swift` (NSPasteboard code moved verbatim), shared `StubImageClipboard` (in `PlazaStubGraphics.swift`), `Legacy/LegacyPlazaPhotoRenderer.swift`
- Test: `PlazaPhotoTests` pixel assertions → `PlazaPhotoTests+Mac.swift`; input-assembly assertions stay for Windows later (Task 11)

**Interfaces:** Produces `PlazaPhotoRenderer.render(_:graphics:) -> PlazaImage?`, `pngData(for:graphics:) -> Data?`, `ImageClipboarding`, `PlatformPlaza.clipboard`.

- [ ] **Step 1: Oracle** `testPhotoIsByteIdentical` for every harness photo input plus mirrored, tilted, swimming, egg-sunk, light and firework-light inputs (raw RGBA and PNG bytes). `testStubClipboardIsUnavailable`.
- [ ] **Step 2: Convert**; move `PlazaPhotoRenderer.swift` off the list.
- [ ] **Step 3: Verify** — harness photos identical; renders identical; frame cost ≤ L; gates; Windows CI green.
- [ ] **Step 4: PR** `refactor(plaza): compose the group photo through the canvas`.

---

### Task 7: Node interface, SpriteKit backend, tweens — first layer: the pond **[opus]** — Size L

**Files:**
- Create: `Team/Plaza/Draw/{PlazaNode,PlazaTexture,PlazaDrawOrder,PlazaTween,PlazaStage,PlazaHeadlessStage}.swift`; `Platform/Mac/Plaza/SpriteKitBackend.swift` (`SKNodeMirror`, `SKSpriteMirror`, `SKCropMirror` (white mask sprite at the rect), the camera as an `SKNodeMirror` over an `SKCameraNode` (as built); texture creation `SKTexture(cgImage: image.cgImage)` / `SKTexture(rect:in:)` with `.nearest`, cached in `nativeCache`; materialize order: scale 1 → unscaled size → texture, anchor, colour, factor, blend, position, z, alpha, hidden, name, rotation → scales → mask → children in order); bridge `extension PlazaNode { func mountInSpriteKit(_ parent: SKNode) }` (removed in Task 10); `Tests/.../PlazaRender/{SpriteKitMirrorParityTests,PlazaTweenOracleTests}.swift`
- Modify: `PlazaPondLayer.swift` (not an `SKNode`; `let root = PlazaNode()`; `PlazaSprite`/`PlazaTexture`), `PlazaScene.swift` (`pondLayer.root.mountInSpriteKit(self)` where it called `addChild(layer)`), `PlazaPondLayerTests.swift` (`layer.root.children`, `as? PlazaSprite`), `PlatformPlaza.swift` (+ `makeStage`, unused until Task 10)
- Test: `PlazaNodeTests.swift`, `PlazaDrawOrderTests.swift`, `PlazaTweenTests.swift` (shared)

**Interfaces:** Consumes Tasks 3–6. Produces the node, texture, draw-order, tween and stage parts of the contract.

- [ ] **Step 1: Failing shared tests.** `testAddChildKeepsOrderAndParent`, `testRemoveFromParentDetaches`, `testSpriteSizeFollowsTheSpriteKitScaleModel` (the Task 1 probe values as expectations), `testFrameMatchesTheProbe`, `testUnchangedWritesDoNotReachTheMirror` (a counting mirror), `testDrawOrderSumsAncestorZ`, `testCameraChildrenAreScreenSpaceInTheSameZOrder`, `testCropSubtreeIsOneUnit`, `testTiesFallBackToTreeOrder`, `testTweenFirstStepIsProgressZero`, `testSequenceCarriesOverInTheSameFrame`, `testGroupEndsWithItsLongestChild`.
- [ ] **Step 2: Failing Mac tests.** `SpriteKitMirrorParityTests.testRandomOperationsLeaveTheSameSpriteKitTree` (seeded, 2,000 operations: add/remove/re-add, every property, scale before/after size, pooled hide/show, texture swaps, sub-rect textures, crop masks) and `testMountedLayerMatchesItsMirror`; `PlazaTweenOracleTests` for the five scripts (poof, jump dust, impact, shutter, delayed call) → per-frame position/alpha/scale/parent equal to SKAction (exact, or within 1e-9 if SpriteKit accumulates differently — if inexact, replicate SpriteKit's accumulation, do not loosen).
- [ ] **Step 3: Micro-benchmark (risk R1).** `testWriteThroughCost` (release if available): 2,000 sprite writes per frame through `PlazaSprite` with mirror vs direct `SKSpriteNode`, 3,000 frames → ratio in the PR; stop and report if > 1.05.
- [ ] **Step 4: Convert the pond layer** (crib the spike's diff; keep its comments). Move `PlazaPondLayer.swift` off the list; `PlazaPondLayerTests` to Windows (async).
- [ ] **Step 5: Harness add-on** — after each capture, `assertMirrorParity` walks every mounted shared subtree against its SK nodes.
- [ ] **Step 6: Fault-inject** — skip the `alpha` write-through → parity test and `pond-swim` render fail; revert.
- [ ] **Step 7: Verify** — renders identical; `--release` frame cost ≤ L; gates; Windows CI green with the new shared tests and `PlazaPondLayerTests`.
- [ ] **Step 8: PR** `refactor(plaza): add the shared node tree and its SpriteKit mirror`.

---

### Rules for Tasks 8–10 (from Task 7's report and review)

- Never use `skNode` in app code, and never add SpriteKit nodes under a mirrored node: the shared tree is the truth; `skNode` exists for tests and the harness.
- Mount where `addChild(layer)` was, in the same order (exact z ties draw in tree order; the harness nudges ties into tree order, so a reordered tie group shows as a diff). `layer.zPosition = …` becomes `layer.root.zPosition = …`.
- Share a `PlazaTexture` wherever an `SKTexture` was shared (one `SKTexture` per `PlazaTexture`); cut sub-textures from the `PlazaTexture` whose `SKTexture` was the parent.
- In the harness, add each mounted root to `PlazaRenderHarness.sharedRoots(of:)` (parity after every capture) and its copy's old class name to `legacyClassNames(of:)` (`"PlazaWeatherLayer"`, …; Task 10: the scene), or every capture reports a tree diff.
- No Double copies of node values: a node reads back SpriteKit's 32-bit value (and SpriteKit's `size`/`frame` rules); keeping a Double copy "to be exact" is what would change pixels.
- Nodes, textures and tweens are main-actor only.
- Tween `call` blocks capture `[weak self]` (as the `SKAction.run` block did); `PlazaTweens(root: stage.root)` steps at the end of `PlazaScene.update` with its clamped dt; start a tween exactly where the `run` was.
- Effect nodes (dust, impact, shutter) stay direct children of the root or the camera, as today.
- Footprints use `SKColor(red:…)` today and the shared path is sRGB (`PlazaColor.skColor` = `SKColor(srgbRed:)`, equal on this Mac per `SpriteKitSemanticsTests`): the render compare must confirm it for the footprint scenes.
- A bridge-mounted root leaves SpriteKit with `removeFromParent()` (`PlazaActor.detach()` must call it); mounting it again requires it to be out first.

### Task 8: The other layers — Size M

**Files:**
- Modify: `PlazaFootprintLayer`, `PlazaWeatherLayer`, `PlazaFireworkLayer`, `PlazaIceLayer`, `PlazaSnowballLayer`, `PlazaTallGrassLayer` (each: `root: PlazaNode`, shared sprites/textures; the scene mounts each root where it added the layer; `layer.zPosition = …` → `layer.root.zPosition = …`), their tests (`root.children`, `as? PlazaSprite`, `texture?.image`)
- Test: `PlazaFootprintTests`, `PlazaIceLayerTests`, `PlazaTallGrassLayerTests`, layer parts of `PlazaFireworksTests` and `PlazaWeatherTests` (their shortcut-guide `ImageRenderer` and scene parts → `+Mac` until Tasks 11/15)

**Interfaces:** Consumes Task 7. Produces each layer's `let root: PlazaNode`; existing test accessors unchanged (`particlePositions`, `shownCount`, `alphas`, `bandTexture(at:) -> PlazaTexture?`, …).

- [ ] **Step 1:** Convert one layer per commit; after each, `plaza-render-compare.sh --runs 3` (render check only) on the scenes that layer draws.
- [ ] **Step 2:** Move the six files off the list; tests to Windows (async); triage.
- [ ] **Step 3: Verify** — full compare identical, frame cost ≤ L; gates; Windows CI green.
- [ ] **Step 4: PR** `refactor(plaza): move the plaza layers onto the shared node tree`.

---

### Task 9: `PlazaActor` **[opus]** — Size M

**Files:**
- Modify: `PlazaActor.swift` (eight nodes become `PlazaSprite`/`PlazaCropNode`; `ghostCrop.maskRect = r` replaces `maskNode = ghostMask`; sub-rect textures through `PlazaTexture(rect:in:)`; texture cache keyed by `ObjectIdentifier(PlazaImage)`; `attach(world: PlazaNode, camera: PlazaNode)`; while the scene is still an `SKScene`, the scene mounts the actor's nodes through the bridge in today's order), `PlazaScene.swift` (call sites)
- Test: actor accessors keep their names and types (`characterSize`, `submergedBodyClip`, `submergedBodyTextureRect`, …); `PlazaSwimLowerHalfTests` etc. compile unchanged except image fixtures

**Interfaces:** Consumes Tasks 5, 7. Produces `PlazaActor` with no SpriteKit import; `attach(world:camera:)` on `PlazaNode`.

- [ ] **Step 1:** Parity first: extend `SpriteKitMirrorParityTests` with `testActorPlacementMatchesTheLegacyActor` — copy today's `PlazaActor` to `Legacy/LegacyPlazaActor.swift`, drive both with the same `place`/`animate`/`setFrames`/`showChat`/`startDance` script (dance, swim, egg sunk, nest, concealment, wet, jump, lunge, wobble) and compare SK trees property by property per frame.
- [ ] **Step 2:** Convert; move `PlazaActor.swift` off the list (the scene stays Mac-only one more task).
- [ ] **Step 3: Verify** — renders identical (all scenes); `--release` frame cost ≤ L; gates; Windows CI green (actor compiles; actor-only tests none yet).
- [ ] **Step 4: PR** `refactor(plaza): move the plaza actor onto the shared node tree`.

---

### Task 10: `PlazaScene` stops being an `SKScene` **[opus]** — Size L

**Files:**
- Modify: `PlazaScene.swift` (plain `@MainActor final class`; `init(…, stage: any PlazaStage = PlatformPlaza.makeStage(size: CGSize(width: 960, height: 640)))`; builds the same tree under `stage.root` in the same order, sets `stage.camera`; `size` / `isPaused` / `backgroundColor` forward to the stage; `isPaused` keeps its `didSet`; `update(_:)` stays public and is also the stage delegate's `stageUpdate`; `stageDidChangeSize` → `layout()`; keys arrive as `stageKeyDown`; `view?.window?.backingScaleFactor` → `stage.backingScale`; the five SKAction sites → `PlazaTweens` stepped at the end of `update`; `children` → `root.children`), `PlazaRenderHarness.skScene(of:)` (→ `(scene.stage as! SpriteKitStage).skScene`), every scene test that used `children`/`SKSpriteNode`/`NSEvent.ModifierFlags`
- Create: `Platform/Mac/Plaza/SpriteKitStage.swift`, `Platform/Mac/Plaza/PlazaSKScene.swift` (`SKScene` subclass: `scaleMode = .resizeFill`, `anchorPoint = .zero`; overrides `update`, `didChangeSize`, `keyDown`/`keyUp` (no `super`, as today) and `isPaused` (forwards platform-made changes)); remove the mount bridge
- Modify: `PlazaWindowController.swift` (`view.presentScene((s.stage as! SpriteKitStage).skScene)`; still Mac-only)

**Interfaces:** Consumes Tasks 7–9. Produces shared `PlazaScene` with `let stage: any PlazaStage`, `var root: PlazaNode { stage.root }`, unchanged public API otherwise.

- [ ] **Step 1: Failing tests.** `testAHiddenPlazaGetsNoFrames` (Mac: after `scene.isPaused = true` and `renderLoop.isPaused = true`, an `SKRenderer` driven 60 frames never calls `stageUpdate`; headless: the stage never calls it), `testStagePauseFromThePlatformRunsTheSameDidSet`, `testKeyEventsReachTheSceneUnchanged` (NSEvent through `PlazaSKScene` → same `PlazaKeyResult` and callbacks as calling `handleKeyDown` directly), `testTweensReplaceTheFiveActions` (counts and timings from the oracle).
- [ ] **Step 2: Convert.** The PR lists each test whose expectation changed because effects now expire without a view, with the old and new expectation.
- [ ] **Step 3:** Move `PlazaScene.swift` off the list (Mac tests still Mac-only until Task 11).
- [ ] **Step 4: Fault-inject** — start tweens one frame late → `PlazaTweenOracleTests` and `jump-dust@3` fail; revert. Leave `isPaused` unforwarded → `testStagePauseFromThePlatformRunsTheSameDidSet` fails; revert.
- [ ] **Step 5: Verify** — renders identical; `--release` frame cost ≤ L (update and render); gates; Windows CI green (scene compiles and links on Windows).
- [ ] **Step 6: PR** `refactor(plaza): run the plaza scene on a drawing stage instead of SpriteKit`.

---

### Task 11: Scene tests on Windows — Size M

**Files:**
- Modify: `Tests/PokeTokenBarTests/mac-only.txt` and every scene-level test file: `Plaza*SceneTests`, `PlazaDanceTests`, `PlazaCollisionTests`, `PlazaPondMotionTests`, `PlazaTackleWaterTests`, `PlazaSwimLowerHalfTests`, `PlazaNatureTests`, `PlazaDaylightTests` (SwiftUI part → `+Mac`), `PlazaSeasonTests`, `PlazaWeatherTests`, `PlazaEmoteTests` (scene part), `PlazaPhotoModeSceneTests`, `PlazaMapTests+Mac`, `PlazaPondTests+Mac`, `TeamHostilePeerTests`; `PlazaRenderScenes.swift` becomes shared (builds on Windows; not run there until stage 6)

- [ ] **Step 1:** Mechanical async conversion in `@MainActor` classes (about 770 synchronous tests across the plaza files; this task takes the scene-level share); fixtures through `PlazaTestImages`.
- [ ] **Step 2:** Remove the files from the list; push; triage each Windows failure: real bug in shared code (fix with the defect protocol) / test assumption (fix so it holds on both) / Mac font metrics or AppKit (split to `+Mac` with `# why`). `TeamHostilePeerTests` node-growth checks may use `root.descendantCount` where that is strictly stronger; keep `root.children.count` where the old assertion compared direct children.
- [ ] **Step 3: Verify** — Mac gate green; Windows CI green; PR table of moved files, executed counts, kept-Mac assertions.
- [ ] **Step 4: PR** `test(plaza): run the plaza scene tests on Windows`.

---

### Task 12: Split `PlazaWindowController` into the shared controller and a Mac shell **[opus]** — Size L

**Files:**
- Create: `Team/Plaza/Draw/PlazaWindowShell.swift` (contract), `Team/Plaza/Draw/PlazaHeadlessShell.swift` (+ `PlazaStubChatInput`), `Team/UI/PlazaMacWindow.swift` (`show()`'s window, `SKView` (`ignoresSiblingOrder = true`, `allowsTransparency = true`), hosting views and constraints moved verbatim; `restoreFrame` (static, used by `PlazaWindowTests` → `+Mac`); `NSWindowDelegate` → `PlazaWindowEvents`; `extension SKView: PlazaPausableView`; `rosterView()`; `NSImage` for the minimap)
- Modify: `PlazaWindowController.swift` (not `NSObject`; no AppKit/SpriteKit import; `init(…, shell: (any PlazaWindowShell)? = nil, chatInput: (any PlazaChatInputHost)? = nil, …)` defaulting to `PlatformPlaza.makeShell()` / `makeChatInput()`; `show()` = `prepareScene()` + `shell.open` + watchdog + `applyBackground()` + character load + `shell.bringToFront()`; every `window?…`, `skView`, `makeFirstResponder`, `NSApp.isActive`, constraint toggle and `hudViews` loop goes through the shell; `PlazaPresenting` conformance moves in; `minContentSize` is a `CGSize`), `Team/UI/PlazaChatInput.swift` (conforms to `PlazaChatInputHost`), `PlatformPlaza.swift` (+ `makeShell`, `makeChatInput`); delete `PlazaPresentingMac.swift`
- `PlazaOverlayBindings` fields: `rosterModel`, `overlayModel`, `feed`, `myMemberID`, `chatLog`, `minimap`, `backgroundModel`, `shortcutModel`, `nameColorModel`, `mapImage: PlazaImage`, `worldSize`, and closures `walkToMember`, `turnRosterPage`, `react`, `chooseMenu`, `closeOverlay`, `chooseCampfire`, `toggleChatLog`, `toggleShortcuts`, `toggleBackground`, `toggleNameColorPicker`, `pickNameColor`, plus `chatInputView` (Mac only, as `AnyObject?`).

**Interfaces:** Consumes Tasks 2–11. Produces `PlazaWindowShell`, `PlazaWindowEvents`, `PlazaChatInputHost`, `PlazaOverlayBindings`, `PlazaMacWindow`, `PlazaHeadlessShell`, shared `PlazaWindowController` (same public API the app and tests use: `show`, `prepareScene`, `handleClose`, `setRendering`, `renderLoop`, `checkRendering`, `startRenderWatchdog`, `isFrontmost`, `title`, `refresh*`, `showBanner`, the `PlazaPresenting` methods, `chatInputForTesting: any PlazaChatInputHost`).

- [ ] **Step 1: Failing tests.** With a recording shell: `testShowOpensTheShellOnceAndBringsItForward`, `testToggleBackgroundSetsTransparencyAndRefocusesTheScene`, `testOpenChatFocusesTheInputAndMovesTheLog`, `testPhotoModeHidesTheHUD`, `testCloseRequestGoesThroughTheShell`, `testWindowEventsDriveRenderingAndRoster` (occlusion, miniaturize, resize → capacity), `testLogStateReadsTheShellDiagnostics`, `testWatchdogSkipsWhileTheShellIsInLiveResize`. Mac: `testMacShellBuildsTheSameViewStack` (subview order and constraints equal a list copied from today's `show()`).
- [ ] **Step 2: Move** window code verbatim into `PlazaMacWindow`; route the controller through the shell.
- [ ] **Step 3: Visual check** — off-screen window snapshot (borderless, x −10000, no activation) before and after for the default and transparent backgrounds → pixel-equal (the HUD is still the same SwiftUI views).
- [ ] **Step 4:** Move `PlazaWindowController.swift` off the list; raise the floor. Remaining Mac-only plaza files move to `Team/UI/` or `Platform/Mac/Plaza/` (`PlazaIconLoader.swift` → `Team/UI/`), so nothing under `Team/Plaza/` stays listed.
- [ ] **Step 5: Verify** — renders identical; frame cost ≤ L; `shared-check.sh`; `test-gate.sh`; Windows CI green; an interactive smoke run of the real app only with the user's hands-off time (ask), otherwise the existing controller tests are the input check.
- [ ] **Step 6: PR** `refactor(plaza): share the plaza controller and keep the window in a Mac shell`.

---

### Task 13: Controller tests on Windows — Size M

**Files:** `Tests/PokeTokenBarTests/mac-only.txt`; `PlazaDittoControllerTests`, `PlazaMimicControllerTests`, `PlazaFocusTests`, `PlazaIceControllerTests`, `PlazaSnowballControllerTests`, `PlazaStartleControllerTests`, `PlazaPullUnderTests`, `PlazaPrayTests`, `PlazaItemsTests`, `PlazaMembersTests`, `PlazaGroupPhotoTests`, `PlazaActivityControllerTests`, `PlazaActivityTests`, `PlazaBoardTests` (SwiftUI parts `+Mac`), `PlazaCardTests` (`ImageRenderer` parts `+Mac`), `PlazaWindowTests` (`restoreFrame`, `NSWindow` parts `+Mac`), `PlazaChatTests` (AppKit field parts stay Mac-only), `PlazaControllerLifetimeTests`, `PlazaScheduleWiringTests`, `PlazaPhotoModeTests`, `PlazaPhotoTests` (input parts), `ParkedDitto.swift`

- [ ] **Step 1:** Async conversion where synchronous; tests construct the controller with `shell: PlazaHeadlessShell()` only where the default would not compile on Windows (the default already is the headless shell there).
- Note (Task 12): until stage 6 the Windows controller's scenes differ from the Mac's: `PlatformPlaza.tileSheet()`/`tallGrassSheet()` return nil through the stub graphics (one `AppLog` line the first time), so the map is plain grass, `pondVisuals` is false, tall-grass art is nil and the ice art is empty. Tests that depend on pond visuals, tall grass or ice art read different scenes there (fix the test assumption or keep the assertion in `+Mac`).
- [ ] **Step 2:** Remove from the list, push, triage as in Task 11.
- [ ] **Step 3: Verify** — Mac gate green; Windows CI green; the Windows executed-test count is reported to the lead so Track B raises the workflow floor.
- [ ] **Step 4: PR** `test(plaza): run the plaza controller tests on Windows`.

**From the merge of this task on, a new plaza feature is written in shared code only** (spec §10 step 3). Tell the lead so the freeze on `main` can be revisited.

---

### Task 14: HUD panels — infrastructure, hint/banner/countdown pills, clock **[opus]** — Size L

**Files:**
- Create: `Team/Plaza/HUD/{PlazaPanel,PlazaHUD,PlazaPillsPanel,PlazaClockPanel,PlazaPanelStyle}.swift` (`PlazaPanelStyle`: the overlay palette, corner radii, stroke widths and paddings copied from the SwiftUI views), `Team/UI/PlazaPanelHostView.swift` (layer-backed `NSView`; `layer.contents` = the panel's `CGImage`, `contentsScale` = backing, nearest magnification; `hitTest` returns self only where `PlazaHUD` reports an interactive hit; forwards `PlazaMouseEvent`s; `acceptsFirstResponder = false`)
- Modify: `PlazaCanvas` + `CGPlazaCanvas` + stub (add `fillRoundedRect(_:radius:)`, `strokeRoundedRect(_:radius:lineWidth:)` now that a panel needs them), `PlazaInput.swift` (mouse), `Team/UI/PlazaOverlayView.swift` (drop the pills; keep content panels, photo frame and menus for now), `PlazaMacWindow.swift` (insert the pills host right above the overlay view, the clock host where `PlazaClockHostingView` was), `PlazaClockView.swift` (deleted), `PlazaWindowController.swift` (owns `PlazaHUD`; `setRendering` drives `hud.isRendering`; the existing 1 s tick asks the clock panel to re-render only when its minute text changes)
- Test: `PlazaHUDTests.swift`, `PlazaPillsPanelTests.swift`, `PlazaClockPanelTests.swift` (shared, stub graphics); `PlazaPanelRenderTests+Mac.swift` (Mac: real CoreText renders written to the harness directory for PR images)

**Interfaces:** Produces the HUD part of the contract; `PlazaWindowController.hud: PlazaHUD`.

- [ ] **Step 1: Failing tests.** `testPillsStackCountdownBannerHintInOrder`, `testBannerWrapsAt360Points`, `testHintIsOneLine`, `testPanelsAreAnchoredLikeTheirConstraints` (frames for 600×372 and 960×640 equal the SwiftUI layout measured once in the Mac test), `testClockRendersOnlyWhenItsTextChanges`, `testAHiddenPlazaRendersNoPanels` (after `setRendering(false)`, model changes cause zero renders; on `true` the dirty panels render once), `testPanelsBelowTheChatLogStayBelowIt` (host order).
- [ ] **Step 2:** Implement; delete the SwiftUI pill and clock code paths.
- [ ] **Step 3: Images** — before/after off-screen snapshots: banner, hint, countdown, clock at backing 1 and 2, default and transparent background. The PR lists every visible difference (expected: sub-pixel antialiasing of rounded strokes, glyph positions within 1 px). The scene itself: harness identical.
- [ ] **Step 4: Fault-inject** — let the clock re-render on every tick while hidden → `testAHiddenPlazaRendersNoPanels` fails; revert.
- [ ] **Step 5: Verify** — harness identical; frame cost ≤ L; gates; Windows CI green with the HUD tests.
- [ ] **Step 6: PR** `feat(plaza): draw the plaza hints and clock as shared panels`. The user approves the images before merge.

---

### Task 15: Shortcut guide, background toggle, name-colour picker, photo frame — Size M

**Files:**
- Create: `Team/Plaza/HUD/{PlazaShortcutGuidePanel,PlazaBackgroundTogglePanel,PlazaNameColorPickerPanel,PlazaPhotoFramePanel}.swift` (the chevron is drawn as a path, not an SF Symbol; the photo frame dim uses an even-odd fill, brackets a stroked path, the guide text shrinks to 0.7 like `minimumScaleFactor`)
- Modify: `PlazaCanvas` (+ `fillPath`/`strokePath` with a small shared `PlazaPath` value type: move, line, close, even-odd flag), `PlazaShortcutGuideView.swift` (keep `PlazaShortcutGuide.entries` / `coveredWidth` as shared data in a new `Team/Plaza/HUD/PlazaShortcutGuideEntries.swift`; the view is deleted), the toggle and picker views, `PlazaOverlayView.swift` (drop the photo frame), `PlazaMacWindow.swift` (hosts in the same positions)
- Test: the `ImageRenderer` tests in `PlazaEmoteTests`/`PlazaFireworksTests` (`guideSize`, `minContentSize` fit) become panel-size tests and move to Windows; `PlazaPhotoOverlayTests` becomes a panel test; `testShortcutGuideKeysAreUnique` stays

- [ ] **Step 1: Failing tests.** `testGuideFoldsAndUnfoldsOnTheHeaderOnly`, `testGuideFitsTheSmallestWindow`, `testThrowLabelFollowsTheSeason`, `testToggleAndPickerHitTargets`, `testPhotoFrameMatchesViewRect` (uses `PlazaPhotoFrame.viewRect(in:)`), `testClicksRefocusTheScene` (through the shell).
- [ ] **Step 2–4:** Implement; images before/after; harness identical; gates; Windows CI green.
- [ ] **Step 5: PR** `feat(plaza): draw the shortcut guide, toggles and photo frame as shared panels`.

---

### Task 16: Member and campfire menus, minimap — Size M

**Files:**
- Create: `Team/Plaza/HUD/{PlazaMenuPanel,PlazaMinimapPanel}.swift`
- Modify: `PlazaMemberMenuView.swift` (titles and rows move to shared `PlazaMenuText`; view deleted), `PlazaOverlayView.swift` (menus leave; the tap-outside-to-cancel area becomes a full-window panel hit region while a menu is open), `PlazaMinimapView.swift` (deleted; the map layer is a shared pixel pass: box-filter downscale (replacing `.interpolation(.medium)`), tint multiply and saturation (`PlazaDaylight.minimapSaturation`) on a `PlazaBitmap`, cached per minute and per season image; dots, view rect, campfire square and item diamond drawn with canvas ellipse/path), `PlazaMacWindow.swift`
- Test: `PlazaCardTests` menu-text checks move to the shared menu tests; minimap model tests to Windows

- [ ] **Step 1: Failing tests.** `testMenuGrowsFrom180ToTheLongestRow`, `testMenuSelectionMarker`, `testClickingARowChooses`, `testClickingOutsideCancels`, `testMinimapDotsAndViewRect`, `testMinimapDimsWhenTheBackgroundIsHidden`, `testMinimapRendersOncePerMinuteAtMost`.
- [ ] **Step 2–4:** Implement; images before/after (the minimap will look slightly different: the downscale filter is ours now — call it out); harness identical; gates; Windows CI green.
- [ ] **Step 5: PR** `feat(plaza): draw the plaza menus and minimap as shared panels`.

---

### Task 17: Decision gate — roster, chat log, board, card — Size S (+ 17a–d if go)

- [ ] **Step 1:** Report to the lead, for the user, in Korean: lines and days Tasks 14–16 actually took; what 17a–d would add to the interface (attributed text runs with several colours, scroll clipping with wheel input and scroll-to-bottom, hover-expand animation, sprite icons in panels, tooltips); the visible-change risk; the D9 alternative and what it costs stage 6.
- [ ] **Step 2 (go):** 17a scroll container + attributed runs (L), 17b chat log (M), 17c roster (L, includes `PlazaIconLoader` through `PlazaImage`), 17d board and card (L). Each follows Task 14's pattern and PR rules.
- [ ] **Step 2 (keep, the D9 deviation):** record the decision in spec §6; leave the four SwiftUI views on the Mac; add `testOverlayModelsAreShared` (a scan: every `@Observable` model those views read lives outside `Team/UI/`).

---

### Task 18: Shared GIF decoder — Size M (independent; any time after Task 3)

**Files:** Create `Team/Plaza/Draw/PlazaGIFDecoder.swift` (GIF87a/89a, LZW, global/local palettes, transparency, disposal 1–3, frame delays with the 0/0.01 s cases handled exactly as `GIFDecoder` does), `Tests/PokeTokenBarTests/PlazaGIFDecoderTests.swift` (shared), `PlazaGIFDecoderParityTests+Mac.swift`

- [ ] **Step 1: Tests.** Shared: hand-built GIF byte fixtures (no Pokémon assets committed): disposal modes, interlace, transparency, truncated data → no crash. Mac: GIFs written by `CGImageDestination` from synthetic frames, decoded by `PlazaGIFDecoder` and by `UI/GIFDecoder` → per-frame pixels and delays equal; env-gated `testEveryCachedSpriteDecodesTheSame` over `PTB_PLAZA_RENDER_SPRITES`.
- [ ] **Step 2:** The Mac keeps `LivePlazaSpriteFetcher` (no visible change). The decoder is for Windows' fetcher in stage 6.
- [ ] **Step 3: PR** `feat(plaza): add a shared GIF decoder for the Windows sprites`.

---

### Task 19: Lock in and report — Size S

**Files:** `Tests/PokeTokenBarTests/SharedSourcesScanTests.swift` (+ `testNoPlazaSourceIsMacOnly`: no `mac-only.txt` entry under `Team/Plaza/`, failure message "plaza code is shared; Mac drawing goes in Platform/Mac/Plaza, Mac views in Team/UI"), delete `Tests/PokeTokenBarTests/Legacy/`, spec §3/§5/§6/§10 as built, `CONTRIBUTING.md` (plaza section: draw only through `PlazaNode`/`PlazaCanvas`; run `plaza-render-compare.sh` for plaza visual changes), `docs/reference/defect-log.md` (one entry per defect class met), `shared-floor.txt`

- [ ] **Step 1:** Fault-inject the new scan (list `Team/Plaza/PlazaScene.swift`) → fails; revert.
- [ ] **Step 2: Live idle check (needs the user's hands-off time; ask, never steal focus).** Release build of `windows-port` and of the last `main` release, each measured for 3 minutes in three states: plaza closed, open and idle, open but fully covered (hidden). Report CPU % (Activity Monitor or `top -l`) and wakeups side by side. Accept: closed and hidden within noise of the release; open idle ≤ release + 10% (guess; confirm with the user).
- [ ] **Step 3:** Final `plaza-render-compare.sh --release --base <last main merge into windows-port before Task 1>` → identical; frame cost ≤ L.
- [ ] **Step 4: PR** `docs(plaza): record the shared plaza and lock it in`. Report to the user in Korean: what is shared, what is still per OS (chat field and its emoji panel, the D9 panels if kept, the SpriteKit/CoreGraphics backend), and what stage 6 must implement (the contract above, plus the Windows shell).

## Order

1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10 → 11 → 12 → 13 → 14 → 15 → 16 → 17 (gate) → 19. Task 18 fits anywhere after 3 (new files only). 4, 5 and 6 are independent of each other once 3 is in and may be reordered; 8's six layers may be split into several PRs if a merge from `main` lands in the middle. Only one build at a time runs on this Mac, so "parallel" means authoring, not verifying.

**With Track B (Windows shell, OS services, transport — `Platform/`, `Package.swift`, a new Windows app target, CI):** the tracks are independent by file ownership. Collisions to manage:
- `Sources/PokeTokenBar/mac-only.txt`, `Tests/PokeTokenBarTests/mac-only.txt`: both edit; line-level merges. `shared-floor.txt`: on any conflict, recount (`SharedSources.lineCount`), never take either side's number.
- `.github/workflows/windows.yml` (test-count floor): Track B owns it; Track A reports new executed counts after Tasks 11 and 13 and the lead has Track B raise the floor.
- The photo clipboard is an OS service in spec §7: Track A declares `ImageClipboarding` and the Mac implementation in `PlatformPlaza.swift` (Task 6); Track B writes the Windows implementation in `Platform/Windows/` later. Confirm with the lead before Task 6.
- `Platform/Mac/`: Track A only adds the `Plaza/` subdirectory.
- `TeamRuntime.swift` / `PlazaPresenting.swift`: Track A does not change their API; Track B's transport work may touch `TeamRuntime`.

## Risks and unknowns (each with the cheapest early check)

- **R1. Indirection cost in `PlazaScene.update`.** Write-through adds a compare and an existential call per changed property. Check: Task 7 Step 3 micro-benchmark (release) and the per-task A/B; Task 1's A/A sets the noise floor. Expected lower cost than today (change detection skips unchanged writes); stop if > 5%.
- **R2. SpriteKit semantics the shared tree must copy.** `size` including scale (and its sign under flip), `frame`, default colour, camera-children z, crop subtree z, exact-tie order under `ignoresSiblingOrder`, texture filtering (all nearest today — verified by grep), `isPaused` changed by SpriteKit itself. Check: Task 1 probes; Task 7 mirror-parity fuzz; tie audit file per harness run. Unknown until Task 1: whether width goes negative under `xScale = -1` (the shared model copies whatever it is).
- **R3. SKAction replacement timing.** Check: Task 7 tween oracle under `SKRenderer`, before any scene change.
- **R4. Text measurement and drawing.** Mac: the CoreText engine must build identical attributed strings (font fallback for emoji in Galmuri lines, truncation with `CTLineCreateTruncatedLine`). Check: Task 3 `testTextLineMatchesCoreTextMetrics` and Task 5 oracles with Hangul/emoji/long inputs. Windows: DirectWrite metrics will differ, so plate widths and bubble wraps differ by a few pixels (spec §5 accepts 1–2 px for Galmuri; Pretendard is a different font) — stage 6's problem, but Track A's shared layout must not assume Mac metrics (stub metrics in Windows tests make this visible).
- **R5. Image identity.** Native GIF frames and PNGs may be device RGB or non-premultiplied; rebuilding them would change pixels. Check: Task 3 `testBundledImagesColourSpaces`; the `real-sprites` harness scene from Task 4 on. Mitigation by design: native images are never rebuilt on the Mac.
- **R6. The harness's own quirks.** `size` reset by `renderer.update`, black first passes, Metal device in `swift test`, `SKRenderer` vs `SKView` frame timing, determinism. Check: Task 1 A/A twice on the same build; the spike showed 9/9 identical. If `SKRenderer` and `SKView` disagree for some effect, the harness cannot see it — the Task 12 off-screen window snapshot is the backstop for the full view.
- **R7. Merge pressure from `main`.** Bug fixes to converted files conflict or merge cleanly into dead code. Check: merge `main` at the start of every task; the legacy oracles and the harness turn a silently-lost fix into a failing test; keep paths and names (Global Constraints).
- **R8. Test migration volume.** About 770 synchronous `@MainActor` plaza tests to make async and many Mac-metric assertions; the Windows triage loop costs about 8 minutes per CI round. Check: Task 2 and Task 4 move small files first and give a per-file round-trip time; Tasks 11 and 13 are separate PRs so the Mac-side conversions are not held hostage by Windows triage.
- **R9. Overlay z-order and look.** Partial migration could flip which of a SwiftUI panel and a drawn panel is on top (today the banner draws above an open board). Check: Task 14 `testPanelsBelowTheChatLogStayBelowIt` and the host insertion rule (insert where the old hosting view was); before/after images per PR.
- **R10. Swift 6 concurrency.** `PlazaImage` caches (NSLock), art builders called off the main actor (`PlazaCampfireArt` uses `NSLock` today), `@MainActor` nodes and textures. Check: `shared-check.sh` with strict concurrency on every task; Windows CI.
- **R11. Release-mode test builds.** `@testable import` needs `-enable-testing` in release. Check: Task 1 Step 5; fallback is debug A/B (conservative).

## Open questions for the session lead

1. D9: does the user keep roster, chat log, board and card as Mac SwiftUI views for now (deviation from spec §6), or should Task 17's go branch be planned in? The gate asks with numbers, but an early "no" saves Task 17's preparation.
2. Ownership: may Track A declare `ImageClipboarding` in `PlatformPlaza.swift` (spec §7 lists the clipboard as an OS service), and will Track B raise the Windows test-count floor when Tasks 11 and 13 report new counts?
3. Does the `main` freeze cover `Team/UI/` and the `*Art` files too, and when does `windows-port` merge into `main` (spec §10 says new plaza features go to shared code after step 3, i.e. after Task 13)?
4. When can the user give hands-off time for the live checks (Task 12 smoke run, Task 19 idle CPU)? Both are blocked without it.
5. Should the Mac switch to the shared GIF decoder once Task 18 proves equality on the whole sprite cache, or keep `SpriteLoader` for good (spec §5 is ambiguous)?
6. Windows modifier mapping (does Ctrl act as `.command` for Ctrl+W, or is Alt+F4 the close?) is stage 6's, but it decides whether `PlazaModifiers.command` keeps its name; fine to leave until then?
7. The legacy oracle copies add roughly 1,500 lines of test code until Task 19; acceptable?
