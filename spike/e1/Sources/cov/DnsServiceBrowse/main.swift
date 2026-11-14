// P12: does `DnsServiceBrowse` import from WinSDK and link? Compile + link is the test; nothing is called.
import WinSDK

let f = DnsServiceBrowse
let r = DnsServiceResolve
let t = DNS_SERVICE_BROWSE_REQUEST.self
withExtendedLifetime((f, r, t)) {}
print("cov DnsServiceBrowse linked")
