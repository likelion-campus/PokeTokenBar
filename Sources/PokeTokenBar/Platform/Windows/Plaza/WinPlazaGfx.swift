#if os(Windows)
import CPlazaD2D
import Foundation

/// Owns one `PTBGfxDevice` (D1). Every bitmap ref and surface keeps it, so the device outlives what was made on it; the
/// last owner releases it (by then nothing draws with it, so the thread does not matter).
final class WinGfxDeviceHandle: @unchecked Sendable {
    let raw: OpaquePointer
    init(_ raw: OpaquePointer) { self.raw = raw }
    deinit { ptb_gfx_device_release(raw) }
}

/// A texture on the device: what `PlazaImage.backendCache` holds on Windows (D2).
///
/// Cache policy: the key is the `PlazaImage` itself (a texture cut from it, `PlazaTexture(rect:in:)`, is a source rect into
/// the same bitmap and never uploads). The bitmap lives exactly as long as its image: no LRU, no budget; when the scene
/// drops an image (a teammate leaves, a season changes, an animation set is evicted) the ref's `deinit` queues the release
/// (any thread) and the next main-thread device call frees it. A ref of an older device generation is stale: the next draw
/// uploads the image again and replaces it.
///
/// The ref does not keep the device alive (Task 5): images the app keeps for its whole life (the map, the art caches) would
/// otherwise hold a closed plaza's Direct3D device. When the device is gone its bitmaps went with it, and the ref is stale.
final class WinBitmapRef: @unchecked Sendable {
    weak var device: WinGfxDeviceHandle?
    let handle: UInt32
    let generation: UInt32
    let bytes: Int

    init(device: WinGfxDeviceHandle, handle: UInt32, generation: UInt32, bytes: Int) {
        self.device = device
        self.handle = handle
        self.generation = generation
        self.bytes = bytes
    }

    deinit {
        if let device { ptb_gfx_bitmap_release(device.raw, handle, generation) }
    }
}

/// Test-only switches that break one parity rule each, so the tests prove they notice (`WindowsPlazaRendererTests.
/// testEachInjectedFaultIsCaught`). Debug builds only; in a release build `has` is always false and compiles away.
@MainActor enum WinRenderFaults {
    enum Fault: CaseIterable, Sendable {
        /// Uploads multiply the colour bytes by alpha a second time (WIC's straight alpha premultiplied twice).
        case premultiplyTwice
        /// Linear instead of nearest-neighbour sampling.
        case bilinear
        /// Equal-z sprites drawn in reverse tree order (the tie rule broken).
        case reverseTies
        /// `.multiply` drawn as `.multiplyX2` and the other way round.
        case swapMultiplyModes
        /// Screen-space items (camera children) drawn without the y-flip.
        case noScreenFlip
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

/// A Direct3D 11 + Direct2D 1.1 device (D1). Main thread only (the Direct2D factory is single-threaded); bitmap refs may be
/// released on any thread. Hardware first, WARP when hardware creation fails or when asked (`PTB_PLAZA_DEVICE=warp`, CI and
/// tests); three losses within 10 s switch to WARP for good.
@MainActor final class WinGfxDevice {
    let owner: WinGfxDeviceHandle
    /// The adapter's description (`DXGI_ADAPTER_DESC`), logged once by the caller.
    let adapter: String
    private(set) var wantsWarp: Bool
    private var lossTimes: [TimeInterval] = []
    private var failedUploads = 0

    private init(owner: WinGfxDeviceHandle, adapter: String, warp: Bool) {
        self.owner = owner
        self.adapter = adapter
        wantsWarp = warp
    }

    /// True when the environment asks for WARP (`PTB_PLAZA_DEVICE=warp`: CI and QA, not a usage location).
    nonisolated static var environmentWantsWarp: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["PTB_PLAZA_DEVICE"]?.lowercased() == "warp"
    }

    /// A new device, or the reason none could be made (the plaza then stays closed and says so in the log).
    static func make(forceWarp: Bool = environmentWantsWarp) -> Result<WinGfxDevice, WinGfxError> {
        guard WinPlazaGraphics.availability.isAvailable else { return .failure(.unavailable(WinPlazaGraphics.availability.summary)) }
        var name = [UInt16](repeating: 0, count: 128)
        guard let raw = ptb_gfx_device_create(forceWarp ? 1 : 0, &name, UInt32(name.count)) else {
            return .failure(.unavailable(WinPlazaCodecs.lastError()))
        }
        let adapter = String(decoding: name.prefix { $0 != 0 }, as: UTF16.self)
        return .success(WinGfxDevice(owner: WinGfxDeviceHandle(raw), adapter: adapter, warp: forceWarp))
    }

