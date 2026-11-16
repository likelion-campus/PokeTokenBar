import Foundation

/// The dialogs the Backup & transfer flows use (stage 7 Task 15, D17). The Windows page implements them with the common file
/// dialogs and task dialogs; the tests with a script, so every flow (a wrong file, cancelling at each step, a failed write)
/// is checked on both systems without a person to click.
@MainActor protocol TransferDialogs: AnyObject {
    /// The save dialog: where to write, nil when cancelled.
    func chooseSaveFile(title: String, suggestedName: String) -> URL?
    /// The open dialog: which file to read, nil when cancelled.
    func chooseOpenFile(title: String) -> URL?
    /// A confirmation of a destructive step: true only when the user pressed `confirmTitle`. Cancel is the default button
    /// (Enter and Esc cancel; `ImportConfirmPolicy`'s rule: one key must not replace progress).
    func confirm(title: String, message: String, confirmTitle: String, cancelTitle: String) -> Bool
    /// A result or an error, with one close button.
    func inform(title: String, message: String, isError: Bool)
    /// Shows the file in the file manager.
    func reveal(_ file: URL)
}

/// Export, import, snapshots: the Mac's `SettingsView` flows (export / import / takeManualSnapshot /
/// confirmAndRestoreSnapshot) over `TransferDialogs`, with the same steps in the same order and the same wording, except
/// where the Mac says "this Mac" (`winImportConfirmTitle`, `winImportConfirmBody`). Import goes through
/// `SaveImportTool.readSave` and `SaveImportTool.apply`, the functions the `--import-save` command uses.
///
/// Every step that can fail leaves the current state alone: a file that cannot be read, is too large, is not a save or comes
/// from a newer version is refused before the confirmation; the apply backs the current state up first and does nothing when
/// it cannot (`SaveTransferError.backupFailed`); the export writes through `PlatformCompat.atomicWrite`, so a failed write
/// leaves no half file.
@MainActor final class SaveTransferFlow {
    enum Outcome: Equatable { case done, cancelled, failed }

    private let companion: CompanionStore
    private let usage: () -> SaveImportTool.Usage
    /// Replaceable so a test (the selftest, over the real page) can script the dialogs of a page that is already built.
    var dialogs: any TransferDialogs
    private let appVersion: String
    private let deviceName: String
    /// The imported or restored state is in the store (the page shows it at once).
    var onApplied: () -> Void = {}
    private var l: L { companion.l }

    /// `usage`: what the running app knows of today (`UsageStore.todayTokensByProvider`, `UsageStore.hasUsageData`, the day key),
    /// which `CompanionStore.applySave` rebases the imported state with, as the Mac's import does.
    init(companion: CompanionStore, usage: @escaping () -> SaveImportTool.Usage, dialogs: any TransferDialogs,
         appVersion: String, deviceName: String) {
        self.companion = companion
        self.usage = usage
        self.dialogs = dialogs
        self.appVersion = appVersion
        self.deviceName = deviceName
    }

    @discardableResult
    func export() -> Outcome {
        guard let url = dialogs.chooseSaveFile(title: l.exportSaveLabel, suggestedName: companion.suggestedExportFileName) else { return .cancelled }
        do {
            let data = try companion.exportedSaveData(appVersion: appVersion, deviceName: deviceName)
            try PlatformCompat.atomicWrite(data, to: url)
            dialogs.reveal(url)
            return .done
        } catch {
            AppLog.write("save export failed: \(error)")
            dialogs.inform(title: l.exportSaveLabel, message: l.userFacingError(error), isError: true)
            return .failed
        }
    }

