// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Windows builds the shared set only: the same directory as a library, minus the paths in each mac-only.txt.
// PTB_SHARED_ONLY=1 makes the Mac take the same branch (scripts/shared-check.sh).
let sharedOnly = ProcessInfo.processInfo.environment["PTB_SHARED_ONLY"] == "1"
#if os(Windows)
let windowsBuild = true
#else
let windowsBuild = sharedOnly
#endif
// Real Windows only: the Windows-only targets (C shims, OpenSSL, the app executable) are never declared on the
// Mac, not even under PTB_SHARED_ONLY, so scripts/shared-check.sh never sees them.
#if os(Windows)
let onWindows = true
#else
let onWindows = false
#endif
// Static OpenSSL from vcpkg (x64-windows-static-md: static libs, dynamic CRT). CI sets PTB_OPENSSL_DIR.
let opensslDir = ProcessInfo.processInfo.environment["PTB_OPENSSL_DIR"] ?? "C:/vcpkg/installed/x64-windows-static-md"

/// Entries of a mac-only.txt next to the manifest-relative directory. Strips CR (Windows checkouts) and comments.
func macOnlyList(_ dir: String) -> [String] {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let list = root.appendingPathComponent(dir).appendingPathComponent("mac-only.txt")
    guard let text = try? String(contentsOf: list, encoding: .utf8) else { return [] }
    return text.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" })
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        .map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }  // SwiftPM matches directories without the slash
}

let package: Package
if windowsBuild {
    package = Package(
        name: "PokeTokenBar",
        platforms: [.macOS(.v14)],  // ignored on Windows; keeps the Mac pre-check on the same deployment target
        products: onWindows ? [.executable(name: "PokeTokenBarWin", targets: ["PokeTokenBarWin"])] : [],
        dependencies: [
            .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        ],
        targets: [
            .target(
                name: "CSQLite",  // vendored amalgamation; the Mac app links the system sqlite3 instead
                path: "Sources/CSQLite",
                exclude: ["LICENSE.md"],
                cSettings: [
                    .define("SQLITE_THREADSAFE", to: "1"),
                    .define("SQLITE_OMIT_LOAD_EXTENSION"),
                    .define("SQLITE_OMIT_DEPRECATED"),
                ]
            ),
            .target(
                name: "PokeTokenBar",
                dependencies: [.product(name: "Crypto", package: "swift-crypto"), "CSQLite"]
                    + (onWindows ? ["CWinShim", "CTeamTLS"] : []),
                path: "Sources/PokeTokenBar",
                exclude: macOnlyList("Sources/PokeTokenBar") + ["mac-only.txt", "Resources"],
                swiftSettings: [.define("PTB_SHARED_ONLY")],  // Platform.current takes the stubs in the shared build
                linkerSettings: onWindows ? [
                    .linkedLibrary("dnsapi"), .linkedLibrary("iphlpapi"), .linkedLibrary("user32"),
                    .linkedLibrary("shell32"), .linkedLibrary("advapi32"), .linkedLibrary("ws2_32"),
                    .linkedLibrary("dbghelp"),
                ] : []
            ),
            .testTarget(
                name: "PokeTokenBarTests",
                dependencies: ["PokeTokenBar"],
                path: "Tests/PokeTokenBarTests",
                exclude: macOnlyList("Tests/PokeTokenBarTests") + ["mac-only.txt", "shared-floor.txt", "Fixtures"]
            ),
        ] + (onWindows ? [
            .target(
                name: "CWinShim",  // Win32/WIC glue the Swift side cannot import; placeholder until the Windows services land
                path: "Sources/CWinShim",
                linkerSettings: [.linkedLibrary("windowscodecs"), .linkedLibrary("ole32"), .linkedLibrary("dbghelp")]
            ),
            .target(
                name: "CTeamTLS",  // OpenSSL (vcpkg, static) for the team link
                path: "Sources/CTeamTLS",
                cSettings: [.unsafeFlags(["-I\(opensslDir)/include"])],
                linkerSettings: [
                    .unsafeFlags(["-L\(opensslDir)/lib"]),
                    .linkedLibrary("libssl"), .linkedLibrary("libcrypto"), .linkedLibrary("crypt32"),
                    .linkedLibrary("ws2_32"), .linkedLibrary("advapi32"), .linkedLibrary("user32"),
                ]
            ),
            .executableTarget(
                name: "PokeTokenBarWin",
                dependencies: ["PokeTokenBar"],
                path: "Sources/PokeTokenBarWin",
                linkerSettings: [.unsafeFlags(["-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup"])]
            ),
        ] : []),
        cxxLanguageStandard: onWindows ? .cxx17 : nil  // the later WIC file in CWinShim
    )
} else {
    package = Package(
        name: "PokeTokenBar",
        platforms: [.macOS(.v14)],
        targets: [
            .executableTarget(
                name: "PokeTokenBar",
                path: "Sources/PokeTokenBar",
                exclude: ["mac-only.txt"],
                resources: [.copy("Resources/Plaza")],
                linkerSettings: [.linkedLibrary("sqlite3")]
            ),
            .testTarget(
                name: "PokeTokenBarTests",
                dependencies: ["PokeTokenBar"],
                path: "Tests/PokeTokenBarTests",
                exclude: ["mac-only.txt", "shared-floor.txt"],
                resources: [
                    .copy("Fixtures/CodexFork"),
                    .copy("Fixtures/CodexSubagent"),
                ]
            ),
        ]
    )
}
