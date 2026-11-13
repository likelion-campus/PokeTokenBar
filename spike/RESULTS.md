# Windows port — stage 0 results

## Experiment 4: a Mac plaza layer behind a drawing interface — YES

- `PlazaPondLayer` no longer imports SpriteKit. It talks to `DrawFactory`/`DrawNode`/`DrawSprite`/`DrawTexture`
  (`SpikeDraw.swift`, 20 lines); the SpriteKit side is `SpikeDrawSpriteKit.swift` (about 40 lines).
- Offscreen `SKRenderer` render, 640x480, scripted splashes and bubbles, 3 timestamps x 3 conditions
  (plain water, a multiply tint above, a multiplyX2 tint above): 9/9 byte-identical before and after.
  Node-tree dumps (position, z, alpha, hidden, size, texture size, blend) identical 9/9.
- Cost: 6000 scripted frames of the layer, 5 runs. Median before 28.3 ms, after 28.6 ms (other runs of the
  unchanged code ranged 23–29 ms, so the difference is inside the noise).
- Existing tests: `swift test --filter Pond` 85 tests, 0 failures. No test file changed. Four test sites read
  `layer.children`; a 3-line SpriteKit-side extension kept them compiling. In stage 2 such tests should read a
  recording implementation instead.
- Rulings: the render used the layer in a bare `SKScene` rather than the full `PlazaScene` at noon / night /
  snow, because those conditions are other layers above or below the pond nodes and do not change the pond's own
  nodes; blend interaction is covered by the two tint conditions. Textures still come from `CGImage`
  (`PlazaPondArt`); making images without CoreGraphics is experiment 3's subject.
- Not learned here: the cost of a layer with many more nodes per frame (`PlazaScene`, `PlazaActor`).

## Experiment 1: does the shared logic compile and test on Windows — YES for the toolchain, with a real finding about the code

Toolchain
- `windows-latest` (Windows Server 2025, VS 2026) + Swift 6.3.2: builds and runs XCTest.
- `windows-2022` + Swift 6.1.2: also builds.
- `windows-latest` + Swift 6.1.2 does NOT build swift-crypto: the VS 2026 STL requires Clang 20+, and Swift 6.1.2
  ships Clang 19 (`error STL1000`). CI must pin a matching pair. Use `windows-latest` + Swift 6.3.x.
- swift-crypto (`import Crypto`) is a drop-in for `CryptoKit` here.

What compiled
- The largest set of `Core`/`Team` files that builds with portable imports only and needs nothing from a Mac-only
  file: 18 files, 1,444 lines, plus 14 test files (82 tests). It builds on Windows. 82 tests run: 16 fail on
  Windows, 13 of the same fail on the Mac in this cut-down package (they scan the repo layout, which the spike
  flattens). One failure is Windows-only: `BinaryLocatorTests.testAugmentedEnvironmentPrependsToolPaths`
  (PATH uses `;` and drive letters on Windows).
- That set is small because the code is not layered, not because Windows rejects it. 83 files (16,720 lines)
  import nothing Apple-only and use no CoreGraphics drawing, but most of them reference a type that lives in a
  Mac-only file. The seam is 20 symbols in about 12 files:
  `LimitsError`, `AccountIdentity`, `ClaudeLimitsProviding`, `OAuthLimitsProvider`, `OAuthCredentialData`
  (`Core/OAuthLimitsProvider.swift`, imports Security), `CustomScanRoots` (Darwin), `CompanionStore`
  (UserNotifications), `LocalAdditionalUsageReader` and `LocalAntigravityUsageCache` (SQLite3), `UsageStore`
  (AppKit), `TeamTransporting` (declared in `TeamTransport.swift`, which imports Network), `TeamNotifier`,
  `TeamFocusTally` (UserNotifications), `PlazaWeather`, `PlazaNameColor`, `PlazaChatLog`, `PlazaWindowController`,
  `PokemonNameDisplayStore`, `CGEventType`, `CGEventSource`.
  Stage 1 has to cut these: move the protocol or value type out of the file that imports the Apple framework.

Windows-only API gaps found by compiling the 83-file set on Windows (beyond the missing symbols above)
- `URLSession`, `URLRequest`, `HTTPURLResponse`: need `import FoundationNetworking` (mechanical).
- `kill` / `SIGKILL` (`ProcessRunner`): replace with `TerminateProcess` behind a shim.
- `NSData.compressed(using: .zlib)` / `decompressed`: not in Foundation on Windows. Needs a zlib dependency.
- `ProcessInfo.beginActivity` / `endActivity`: not available; make it a no-op or use `SetThreadExecutionState`.
- `NSString.abbreviatingWithTildeInPath`: not available; small helper.
- Files with these gaps also show follow-on type-check errors; the full list will only be final once the seam is cut.
- CRLF: Windows checkouts convert text files. Any script that reads a list file must strip `\r`, or the repo needs
  `.gitattributes`.

Not learned: whether the 15k lines behind the seam hide more gaps. Stage 1 will tell, file by file.

## Experiment 2: Mac <-> Windows discovery and TLS-PSK — YES on CI and on this Mac; the real-PC run is still open