    @discardableResult
    func importSave() -> Outcome {
        guard let url = dialogs.chooseOpenFile(title: l.importSaveLabel) else { return .cancelled }
        let envelope: SaveEnvelope
        do {
            envelope = try SaveImportTool.readSave(at: url)
        } catch {
            AppLog.write("save import read failed: \(error)")
            dialogs.inform(title: l.importSaveLabel, message: l.importErrorMessage(error), isError: true)
            return .failed
        }
        let incoming = SaveSummary(state: envelope.state)

        // 고른 즉시 덮어쓰지 않는다 — 무엇이 대체되는지 수치로 보여주고 한 번 더 확인받는다.
        let current = companion.transferSummary
        let body = l.winImportConfirmBody(
            incomingDex: incoming.dexCount,
            incomingTokens: TokenFormatter.compact(incoming.lifetimeTokens),
            exportedAt: PopoverTransferFormat.exportedAtText(envelope.exportedAt, language: companion.language),
            sourceDevice: envelope.sourceDevice,
            currentDex: current.dexCount,
            currentTokens: TokenFormatter.compact(current.lifetimeTokens))
        guard dialogs.confirm(title: l.winImportConfirmTitle, message: body, confirmTitle: l.importConfirmReplace, cancelTitle: l.cancel)
        else { return .cancelled }

        do {
            try SaveImportTool.apply(envelope, to: companion, usage: usage())
        } catch {
            AppLog.write("save import apply failed: \(error)")
            dialogs.inform(title: l.importSaveLabel, message: l.importErrorMessage(error), isError: true)
            return .failed
        }
        onApplied()
        dialogs.inform(title: l.importSaveLabel,
                       message: l.importSaveDone(dex: incoming.dexCount, tokens: TokenFormatter.compact(incoming.lifetimeTokens)),
                       isError: false)
        return .done
    }

    @discardableResult
    func createSnapshot() -> Outcome {
        do {
            try companion.createManualSnapshot()
            dialogs.inform(title: l.createSnapshotButton, message: l.snapshotCreatedToast, isError: false)
            return .done
        } catch {
            AppLog.write("manual snapshot creation failed: \(error)")
            dialogs.inform(title: l.createSnapshotButton, message: l.userFacingError(error), isError: true)
            return .failed
        }
    }

    @discardableResult
    func restore(_ snapshot: SaveSnapshot) -> Outcome {
        let current = companion.transferSummary
        let body = l.restoreConfirmBody(
            snapshotDate: PopoverTransferFormat.exportedAtText(snapshot.date, language: companion.language),
            snapshotDex: snapshot.dexCount,
            snapshotTokens: TokenFormatter.compact(snapshot.lifetimeTokens),
            currentDex: current.dexCount,
            currentTokens: TokenFormatter.compact(current.lifetimeTokens))
        guard dialogs.confirm(title: l.restoreConfirmTitle, message: body, confirmTitle: l.restoreSnapshotButton, cancelTitle: l.cancel)
        else { return .cancelled }
        do {
            let now = usage()
            try companion.restoreSnapshot(snapshot, todayTokensByProvider: now.todayTokensByProvider, todayDate: now.todayDate,
                                          hasUsageData: now.hasUsageData)
        } catch {
            AppLog.write("snapshot restore failed: \(error)")
            dialogs.inform(title: l.restoreSnapshotButton, message: l.importErrorMessage(error), isError: true)
            return .failed
        }
        onApplied()
        dialogs.inform(title: l.restoreSnapshotButton,
                       message: l.restoreDoneMessage(dex: snapshot.dexCount, tokens: TokenFormatter.compact(snapshot.lifetimeTokens)),
                       isError: false)
        return .done
    }
}

/// The 28 pt sprite of a snapshot row (G16): one still sprite slot over nothing, left to the host's sprite animator (a
/// missing picture shows the egg, as the Mac's `SpriteView(speciesID: nil)`).
@MainActor final class SnapshotSpritePart: PopoverPart {
    static let side: CGFloat = 28
    var onChange: (() -> Void)?
    private let subject: PlazaSpriteSubjectKey

    init(speciesID: Int?, shiny: Bool, form: PokemonForm?) {
        subject = PlazaSpriteSubjectKey(speciesID: speciesID, shiny: speciesID == nil ? false : shiny, form: speciesID == nil ? nil : form)
    }

    func size(width: CGFloat, scale: CGFloat, text: any PlazaTextEngine) -> CGSize { CGSize(width: Self.side, height: Self.side) }

    func render(scale: CGFloat, graphics: any PlazaGraphics) -> PopoverDrawing {
        PopoverDrawing(drawing: PlazaPanelDrawing(layers: [], accessibility: [], tooltips: []),
                       spriteSlots: [SpriteSlot(frame: CGRect(x: 0, y: 0, width: Self.side, height: Self.side), subject: subject, bob: false, animated: false)])
    }

    func hit(_ point: CGPoint) -> PlazaPanelHit? { nil }
}
