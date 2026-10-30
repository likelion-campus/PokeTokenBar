import AppKit
import XCTest

/// A system memory-pressure signal changes every NSCache in the process until the next normal signal:
/// after "warn" caches without a limit keep nothing, and after "critical" caches that already exist keep
/// nothing. Tests that read back what they just cached then fail in a block, on whichever run the Mac
/// happens to get the signal. See docs/reference/defect-log.md.
enum NSCachePressure {
    static let normal: UInt = 1, warn: UInt = 2, critical: UInt = 4

    private typealias Simulate = @convention(c) (UInt) -> Void
    private nonisolated(unsafe) static let symbol: UnsafeMutableRawPointer? = dlsym(
        dlopen("/usr/lib/system/libcache.dylib", RTLD_NOW), "cache_simulate_memory_warning_event")

    static var isAvailable: Bool { symbol != nil }

    /// Affects this process only.
    static func signal(_ level: UInt) {
        guard let symbol else { return }
        unsafeBitCast(symbol, to: Simulate.self)(level)
    }
}

/// Puts the caches back to normal before every test, so no test depends on the Mac's memory at that moment.
final class NSCachePressureResetObserver: NSObject, XCTestObservation {
    func testCaseWillStart(_ testCase: XCTestCase) {
        NSCachePressure.signal(NSCachePressure.normal)
    }
}

/// Named to run first: test classes run alphabetically, and SwiftPM test bundles have no principal class
/// that could register the observer earlier.
@MainActor
final class AaaNSCachePressureGuardTests: XCTestCase {
    private static let observer: NSCachePressureResetObserver = {
        let o = NSCachePressureResetObserver()
        XCTestObservationCenter.shared.addTestObserver(o)
        return o
    }()

    private func keepsWhatItStores(_ cache: NSCache<NSString, NSImage>) -> Bool {
        let key = UUID().uuidString as NSString
        let image = NSImage(size: NSSize(width: 2, height: 2))
        cache.setObject(image, forKey: key)
        return cache.object(forKey: key) === image
    }

    /// The signal is handled on another queue, a moment after it is sent.
    private func eventually(_ condition: () -> Bool) -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            usleep(10_000)
        }
        return false
    }

    func testObserverRestoresCachesAfterACriticalSignal() throws {
        _ = Self.observer   // Register before anything can skip this test: every later test relies on it.
        try XCTSkipUnless(NSCachePressure.isAvailable, "libcache no longer exports the signal")
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        XCTAssertTrue(keepsWhatItStores(cache))

        NSCachePressure.signal(NSCachePressure.critical)
        defer { NSCachePressure.signal(NSCachePressure.normal) }
        try XCTSkipUnless(eventually { !keepsWhatItStores(cache) },
                          "on this macOS a critical signal no longer stops caches")

        Self.observer.testCaseWillStart(self)
        XCTAssertTrue(eventually { keepsWhatItStores(cache) }, "the observer must bring the cache back")
    }
}
