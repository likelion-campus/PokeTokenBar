// P12: does `SHGetKnownFolderPath` import from WinSDK and link? Compile + link is the test; nothing is called.
import WinSDK

let f = SHGetKnownFolderPath
let id = FOLDERID_LocalAppData
withExtendedLifetime((f, id)) {}
print("cov SHGetKnownFolderPath linked")
