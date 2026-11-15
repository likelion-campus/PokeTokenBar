import Foundation

/// Pure decisions about the user's language on Windows, kept in shared code so the Mac tests them too.
enum UILanguages {
    /// The preferred-language list: the display-language list when it has entries, else the user locale name alone,
    /// else empty. Blank entries are dropped. Order is kept: the Mac reads only the FIRST entry and so does the app.
    static func resolve(ui: [String], localeName: String?) -> [String] {
        let list = ui.filter { !$0.isEmpty }
        if !list.isEmpty { return list }
        if let localeName, !localeName.isEmpty { return [localeName] }
        return []
    }

    /// A one-time correction for a Windows install that started before the language was detected there: its saved state
    /// holds "en" that no one chose (the Windows app has no language setting yet). Returns the language to save, or nil
    /// to leave things alone. Runs once (`alreadyMigrated`), so a later explicit choice is never overwritten.
    static func migratedLanguage(stored: AppLanguage, detected: AppLanguage, alreadyMigrated: Bool) -> AppLanguage? {
        guard !alreadyMigrated, stored == .en, detected != .en else { return nil }
        return detected
    }
}
