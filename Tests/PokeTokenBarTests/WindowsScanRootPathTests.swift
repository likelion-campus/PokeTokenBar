#if os(Windows)
import Foundation
import WinSDK
import XCTest
@testable import PokeTokenBar

/// The path forms a Windows user types into Settings → Advanced (custom scan folders, additional Claude folders), through the
/// real file system: spaces, non-ASCII, trailing and mixed separators, a drive root, a UNC share (P19, stage 7 Task 14). The
/// share is this PC's own administrative share of the fixture folder (`\\localhost\C$\…`), also mapped to a free drive letter
/// (`net use`); on the CI runner both must exist (the tests fail without them), elsewhere they are skipped.
final class WindowsScanRootPathTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-paths-\(UUID().uuidString)")
        for name in ["plain", "with space", "한글 폴더", "logs/proj-a", "logs/proj-b", "logs/other"] {
            try? FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
    }

    override func tearDown() {
        if let mapped { Self.net(["use", mapped, "/delete", "/y"]) }
        mapped = nil
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private var mapped: String?
    private static var onCI: Bool { ProcessInfo.processInfo.environment["CI"] != nil }
    private struct Missing: Error, CustomStringConvertible { let description: String }

    /// What a test needs from this PC: on the runner its absence is a failure, elsewhere a skip.
    private func require<T>(_ value: T?, _ what: String) throws -> T {
        if let value { return value }
        if Self.onCI { throw Missing(description: "\(what) is missing on the CI runner") }
        throw XCTSkip("no \(what) on this PC")
    }

    @discardableResult
    private static func net(_ arguments: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: #"C:\Windows\System32\net.exe"#)
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// The fixture's drive mapped to a free letter as `net use X: \\localhost\C$` maps it (a network drive: `GetDriveTypeW` says
    /// DRIVE_REMOTE): the same folder as `X:\…`, or nil.
    private func mappedDrive(_ rest: String = "") -> String? {
        let n = native(rest)
        let u = Array(n)
        guard u.count > 3, u[1] == ":" else { return nil }
        if mapped == nil {
            let used = GetLogicalDrives()
            guard let letter = "ZYXWVUTSRQPONM".first(where: { used & (DWORD(1) << DWORD($0.asciiValue! - 65)) == 0 }) else { return nil }
            let drive = "\(letter):"
            guard Self.net(["use", drive, "\\\\localhost\\\(u[0])$"]) == 0 else { return nil }
            mapped = drive
        }
        guard let mapped else { return nil }
        let path = mapped + String(u.dropFirst(2))
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// `C:\…\ptb-paths-…\<rest>` with backslashes.
    private func native(_ rest: String = "") -> String {
        WinPath.native(rest.isEmpty ? root : root.appendingPathComponent(rest))
    }

    /// The same folder through `\\localhost\<drive>$\…`, or nil when this PC has no such share.
    private func unc(_ rest: String = "") -> String? {
        let n = native(rest)
        let u = Array(n)
        guard u.count > 3, u[1] == ":" else { return nil }
        let share = "\\\\localhost\\\(u[0])$" + String(u.dropFirst(2))
        return FileManager.default.fileExists(atPath: share) ? share : nil
    }

    func testWhatFoundationMakesOfAUNCPath() throws {
        let share = try require(unc("plain"), "administrative share")
        let slashed = share.replacingOccurrences(of: "\\", with: "/")
        let url = URL(fileURLWithPath: share)
        var isDir: ObjCBool = false
        let shareRoot = String(share.prefix(while: { $0 != "$" })) + "$"
        print("PATH-PROBE|unc=\(share)|URL.path=\(url.path)|standardized=\(url.standardizedFileURL.path)"
              + "|resolved=\(url.resolvingSymlinksInPath().path)|resolved.standardized=\(url.resolvingSymlinksInPath().standardizedFileURL.path)"
              + "|native=\(WinPath.native(url))|exists(backslash)=\(FileManager.default.fileExists(atPath: share))"
              + "|exists(slashes)=\(FileManager.default.fileExists(atPath: slashed, isDirectory: &isDir)) dir=\(isDir.boolValue)"
              + "|exists(URL.path)=\(FileManager.default.fileExists(atPath: url.path))"
              + "|shareRoot=\(shareRoot)|exists(shareRoot)=\(FileManager.default.fileExists(atPath: shareRoot))"
              + "|exists(shareRoot/)=\(FileManager.default.fileExists(atPath: shareRoot + "\\"))"
              + "|list(shareRoot slashes/)=\(((try? FileManager.default.contentsOfDirectory(atPath: shareRoot.replacingOccurrences(of: "\\", with: "/") + "/")) ?? []).count)"
              + "|list(logs)=\(((try? FileManager.default.contentsOfDirectory(atPath: (unc("logs") ?? "").replacingOccurrences(of: "\\", with: "/"))) ?? []).sorted())"
              + "|normalizedRoots=\(LocalUsageReader.normalizedRoots([url]).map(\.path))"
              + "|accountRoots=\(ClaudeAccountRoots.roots(from: share).map(\.path))"
              + "|splitRoot=\(PlatformCompat.splitRoot(share))|resolvedFileURL=\(PlatformCompat.resolvedFileURL(url).path)"
              + "|standardizedDirectoryURL=\(PlatformCompat.standardizedDirectoryURL(share).path)")
        // What swift-foundation itself makes of a share (the reason for the seams): kept as a record, not as a rule.
        XCTAssertEqual(url.path, slashed)
    }

    /// How swift-foundation lists a share's files, spelling by spelling (a record for the defect log; asserts nothing).
    func testHowAShareIsEnumerated() throws {
        let share = try require(unc("plain"), "administrative share")
        try Data("{}\n".utf8).write(to: root.appendingPathComponent("plain/a.jsonl"))
        let fm = FileManager.default
        let device = "\\\\?\\UNC\\" + share.dropFirst(2)
        var forms: [(String, URL)] = [("local", URL(fileURLWithPath: native("plain"))), ("unc", URL(fileURLWithPath: share)),
                                      ("unc-dir", URL(fileURLWithPath: share, isDirectory: true)),
                                      ("slashes", URL(fileURLWithPath: share.replacingOccurrences(of: "\\", with: "/"))),
                                      ("device", URL(fileURLWithPath: device))]
        let rest = share.dropFirst(2).split(separator: "\\", maxSplits: 1).map(String.init)   // ["localhost", "C$\\…\\plain"]
        if rest.count == 2, let hosted = URL(string: "file://\(rest[0])/" + rest[1].replacingOccurrences(of: "\\", with: "/")
                                                  .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!) {
            forms.append(("host-url", hosted))
        }
        if let mapped = mappedDrive("plain") { forms.append(("mapped", URL(fileURLWithPath: mapped))) }
        for (name, url) in forms {
            let path = url.path
            var withKeys: [String] = [], plain: [String] = []
            if let en = fm.enumerator(at: url, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles]) {
                for case let u as URL in en { withKeys.append(u.path) }
            }
            if let en = fm.enumerator(at: url, includingPropertiesForKeys: nil) { for case let u as URL in en { plain.append(u.path) } }
            let byPath = (fm.enumerator(atPath: path)?.allObjects as? [String]) ?? []
            let child = URL(fileURLWithPath: "a.jsonl", relativeTo: url)
            let listed = ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []).map(\.path)
            let file = url.appendingPathComponent("a.jsonl")
            let date: String
            do { date = "\(try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate.map { "\($0)" } ?? "nil")" }
            catch { date = "error \(error)" }
            print("ENUM-PROBE|\(name)|absolute=\(url.absoluteString)|URL.path=\(path)|exists=\(fm.fileExists(atPath: url.path))|enumerator(at:keys)=\(withKeys)"
                  + "|enumerator(at:)=\(plain)|enumerator(atPath:)=\(byPath)|contents(at:)=\(listed)|file.mtime=\(date)"
                  + "|jsonlFiles=\(LocalUsageReader.jsonlFiles(in: url, modifiedSince: .distantPast).map(\.path))"
                  + "|resolved=\(PlatformCompat.resolvedFileURL(url).path)|relativeChild=\(child.path) exists=\(fm.fileExists(atPath: child.path))"
                  + "|appended=\(url.appendingPathComponent("a.jsonl").path)")
        }
    }

    /// The P19 trigger: a UNC folder in the custom scan folders is found (it used to be looked up as `\server\share\…` on the
    /// current drive and count 0).
    func testAUNCScanFolderIsFound() throws {
        let share = try require(unc("plain"), "administrative share"), logs = try require(unc("logs"), "administrative share")
        let found = CustomScanRoots.expand(share)
        XCTAssertEqual(found.count, 1, "\(share) -> \(found.map(\.path))")
        XCTAssertEqual(found.first.map { FileManager.default.fileExists(atPath: $0.path) }, true)
        XCTAssertEqual(CustomScanRoots.survivingExtraCount(defaults: [], extraRaw: share), 1)
        XCTAssertEqual(CustomScanRoots.expand(logs + "\\proj-*").count, 2, "a wildcard under a share")
        XCTAssertEqual(CustomScanRoots.survivingExtraCount(defaults: [], extraRaw: logs + "\\proj-*"), 2)
        XCTAssertEqual(CustomScanRoots.expand(share.replacingOccurrences(of: "\\", with: "/")).count, 1, "//server/share with slashes")
        // What the scan then reads: the folded roots are the share's folders, and they exist (not `UNC\…` under the current folder).
        let roots = CustomScanRoots.union(defaults: [], extraRaw: share + "\n" + logs + "\\proj-*")
        XCTAssertEqual(roots.count, 3, "\(roots.map(\.path))")
        XCTAssertTrue(roots.allSatisfy { $0.path.hasPrefix("//localhost/") && FileManager.default.fileExists(atPath: $0.path) }, "\(roots.map(\.path))")
        XCTAssertEqual(LocalUsageReader.normalizedRoots([URL(fileURLWithPath: share), URL(fileURLWithPath: share + "\\")]).count, 1, "one share written twice")
        // The symptom itself: a log file in the shared folder is found by the scan through the folded root (swift-foundation's
        // URL-based listing returns nothing under a share; `PlatformCompat.enumerator` walks it with the String-based one).
        try Data("{}\n".utf8).write(to: root.appendingPathComponent("plain/a.jsonl"))
        let plain = try XCTUnwrap(CustomScanRoots.union(defaults: [], extraRaw: share).first)
        XCTAssertEqual(LocalUsageReader.jsonlFiles(in: plain, modifiedSince: Date(timeIntervalSinceNow: -3600)).map(\.lastPathComponent), ["a.jsonl"],
                       "through \(plain.path)")
    }

    /// The share walk yields what Foundation's enumerator yields for the same folder on the local disk (dot-names aside: the
    /// share walk skips them as the Mac does), in the same order rules: a folder's contents right after it, `level` from 1,
    /// `skipDescendants()` closing the folder just returned.
    func testAShareIsWalkedAsALocalFolderIs() throws {
        let share = try require(unc("plain"), "administrative share")
        let fm = FileManager.default
        for rel in ["a.jsonl", "sub/b.jsonl", "sub/deep/c.jsonl", "z/d.jsonl", ".hidden/x.jsonl", ".dot.jsonl"] {
            let url = root.appendingPathComponent("plain/" + rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{}\n".utf8).write(to: url)
        }
        func walk(_ url: URL, skipping: String? = nil) -> [String] {
            guard let en = PlatformCompat.enumerator(fm, at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return ["nil"] }
            let base = url.path.count + 1
            var out: [String] = []
            for case let u as URL in en {
                let rel = String(u.path.dropFirst(base))
                out.append("\(en.level):\(rel)")
                if rel == skipping { en.skipDescendants() }
            }
            return out
        }
        let shared = walk(URL(fileURLWithPath: share)), local = walk(URL(fileURLWithPath: native("plain")))
        print("WALK-PROBE|share=\(shared)|local=\(local)")
        XCTAssertEqual(shared, ["1:a.jsonl", "1:sub", "2:sub/b.jsonl", "2:sub/deep", "3:sub/deep/c.jsonl", "1:z", "2:z/d.jsonl"])
        XCTAssertEqual(Set(shared), Set(local.filter { !$0.contains("/.") && !$0.contains(":.") }), "the local walk of the same folder")
        XCTAssertEqual(walk(URL(fileURLWithPath: share), skipping: "sub"), ["1:a.jsonl", "1:sub", "1:z", "2:z/d.jsonl"])
        XCTAssertEqual(walk(URL(fileURLWithPath: share + "\\missing")), [])
        // The other listing seam, and the callers that walk a root: the Codex rollouts, Aside's databases one folder down.
        XCTAssertEqual(try PlatformCompat.contentsOfDirectory(fm, at: URL(fileURLWithPath: share), includingPropertiesForKeys: nil).map(\.lastPathComponent),
                       [".dot.jsonl", ".hidden", "a.jsonl", "sub", "z"])
        XCTAssertEqual(LocalUsageReader.codexRolloutFiles(in: URL(fileURLWithPath: share)).count, 4)
        try Data("fixture".utf8).write(to: root.appendingPathComponent("plain/z/state.db"))
        XCTAssertEqual(LocalAsideUsageReader.databases(roots: [URL(fileURLWithPath: share)]).map(\.lastPathComponent), ["state.db"])
    }

    /// A mapped network drive (`net use X: \\server\share`): Windows resolves it to `\\?\UNC\server\share\…`, which swift-foundation
    /// turned into `UNC/server/share/…` relative to the current folder: the folded root did not exist and the scan found nothing,
    /// while Settings still counted the folder (review of Task 14, Important 1). Kept as `X:\…` (a share spelling lists nothing).
    func testAMappedDriveFolderIsScanned() throws {
        let drive = try require(mappedDrive("plain"), "mapped network drive")
        print("PATH-PROBE|mapped=\(drive)|resolvedFileURL=\(PlatformCompat.resolvedFileURL(URL(fileURLWithPath: drive)).path)"
              + "|foundation=\(URL(fileURLWithPath: drive).resolvingSymlinksInPath().path)")
        try Data("{}\n".utf8).write(to: root.appendingPathComponent("plain/a.jsonl"))
        try Data("fixture".utf8).write(to: root.appendingPathComponent("plain/state.db"))
        let roots = CustomScanRoots.union(defaults: [], extraRaw: drive)
        XCTAssertEqual(roots.count, 1, "\(roots.map(\.path))")
        let folded = try XCTUnwrap(roots.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folded.path), "the folded root \(folded.path) does not exist")
        XCTAssertEqual(LocalUsageReader.jsonlFiles(in: folded, modifiedSince: Date(timeIntervalSinceNow: -3600)).map(\.lastPathComponent), ["a.jsonl"])
        XCTAssertEqual(CustomScanRoots.survivingExtraCount(defaults: [], extraRaw: drive), 1)
        XCTAssertTrue(folded.path.lowercased().hasPrefix(String(drive.prefix(2)).lowercased() + "/"), "kept as the drive: \(folded.path)")
        // An additional Claude folder there, and Aside's database there.
        let account = ClaudeAccountRoots.roots(from: drive)
        XCTAssertEqual(account.count, 1)
        XCTAssertEqual(LocalUsageReader.normalizedRoots(account).map { FileManager.default.fileExists(atPath: $0.path) }, [true])
        let db = LocalAsideUsageReader.databases(roots: [URL(fileURLWithPath: drive)])
        XCTAssertEqual(db.map { FileManager.default.fileExists(atPath: $0.path) }, [true], "\(db.map(\.path))")
    }

    /// A link to a share (a directory symbolic link `…\to-share` → `\\localhost\C$\…\plain`) is scanned through the link.
    func testALinkToAShareIsFollowed() throws {
        let share = try require(unc("plain"), "administrative share")
        let link = root.appendingPathComponent("to-share")
        do { try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: share) } catch {
            throw XCTSkip("no symbolic link privilege: \(error)")
        }
        try Data("{}\n".utf8).write(to: root.appendingPathComponent("plain/a.jsonl"))
        let folded = try XCTUnwrap(CustomScanRoots.union(defaults: [], extraRaw: WinPath.native(link)).first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folded.path), folded.path)
        XCTAssertEqual(LocalUsageReader.jsonlFiles(in: folded, modifiedSince: Date(timeIntervalSinceNow: -3600)).map(\.lastPathComponent), ["a.jsonl"])
    }

    /// A drive root as a custom folder is an ancestor of the defaults on that drive: dropped, as the Mac drops `/` (#162-B: an
    /// ancestor root would fold the hidden defaults away or scan them twice).
    func testADriveRootNeverEvictsTheDefaults() throws {
        let drive = String(native().prefix(2))
        let defaults = [root.appendingPathComponent("logs/proj-a")]
        print("PATH-PROBE|driveRoot|URL.path=\(URL(fileURLWithPath: drive + "/").path)|resolved=\(PlatformCompat.resolvedFileURL(URL(fileURLWithPath: drive + "\\")).path)"
              + "|expand=\(CustomScanRoots.expand(drive + "\\").map(\.path))|union=\(CustomScanRoots.union(defaults: defaults, extraRaw: drive + "\\").map(\.path))")
        XCTAssertEqual(CustomScanRoots.survivingExtraCount(defaults: defaults, extraRaw: drive + "\\"), 0)
        XCTAssertEqual(CustomScanRoots.survivingExtraCount(defaults: defaults, extraRaw: drive + "/"), 0)
        XCTAssertEqual(CustomScanRoots.union(defaults: defaults, extraRaw: drive + "\\").map(\.path), LocalUsageReader.normalizedRoots(defaults).map(\.path))
    }

    /// A custom scan folder on a share for a provider whose reader resolves its database path (Aside's `state.db`).
    func testAProviderDatabaseOnAShareIsFound() throws {
        let share = try require(unc("plain"), "administrative share")
        try Data("fixture".utf8).write(to: root.appendingPathComponent("plain/state.db"))
        let found = LocalAsideUsageReader.databases(roots: [URL(fileURLWithPath: share)])
        XCTAssertEqual(found.count, 1, "\(found.map(\.path))")
        XCTAssertEqual(found.first.map { FileManager.default.fileExists(atPath: $0.path) }, true)
    }

    func testTheWindowsPathFormsAreFound() throws {
        let forms = [native("with space"), native("한글 폴더"), native("plain") + "\\", native("plain").replacingOccurrences(of: "\\", with: "/"),
                     native("logs") + "/proj-a", native("logs") + "\\proj-*"]
        let found = CustomScanRoots.expand(forms.joined(separator: "\n"))
        XCTAssertEqual(found.count, 7, "\(found.map(\.path))")
        // The same folder written three ways counts once, the wildcard's two folders once each: with space, 한글, plain, a, b.
        XCTAssertEqual(CustomScanRoots.survivingExtraCount(defaults: [], extraRaw: forms.joined(separator: ",")), 5)
        let drive = String(native().prefix(2)) + "\\"
        XCTAssertEqual(CustomScanRoots.expand(drive).count, 1, "the drive root \(drive)")
        XCTAssertEqual(CustomScanRoots.expand(native("missing") + "\n" + native("missing") + "\\*").count, 0)
    }

    func testAdditionalClaudeFoldersTakeTheSameForms() throws {
        let local = ClaudeAccountRoots.roots(from: [native("with space"), native("한글 폴더") + "\\", native("plain").replacingOccurrences(of: "\\", with: "/")]
            .joined(separator: "\n"))
        XCTAssertEqual(local.count, 3, "\(local.map(\.path))")
        let share = try require(unc("plain"), "administrative share")
        let shared = ClaudeAccountRoots.roots(from: share)
        XCTAssertEqual(shared.count, 1, "\(share) -> \(shared.map(\.path))")
        XCTAssertEqual(shared.first.map { FileManager.default.fileExists(atPath: $0.path) }, true)
    }
}
#endif
