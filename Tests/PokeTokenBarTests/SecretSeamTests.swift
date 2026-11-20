import Foundation
import XCTest
@testable import PokeTokenBar

/// The session key's file goes through `PlatformCompat.writeSecret` / `readSecret` (stage 7 Task 14, D14): the two upstream
/// lines in `SessionKeyStore`. On the Mac the seams are exactly the calls they replaced (pinned here); on Windows they encrypt
/// with DPAPI (`WindowsPopoverSecretTests`). Fixture keys only.
final class SecretSeamTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-secret-seam-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private let data = Data(#"{"key":"sk-ant-sid02-fixture-fixture-fixture-fixture"}"#.utf8)

    /// Both systems: what goes in through the seam comes out of it, and a missing file is nil.
    func testWhatIsWrittenIsRead() throws {
        let url = dir.appendingPathComponent("secret.json")
        XCTAssertNil(PlatformCompat.readSecret(at: url))
        try PlatformCompat.writeSecret(data, to: url)
        XCTAssertEqual(PlatformCompat.readSecret(at: url), data)
        try PlatformCompat.writeSecret(Data(#"{"key":"other"}"#.utf8), to: url)
        XCTAssertEqual(PlatformCompat.readSecret(at: url), Data(#"{"key":"other"}"#.utf8), "a second write replaces the first")
    }

    #if !os(Windows)
    /// Mac pin: `writeSecret` is `data.write(to:options: .atomic)` byte for byte, and an owner-only file stays owner-only.
    func testTheMacWritesASecretAsDataWriteAtomicDid() throws {
        let seam = dir.appendingPathComponent("seam.json"), old = dir.appendingPathComponent("old.json")
        for url in [seam, old] {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: NSNumber(value: Int16(0o600))])
        }
        try PlatformCompat.writeSecret(data, to: seam)
        try data.write(to: old, options: .atomic)
        XCTAssertEqual(try Data(contentsOf: seam), data)
        XCTAssertEqual(try Data(contentsOf: seam), try Data(contentsOf: old))
        func mode(_ url: URL) throws -> Int16? {
            (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.int16Value
        }
        XCTAssertEqual(try mode(seam), try mode(old))
        XCTAssertEqual(try mode(seam), 0o600)
    }

    /// Mac pin: `readSecret` is `try? Data(contentsOf:)`: the file's bytes as they are (plain JSON), nil without a file.
    func testTheMacReadsASecretAsDataContentsOfDid() throws {
        let url = dir.appendingPathComponent("plain.json")
        try data.write(to: url)
        XCTAssertEqual(PlatformCompat.readSecret(at: url), try? Data(contentsOf: url))
        XCTAssertEqual(PlatformCompat.readSecret(at: url), data, "the Mac keeps the file in plain JSON")
        let missing = dir.appendingPathComponent("missing.json")
        XCTAssertEqual(PlatformCompat.readSecret(at: missing), try? Data(contentsOf: missing))
        XCTAssertNil(PlatformCompat.readSecret(at: missing))
    }

    /// Mac pin: the store's file is still the plain owner-only JSON the Mac always wrote.
    func testTheMacStoreFileIsStillPlainOwnerOnlyJSON() throws {
        let store = SessionKeyStore(fileURL: dir.appendingPathComponent("session-key.json"))
        let credential = SessionKeyCredential(key: "sk-ant-sid02-" + String(repeating: "m", count: 60), organizationID: "org-mac")
        try store.save(credential)
        // Plain JSON of the credential. Not byte-equal to a second `JSONEncoder().encode`: the key order of an unsorted encoder is
        // not stable (swift-foundation), and the runner's two encodes came out as two orders of the same 110 bytes.
        let onDisk = try Data(contentsOf: store.fileURL)
        XCTAssertEqual(try JSONDecoder().decode(SessionKeyCredential.self, from: onDisk), credential)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: onDisk) as? [String: String],
                       ["key": credential.key, "organizationID": "org-mac"], "plain JSON, exactly these two fields")
        let mode = (try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber)?.int16Value
        XCTAssertEqual(mode, 0o600)
        XCTAssertEqual(store.load(), credential)
    }
    #endif
}

/// The match count Settings shows for the custom scan folders (`CustomScanRoots.survivingExtraCount`), on a fixture tree the
/// same way on both systems: the Windows page calls the same function the Mac's `scheduleCustomScanMatchCount` calls.
final class ScanFolderCountTests: XCTestCase {
    func testTheMatchCountForAFixtureTreeIsTheSameOnBothSystems() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-scan-count-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["logs/proj-a", "logs/proj-b", "logs/other", "with space", "한글 폴더"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data("x".utf8).write(to: root.appendingPathComponent("file"))
        let p = root.path
        let raw = "\(p)/logs/proj-*\n\(p)/with space, \(p)/한글 폴더/\n\(p)/missing\n\(p)/missing/*\n\(p)/file\n\(p)/logs/proj-a/\nrelative/path"
        // proj-a, proj-b, "with space", 한글 폴더; proj-a twice counts once; the missing ones, a file and a relative path not at all.
        XCTAssertEqual(CustomScanRoots.survivingExtraCount(defaults: [root.appendingPathComponent("logs/other")], extraRaw: raw), 4)
        // An ancestor of a default never counts (it would evict the default).
        XCTAssertEqual(CustomScanRoots.survivingExtraCount(defaults: [root.appendingPathComponent("logs/other")], extraRaw: "\(p)/logs"), 0)
    }
}
