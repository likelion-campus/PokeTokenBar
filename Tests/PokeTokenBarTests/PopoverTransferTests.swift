import XCTest
@testable import PokeTokenBar

// Stage 7 Task 15: difficulty, backup and transfer in the popover. Shared (both systems): the draft and the slider mapping, and
// every Backup & transfer flow over scripted dialogs (no person to click on a runner).

private struct OfflineProvider: PokeProviding {
    struct Unavailable: Error {}
    func line(baseSpeciesID: Int) async throws -> EvoLine { throw Unavailable() }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { throw Unavailable() }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { throw Unavailable() }
}

/// Answers the flows' dialogs from a script and records what was asked.
@MainActor final class ScriptedTransferDialogs: TransferDialogs {
    var saveAnswer: URL?
    var openAnswer: URL?
    var confirmAnswer = false
    private(set) var asked: [String] = []
    private(set) var savedSuggestions: [String] = []
    private(set) var confirms: [(title: String, message: String, confirm: String, cancel: String)] = []
    private(set) var informs: [(title: String, message: String, isError: Bool)] = []
    private(set) var revealed: [URL] = []

    func chooseSaveFile(title: String, suggestedName: String) -> URL? {
        asked.append("save:\(title)")
        savedSuggestions.append(suggestedName)
        return saveAnswer
    }
    func chooseOpenFile(title: String) -> URL? { asked.append("open:\(title)"); return openAnswer }
    func confirm(title: String, message: String, confirmTitle: String, cancelTitle: String) -> Bool {
        asked.append("confirm")
        confirms.append((title, message, confirmTitle, cancelTitle))
        return confirmAnswer
    }
    func inform(title: String, message: String, isError: Bool) { asked.append("inform"); informs.append((title, message, isError)) }
    func reveal(_ file: URL) { revealed.append(file) }
}

@MainActor
final class PopoverDifficultyDraftTests: XCTestCase {
    private func companion(growth: Double? = nil, shop: Double? = nil, state: CompanionState = CompanionState()) throws -> CompanionStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-diff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("companion-state.json")
        try JSONEncoder().encode(state).write(to: file)
        let defaults = TestDefaults.make(suite: "ptb.popover.difficulty")
        if let growth { defaults.set(growth, forKey: "growthDifficulty") }
        if let shop { defaults.set(shop, forKey: "shopDifficulty") }
        return CompanionStore(provider: OfflineProvider(), fileURL: file, defaults: defaults)
    }

    func testTheDraftStartsAtTheStoreAndDiffersOnlyWhenEdited() async throws {
        let store = try companion(growth: 0.5, shop: 1.5)
        var draft = PopoverDifficultyDraft(companion: store)
        XCTAssertEqual(draft.growth, 0.5)
        XCTAssertEqual(draft.shop, 1.5)
        XCTAssertFalse(draft.differs(from: store))
        draft.growth = 0.7
        XCTAssertTrue(draft.differs(from: store))
        draft.growth = 0.5
        draft.shop = 1.6
        XCTAssertTrue(draft.differs(from: store), "either slider alone makes Save appear")
        draft.shop = 1.5
        XCTAssertFalse(draft.differs(from: store))
    }

    func testAnUnsavedDraftTouchesNothing() async throws {
        let store = try companion()
        var draft = PopoverDifficultyDraft(companion: store)
        draft.growth = 0.25
        draft.shop = 2
        XCTAssertEqual(store.growthDifficulty, 1)
        XCTAssertEqual(store.shopDifficulty, 1)
    }

    /// Save rescales the banked progress exactly as the store's setters do: the same state as calling them directly.
    func testSaveWritesBothAndRescalesTheProgressLikeTheStore() async throws {
        var egg = CompanionState()
        egg.eggUsage = 40_000_000
        let viaDraft = try companion(state: egg)
        let direct = try companion(state: egg)
        var draft = PopoverDifficultyDraft(companion: viaDraft)
        draft.growth = 0.5
        draft.shop = 1.2
        draft.save(to: viaDraft)
        direct.setGrowthDifficulty(0.5)
        direct.setShopDifficulty(1.2)
        XCTAssertEqual(viaDraft.growthDifficulty, 0.5)
        XCTAssertEqual(viaDraft.shopDifficulty, 1.2)
        XCTAssertEqual(viaDraft.state.eggUsage, direct.state.eggUsage)
        XCTAssertNotEqual(viaDraft.state.eggUsage, 40_000_000, "the banked egg progress was rescaled to the new threshold")
        XCTAssertEqual(draft, PopoverDifficultyDraft(companion: viaDraft), "after Save the draft is the store's value again")
        XCTAssertFalse(draft.differs(from: viaDraft))
    }

    func testTheSliderPositionsCoverTheMacsTrack() async throws {
        let r = PopoverDifficultySlider.range
        XCTAssertEqual(r.lowerBound, 0)
        XCTAssertEqual(PopoverDifficultySlider.value(atPosition: r.lowerBound), PokemonBalance.difficultyRange.lowerBound)
        XCTAssertEqual(PopoverDifficultySlider.value(atPosition: r.upperBound), PokemonBalance.difficultyRange.upperBound)
        // The default sits on the track and snaps to exactly 1.
        XCTAssertEqual(PopoverDifficultySlider.value(atPosition: PopoverDifficultySlider.position(of: 1)), 1)
        // Values rise along the track, each inside the allowed range.
        var previous = 0.0
        for p in r {
            let v = PopoverDifficultySlider.value(atPosition: p)
            XCTAssertTrue(PokemonBalance.difficultyRange.contains(v), "position \(p) -> \(v)")
            XCTAssertGreaterThanOrEqual(v, previous, "position \(p)")
            previous = v
        }
        // A value shows on the track where the Mac's slider would stand, and standing there sets the same value again (the value
        // is rounded to two digits, so several positions can share one at the low end of the log scale).
        for p in r {
            let value = PopoverDifficultySlider.value(atPosition: p)
            let back = PopoverDifficultySlider.position(of: value)
            XCTAssertEqual(PopoverDifficultySlider.value(atPosition: back), value, "position \(p) -> \(value) shows at \(back)")
        }
    }

    func testPositionMapsTheMacsSliderPosition() async throws {
        for p in stride(from: 0, through: PopoverDifficultySlider.resolution, by: 7) {
            let mac = PokemonBalance.difficulty(atPosition: Double(p) / Double(PopoverDifficultySlider.resolution))
            XCTAssertEqual(PopoverDifficultySlider.value(atPosition: p), mac)
        }
        for v in [0.1, 0.25, 0.5, 1, 1.5, 2] {
            XCTAssertEqual(PopoverDifficultySlider.position(of: v),
                           Int((PokemonBalance.difficultyPosition(v) * Double(PopoverDifficultySlider.resolution)).rounded()))
        }
    }
}

