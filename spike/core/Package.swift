// swift-tools-version: 6.0
// Throwaway: builds the Foundation-only part of the app on Windows. Sources are copied in by sync.sh.
import PackageDescription

let package = Package(
    name: "PTBShared",
    platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")],
    targets: [
        .target(name: "PokeTokenBar", dependencies: [.product(name: "Crypto", package: "swift-crypto")], path: "Sources/PokeTokenBar"),
        .testTarget(name: "PokeTokenBarTests", dependencies: ["PokeTokenBar"], path: "Tests/PokeTokenBarTests"),
    ]
)
