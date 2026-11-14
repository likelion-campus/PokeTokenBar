// swift-tools-version: 6.0
// Throwaway (Track B experiment E1): which main loop lets @MainActor work, Timers and Win32 messages share the
// process main thread, plus Foundation-on-Windows facts. Never merged. Swift 6 language mode, like the app.
import PackageDescription

/// P12: one executable per WinSDK API, so each one's import and link result stands alone.
let coverage: [(api: String, libs: [String])] = [
    ("DnsServiceRegister", ["dnsapi"]),
    ("DnsServiceBrowse", ["dnsapi"]),
    ("NotifyNetworkConnectivityHintChange", ["iphlpapi"]),
    ("GetLastInputInfo", ["user32"]),
    ("Shell_NotifyIconW", ["shell32"]),
    ("CredReadW", ["advapi32"]),
    ("RegisterPowerSettingNotification", ["user32", "uuid"]),
    ("RegisterSuspendResumeNotification", ["user32"]),
    ("WSAPoll", ["ws2_32"]),
    ("MiniDumpWriteDump", ["dbghelp"]),
    ("SHGetKnownFolderPath", ["shell32", "ole32", "uuid"]),
]

let package = Package(
    name: "ptbe1",
    targets: [
        .target(
            name: "CE1Shim",
            path: "Sources/CE1Shim",
            linkerSettings: ["user32", "shell32", "psapi"].map { .linkedLibrary($0) }
        ),
        .executableTarget(name: "ptbe1", dependencies: ["CE1Shim"], path: "Sources/ptbe1"),
        .executableTarget(name: "ptbe1async", dependencies: ["CE1Shim"], path: "Sources/ptbe1async"),
    ] + coverage.map { item in
        .executableTarget(
            name: "cov_\(item.api)",
            path: "Sources/cov/\(item.api)",
            linkerSettings: item.libs.map { .linkedLibrary($0) }
        )
    }
)
