#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PokeTokenBar

/// Where Cursor, Grok and OpenCode Go keep the login their limits use, on both systems, with fake values only.
/// The user-name folder is non-ASCII on purpose: a path that round-trips through the Windows wide APIs must still open.
@MainActor
final class OtherProviderLimitsLocationTests: XCTestCase {
    private var directory: URL!
    private var home: URL { directory.appendingPathComponent("사용자-ユーザー", isDirectory: true) }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ptb-other-limits-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for attempt in 0..<5 {
            do { try FileManager.default.removeItem(at: directory); break }
            catch { if attempt == 4 { throw error }; Thread.sleep(forTimeInterval: 0.3) }
        }
    }

    // MARK: Roots

    func testCursorDefaultRootsAreTheElectronUserDataFolders() async {
        let roots = LocalAdditionalUsageReader.cursorRoots(customRootsValue: nil, home: home).map(\.path)
        #if os(Windows)
        let base = home.appendingPathComponent("AppData/Roaming")
        #else
        let base = home.appendingPathComponent("Library/Application Support")
        #endif
        XCTAssertEqual(roots, [base.appendingPathComponent("Cursor/User/globalStorage").path,
                               base.appendingPathComponent("Cursor Nightly/User/globalStorage").path])
    }

    func testOpenCodeDefaultRootIsTheXDGDataFolderUnderHome() async {
        // OpenCode keeps `~/.local/share/opencode` on every system, Windows included (xdg-basedir does not special-case it).
        let roots = LocalAdditionalUsageReader.openCodeRoots(customRootsValue: nil, home: home).map(\.path)
        XCTAssertEqual(roots, [home.appendingPathComponent(".local/share/opencode").path])
    }

    func testRoamingAppDataFollowsTheVariableOnlyForTheCurrentHome() async {
        let current = URL(fileURLWithPath: "/users/me")
        let other = URL(fileURLWithPath: "/users/other")
        let redirected = "/redirected/roaming"
        XCTAssertEqual(PlatformCompat.windowsRoamingAppData(home: current, appData: redirected, currentHome: current).path,
                       URL(fileURLWithPath: redirected).path)
        XCTAssertEqual(PlatformCompat.windowsRoamingAppData(home: other, appData: redirected, currentHome: current).path,
                       "/users/other/AppData/Roaming")
        for unset in [nil, "", "  "] as [String?] {
            XCTAssertEqual(PlatformCompat.windowsRoamingAppData(home: current, appData: unset, currentHome: current).path,
                           "/users/me/AppData/Roaming")
        }
    }

    func testTheMacRootsAreTheSameExpressions() async {
        #if !os(Windows)
        XCTAssertEqual(PlatformCompat.userApplicationSupport(home: home).path, home.path + "/Library/Application Support")
        #endif
    }

    // MARK: Cursor login (state.vscdb ItemTable)

    private func seedCursor(_ root: URL, access: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("state.vscdb").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT UNIQUE, value BLOB); "
            + "INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', '\(access)');", nil, nil, nil), SQLITE_OK)
    }

    func testCursorLoginIsReadFromANonASCIIUserFolder() async throws {
        let root = LocalAdditionalUsageReader.cursorRoots(customRootsValue: nil, home: home)[0]
        try seedCursor(root, access: "fake-access-token")
        XCTAssertEqual(LocalAdditionalUsageReader.cursorAuthAccessToken(
            roots: LocalAdditionalUsageReader.cursorRoots(customRootsValue: nil, home: home)), "fake-access-token")
    }

    func testCursorLoginMissingOrMalformedIsNil() async throws {
        let roots = LocalAdditionalUsageReader.cursorRoots(customRootsValue: nil, home: home)
        XCTAssertNil(LocalAdditionalUsageReader.cursorAuthAccessToken(roots: roots))
        try FileManager.default.createDirectory(at: roots[0], withIntermediateDirectories: true)
        try Data("this is not a database".utf8).write(to: roots[0].appendingPathComponent("state.vscdb"))
        XCTAssertNil(LocalAdditionalUsageReader.cursorAuthAccessToken(roots: roots))
    }

    // MARK: Grok login (auth.json)

    func testGrokLoginIsReadFromANonASCIIFolderAndAnExpiredOneIsStillSent() async throws {
        let grok = home.appendingPathComponent(".grok", isDirectory: true)
        try FileManager.default.createDirectory(at: grok, withIntermediateDirectories: true)
        let file = grok.appendingPathComponent("auth.json")
        try Data(#"{"https://auth.x.ai::a":{"key":"fake-expired","expires_at":"2020-01-01T00:00:00.000000Z"}}"#.utf8).write(to: file)
        // The app never judges expiry itself: the endpoint's 401 does (`grokLimitsAuthExpired`).
        XCTAssertEqual(GrokRateLimitsProvider.accessToken(authFile: file), "fake-expired")
    }

    func testGrokMalformedAuthFileIsNil() async throws {
        let file = directory.appendingPathComponent("auth.json")
        for text in ["", "not json", "[1,2]", #"{"a":"string"}"#, #"{"a":{"key":"  "}}"#] {
            try Data(text.utf8).write(to: file)
            XCTAssertNil(GrokRateLimitsProvider.accessToken(authFile: file), text)
        }
    }

    // MARK: OpenCode login (auth.json fallback and the credential table)

    func testOpenCodeKeyFromANonASCIIFolderAndMalformedFile() async throws {
        let root = LocalAdditionalUsageReader.openCodeRoots(customRootsValue: nil, home: home)[0]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("auth.json")
        try Data("{ broken".utf8).write(to: file)
        XCTAssertNil(LocalAdditionalUsageReader.openCodeAPIKey(integrationID: "opencode-go", roots: [root]))
        try Data(#"{"opencode-go":{"type":"api","key":"fake-key"}}"#.utf8).write(to: file)
        XCTAssertEqual(LocalAdditionalUsageReader.openCodeAPIKey(integrationID: "opencode-go", roots: [root]), "fake-key")
    }

    // MARK: Requests

    #if os(Windows)
    /// The providers' own sessions (ephemeral, no custom protocol) and their request shapes are taken by WinHTTP, not URLSession.
    func testTheLimitsRequestsGoThroughWinHTTP() async throws {
        let session = URLSession(configuration: .ephemeral)
        var post = URLRequest(url: CursorRateLimitsProvider.usageURL, timeoutInterval: 10)
        post.httpMethod = "POST"
        post.httpBody = Data("{}".utf8)
        let gets = [GrokRateLimitsProvider.usageURL, OpenCodeGoRateLimitsProvider.usageURL].map { URLRequest(url: $0) }
        XCTAssertTrue(WinHTTPFetch.handles(post, session: session))
        for request in gets { XCTAssertTrue(WinHTTPFetch.handles(request, session: session), request.url?.host ?? "") }
    }
    #endif
}