@MainActor
final class SaveTransferFlowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private var dir: URL!
    private var stateFile: URL { dir.appendingPathComponent("companion-state.json") }
    private var companion: CompanionStore!
    private var dialogs: ScriptedTransferDialogs!
    private var flow: SaveTransferFlow!
    private var applied = 0
    private var usage = SaveImportTool.Usage.none

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-transfer-flow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var mine = CompanionState()
        mine.usedSinceInstall = 1234
        mine.dex = [DexEntry(baseID: 10, finalID: 12, chainOrder: [10, 11, 12], rarity: .common, caughtAt: now)]
        try JSONEncoder().encode(mine).write(to: stateFile)
        let defaults = TestDefaults.make(suite: "ptb.popover.transfer")
        companion = CompanionStore(provider: OfflineProvider(), clock: { self.now }, fileURL: stateFile, defaults: defaults)
        dialogs = ScriptedTransferDialogs()
        flow = SaveTransferFlow(companion: companion, usage: { self.usage }, dialogs: dialogs, appVersion: "2.5.613", deviceName: "This PC")
        flow.onApplied = { self.applied += 1 }
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func saveFile(_ name: String = "mac.json", dex: Int = 2, tokens: Int = 8_000_000_000) throws -> URL {
        var s = CompanionState()
        s.usedSinceInstall = tokens
        s.dex = (0..<dex).map { DexEntry(baseID: 1 + $0 * 3, finalID: 3 + $0 * 3, chainOrder: [1 + $0 * 3, 3 + $0 * 3], rarity: .common, caughtAt: now) }
        let url = dir.appendingPathComponent(name)
        try SaveTransfer.encode(state: s, appVersion: "2.5.0", deviceName: "Old Mac", now: now).write(to: url)
        return url
    }

    private func backups() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(SaveTransfer.backupFilePrefix) }
    }

    /// Nothing about the current companion changed: the summary, the file on disk and no backup written.
    private func assertUntouched(_ before: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(companion.transferSummary, SaveSummary(state: try JSONDecoder().decode(CompanionState.self, from: before)), file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: stateFile), before, "the state file is unchanged", file: file, line: line)
        XCTAssertEqual(try backups(), [], "no backup was needed, none written", file: file, line: line)
        XCTAssertEqual(applied, 0, file: file, line: line)
    }

    // MARK: export

    func testExportWritesTheSaveAndRevealsIt() async throws {
        let target = dir.appendingPathComponent("my save – 한글 폴더 \u{1F600}.json")
        dialogs.saveAnswer = target
        XCTAssertEqual(flow.export(), .done)
        XCTAssertEqual(dialogs.asked, ["save:\(companion.l.exportSaveLabel)"])
        XCTAssertEqual(dialogs.savedSuggestions, [companion.suggestedExportFileName], "the dialog starts from the Mac's suggested name")
        XCTAssertEqual(dialogs.revealed, [target])
        XCTAssertTrue(dialogs.informs.isEmpty)
        let envelope = try SaveTransfer.decode(try Data(contentsOf: target))
        XCTAssertEqual(SaveSummary(state: envelope.state), companion.transferSummary)
        XCTAssertEqual(envelope.sourceDevice, "This PC")
        XCTAssertEqual(envelope.appVersion, "2.5.613")
    }

    func testCancellingTheSaveDialogDoesNothing() async throws {
        dialogs.saveAnswer = nil
        XCTAssertEqual(flow.export(), .cancelled)
        XCTAssertEqual(dialogs.asked.count, 1)
        XCTAssertTrue(dialogs.revealed.isEmpty)
        XCTAssertTrue(dialogs.informs.isEmpty)
    }

    /// The destination cannot be written (a path under a file): the error is shown, the other file is untouched, nothing reveals.
    func testAnExportThatCannotBeWrittenShowsTheErrorAndLeavesNoFile() async throws {
        let blocker = dir.appendingPathComponent("blocker")
        try Data("KEEP".utf8).write(to: blocker)
        dialogs.saveAnswer = blocker.appendingPathComponent("save.json")
        XCTAssertEqual(flow.export(), .failed)
        XCTAssertEqual(dialogs.informs.count, 1)
        XCTAssertTrue(dialogs.informs[0].isError)
        XCTAssertEqual(dialogs.informs[0].title, companion.l.exportSaveLabel)
        XCTAssertTrue(dialogs.revealed.isEmpty)
        XCTAssertEqual(try Data(contentsOf: blocker), Data("KEEP".utf8))
    }

    // MARK: import

    func testImportReplacesTheStateAfterTheConfirmationWithBothSummaries() async throws {
        let file = try saveFile(dex: 3, tokens: 8_000_000_000)
        let before = try Data(contentsOf: stateFile)
        dialogs.openAnswer = file
        dialogs.confirmAnswer = true
        usage = SaveImportTool.Usage(todayTokensByProvider: ["claude_code": 5_000], todayDate: "2026-11-16", hasUsageData: true)
        XCTAssertEqual(flow.importSave(), .done)

        let l = companion.l
        XCTAssertEqual(dialogs.asked, ["open:\(l.importSaveLabel)", "confirm", "inform"])
        let confirm = try XCTUnwrap(dialogs.confirms.first)
        XCTAssertEqual(confirm.title, l.winImportConfirmTitle)
        XCTAssertEqual(confirm.confirm, l.importConfirmReplace)
        XCTAssertEqual(confirm.cancel, l.cancel)
        XCTAssertTrue(confirm.message.contains(TokenFormatter.compact(8_000_000_000)), "the incoming save's tokens: \(confirm.message)")
        XCTAssertTrue(confirm.message.contains(TokenFormatter.compact(1234)), "this device's current tokens: \(confirm.message)")
        XCTAssertTrue(confirm.message.contains("Old Mac"), "the device it came from")
        XCTAssertFalse(confirm.message.contains("Mac's") || confirm.message.contains("this Mac"), "Windows says this PC: \(confirm.message)")

        XCTAssertEqual(companion.state.dex.count, 3)
        XCTAssertEqual(companion.state.usedSinceInstall, 8_000_000_000)
        XCTAssertEqual(applied, 1)
        XCTAssertEqual(try backups(), [SaveTransfer.backupFileName(date: now)])
        let backup = try Data(contentsOf: dir.appendingPathComponent(SaveTransfer.backupFileName(date: now)))
        XCTAssertEqual(try JSONDecoder().decode(CompanionState.self, from: backup).usedSinceInstall, 1234, "the previous state is what was backed up")
        XCTAssertNotEqual(try Data(contentsOf: stateFile), before)
        let done = try XCTUnwrap(dialogs.informs.first)
        XCTAssertFalse(done.isError)
        XCTAssertEqual(done.message, l.importSaveDone(dex: 3, tokens: TokenFormatter.compact(8_000_000_000)))
        // The running app's usage numbers were applied (the Mac passes them): this device's baseline is set from them.
        XCTAssertTrue(companion.state.installBaselineSet)
        XCTAssertEqual(companion.state.claimedTodayTokensByProvider, ["claude_code": 5_000])
        XCTAssertEqual(companion.state.lastDate, "2026-11-16")
    }

    func testImportWithoutUsageDataLeavesTheBaselineForTheNextUpdate() async throws {
        dialogs.openAnswer = try saveFile()
        dialogs.confirmAnswer = true
        usage = .none
        XCTAssertEqual(flow.importSave(), .done)
        XCTAssertFalse(companion.state.installBaselineSet)
    }

    func testCancellingTheOpenDialogOrTheConfirmationChangesNothing() async throws {
        let before = try Data(contentsOf: stateFile)
        dialogs.openAnswer = nil
        XCTAssertEqual(flow.importSave(), .cancelled)
        XCTAssertEqual(dialogs.asked.count, 1)
        try assertUntouched(before)

        dialogs.openAnswer = try saveFile()
        dialogs.confirmAnswer = false
        XCTAssertEqual(flow.importSave(), .cancelled)
        XCTAssertTrue(dialogs.informs.isEmpty, "a cancel shows no message")
        try assertUntouched(before)
    }

    /// A wrong, too large, newer or unreadable file shows the Mac's message and never reaches the confirmation.
    func testRefusedFilesShowTheMacsMessageAndChangeNothing() async throws {
        let before = try Data(contentsOf: stateFile)
        let l = companion.l
        let wrong = dir.appendingPathComponent("wrong.json")
        try Data(#"{"hello":"world"}"#.utf8).write(to: wrong)
        let big = dir.appendingPathComponent("big.json")
        try Data(count: SaveTransfer.maxFileBytes + 1).write(to: big)
        let newer = dir.appendingPathComponent("newer.json")
        try Data(#"{"format":"poketokenbar.save","schema":999,"appVersion":"9.0.0","exportedAt":"2026-01-01T00:00:00Z","sourceDevice":"Future","state":{"unknown":1}}"#.utf8).write(to: newer)
        let missing = dir.appendingPathComponent("missing.json")
        let cases: [(URL, String)] = [(wrong, l.importErrorNotSaveFile), (big, l.importErrorTooLarge), (newer, l.importErrorNewerSchema),
                                      (missing, l.userFacingError(CocoaError(.fileReadNoSuchFile)))]
        for (file, message) in cases {
            dialogs.openAnswer = file
            XCTAssertEqual(flow.importSave(), .failed, file.lastPathComponent)
            XCTAssertEqual(dialogs.informs.last?.title, l.importSaveLabel)
            XCTAssertEqual(dialogs.informs.last?.isError, true)
            if file != missing { XCTAssertEqual(dialogs.informs.last?.message, message, file.lastPathComponent) }
            try assertUntouched(before)
        }
        XCTAssertTrue(dialogs.confirms.isEmpty, "none of them reached the confirmation")
    }

    /// The code refuses to replace the state when the backup cannot be written (the confirmation promises one).
    func testImportDoesNotApplyWhenTheBackupCannotBeWritten() async throws {
        let file = try saveFile()
        // The backup is named by the clock; a directory of that name makes the write fail.
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(SaveTransfer.backupFileName(date: now)), withIntermediateDirectories: true)
        let before = try Data(contentsOf: stateFile)
        dialogs.openAnswer = file
        dialogs.confirmAnswer = true
        XCTAssertEqual(flow.importSave(), .failed)
        XCTAssertEqual(dialogs.informs.last?.message, companion.l.importErrorBackupFailed)
        XCTAssertEqual(try Data(contentsOf: stateFile), before)
        XCTAssertEqual(companion.state.usedSinceInstall, 1234)
        XCTAssertEqual(applied, 0)
    }

    // MARK: export -> import round trip

    func testAnExportedSaveImportsBackWithTheSameSummary() async throws {
        let target = dir.appendingPathComponent("round trip.json")
        dialogs.saveAnswer = target
        XCTAssertEqual(flow.export(), .done)
        let exported = companion.transferSummary
        // Another state on this device, then the exported file is imported over it.
        dialogs.openAnswer = try saveFile("other.json", dex: 5, tokens: 99)
        dialogs.confirmAnswer = true
        XCTAssertEqual(flow.importSave(), .done)
        XCTAssertEqual(companion.transferSummary, SaveSummary(state: companion.state))
        XCTAssertNotEqual(companion.transferSummary, exported)
        dialogs.openAnswer = target
        XCTAssertEqual(flow.importSave(), .done)
        XCTAssertEqual(companion.transferSummary, exported)
    }

    // MARK: snapshots

    func testCreateSnapshotAnnouncesIt() async throws {
        XCTAssertEqual(flow.createSnapshot(), .done)
        XCTAssertEqual(dialogs.informs.last?.message, companion.l.snapshotCreatedToast)
        XCTAssertEqual(companion.availableSnapshots.count, 1)
    }

    func testRestoreAsksFirstThenReplacesAndTheCancelKeepsTheState() async throws {
        _ = try companion.createManualSnapshot(now: now)
        let snapshot = try XCTUnwrap(companion.availableSnapshots.first)
        // Another state, so a restore is a change.
        dialogs.openAnswer = try saveFile(dex: 4, tokens: 777)
        dialogs.confirmAnswer = true
        XCTAssertEqual(flow.importSave(), .done)
        XCTAssertEqual(companion.state.dex.count, 4)

        let l = companion.l
        dialogs.confirmAnswer = false
        XCTAssertEqual(flow.restore(snapshot), .cancelled)
        XCTAssertEqual(companion.state.dex.count, 4, "cancelled: nothing restored")
        XCTAssertEqual(dialogs.confirms.last?.title, l.restoreConfirmTitle)
        XCTAssertEqual(dialogs.confirms.last?.confirm, l.restoreSnapshotButton)

        dialogs.confirmAnswer = true
        XCTAssertEqual(flow.restore(snapshot), .done)
        XCTAssertEqual(companion.state.dex.count, 1)
        XCTAssertEqual(companion.state.usedSinceInstall, 1234)
        XCTAssertEqual(dialogs.informs.last?.message, l.restoreDoneMessage(dex: 1, tokens: TokenFormatter.compact(1234)))
    }
}

