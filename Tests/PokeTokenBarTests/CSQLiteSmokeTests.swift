import XCTest
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

/// Opens an in-memory database through the same import guard the readers use: system SQLite3 on the Mac,
/// the vendored CSQLite on Windows.
final class CSQLiteSmokeTests: XCTestCase {
    func testSelectOne() {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT 1", -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(stmt, 0), 1)
    }
}
