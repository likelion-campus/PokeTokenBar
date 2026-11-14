// P12: does `SHGetKnownFolderPath` import from WinSDK and link? Compile + link is the test; nothing is called.
import WinSDK

let f = SHGetKnownFolderPath
let id = FOLDERID_LocalAppData
withExtendedLifetime((f, id)) {}
// Forces a real symbol reference the optimizer cannot drop (never true at runtime).
if CommandLine.arguments.count > 1000 {
    var k = FOLDERID_LocalAppData
    _ = SHGetKnownFolderPath(&k, 0, nil, nil)
}
print("cov SHGetKnownFolderPath linked")