- `spike/probe/ptbprobe.c` (about 230 lines of C): DNS-SD through the built-in `windns` API
  (`DnsServiceRegister` / `DnsServiceBrowse` / `DnsServiceResolve`), Winsock TCP, TLS 1.2 PSK through OpenSSL 3.6
  linked statically (vcpkg `openssl:x64-windows-static`). The exe is 5.3 MB and needs nothing installed.
- On the Windows runner (build 26100): advertise -> browse found it -> resolve -> TCP -> `TLSv1.2
  PSK-AES128-GCM-SHA256` -> one line each way. Key derivation matches the Mac (`CITEST` -> SHA-256 prefix
  `b5ba566299247fc1` on both).
- On this Mac: `openssl s_client` (OpenSSL 3.6, same PSK, identity `ptb-team-v1`) against
  `scripts/team-probe.swift serve` (Network.framework): handshake OK and the line arrived. So the TLS stack the
  Windows probe uses is wire-compatible with the Mac side.
- Ruling: skipped Schannel and went straight to a linked TLS library. Microsoft's docs say no PSK suite is enabled
  by default, which points at a policy change (admin) — a stated failure condition — and the SSPI handshake code
  is several times larger. Cost if wrong: about 5 MB of exe and an Apache-2.0 dependency that Schannel might have
  avoided.
- Ruling: the probe is plain C, not Swift. The question was the protocol, and Swift <-> C on Windows is covered by
  experiment 3.
- Side effect to know: while the Mac probe advertised `_ptbteam._tcp` for about 90 s, seven other machines on the
  office network (teammates' apps) dialled it and were refused (`bad MAC`, different key). Nothing was sent to
  them. The user guide warns about these lines.
- STILL OPEN (needs the user's PC): runs A, B, C in `README-ko` — discovery across two real machines on the office
  Wi-Fi, a standard (non-admin) account, the firewall prompt, and any security software. The CI runner is an
  administrator on one machine, so it cannot answer those.

## Experiment 3: Direct2D from Swift, headless — YES

- Swift 6.3.2 `executableTarget` + a C++ shim target (`CD2D`, about 200 lines) with a plain C header. Swift calls it
  directly; SwiftPM builds the C++ with no extra tooling. `ptbdraw.exe` is 0.6 MB (plus the Swift runtime DLLs).
- Pipeline: D3D11 device (WARP on CI) -> Direct2D device context -> offscreen bitmap -> WIC PNG.
- The CI render (`draw-png` artifact) shows: tiles from `plaza-tiles.png` at 3x, crisp; `Galmuri11.ttf` loaded from
  a file into a private font collection (not installed), Hangul and Latin, aliased, at 12 and 24 px; a name plate in
  Pretendard Bold from a file; colour emoji through Segoe UI Emoji; a multiply tint over half the scene through the
  Direct2D Blend effect.
- So headless PNGs from a Windows runner are usable for PR images and for checks from a Mac session.
- Ruling: no window. `--hardware` renders the same pipeline on the GPU offscreen instead; presenting to a swap
  chain is routine and was left out. Cost if wrong: a presentation problem shows up in stage 6.
- Not covered: `multiplyX2`, rotation, crop nodes, GIF decoding, text measurement, performance.
- STILL OPEN (needs the user's PC): the same render on a real GPU, to compare with the WARP image.

### Experiment 2, real-PC run (2026-11-13, office Wi-Fi) — YES for A and B

- Windows PC `DESKTOP-75RFFUC` (10.10.162.115) and this Mac (10.10.162.132), same Wi-Fi.
- Run A (Windows serves, Mac browses): the Mac found `probe-win-412f._ptbteam._tcp.local.`, connected,
  `TLS-PSK handshake OK`, sent a ping and received the pong.
- Run B (Mac serves, Windows browses): the Mac logged incoming connections from 10.10.162.115,
  `TLS-PSK handshake OK`, and `got: ping DESKTOP-75RFFUC …`. So Windows discovered the Mac service by DNS-SD,
  resolved it and connected, both IPv4.
- Noise as predicted: the Mac probe refused 9 dials from teammates' apps (`bad MAC`).
- Still to hear from the user: Windows version, whether the account was a standard one, whether the firewall
  prompt appeared and asked for an admin password, run C (the real app's service is visible), and the `out.png`
  from `ptbdraw --hardware`.
- User's answers: Windows 11, a standard (non-admin) account. The firewall prompt appeared on run A. Whether it
  asked for an admin password was not answered; run A's inbound connection did succeed. `ptbdraw --hardware`
  saved `out.png`, and by eye it is the same picture as the WARP render (no pixel diff was made; the file was not
  sent back). Run C (the real app's service is visible) was effectively covered by run A's Mac log and by the
  Windows browse reaching the Mac; the Windows-side FOUND lines for teammates' apps were not sent back.
- Follow-up from the user: they are not sure the dialog was the firewall prompt (one alert appeared and went away on
  OK). `netsh advfirewall firewall show rule name=all | findstr /i ptbprobe` on that PC printed a line, so Windows
  did create a firewall rule for the probe from a standard account, with no admin password. The rule's action
  (allow/block) and profile were not read; run A's inbound success implies it allows on that network.
  Stage 4 must still check this from a clean state with the real installer.
