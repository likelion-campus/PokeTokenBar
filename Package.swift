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
        dependencies: [
            .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        ],
        targets: [
            .target(
                name: "PokeTokenBar",
                dependencies: [.product(name: "Crypto", package: "swift-crypto")],
                path: "Sources/PokeTokenBar",
                exclude: macOnlyList("Sources/PokeTokenBar") + ["mac-only.txt", "Resources"]
            ),
            .testTarget(
                name: "PokeTokenBarTests",
                dependencies: ["PokeTokenBar"],
                path: "Tests/PokeTokenBarTests",
                exclude: macOnlyList("Tests/PokeTokenBarTests") + ["mac-only.txt", "shared-floor.txt", "Fixtures"]
            ),
        ]
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
