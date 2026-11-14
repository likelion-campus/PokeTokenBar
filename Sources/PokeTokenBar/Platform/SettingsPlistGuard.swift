import Foundation

/// Keeps the Windows settings plists from being lost. On Windows CoreFoundation writes a plist in place (no temporary
/// file, no rename: `CFURLWriteDataAndPropertiesToResource`), and when the file does not parse it retries three times and
/// then silently uses an EMPTY dictionary, so the next sync writes back only the changed keys: a kill or power cut during
/// a write can wipe every setting and `team.memberID`. The guard keeps a verified copy (`<plist>.bak`, written with
/// `PlatformCompat.atomicWrite`) and restores it at launch before the first read. Pure file logic, tested on both OSes.
enum SettingsPlistGuard {
    enum Outcome: Equatable {
        case untouched      // the plist parses (an older backup never replaces it)
        case restored       // missing or unreadable, the backup came back
        case startsClean    // unreadable and no usable backup: CF will start from an empty dictionary
        case nothing        // no plist and no backup: a first run
    }

    static func backupURL(for plist: URL) -> URL { URL(fileURLWithPath: plist.path + ".bak") }

    /// A property list whose root is a dictionary: what CF accepts.
    static func parses(_ data: Data) -> Bool {
        guard !data.isEmpty,
              let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return false }
        return root is [String: Any]
    }

    static func restoreIfNeeded(plist: URL, log: (String) -> Void) -> Outcome {
        let backup = backupURL(for: plist)
        let current = try? Data(contentsOf: plist)
        if let current, parses(current) { return .untouched }
        let saved = try? Data(contentsOf: backup)
        let usable = saved.map(parses) ?? false
        if usable, let saved {
            do {
                try PlatformCompat.atomicWrite(saved, to: plist)
                log("settings plist \(plist.lastPathComponent) was \(current == nil ? "missing" : "unreadable"): restored from its backup")
                return .restored
            } catch {
                log("settings plist \(plist.lastPathComponent): restoring the backup failed: \(error)")
            }
        }
        if current != nil {
            log("settings plist \(plist.lastPathComponent) is unreadable and has no usable backup: starting with empty settings")
            return .startsClean
        }
        return .nothing
    }

    /// Copies the plist to its backup when (and only when) it parses. False: nothing copied.
    @discardableResult
    static func backUpIfValid(plist: URL) -> Bool {
        guard let data = try? Data(contentsOf: plist), parses(data) else { return false }
        return (try? PlatformCompat.atomicWrite(data, to: backupURL(for: plist))) != nil
    }
}
