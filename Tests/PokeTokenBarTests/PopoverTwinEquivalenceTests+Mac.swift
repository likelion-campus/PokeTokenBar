import XCTest
@testable import PokeTokenBar

/// Each shared twin of logic that stays in an upstream `UI/` file behaves as the original (stage 7, D8). Mac only: the
/// originals are Mac-only. The text side of the same promise is `PopoverParityScanTests.testTwinsMatchTheirOriginals`.
@MainActor
final class PopoverTwinEquivalenceTests: XCTestCase {
    /// A fixed generator so a failure replays.
    private struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private enum Action: CaseIterable {
        case reset, openSessionKeySettings, openDexEntry, openRepresentativeDex
        case setTab, setShowSettings, setShowingRecap, toggleCollectionLog, setCollectionLogSame
        case setProvider, setAccount, setExpandAdvanced, setDexDetail
    }

    private static let tabs: [(PopoverTab, PopoverState.Tab)] = [(.home, .home), (.shop, .shop), (.bag, .bag), (.collection, .collection)]

    private func fields(_ n: PopoverNavigation) -> [String] {
        [String(n.showSettings), "\(Self.tabs.firstIndex { $0.0 == n.tab }!)", String(n.showingCollectionLog), String(n.showingRecap),
         n.dexDetailCollectionID ?? "-", n.providerID ?? "-", n.claudeAccountID ?? "-", String(n.expandAdvancedOnOpen)]
    }

    private func fields(_ s: PopoverState) -> [String] {
        [String(s.showSettings), "\(Self.tabs.firstIndex { $0.1 == s.tab }!)", String(s.showingCollectionLog), String(s.showingRecap),
         s.dexDetailCollectionID ?? "-", s.providerID ?? "-", s.claudeAccountID ?? "-", String(s.expandAdvancedOnOpen)]
    }

    /// 200 random sequences of 1…40 actions (every route, every setter, every didSet path) leave both with equal fields
    /// after each step.
    func testPopoverStateFollowsPopoverNavigation() async {
        var rng = SplitMix(state: 0x5EED_0007)
        var steps = 0
        for sequence in 0..<200 {
            let mac = PopoverNavigation(), twin = PopoverState()
            for step in 0..<Int.random(in: 1...40, using: &rng) {
                let action = Action.allCases.randomElement(using: &rng)!
                let flag = Bool.random(using: &rng)
                let id = ["25", "133", "6-mega-x", nil].randomElement(using: &rng)!
                switch action {
                case .reset: mac.reset(); twin.reset()
                case .openSessionKeySettings: mac.openSessionKeySettings(); twin.openSessionKeySettings()
                case .openDexEntry: mac.openDexEntry(collectionID: id ?? "1"); twin.openDexEntry(collectionID: id ?? "1")
                case .openRepresentativeDex: mac.openRepresentativeDex(); twin.openRepresentativeDex()
                case .setTab:
                    let t = Self.tabs.randomElement(using: &rng)!
                    mac.tab = t.0; twin.tab = t.1
                case .setShowSettings: mac.showSettings = flag; twin.showSettings = flag
                case .setShowingRecap: mac.showingRecap = flag; twin.showingRecap = flag
                case .toggleCollectionLog: mac.showingCollectionLog.toggle(); twin.showingCollectionLog.toggle()
                case .setCollectionLogSame: mac.showingCollectionLog = mac.showingCollectionLog; twin.showingCollectionLog = twin.showingCollectionLog
                case .setProvider: mac.providerID = id; twin.providerID = id
                case .setAccount: mac.claudeAccountID = id; twin.claudeAccountID = id
                case .setExpandAdvanced: mac.expandAdvancedOnOpen = flag; twin.expandAdvancedOnOpen = flag
                case .setDexDetail: mac.dexDetailCollectionID = id; twin.dexDetailCollectionID = id
                }
                steps += 1
                XCTAssertEqual(fields(twin), fields(mac), "sequence \(sequence) step \(step) after \(action)")
                if fields(twin) != fields(mac) { return }
            }
        }
        XCTAssertGreaterThan(steps, 2_000)
    }

    /// The open-plaza action is a stored closure on both; it survives every route.
    func testTheOpenPlazaActionSurvivesTheRoutesOnBoth() async {
        let mac = PopoverNavigation(), twin = PopoverState()
        var calls = (mac: 0, twin: 0)
        mac.onOpenPlaza = { calls.mac += 1 }
        twin.onOpenPlaza = { calls.twin += 1 }
        mac.reset(); twin.reset()
        mac.openDexEntry(collectionID: "25"); twin.openDexEntry(collectionID: "25")
        mac.onOpenPlaza?(); twin.onOpenPlaza?()
        XCTAssertEqual(calls.mac, 1)
        XCTAssertEqual(calls.twin, 1)
    }
}