    var generation: UInt32 { ptb_gfx_device_generation(owner.raw) }

    var stats: PTBGfxDeviceStats {
        var s = PTBGfxDeviceStats()
        ptb_gfx_device_stats(owner.raw, &s)
        return s
    }

    var isWarp: Bool { stats.isWarp != 0 }

    /// The image's bitmap on this device, uploaded the first time (and again after a rebuild). Nil when the image is empty
    /// or the upload failed (logged once per failure kind by the caller's stats).
    func bitmap(for image: PlazaImage) -> WinBitmapRef? {
        let gen = generation
        if let ref = image.backendCache as? WinBitmapRef, ref.generation == gen, ref.device === owner { return ref }
        let bitmap = image.pixels
        guard bitmap.width > 0, bitmap.height > 0 else { return nil }
        let opaque: Int32 = bitmap.alpha == .noneSkipLast ? 1 : 0
        let handle: UInt32
        if WinRenderFaults.has(.premultiplyTwice) {
            var bytes = bitmap.bytes
            for i in stride(from: 0, to: bytes.count, by: 4) {
                let a = UInt32(bytes[i + 3])
                for c in 0..<3 { bytes[i + c] = UInt8((UInt32(bytes[i + c]) * a + 127) / 255) }
            }
            handle = bytes.withUnsafeBufferPointer {
                ptb_gfx_bitmap(owner.raw, $0.baseAddress, UInt32(bitmap.width), UInt32(bitmap.height), UInt32(bitmap.width * 4), opaque)
            }
        } else {
            handle = bitmap.bytes.withUnsafeBufferPointer {
                ptb_gfx_bitmap(owner.raw, $0.baseAddress, UInt32(bitmap.width), UInt32(bitmap.height), UInt32(bitmap.width * 4), opaque)
            }
        }
        guard handle != 0 else {
            failedUploads += 1
            if failedUploads == 1 { AppLog.write("plaza renderer: bitmap upload failed (\(WinPlazaCodecs.lastError()))") }
            return nil
        }
        let ref = WinBitmapRef(device: owner, handle: handle, generation: gen, bytes: bitmap.width * bitmap.height * 4)
        image.backendCache = ref
        return ref
    }

    /// After a loss: new device objects, generation + 1 (every bitmap ref is stale and re-uploads lazily). Three losses
    /// within 10 s switch to WARP. False when no device could be made again.
    func recreateAfterLoss(at now: TimeInterval) -> Bool {
        lossTimes = lossTimes.filter { now - $0 < 10 } + [now]
        if lossTimes.count >= 3, !wantsWarp {
            wantsWarp = true
            AppLog.write("plaza renderer: three device losses within 10 s, switching to WARP")
        }
        let code = ptb_gfx_device_recreate(owner.raw, wantsWarp ? 1 : 0)
        if code >= 0 {
            failedRebuilds = 0
            AppLog.write("plaza renderer: device lost, rebuilt (generation \(generation), warp \(isWarp))")
        } else {
            failedRebuilds += 1
            if failedRebuilds == 1 { AppLog.write("plaza renderer: device lost and not rebuilt: \(WinPlazaCodecs.lastError()) (retried every tick, logged once)") }
        }
        return code >= 0
    }

    private var failedRebuilds = 0

    /// Test and selftest: the next frame's `EndDraw` reports `D2DERR_RECREATE_TARGET` and the device is lost.
    func injectDeviceLoss() { ptb_gfx_inject_fault(owner.raw, 1) }

    /// Debug options for the shim (see `ptb_gfx_set_options`).
    func setOptions(_ flags: UInt32) { ptb_gfx_set_options(owner.raw, flags) }

