// P12: does `DnsServiceRegister` import from WinSDK and link? Compile + link is the test; nothing is called.
import WinSDK

let f = DnsServiceRegister
let c = DnsServiceDeRegister
let t = DNS_SERVICE_REGISTER_REQUEST.self
withExtendedLifetime((f, c, t)) {}
// Forces a real symbol reference the optimizer cannot drop (never true at runtime).
if CommandLine.arguments.count > 1000 {
    _ = DnsServiceRegister(nil, nil)
    _ = DnsServiceDeRegister(nil, nil)
}
print("cov DnsServiceRegister linked")
