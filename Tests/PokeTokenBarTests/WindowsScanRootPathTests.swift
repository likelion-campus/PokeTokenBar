#if os(Windows)
import Foundation
import WinSDK
import XCTest
@testable import PokeTokenBar

/// The path forms a Windows user types into Settings → Advanced (custom scan folders, additional Claude folders), through the
/// real file system: spaces, non-ASCII, trailing and mixed separators, a drive root, a UNC share (P19, stage 7 Task 14). The
/// share is this PC's own administrative share of the fixture folder (`\\localhost\C$\…`); without one (a PC with it turned
/// off) those tests are skipped.
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
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
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
        guard let share = unc("plain") else { throw XCTSkip("no administrative share on this PC") }
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

    /// The P19 trigger: a UNC folder in the custom scan folders is found (it used to be looked up as `\server\share\…` on the
    /// current drive and count 0).
    func testAUNCScanFolderIsFound() throws {
        guard let share = unc("plain"), let logs = unc("logs") else { throw XCTSkip("no administrative share on this PC") }
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
    }

    /// A custom scan folder on a share for a provider whose reader resolves its database path (Aside's `state.db`).
    func testAProviderDatabaseOnAShareIsFound() throws {
        guard let share = unc("plain") else { throw XCTSkip("no administrative share on this PC") }
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
        guard let share = unc("plain") else { throw XCTSkip("no administrative share on this PC") }
        let shared = ClaudeAccountRoots.roots(from: share)
        XCTAssertEqual(shared.count, 1, "\(share) -> \(shared.map(\.path))")
        XCTAssertEqual(shared.first.map { FileManager.default.fileExists(atPath: $0.path) }, true)
    }
}
#endif