    /// Waits until the GPU (WARP: its worker threads) has executed everything submitted. Timing only.
    func finish() { _ = ptb_gfx_finish(owner.raw) }
}

enum WinGfxError: Error, CustomStringConvertible, Equatable {
    case unavailable(String)
    var description: String {
        switch self {
        case .unavailable(let why): "Direct2D device unavailable: \(why)"
        }
    }
}

/// Owns one `PTBGfxSurface`; keeps the device alive behind it.
final class WinGfxSurfaceHandle: @unchecked Sendable {
    let raw: OpaquePointer
    let device: WinGfxDeviceHandle
    init(_ raw: OpaquePointer, device: WinGfxDeviceHandle) {
        self.raw = raw
        self.device = device
    }
    deinit { ptb_gfx_surface_release(raw) }
}

/// Where a frame is drawn: an offscreen frame bitmap, or a window's (Task 5: the frame bitmap presented through the window's
/// DirectComposition swap chain), sized in device pixels. Main thread only.
@MainActor final class WinGfxSurface {
    let device: WinGfxDevice
    let handle: WinGfxSurfaceHandle
    /// A window surface presents (`present()`); an offscreen one only draws and reads back.
    let isWindow: Bool
    private(set) var width: Int
    private(set) var height: Int

    private init(device: WinGfxDevice, handle: WinGfxSurfaceHandle, width: Int, height: Int, isWindow: Bool = false) {
        self.device = device
        self.handle = handle
        self.width = width
        self.height = height
        self.isWindow = isWindow
    }

    /// The window's surface (D1): a composition swap chain for `hwnd` (which has `WS_EX_NOREDIRECTIONBITMAP`).
    static func window(device: WinGfxDevice, hwnd: UnsafeMutableRawPointer, width: Int, height: Int) -> Result<WinGfxSurface, WinGfxError> {
        guard width > 0, height > 0, let raw = ptb_gfx_surface_window(device.owner.raw, hwnd, UInt32(width), UInt32(height)) else {
            return .failure(.unavailable("window surface \(width)x\(height): \(WinPlazaCodecs.lastError())"))
        }
        return .success(WinGfxSurface(device: device, handle: WinGfxSurfaceHandle(raw, device: device.owner), width: width, height: height,
                                      isWindow: true))
    }

    /// A window surface: true when a frame may be drawn and presented now (the swap chain's frame-latency waitable,
    /// waited up to `waitMs`); false while the GPU is behind.
    func acquireFrame(waitMs: UInt32 = 0) -> Bool { ptb_gfx_window_acquire(handle.raw, waitMs) != 0 }

    /// A window surface: presents the last drawn frame. 0 or `DXGI_STATUS_OCCLUDED`, else the failure (a device loss marks the
    /// device lost: rebuild it).
    func present() -> Int32 { ptb_gfx_window_present(handle.raw) }

    var windowStats: PTBGfxWindowStats {
        var s = PTBGfxWindowStats()
        ptb_gfx_window_stats(handle.raw, &s)
        return s
    }

    static func offscreen(device: WinGfxDevice, width: Int, height: Int) -> Result<WinGfxSurface, WinGfxError> {
        guard width > 0, height > 0, let raw = ptb_gfx_surface_offscreen(device.owner.raw, UInt32(width), UInt32(height)) else {
            return .failure(.unavailable("offscreen surface \(width)x\(height): \(WinPlazaCodecs.lastError())"))
        }
        return .success(WinGfxSurface(device: device, handle: WinGfxSurfaceHandle(raw, device: device.owner), width: width, height: height))
    }

    /// Device pixels. The resources are made again on the next frame (a window surface resizes its buffers now).
    func resize(width: Int, height: Int) {
        guard width > 0, height > 0, width != self.width || height != self.height else { return }
        let code = isWindow ? ptb_gfx_window_resize(handle.raw, UInt32(width), UInt32(height))
            : ptb_gfx_surface_resize(handle.raw, UInt32(width), UInt32(height))
        if code >= 0 || isWindow {   // a window surface keeps the new size even when its buffers must be made again
            self.width = width
            self.height = height
        }
    }

    /// The last frame as premultiplied RGBA8, row 0 at the top (the harness and the selftest). Nil when nothing was drawn
    /// on this device generation.
    func readRGBA() -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: width * height * 4)
        let code = out.withUnsafeMutableBufferPointer { ptb_gfx_read(handle.raw, $0.baseAddress, UInt32(width * 4)) }
        return code >= 0 ? out : nil
    }
}
#endif
