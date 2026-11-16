import Foundation

/// The logic of `PokeTokenBar.exe --import-save <file>`: applies a save exported from the Mac app (Settings -> Backup &
/// Transfer -> export) to this PC, for a PC without AI-tool usage whose companion would stay an egg. Shared (and so
/// unit-tested on both systems) while the Windows app has no settings UI; stage 7 Task 15's Backup & Transfer page
/// reuses `run` instead of writing a second import path.
///
/// It is the Mac's import (`SettingsView.importSave`) minus the confirmation dialog: `SaveTransfer.decode` (size cap,
/// validation, lenient decoding), then `CompanionStore.applySave` (back up the current state to
/// `companion-state.pre-import-<time>.json` next to it, rebase for this device, save). Differences, on purpose:
/// - The usage numbers: the Mac passes its live `UsageStore` values. A one-shot tool does not parse the logs, so it passes
///   "no usage data yet" (`[:]`, today `""`, `hasUsageData: false`) - exactly the branch `rebasedForThisDevice` takes on
///   the Mac before its first parse: the install baseline is left unset and the app's first normal update seeds it, so
///   today's usage on this PC is not credited retroactively.
/// - No network: the companion's evolution line is loaded by the app at its next start.
/// Team settings (code, nickname, member id) live in the app's defaults, not in the save; the import never touches them.
/// Nothing secret is in a save and nothing but species, level, Pokedex count and the backup path is printed.
/// Exit codes: 0 applied, 2 bad argument or bad file, 3 the app is running, 4 could not back up or apply.
enum SaveImportTool {
    struct Result: Equatable {
        var exitCode: Int32
        var line: String
    }

    /// `makeDefaults` runs only once the file is valid: a failure before that touches nothing, not even the settings guard.
    @MainActor static func run(path: String?, stateDirectory: URL, appIsRunning: () -> Bool,
                               makeDefaults: () -> UserDefaults, now: @escaping () -> Date = Date.init) -> Result {
        if appIsRunning() {
            return Result(exitCode: 3, line: "PokeTokenBar is running: quit it from the tray menu first, then run this again")
        }
        guard let path, !path.isEmpty, !path.hasPrefix("--") else {
            return Result(exitCode: 2, line: "usage: PokeTokenBar.exe --import-save <file exported from the Mac app>")
        }
        let file = URL(fileURLWithPath: path)
        let envelope: SaveEnvelope
        do {
            let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
            if size > SaveTransfer.maxFileBytes { throw SaveTransferError.fileTooLarge(bytes: size, limit: SaveTransfer.maxFileBytes) }
            envelope = try SaveTransfer.decode(try Data(contentsOf: file))
        } catch SaveTransferError.fileTooLarge(let bytes, let limit) {
            return Result(exitCode: 2, line: "not imported: the file is too large for a save (\(bytes) bytes, limit \(limit))")
        } catch SaveTransferError.newerSchema {
            return Result(exitCode: 2, line: "not imported: this save was made by a newer version of PokeTokenBar; update this app first")
        } catch SaveTransferError.notASaveFile {
            return Result(exitCode: 2, line: "not imported: the file is not a PokeTokenBar save")
        } catch {
            return Result(exitCode: 2, line: "not imported: cannot read \(file.path)")
        }

        let stateFile = stateDirectory.appendingPathComponent("companion-state.json")
        let store = CompanionStore(provider: NoNetworkProvider(), clock: now, fileURL: stateFile, defaults: makeDefaults())
        let backup = stateDirectory.appendingPathComponent(SaveTransfer.backupFileName(date: now()))
        do {
            try store.applySave(envelope, todayTokensByProvider: [:], todayDate: "", hasUsageData: false)
        } catch SaveTransferError.backupFailed {
            return Result(exitCode: 4, line: "not imported: the current state could not be backed up, so nothing was changed")
        } catch {
            return Result(exitCode: 4, line: "not imported: \(error)")
        }
        let state = store.state
        let who: String
        if let active = state.active {
            let id = active.currentID
            let name = state.dex.lazy.compactMap { $0.names?[id] }.compactMap { state.language.resolveName($0) }.first ?? "#\(id)"
            who = active.profile.map { "\(name) Lv\($0.level)" } ?? name
        } else {
            who = "egg"
        }
        return Result(exitCode: 0, line: "imported: companion \(who), \(state.dex.count) Pokedex entries, previous state backed up to \(backup.path)")
    }

    /// The tool never fetches: the app loads the evolution line itself at its next start.
    private struct NoNetworkProvider: PokeProviding {
        struct Offline: Error {}
        func line(baseSpeciesID: Int) async throws -> EvoLine { throw Offline() }
        func baseSpeciesIndex() async throws -> [BaseSpecies] { throw Offline() }
        func baseSpecies(id: Int) async throws -> BaseSpecies? { throw Offline() }
    }
}
