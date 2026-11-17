#if os(Windows)
import Foundation
import WinSDK

/// What showing a popover page costs (field report 2026-11-17: Settings opened from Home stuttered for about five seconds on
/// a real PC before it stood). One trace runs per page the popover builds (an open, a swap, a DPI or appearance rebuild, the
/// page building itself again): it counts the page's builds, its layout and refresh passes, the windows made, and the paints
/// and erases of the popover's windows (those inside a build put a half-built page on screen), times the build and each named
/// step of it, and notes the last moment the page changed. It ends when the page goes or at the first event after `window`,
/// and writes one log line. No timer: it only reacts to the calls that feed it.
///
/// Names and numbers only: never a text of the page (a team code, a key, a folder).
@MainActor final class WinOpenTrace {
    struct Step: Equatable, Sendable {
        var name: String
        var ms: Double
    }

    struct Report: Equatable, Sendable {
        var page: String
        var via: String
        /// When the trace started (`WinPopover.milliseconds`; not in the line).
        var startedAt = 0.0
        /// Main-thread time inside builds, and from the start to the last change of the page (a build, a layout, a refresh, a
        /// window made, a paint of a pane or control: not a drawn view's own animation).
        var buildMs = 0.0, settledMs = 0.0
        var builds = 0, layouts = 0, refreshes = 0, windows = 0
        var paints = 0, erases = 0, paintsInBuild = 0, erasesInBuild = 0, drawnPaints = 0
        var steps: [Step] = []

        var slow: [Step] { steps.filter { $0.ms >= WinOpenTrace.slowMs } }

        var line: String {
            func ms(_ v: Double) -> String { String(Int(v.rounded())) }
            let parts = steps.map { "\($0.name) \(ms($0.ms))" }.joined(separator: ", ")
            let slowParts = slow.map { "\($0.name) \(ms($0.ms)) ms" }.joined(separator: ", ")
            return "popover page \(page) via \(via): build \(ms(buildMs)) ms in \(builds) build(s), settled \(ms(settledMs)) ms; "
                + "layouts \(layouts), refreshes \(refreshes), windows made \(windows); paints \(paints) (\(paintsInBuild) inside a build), "
                + "erases \(erases) (\(erasesInBuild) inside a build), drawn-view paints \(drawnPaints); steps (ms): \(parts.isEmpty ? "-" : parts); "
                + "slow (>= \(Int(WinOpenTrace.slowMs)) ms): \(slowParts.isEmpty ? "none" : slowParts)"
        }
    }

    enum Event { case layout, refresh, window, paint, erase, drawnPaint }

    /// How long after its start a trace keeps counting: the field report's five seconds, twice.
    nonisolated static let window = 10_000.0
    /// A step at least this long is named in the log line as slow (a frame and more of a blocked main thread).
    nonisolated static let slowMs = 20.0

    private(set) static var current: WinOpenTrace?
    /// The report of the trace that ended last (the selftest reads it).
    private(set) static var last: Report?
    /// Builds running now (nested: a page that builds a region inside its build).
    private(set) static var buildDepth = 0
    /// Lines written (the selftest reads it).
    private(set) static var linesWritten = 0

    private let owner: ObjectIdentifier
    private let start: Double
    private var lastActivity: Double
    private(set) var report: Report

    private init(page: AnyObject, via: String, now: Double) {
        owner = ObjectIdentifier(page)
        start = now
        lastActivity = now
        report = Report(page: Self.name(page), via: via, startedAt: now)
    }

    static func name(_ page: AnyObject) -> String {
        let full = String(describing: type(of: page))
        return full.hasPrefix("Win") ? String(full.dropFirst(3)) : full
    }

    static func now() -> Double { WinPopover.milliseconds() }

    /// A build of `page`: counted in the running trace for that page, else it starts one (`via` names why it is built).
    static func build(_ page: AnyObject, via: String, _ body: () -> Void) {
        let t0 = now()
        if let c = current, c.owner != ObjectIdentifier(page) || t0 - c.start > window { end() }
        if current == nil { current = WinOpenTrace(page: page, via: via, now: t0) }
        buildDepth += 1
        body()
        buildDepth -= 1
        let t1 = now()
        guard let c = current, c.owner == ObjectIdentifier(page) else { return }
        c.report.builds += 1
        c.report.buildMs += t1 - t0
        c.touch(t1)
    }

    /// A named part of a build, timed (a section of a page, a call that reads files or the registry).
    @discardableResult
    static func step<T>(_ name: String, _ body: () -> T) -> T {
        guard current != nil else { return body() }
        let t0 = now()
        let result = body()
        let t1 = now()
        if let c = current { c.report.steps.append(Step(name: name, ms: t1 - t0)) }
        return result
    }

    /// Times consecutive parts of a build without nesting them in closures: each `mark` records the time since the last one.
    @MainActor struct Lap {
        private var last: Double

        init() { last = WinOpenTrace.now() }

        mutating func mark(_ name: String) {
            let t = WinOpenTrace.now()
            if let c = WinOpenTrace.current { c.report.steps.append(Step(name: name, ms: t - last)) }
            last = t
        }
    }

    /// Something the page did or had done to it.
    static func note(_ event: Event) {
        guard let c = current else { return }
        let t = now()
        guard t - c.start <= window else {
            end()
            return
        }
        let inBuild = buildDepth > 0
        switch event {
        case .layout: c.report.layouts += 1
        case .refresh: c.report.refreshes += 1
        case .window: c.report.windows += 1
        case .paint:
            c.report.paints += 1
            if inBuild { c.report.paintsInBuild += 1 }
        case .erase:
            c.report.erases += 1
            if inBuild { c.report.erasesInBuild += 1 }
        case .drawnPaint:
            c.report.drawnPaints += 1
            return   // a drawn view's own animation is not the page changing
        }
        c.touch(t)
    }

    /// The running trace's report so far (the selftest reads it while the page is still up).
    static var running: Report? { current?.report }

    /// Ends the running trace (its page goes, or another page is built) and writes its line.
    static func end() {
        guard let c = current else { return }
        current = nil
        last = c.report
        linesWritten += 1
        AppLog.write(c.report.line)
    }

    private func touch(_ t: Double) {
        lastActivity = max(lastActivity, t)
        report.settledMs = lastActivity - start
    }
}
#endif