/// The Windows wording of the three strings that name "this Mac": every language, and no Mac in it.
final class PopoverTransferStringsTests: XCTestCase {
    func testTheWindowsImportWordingNamesNoMac() {
        for lang in AppLanguage.allCases {
            let l = L(lang)
            let all = [l.winImportConfirmTitle, l.winImportSaveHint,
                       l.winImportConfirmBody(incomingDex: 1, incomingTokens: "2", exportedAt: "3", sourceDevice: "4", currentDex: 5, currentTokens: "6"),
                       l.winSaveFileFilterName]
            for text in all {
                XCTAssertFalse(text.contains("Mac"), "\(lang): \(text)")
                XCTAssertFalse(text.contains("macOS") || text.contains("Finder"), "\(lang): \(text)")
            }
            if lang != .en { XCTAssertNotEqual(l.winImportConfirmTitle, L(.en).winImportConfirmTitle, "\(lang) is translated") }
            // Same facts as the Mac's text: every number the Mac's body shows is in the Windows one.
            let body = l.winImportConfirmBody(incomingDex: 111, incomingTokens: "222", exportedAt: "333", sourceDevice: "444", currentDex: 555, currentTokens: "666")
            for n in ["111", "222", "333", "444", "555", "666"] { XCTAssertTrue(body.contains(n), "\(lang) body lacks \(n)") }
            let mac = l.importConfirmBody(incomingDex: 111, incomingTokens: "222", exportedAt: "333", sourceDevice: "444", currentDex: 555, currentTokens: "666")
            XCTAssertEqual(body.split(separator: "\n").count, mac.split(separator: "\n").count, "\(lang): same lines as the Mac's")
        }
    }
}
