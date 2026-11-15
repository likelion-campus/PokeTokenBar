---
summary: Why URLSession on Windows keeps two dispatch threads waking each other for a whole transfer on a new connection, with a minimal reproduction, measurements, the upstream source lines and our workaround. Ready to paste into an upstream issue if the user decides to file one.
read_when: Adding network code that runs on Windows, measuring idle cost on Windows, or deciding whether to report this upstream.
---

# URLSession on Windows: a busy loop for the whole transfer on every new connection

Not filed anywhere. Filing an upstream issue is the user's decision; this page is written so it can be pasted as one.

## Affected versions

- Swift toolchain 6.3.2 for Windows (x86_64): swift-corelibs-foundation `swift-6.3.2-RELEASE` (identical to `release/6.3` for the
  files below), swift-corelibs-libdispatch `swift-6.3.2-RELEASE`.
- libcurl 8.9.1 ("8.9.1-DEV", Schannel), linked statically into `FoundationNetworking.dll`.
- Measured on GitHub Actions `windows-latest` (Windows Server 2025, 4 vCPU). Not checked on Linux.

## Symptom

From the moment a URLSession task opens a new TCP connection until the transfer ends, two dispatch threads wake each other
27,000-50,000 times a second each and use about one CPU core between them. A response that takes 2 s to arrive costs about
170,000 context switches and 4 G cycles; one that takes 10 s, 840,000 and 21 G. A reused keep-alive connection is quiet.

| case (in-process loopback HTTP server, no network) | request | busy period | busiest thread cs (rate) | process cs | process cycles |
|---|---|---|---|---|---|
| new connection, answer at once | 2 ms | 21 ms | 23 | 56 | 16 M |
| new connection, answer after 2 s | 2004 ms | 2027 ms | 83,342 (41,104/s) | 166,675 | 4.13 G |
| new connection, answer after 10 s | 10004 ms | 10043 ms | 421,347 (41,951/s) | 842,621 | 20.8 G |
| new connection, body stalls; request timeout 10 s | 20013 ms (the timeout never fired; the server closed at 20 s) | 20019 ms | 855,484 (42,731/s) | 1,710,695 | 41.5 G |
| new connection, 8 MB at once | 14 ms | 47 ms | 487 | 1,035 | 62 M |
| new connection, `Connection: close`, 2 s | 2009 ms | 2030 ms | 86,314 | 172,656 | 4.18 G |
| reused connection (URLSession.shared), 2 s | 2005 ms | 0 | 19 | 48 | 6 M |
| WinHTTP (synchronous, own thread), 2 s / 10 s | 2003 / 10006 ms | 0 | 9 / 21 | 46 / 65 | 5 / 8 M |

The cost scales with how long the transfer waits, not with how much data it moves. Real hosts: a status page fetch on a new
connection (190 ms) cost 12,267 context switches; two of them in parallel, 18,811.

## Minimal reproduction

```swift
import Foundation
import FoundationNetworking

// Any HTTP server that answers after a delay; a new session forces a new connection.
let session = URLSession(configuration: .ephemeral)
var request = URLRequest(url: URL(string: "http://127.0.0.1:8080/delay/2000")!)
request.timeoutInterval = 30
let (data, _) = try await session.data(for: request)
// While this waits, watch the process's threads (Process Explorer / per-thread context switch counters): two dispatch
// threads ('com.apple.root.user-interactive-qos.overcommit' and a 'com.apple.root.default-qos.overcommit' worker) switch
// tens of thousands of times a second until the response arrives.
```

Stack samples of the hot thread during the wait: 138-147 of 150 in `ntdll!ZwRemoveIoCompletion <
KERNELBASE!GetQueuedCompletionStatus < dispatch.dll` (the event loop), 3-6 of 150 in `WS2_32!send < dispatch.dll` (curl has
nothing to send). The partner workers sit in `dispatch_semaphore_wait` and post back to the IOCP on a chain through
`FoundationNetworking.dll`.

## Cause (source lines at swift-6.3.2-RELEASE)

