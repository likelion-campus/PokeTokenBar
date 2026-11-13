// swift-tools-version: 6.0
// Throwaway (spec §9 experiment 3): Swift drives Direct2D / DirectWrite / WIC through a small C++ shim.
import PackageDescription

let package = Package(
    name: "ptbdraw",
    targets: [
        .target(
            name: "CD2D",
            path: "Sources/CD2D",
            cxxSettings: [.unsafeFlags(["-std=c++17"])],
            linkerSettings: ["d2d1", "dwrite", "d3d11", "windowscodecs", "ole32", "dxguid"].map { .linkedLibrary($0) }
        ),
        .executableTarget(name: "ptbdraw", dependencies: ["CD2D"], path: "Sources/ptbdraw"),
    ]
)
