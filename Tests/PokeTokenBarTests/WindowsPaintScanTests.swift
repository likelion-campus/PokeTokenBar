import XCTest

/// The Windows popover's shapes are drawn antialiased through `WinPaint` (visual polish K2). GDI's `RoundRect` is aliased and
/// `DrawFocusRect` is the dotted classic cue, so neither may come back anywhere in the Windows sources outside the painter's own
/// GDI fallback (`WinPaint.swift`). The painter itself is proven on the runner (`ui.kit.paint`, `ui.kit.focusRing`).
final class WindowsPaintScanTests: XCTestCase {
    private static let forbidden = ["RoundRect(", "DrawFocusRect("]
    private static let allowedFile = "Platform/Windows/Popover/WinPaint.swift"
    /// The painter's own GDI fallback, and the selftest that draws the classic calls as the negative control of its checks.
    private static let allowed: Set<String> = [allowedFile, "Platform/Windows/WindowsSelftestPopoverPaint.swift"]

    static func violations(in files: [URL], root: URL) throws -> [String] {
        var out: [String] = []
        for url in files {
            let rel = SharedSources.relativePath(url, root: root)
            guard rel.hasPrefix("Platform/Windows/"), !allowed.contains(rel) else { continue }
            for (i, line) in try SharedSources.lines(of: url).enumerated() {
                let code = line.components(separatedBy: "//").first ?? line
                for call in forbidden where code.contains(call) {
                    out.append("\(rel):\(i + 1) calls \(call.dropLast()): draw through WinPaint (antialiased rounded shapes, the Windows 11 focus ring)")
                }
            }
        }
        return out
    }

    func testNoAliasedShapeOrDottedFocusRectInTheWindowsSources() throws {
        let files = SharedSources.allSwiftFiles(root: SharedSources.sourcesRoot)
        XCTAssertTrue(files.contains { SharedSources.relativePath($0, root: SharedSources.sourcesRoot) == Self.allowedFile }, "the painter file moved: update the scan")
        XCTAssertEqual(try Self.violations(in: files, root: SharedSources.sourcesRoot), [])
    }

    func testTheScanCatchesTheClassicCalls() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-paint-scan-\(UUID().uuidString)")
        let windows = dir.appendingPathComponent("Platform/Windows/Popover")
        try FileManager.default.createDirectory(at: windows, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func scan(_ text: String, file: String = "Injected.swift") throws -> Int {
            let f = windows.appendingPathComponent(file)
            try text.write(to: f, atomically: true, encoding: .utf8)
            return try Self.violations(in: [f], root: dir).count
        }
        XCTAssertEqual(try scan("_ = RoundRect(dc, 0, 0, 10, 10, 4, 4)\n"), 1)
        XCTAssertEqual(try scan("_ = DrawFocusRect(d.hDC, &f)\n"), 1)
        XCTAssertEqual(try scan("// RoundRect( was the old way\nWinPaint.roundedRect(dc, r)\n"), 0)
        XCTAssertEqual(try scan("_ = RoundRect(dc, 0, 0, 10, 10, 4, 4)\n", file: "WinPaint.swift"), 0, "the painter's GDI fallback is the one allowed place")
    }
}