1. swift-corelibs-foundation `Sources/FoundationNetworking/URLSession/libcurl/MultiHandle.swift` watches curl's sockets with
   dispatch sources; on Windows `DispatchSource.makeReadSource/makeWriteSource(handle:)` (lines 527-549).
2. `register(socket:for:what:socketSourcePtr:)` (lines 110-140) only creates the sources that are missing when curl changes its
   interest (`createSources`, 581-602, each guarded by `readSource == nil` / `writeSource == nil`). Both sources are torn down only
   for `CURL_POLL_REMOVE` (125-131, `tearDown` 551-577). The write source created while curl connects (curl asks for
   `CURL_POLL_OUT`) therefore stays registered after curl asks for `CURL_POLL_IN` only.
3. swift-corelibs-libdispatch `src/event/event_windows.c`: read and write sources on one socket share one muxnote (line 100).
   `_dispatch_io_trigger` (455-505) emulates a level-triggered write source: it issues a zero-byte `send()` and, if that succeeds,
   posts "writable" to the I/O completion port at once (487-505). Every re-arm after a handler runs calls it again
   (`_dispatch_unote_resume_muxed`, 581-588).
4. A connected socket is always writable. So the write source fires, `performAction` calls
   `curl_multi_socket_action(socket, 0)` (MultiHandle 288-303), curl has nothing to write, the source re-arms, the zero-byte
   `send` succeeds, the source fires again, and so on between the event-loop thread (`GetQueuedCompletionStatus`,
   event_windows.c 898-948) and a root-queue worker, until curl removes the socket at the end of the transfer.
5. A reused connection never gets a write source (curl does not ask for write readiness to send a request on an open socket),
   which is why only new connections spin. libcurl reuses an idle connection only within 118 s (curl 8.9.1 `lib/url.c` 481
   `set->maxage_conn = 118`, `conn_maxage` 722-733; corelibs does not change it), so anything polled every two minutes or more
   connects afresh every time.

Two possible upstream fixes, either sufficient: in `MultiHandle.register`, cancel the write (or read) source when curl drops
that interest (treat `CURL_POLL_IN` after `CURL_POLL_INOUT` as "remove the write source"); or in libdispatch's Windows backend,
do not re-post write readiness on every re-arm of a socket that stayed writable.

A related finding, not traced: the request timeout (`URLRequest.timeoutInterval`, an idle `_TimeoutSource` re-created on every
data callback, `HTTPURLProtocol.swift` 412-435 and `EasyHandle.swift` 593-631) did not end a transfer whose body stalled; it
ran until the server closed the connection 20 s later.

## Our workaround

`PlatformCompat.oneShotData(for:session:)` and `oneShotData(from:)` (`Sources/PokeTokenBar/Platform/PlatformCompat.swift`): on
the Mac exactly the URLSession call the caller made before; on Windows a WinHTTP request on a thread of its own that blocks in
the kernel (`Platform/Windows/WinHTTPFetch.swift`), one session per fetch, closed with it. Every one-shot request of the app that
runs on Windows goes through it (`WindowsSeamScanTests.testNoRequestOutsideTheSeamInCodeThatRunsOnWindows`). The installed app's
idle gate went from 1,568-7,209 to 166-186 context switches a minute in a 300 s window with two store refreshes.

What the replacement had to match, or chose to do differently from corelibs (the comment on `WinHTTPFetch` has the details and
citations): redirects are followed by our code (`WINHTTP_OPTION_REDIRECT_POLICY_NEVER`) with the Mac's header rules, which
`RedirectHeadersMacTests` pins (the Mac's URLSession drops `Authorization` on every hop; corelibs keeps every header), and a
request with a `Cookie` does not follow a redirect to another origin; a server's NTLM/Negotiate challenge is never answered with
the Windows logon (`WINHTTP_DISABLE_AUTHENTICATION`, logon policy HIGH), only a proxy's 407; TLS 1.2 and 1.3 only; a total
deadline, which corelibs never had for a body that keeps trickling in.
