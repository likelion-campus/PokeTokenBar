#if os(Windows)
import CWinShim
import WinSDK
import XCTest
@testable import PokeTokenBar

/// Stage 7 Task 15 on Windows: the shim's argument checks and the file behaviour the export and import rely on. The dialogs
/// themselves are opened and driven by the selftest on the runner (a unit test has nobody to answer them).
final class WindowsPopoverDialogTests: XCTestCase {
    func testTheShimRefusesBadArgumentsWithoutOpeningAnything() {
        var chosen: Int32 = 7
        var buttons: UnsafePointer<UInt16>?
        XCTAssertNotEqual(withUnsafePointer(to: &buttons) { ptb_task_dialog(nil, nil, nil, nil, 0, $0, 0, 0, &chosen) }, 0)
        var out = [UInt16](repeating: 1, count: 4)
        XCTAssertNotEqual(ptb_file_dialog(nil, 1, nil, nil, nil, nil, nil, nil, 0), 0)
        XCTAssertNotEqual(ptb_file_dialog(nil, 0, nil, nil, nil, nil, nil, &out, 1), 0)
        XCTAssertNotEqual(ptb_acc_set_value(nil, nil), 0)
        XCTAssertEqual(ptb_file_dialog_close(), 0, "no dialog is open")
        XCTAssertNil(ptb_task_dialog_window())
    }

    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb dialog 한글 \(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A destination that is a read-only file: the write fails, the file keeps its content and no temporary file stays behind.
    func testAWriteOverAReadOnlyFileFailsAndLeavesNothingHalfWritten() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("save – 파일.json")
        try Data("KEEP".utf8).write(to: file)
        _ = WinPath.native(file).withCString(encodedAs: UTF16.self) { SetFileAttributesW($0, DWORD(FILE_ATTRIBUTE_READONLY)) }
        defer { _ = WinPath.native(file).withCString(encodedAs: UTF16.self) { SetFileAttributesW($0, DWORD(FILE_ATTRIBUTE_NORMAL)) } }
        XCTAssertThrowsError(try PlatformCompat.atomicWrite(Data("NEW".utf8), to: file))
        XCTAssertEqual(try Data(contentsOf: file), Data("KEEP".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 1, "no temporary file left")
    }

    /// A save in a folder with a space and Korean characters reads back through the import's own reader.
    func testASaveInANonAsciiFolderReadsBack() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("my save – 백업.json")
        try PlatformCompat.atomicWrite(try SaveTransfer.encode(state: CompanionState(), appVersion: "1", deviceName: "PC", now: Date()), to: file)
        XCTAssertEqual(try SaveImportTool.readSave(at: file).sourceDevice, "PC")
    }
}
#endif
