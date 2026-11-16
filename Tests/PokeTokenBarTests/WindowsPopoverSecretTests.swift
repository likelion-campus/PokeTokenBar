#if os(Windows)
import Foundation
import WinSDK
import XCTest
@testable import PokeTokenBar

/// The session key's file on Windows (stage 7 Task 14, D14): DPAPI through `WinSecret`, and `SessionKeyStore` through the
/// `PlatformCompat` secret seams. Fixture keys only.
final class WindowsPopoverSecretTests: XCTestCase {
    private var dir: URL!
    private let lines = LineBox()
    private let fixtureKey = "sk-ant-sid02-" + String(repeating: "Fx7q", count: 20)

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-secret-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        WinSecret.resetReportsForTesting()
        let box = lines
        WinSecret.logLineForTesting = { box.append($0) }
    }

    override func tearDown() {
        WinSecret.logLineForTesting = nil
        WinSecret.resetReportsForTesting()
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private var credential: SessionKeyCredential { SessionKeyCredential(key: fixtureKey, organizationID: "org-fixture") }
    private var keyBytes: Data { Data(fixtureKey.utf8) }
    private func file(_ name: String = "session-key.json") -> URL { dir.appendingPathComponent(name) }

    // MARK: DPAPI

    func testTheBlobIsLaidOutAsDATA_BLOB() {
        XCTAssertEqual(WinSecret.Blob.size, 16, "DATA_BLOB on 64-bit Windows")
        XCTAssertEqual(WinSecret.Blob.pointerOffset, 8)
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: 4, alignment: 1)
        defer { bytes.deallocate() }
        let blob = WinSecret.Blob(count: 4, bytes: bytes)
        defer { blob.free() }
        XCTAssertEqual(blob.count, 4)
        XCTAssertEqual(blob.bytes, bytes)
    }

    func testARoundTripGivesTheBytesBack() throws {
        let plain = try JSONEncoder().encode(credential)
        let blob = try XCTUnwrap(WinSecret.protect(plain), "CryptProtectData refused")
        XCTAssertNotEqual(blob, plain)
        XCTAssertNil(blob.range(of: keyBytes), "the key in the encrypted bytes")
        XCTAssertFalse(WinSecret.isPlainJSON(blob))
        XCTAssertEqual(blob.prefix(4), Data([1, 0, 0, 0]), "a DPAPI blob starts with its version")
        XCTAssertEqual(WinSecret.unprotect(blob), plain)
        print("SECRET-PROBE|round trip|plain=\(plain.count) bytes|blob=\(blob.count) bytes")
    }

    func testATamperedBlobReadsAsNothing() throws {
        let plain = try JSONEncoder().encode(credential)
        let blob = try XCTUnwrap(WinSecret.protect(plain))
        for index in [24, blob.count / 2, blob.count - 1] {
            var bad = blob
            bad[bad.startIndex + index] ^= 0x40
            XCTAssertNil(WinSecret.unprotect(bad), "a blob changed at byte \(index) decrypted")
        }
        XCTAssertNil(WinSecret.unprotect(blob.prefix(blob.count - 8)), "a cut blob decrypted")
        XCTAssertNil(WinSecret.unprotect(Data([1, 0, 0, 0]) + Data(repeating: 7, count: 200)), "random bytes decrypted")
    }

    func testAnotherEntropyReadsAsNothing() throws {
        let plain = try JSONEncoder().encode(credential)
        let ours = try XCTUnwrap(WinSecret.protect(plain))
        XCTAssertNil(WinSecret.unprotect(ours, entropy: Data("another app".utf8)))
        XCTAssertNil(WinSecret.unprotect(ours, entropy: Data()), "read without the entropy")
        let theirs = try XCTUnwrap(WinSecret.protect(plain, entropy: Data("another app".utf8)))
        XCTAssertNil(WinSecret.unprotect(theirs), "another program's blob taken for ours")
        let none = try XCTUnwrap(WinSecret.protect(plain, entropy: Data()))
        XCTAssertNil(WinSecret.unprotect(none), "a blob made without entropy taken for ours")
    }

    func testPlainJSONIsTellableFromABlob() {
        XCTAssertTrue(WinSecret.isPlainJSON(Data(" \r\n{\"key\":1}".utf8)))
        XCTAssertFalse(WinSecret.isPlainJSON(Data("[1]".utf8)))
        XCTAssertFalse(WinSecret.isPlainJSON(Data([1, 0, 0, 0, 0x7B])))
        XCTAssertFalse(WinSecret.isPlainJSON(Data()))
    }

    // MARK: the store through the seams

    func testTheStoreSavesTheKeyEncrypted() throws {
        let store = SessionKeyStore(fileURL: file())
        try store.save(credential)
        let raw = try Data(contentsOf: store.fileURL)
        XCTAssertNil(raw.range(of: keyBytes), "the key is in the file as plain text")
        XCTAssertFalse(WinSecret.isPlainJSON(raw))
        XCTAssertEqual(store.load(), credential)
        XCTAssertEqual(lines.all, [], "a good save and read log nothing")
        store.clear()
        XCTAssertNil(store.load())
    }

    func testAPlainFileIsReadThenEncryptedInPlace() throws {
        let store = SessionKeyStore(fileURL: file())
        try JSONEncoder().encode(credential).write(to: store.fileURL)   // what an earlier Windows build left
        XCTAssertEqual(store.load(), credential, "the plain file is read")
        let raw = try Data(contentsOf: store.fileURL)
        XCTAssertNil(raw.range(of: keyBytes), "the file is still plain text after the first read")
        XCTAssertEqual(try JSONDecoder().decode(SessionKeyCredential.self, from: try XCTUnwrap(WinSecret.unprotect(raw))), credential)
        XCTAssertEqual(store.load(), credential, "the encrypted file is read")
        XCTAssertEqual(lines.all.count, 1, "\(lines.all)")
        XCTAssertTrue(lines.all.first?.contains("session-key.json was plain text") == true, "\(lines.all)")
        XCTAssertFalse(lines.all.joined().contains("sk-ant-"), "key material in a log line")
    }

    /// The migration replaces the plain file with the encrypted one in one rename: a reader looking at the file all the time
    /// never finds it missing (`GetFileAttributesW` opens no handle, so it does not slow the rename down either).
    func testTheMigrationNeverLeavesTheFileMissing() throws {
        let url = file()
        let plain = try JSONEncoder().encode(credential)
        try WinAtomicWrite.write(plain, to: url)
        let probe = FileProbe(path: WinPath.native(url))
        let thread = Thread { probe.run() }
        thread.start()
        var migrated = 0
        for _ in 0..<60 {
            try WinAtomicWrite.write(plain, to: url)   // plain again (no gap either: a rename)
            WinSecret.resetReportsForTesting()
            guard WinSecret.read(at: url) == plain else { XCTFail("the plain file did not read back"); break }
            if let raw = try? Data(contentsOf: url), !WinSecret.isPlainJSON(raw) { migrated += 1 }
        }
        probe.stop()
        while !probe.finished { Thread.sleep(forTimeInterval: 0.001) }
        print("SECRET-PROBE|migration|migrated \(migrated) of 60|reader looked \(probe.looks) times|missing \(probe.misses)")
        XCTAssertEqual(migrated, 60)
        XCTAssertGreaterThan(probe.looks, 60, "the reader did not run alongside")
        XCTAssertEqual(probe.misses, 0, "the file was missing while it was migrated")
    }

    func testAFileThatDoesNotDecryptReadsAsNoKeyWithOneLogLine() throws {
        let store = SessionKeyStore(fileURL: file())
        // DPAPI-made, but not for this app (another program, or another account's key: either way not ours to decrypt).
        let foreign = try XCTUnwrap(WinSecret.protect(try JSONEncoder().encode(credential), entropy: Data("elsewhere".utf8)))
        try foreign.write(to: store.fileURL)
        XCTAssertNil(store.load())
        XCTAssertNil(store.load(), "the second read")
        XCTAssertEqual(lines.all.count, 1, "one log line for one unreadable file: \(lines.all)")
        let line = lines.all.first ?? ""
        XCTAssertTrue(line.contains("session-key.json cannot be decrypted"), line)
        XCTAssertFalse(line.contains("sk-ant-"), "key material in the log line")
        XCTAssertFalse(line.contains("org-fixture"))
        // A damaged file of the same name is the same file: still one line. A new save makes it readable.
        try (Data([1, 0, 0, 0]) + Data(repeating: 9, count: 120)).write(to: store.fileURL)
        XCTAssertNil(store.load())
        XCTAssertEqual(lines.all.count, 1)
        try store.save(credential)
        XCTAssertEqual(store.load(), credential)
        print("SECRET-PROBE|undecryptable|\(line)")
    }

    func testAnEmptyFileIsNoKeyAndNoLogLine() throws {
        let store = SessionKeyStore(fileURL: file())
        FileManager.default.createFile(atPath: store.fileURL.path, contents: Data())   // `save` creates it empty first
        XCTAssertNil(store.load())
        XCTAssertEqual(lines.all, [])
    }

    func testAnAccountKeyFileIsEncryptedToo() throws {
        let root = dir.appendingPathComponent(".claude-work")
        let store = SessionKeyStore.forConfigRoot(root, directory: dir)
        try store.save(credential)
        XCTAssertNil(try Data(contentsOf: store.fileURL).range(of: keyBytes))
        XCTAssertEqual(store.load(), credential)
    }
}

/// Log lines from any thread.
private final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}

/// Looks at a file's attributes in a loop on its own thread.
private final class FileProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let path: String
    private var stopped = false
    private var counts = (looks: 0, misses: 0)
    private var done = false

    init(path: String) { self.path = path }

    func run() {
        while true {
            lock.lock()
            if stopped { done = true; lock.unlock(); return }
            lock.unlock()
            let attributes = path.withCString(encodedAs: UTF16.self) { GetFileAttributesW($0) }
            lock.lock()
            counts.looks += 1
            if attributes == DWORD.max /* INVALID_FILE_ATTRIBUTES */ { counts.misses += 1 }
            lock.unlock()
        }
    }

    func stop() { lock.lock(); stopped = true; lock.unlock() }
    var finished: Bool { lock.lock(); defer { lock.unlock() }; return done }
    var looks: Int { lock.lock(); defer { lock.unlock() }; return counts.looks }
    var misses: Int { lock.lock(); defer { lock.unlock() }; return counts.misses }
}
#endif
